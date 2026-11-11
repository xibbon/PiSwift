import PiSwiftChord
import Synchronization
import Testing
@testable import PiSwiftDurable

private enum ObserverTestError: Error { case bug, disk }
private struct ObserverRecorder<Value: Sendable>: Sendable {
    let calls = SessionTestLog<WatchCall<Value>>()
    let ends = SessionTestLog<WatchEnd>()
    var observer: Observer<Value> {
        Observer(advance: { call, _ in calls.append(call) }, end: { ends.append($0) })
    }
}

// v1.5.2 CH3 session-observers.test.ts. Swift observers are synchronous throwing closures;
// a rejected JavaScript promise has no synchronous Swift equivalent. Deferred stores belong to D2.
@Suite(.timeLimit(.minutes(1))) struct SessionObserversTests {
    @Test("returns undefined for an absent address and attaches nothing") func absent() async throws {
        // upstream :77
        let h = try await openTestSession(); let token = try observationToken()
        let recorder = ObserverRecorder<ObservationValue>()
        #expect(try await h.session.observeDoc(token, observer: recorder.observer, context: .background) == nil)
        try await setObservation(1, h, token)
        #expect(recorder.calls.count == 0); #expect(h.session.documentCacheSizes.attached == 0)
        try await h.session.close(context: .background)
    }

    @Test("starts at the committed value and advances at the publication of each stored commit with its ops")
    func committedValue() async throws {
        // upstream :87. The log is read immediately after commit; no delivery worker is needed.
        let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
        let observation = try #require(try await h.session.observeDoc(token, observer: recorder.observer, context: .background))
        #expect(observation.value == .initial)
        try await setObservation(3, h, token)
        #expect(await h.storage.commits.count == 2)
        var expected = ObservationValue.initial; expected.value = 3
        #expect(recorder.calls.values == [.value(value: expected, ops: [.set(["value"], 3)], retired: false)])
        #expect(observation.value == .initial)
        observation.detach(); try await h.session.close(context: .background)
    }

    @Test("follows a conversation document's address: a retirement with the last value, then the new incarnation")
    func address() async throws {
        // upstream :132
        let h = try await openTestSession(); let id = try await createConversation(h.session)
        let token = try ConversationDocToken<JSONObject>(kind: "observer.address", version: 1, fork: .initial,
            initial: { ["count": 0] }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 2) }, context: .background)
        let recorder = ObserverRecorder<JSONObject>()
        let observation = try #require(try await h.session.observeDoc(token, conversationId: id, observer: recorder.observer, context: .background))
        try await h.session.commit({ tx in try await tx.retireDoc(token, conversationId: id) }, context: .background)
        #expect(try await h.session.observeDoc(token, conversationId: id, observer: recorder.observer, context: .background) == nil)
        #expect(h.session.documentCacheSizes.attached == 0)
        try await h.session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 9) }, context: .background)
        #expect(recorder.calls.values == [.value(value: observation.value, ops: [], retired: true),
            .value(value: ["count": 9], ops: [.replace(["count": 9])], retired: false)])
        #expect(h.session.documentCacheSizes.attached == 1)
        observation.detach(); try await h.session.close(context: .background)
    }

    @Test("gets nothing after detach, which is idempotent and unpins the document") func detach() async throws {
        // upstream :162
        let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
        let observation = try #require(try await h.session.observeDoc(token, observer: recorder.observer, context: .background))
        #expect(h.session.documentCacheSizes.attached == 1)
        observation.detach(); observation.detach()
        #expect(h.session.documentCacheSizes.attached == 0)
        try await setObservation(1, h, token); try await h.session.close(context: .background)
        #expect(recorder.calls.count == 0); #expect(recorder.ends.count == 0)
    }

    @Test("ends once when the Session closes: observer failed and watch ended") func close() async throws {
        // upstream :176,187. WatchFailure has value semantics, so error identity is not part of Swift's API.
        for _ in 0..<2 {
            let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
            _ = try await h.session.observeDoc(token, observer: recorder.observer, context: .background)
            let watch = try #require(try await h.session.watchDoc(token, context: .background))
            try await h.session.close(context: .background); try await h.session.close(context: .background)
            #expect(recorder.ends.values == [.failed(.message("session closed"))])
            #expect(await watch.closed == .ended)
        }
    }

    @Test("ends with the error that failed the Session") func storageFailure() async throws {
        // upstream :203 and :403, with the same source failure for watch and both observer kinds.
        let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
        let commitEnds = SessionTestLog<WatchEnd>()
        _ = try await h.session.observeDoc(token, observer: recorder.observer, context: .background)
        _ = try h.session.observeCommits(CommitObserver(advance: { _, _ in }, end: { commitEnds.append($0) }))
        let watch = try #require(try await h.session.watchDoc(token, context: .background))
        await h.storage.failNextCommit(ObserverTestError.disk)
        await #expect(throws: ObserverTestError.self) { try await setObservation(1, h, token) }
        _ = await h.session.closed
        let end = WatchEnd.failed(.message(String(describing: ObserverTestError.disk)))
        #expect(recorder.ends.values == [end]); #expect(commitEnds.values == [end]); #expect(await watch.closed == end)
    }

    @Test("reports a throwing observer, detaches it and ends it; the commit and other observers go on")
    func listenerFailure() async throws {
        // upstream :215
        let storage = ControlledStorage(); let reports = SessionTestLog<String>(); let infos = SessionTestLog<ReportInfo>()
        let session = try await Session.open(storage: storage, onReport: { error, info in
            reports.append(String(describing: error)); infos.append(info)
        }, context: .background)
        let token = try observationToken(); try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let ends = SessionTestLog<WatchEnd>(); let healthy = ObserverRecorder<ObservationValue>()
        _ = try await session.observeDoc(token, observer: Observer(advance: { _, _ in throw ObserverTestError.bug }, end: { ends.append($0) }), context: .background)
        _ = try await session.observeDoc(token, observer: healthy.observer, context: .background)
        for value in 1...2 { try await session.commit({ tx in try await tx.doc(token).set("value", .number(Double(value))) }, context: .background) }
        #expect(reports.values == ["bug"]); #expect(infos.values == [.listenerError])
        #expect(ends.values == [.listenerError("bug")]); #expect(healthy.calls.count == 2)
        #expect(session.failure == nil); #expect(try await session.snapshot(token, context: .background)?.value == 2)
        try await session.close(context: .background); #expect(ends.count == 1)
    }

    @Test("attaches atomically on the line: a commit queued before attachment is in its value") func atomicAttach() async throws {
        // upstream :241. A held store fixes admission order without a sleep.
        let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
        let gate = await h.storage.holdCommits()
        let commit = Task { try await setObservation(11, h, token) }
        await gate.waitUntilEntered()
        let attaching = Task { try await h.session.observeDoc(token, observer: recorder.observer, context: .background) }
        await gate.release(); try await commit.value
        let observation = try #require(try await attaching.value)
        #expect(observation.value.value == 11); #expect(recorder.calls.count == 0)
        observation.detach(); try await h.session.close(context: .background)
    }

    @Test("rejects a cancelled attachment and attaches nothing") func cancelled() async throws {
        // upstream :254, plus cancellation while loading.
        let (h, token) = try await createObservationState(); let recorder = ObserverRecorder<ObservationValue>()
        let caller = ChordContext.background.withCancel(); caller.cancel(ObserverTestError.bug)
        await #expect(throws: ObserverTestError.self) { _ = try await h.session.observeDoc(token, observer: recorder.observer, context: caller.context) }
        try await h.session.unloadDocuments(); let gate = await h.storage.holdFindDocument()
        let loading = ChordContext.background.withCancel()
        let attaching = Task { try await h.session.observeDoc(token, observer: recorder.observer, context: loading.context) }
        await gate.waitUntilEntered(); loading.cancel(ObserverTestError.bug); await gate.release()
        await #expect(throws: ObserverTestError.self) { _ = try await attaching.value }
        #expect(h.session.documentCacheSizes.attached == 0); try await h.session.close(context: .background)
    }

    @Test("rejects on a closed Session") func closedAdmission() async throws {
        // upstream :296. Scope IDs are nonoptional Swift arguments.
        let h = try await openTestSession(); let token = try observationToken()
        try await h.session.close(context: .background)
        await #expect(throws: SessionError.closed) { _ = try await h.session.observeDoc(token, observer: ObserverRecorder<ObservationValue>().observer, context: .background) }
    }

    @Test("gets every stored commit then failed after its last publication") func commitCloseOrder() async throws {
        // upstream :389. Close can seal admission while a commit is already in storage.
        let (h, token) = try await createObservationState(); let events = SessionTestLog<String>()
        _ = try h.session.observeCommits(CommitObserver(advance: { _, _ in events.append("commit") }, end: { end in
            #expect(end == .failed(.message("session closed"))); events.append("end")
        }))
        try await setObservation(1, h, token)
        let gate = await h.storage.holdCommits(); let committing = Task { try await setObservation(2, h, token) }
        await gate.waitUntilEntered(); let sealed = SessionTestGate()
        _ = try h.session.subscribeClose { sealed.release() }
        let closing = Task { try await h.session.close(context: .background) }
        await sealed.wait(); #expect(events.values == ["commit"])
        await gate.release(); try await committing.value; try await closing.value
        #expect(events.values == ["commit", "commit", "end"])
    }

    @Test("commit observers get nothing after detach, not even their end") func commitDetach() async throws {
        // upstream :414
        let (h, token) = try await createObservationState(); let calls = SessionTestLog<Int>()
        let observation = try h.session.observeCommits(CommitObserver(advance: { _, _ in calls.append(1) }, end: { _ in calls.append(2) }))
        try await setObservation(1, h, token); observation.detach(); observation.detach()
        try await setObservation(2, h, token); try await h.session.close(context: .background)
        #expect(calls.values == [1])
    }

    @Test("reports a throwing commit observer and the others go on") func commitFailureIsolation() async throws {
        // upstream :427
        let reports = SessionTestLog<String>(); let storage = ControlledStorage()
        let session = try await Session.open(storage: storage, onReport: { reports.append(String(describing: $0)) }, context: .background)
        let ends = SessionTestLog<WatchEnd>(); let healthy = SessionTestLog<Int>()
        _ = try session.observeCommits(CommitObserver(advance: { _, _ in throw ObserverTestError.bug }, end: { ends.append($0) }))
        _ = try session.observeCommits(CommitObserver(advance: { _, _ in healthy.append(1) }, end: { _ in }))
        let token = try observationToken()
        for value in 1...2 { try await session.commit({ tx in try await tx.doc(token).set("value", .number(Double(value))) }, context: .background) }
        #expect(reports.values == ["bug"]); #expect(ends.values == [.listenerError("bug")]); #expect(healthy.count == 2)
        try await session.close(context: .background); #expect(ends.count == 1)
    }

    @Test("gets nothing more of a commit after throwing or detaching on retirement", arguments: [true, false])
    func detachDuringRetirement(throwing: Bool) async throws {
        // upstream :469 and :496
        let (h, token) = try await createObservationState(); let calls = SessionTestLog<WatchCall<ObservationValue>>()
        let ends = SessionTestLog<WatchEnd>(); let attached = Mutex<Observation<ObservationValue>?>(nil)
        let observation = try #require(try await h.session.observeDoc(token, observer: Observer(advance: { call, _ in
            calls.append(call)
            if throwing { throw ObserverTestError.bug }
            attached.withLock { $0 }?.detach()
        }, end: { ends.append($0) }), context: .background))
        attached.withLock { $0 = observation }
        try await h.session.commit({ tx in try await tx.retireDoc(token); try await tx.doc(token).set("value", 2) }, context: .background)
        #expect(calls.values == [.value(value: .initial, ops: [], retired: true)])
        #expect(ends.values == (throwing ? [.listenerError("bug")] : []))
        #expect(h.session.documentCacheSizes.attached == 0)
        observation.detach(); try await h.session.close(context: .background)
    }

    @Test("gets nothing when another observer detaches it first") func anotherObserverDetaches() async throws {
        // upstream :520
        let (h, token) = try await createObservationState(); let second = Mutex<Observation<ObservationValue>?>(nil)
        let first = try #require(try await h.session.observeDoc(token, observer: Observer(advance: { _, _ in second.withLock { $0 }?.detach() }, end: { _ in }), context: .background))
        let recorder = ObserverRecorder<ObservationValue>()
        let observation = try await h.session.observeDoc(token, observer: recorder.observer, context: .background)
        second.withLock { $0 = observation }
        try await h.session.commit({ tx in try await tx.retireDoc(token); try await tx.doc(token).set("value", 2) }, context: .background)
        #expect(recorder.calls.count == 0); #expect(recorder.ends.count == 0)
        first.detach(); #expect(h.session.documentCacheSizes.attached == 0)
        try await h.session.close(context: .background)
    }
}
