import PiSwiftChord
import Synchronization
import Testing
@testable import PiSwiftDurable

struct ObservationValue: Codable, Sendable, Equatable {
    struct Retained: Codable, Sendable, Equatable { var label: String }
    var value: Int
    var items: [String]
    var retained: Retained
    static let initial = ObservationValue(value: 0, items: ["a", "b"], retained: Retained(label: "stable"))
}
func observationToken(kind: String = "watch.state") throws -> SessionDocToken<ObservationValue> {
    try SessionDocToken(kind: kind, version: 1, initial: { .initial })
}
func createObservationState() async throws -> (SessionTestHarness, SessionDocToken<ObservationValue>) {
    let harness = try await openTestSession()
    let token = try observationToken()
    try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
    return (harness, token)
}
func setObservation(_ value: Int, _ harness: SessionTestHarness, _ token: SessionDocToken<ObservationValue>, context: ChordContext = .background) async throws {
    try await harness.session.commit({ tx in try await tx.doc(token).set("value", .number(Double(value))) }, context: context)
}
struct ObservationFrame: Sendable, Equatable { let value: ObservationValue?; let ops: [Delta.Op] }
enum ObservationFailure: Error, Equatable { case acquisition, listener }

@Suite struct SessionWatchTests {
    @Test("never creates an absent document") func absent() async throws {
        let harness = try await openTestSession(); let token = try observationToken()
        #expect(try await harness.session.watchDoc(token, context: .background) == nil)
        #expect(await harness.storage.commits.isEmpty); #expect(await harness.storage.mintCount == 0)
    }

    @Test("keeps the acquisition revision until start and delivers exact committed frames") func acquisitionAndExactFrames() async throws {
        let (harness, token) = try await createObservationState()
        let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let initial = watch.value
        try await setObservation(1, harness, token); let first = documentChanges(try #require(harness.publications.values.last))[0]
        try await setObservation(2, harness, token); let second = documentChanges(try #require(harness.publications.values.last))[0]
        #expect(watch.value == initial)
        let log = SessionTestLog<ObservationFrame>()
        // A synchronous re-entry would deadlock on this mutex.
        let startLock = Mutex(false)
        try startLock.withLock { started in
            try watch.start { value, ops, _ in
                #expect(startLock.withLock { $0 }); #expect(watch.value == value)
                log.append(ObservationFrame(value: value, ops: ops))
            }
            started = true
        }
        await watch.waitUntilIdle()
        #expect(log.values.map { $0.value?.value } == [1, 2]); #expect(log.values.map(\.ops) == [first.ops, second.ops])
        #expect(initial?.value == 0); _ = await watch.stop()
    }

    @Test("serializes callbacks and buffers exact frames committed while one is in flight") func serialDelivery() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background))
        let entered = SessionTestGate(); let release = SessionTestGate(); let values = SessionTestLog<Int>(); let counts = Mutex((active: 0, maximum: 0))
        try watch.start { value, _, _ in
            counts.withLock { $0.active += 1; $0.maximum = max($0.maximum, $0.active) }; values.append(value?.value ?? -1)
            if values.count == 1 { entered.release(); await release.wait() }
            counts.withLock { $0.active -= 1 }
        }
        try await setObservation(1, harness, token); await entered.wait()
        for value in 2...20 { try await setObservation(value, harness, token) }
        #expect(values.values == [1]); release.release(); await watch.waitUntilIdle()
        #expect(counts.withLock { $0.maximum } == 1); #expect(values.values == Array(1...20)); _ = await watch.stop()
    }

    @Test("allows a listener to initiate a later Session commit") func listenerCommit() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let values = SessionTestLog<Int>(); let completed = SessionTestGate()
        try watch.start { value, _, _ in
            values.append(value?.value ?? -1)
            if value?.value == 1 { try await setObservation(2, harness, token) } else { completed.release() }
        }
        try await setObservation(1, harness, token); await completed.wait(); await watch.waitUntilIdle()
        #expect(values.values == [1, 2]); _ = await watch.stop()
    }

    @Test("collapses 101 pending commits to one root replacement") func overflowBeforeStart() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background))
        for value in 1...101 { try await setObservation(value, harness, token) }
        let log = SessionTestLog<ObservationFrame>(); try watch.start { value, ops, _ in log.append(.init(value: value, ops: ops)) }; await watch.waitUntilIdle()
        #expect(log.count == 1); #expect(log.values.first?.value?.value == 101)
        #expect(log.values.first?.ops == [.replace(.object(try #require(documentChanges(harness.publications.values.last!).first?.value)))]); _ = await watch.stop()
    }

    @Test("never folds the in-flight frame into an overflow reset") func overflowInFlight() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let entered = SessionTestGate(); let release = SessionTestGate(); let log = SessionTestLog<ObservationFrame>()
        try watch.start { value, ops, _ in log.append(.init(value: value, ops: ops)); if log.count == 1 { entered.release(); await release.wait() } }
        try await setObservation(1, harness, token); await entered.wait(); let firstOps = documentChanges(harness.publications.values.last!)[0].ops
        for value in 2...102 { try await setObservation(value, harness, token) }
        release.release(); await watch.waitUntilIdle()
        #expect(log.values.map { $0.value?.value } == [1, 102]); #expect(log.values[0].ops == firstOps)
        #expect(log.values[1].ops == [.replace(.object(documentChanges(harness.publications.values.last!)[0].value!))]); _ = await watch.stop()
    }

    @Test("folds retirement into an overflow reset and then closes") func overflowRetirement() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background))
        for value in 1...100 { try await setObservation(value, harness, token) }
        try await harness.session.commit({ tx in try await tx.retireDoc(token) }, context: .background)
        let log = SessionTestLog<ObservationFrame>(); try watch.start { value, ops, _ in log.append(.init(value: value, ops: ops)) }
        guard case .retired = await watch.closed else { Issue.record("Expected retirement"); return }
        #expect(log.values == [.init(value: nil, ops: [.replace(nil)])])
    }

    @Test("delivers replayable structural no-op commits instead of suppressing them") func structuralNoOp() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let initial = watch.value
        try await harness.session.commit({ tx in let items = try await tx.doc(token).child("items")!; let first = try items.popFirst()!; try items.prepend(contentsOf: [first]) }, context: .background)
        let log = SessionTestLog<ObservationFrame>(); try watch.start { value, ops, _ in log.append(.init(value: value, ops: ops)) }; await watch.waitUntilIdle()
        #expect(log.count == 1); #expect(log.values[0].value == initial); #expect(!log.values[0].ops.isEmpty); _ = await watch.stop()
    }

    @Test("preserves commit Context values without inheriting producer cancellation") func frameContext() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background))
        let key = ChordContextKey<String>("watch-test"); let producer = ChordContext.background.withCancel(); let context = producer.context.withValue("newest-commit", for: key)
        let entered = SessionTestGate(); let release = SessionTestGate(); let delivered = SessionTestLog<ChordContext>()
        try watch.start { _, _, context in delivered.append(context); entered.release(); await release.wait() }
        try await setObservation(1, harness, token, context: context); await entered.wait()
        #expect(delivered.values[0].value(key) == "newest-commit"); #expect(delivered.values[0].abortSignal == nil)
        producer.cancel(); guard case .stopped = await watch.stop() else { Issue.record("Expected stop"); return }
        #expect(delivered.values[0].abortSignal == nil); release.release(); await watch.waitUntilIdle()
    }

    @Test("keeps earlier immutable revisions stable") func oldRevisions() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let initial = watch.value
        let log = SessionTestLog<ObservationValue?>(); try watch.start { value, _, _ in log.append(value) }
        try await setObservation(1, harness, token); await watch.waitUntilIdle()
        #expect(log.values[0] == watch.value); #expect(log.values[0]?.retained == initial?.retained); #expect(initial?.value == 0); _ = await watch.stop()
    }

    @Test("delivers retirement and does not follow recreation") func retirementAndRecreation() async throws {
        let (harness, token) = try await createObservationState(); let old = try #require(try await harness.session.watchDoc(token, context: .background)); let values = SessionTestLog<ObservationValue?>()
        try old.start { value, _, _ in values.append(value) }
        try await harness.session.commit({ tx in try await tx.retireDoc(token); try await tx.doc(token).set("value", 10) }, context: .background)
        guard case .retired = await old.closed else { Issue.record("Expected retirement"); return }
        #expect(values.values == [nil]); #expect(old.value == nil)
        let replacement = try #require(try await harness.session.watchDoc(token, context: .background)); #expect(replacement.value?.value == 10)
        try await setObservation(11, harness, token); #expect(old.value == nil); _ = await replacement.stop()
    }

    @Test("Session close discards retirement buffered before start") func closeBeforeStart() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let baseline = watch.value
        try await harness.session.commit({ tx in try await tx.retireDoc(token) }, context: .background); try await harness.session.close(context: .background)
        guard case .sessionClosed = await watch.closed else { Issue.record("Expected Session close"); return }
        #expect(watch.value == baseline); #expect(throws: (any Error).self) { try watch.start { _, _, _ in } }
    }

    @Test("Session close discards retirement behind an in-flight callback") func closeBufferedRetirement() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let entered = SessionTestGate(); let release = SessionTestGate(); let values = SessionTestLog<Int?>()
        try watch.start { value, _, _ in values.append(value?.value); entered.release(); await release.wait() }
        try await setObservation(1, harness, token); await entered.wait(); try await harness.session.commit({ tx in try await tx.retireDoc(token) }, context: .background)
        try await harness.session.close(context: .background); guard case .sessionClosed = await watch.closed else { Issue.record("Expected Session close"); return }
        release.release(); await watch.waitUntilIdle(); #expect(values.values == [1])
    }

    @Test("supports idempotent stop and rejects repeated or late start") func lifecycle() async throws {
        let (harness, token) = try await createObservationState(); let started = try #require(try await harness.session.watchDoc(token, context: .background))
        try started.start { _, _, _ in }; #expect(throws: (any Error).self) { try started.start { _, _, _ in } }
        guard case .stopped = await started.stop(), case .stopped = await started.stop() else { Issue.record("Expected stop"); return }
        let stopped = try #require(try await harness.session.watchDoc(token, context: .background)); _ = await stopped.stop()
        #expect(throws: (any Error).self) { try stopped.start { _, _, _ in } }
    }

    @Test("cancels acquisition without leaking a registered watch") func acquisitionCancellation() async throws {
        let (harness, token) = try await createObservationState(); try await harness.session.unloadDocuments(); let gate = await harness.storage.holdFindDocument(); let child = ChordContext.background.withCancel()
        let acquisition = Task { try await harness.session.watchDoc(token, context: child.context) }; await gate.waitUntilEntered(); child.cancel(ObservationFailure.acquisition); await gate.release()
        await #expect(throws: ObservationFailure.acquisition) { _ = try await acquisition.value }; try await harness.session.close(context: .background)
    }

    @Test("cancels future delivery without aborting an in-flight callback") func cancellationInFlight() async throws {
        let (harness, token) = try await createObservationState(); let child = ChordContext.background.withCancel(); let watch = try #require(try await harness.session.watchDoc(token, context: child.context)); let entered = SessionTestGate(); let release = SessionTestGate(); let contexts = SessionTestLog<ChordContext>()
        try watch.start { _, _, context in contexts.append(context); entered.release(); await release.wait() }
        try await setObservation(1, harness, token); await entered.wait(); child.cancel()
        guard case .cancelled = await watch.closed else { Issue.record("Expected cancellation"); return }
        #expect(contexts.values[0].abortSignal == nil); release.release(); await watch.waitUntilIdle()
    }

    @Test("Session close stops future delivery without joining an in-flight callback") func closeInFlight() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let entered = SessionTestGate(); let release = SessionTestGate(); let contexts = SessionTestLog<ChordContext>()
        try watch.start { _, _, context in contexts.append(context); entered.release(); await release.wait() }
        try await setObservation(1, harness, token); await entered.wait(); try await harness.session.close(context: .background)
        guard case .sessionClosed = await watch.closed else { Issue.record("Expected Session close"); return }
        #expect(contexts.values[0].abortSignal == nil); release.release(); await watch.waitUntilIdle()
    }

    @Test("settles listener failure on only the affected watch") func listenerFailure() async throws {
        let (harness, token) = try await createObservationState(); let failed = try #require(try await harness.session.watchDoc(token, context: .background)); let healthy = try #require(try await harness.session.watchDoc(token, context: .background)); let calls = SessionTestLog<Int>()
        try failed.start { _, _, _ in throw ObservationFailure.listener }; try healthy.start { _, _, _ in calls.append(1) }
        try await setObservation(1, harness, token)
        guard case .listenerError(let error) = await failed.closed else { Issue.record("Expected listener error"); return }
        #expect(error as? ObservationFailure == .listener); await healthy.waitUntilIdle(); #expect(calls.count == 1); _ = await healthy.stop()
    }

    @Test("hydrates migration without writing and observes the later exact edit") func migration() async throws {
        let harness = try await openTestSession(); let old = try SessionDocToken<JSONObject>(kind: "watch.migration", version: 1, initial: { ["value": 3] }); let current = try SessionDocToken<JSONObject>(kind: "watch.migration", version: 2, initial: { ["value": 0, "migrated": false] }, migrate: { value, _ in ["value": value["value"]!, "migrated": true] })
        try await harness.session.commit({ tx in _ = try await tx.doc(old) }, context: .background); try await harness.session.unloadDocuments(); let commits = await harness.storage.commits.count
        let watch = try #require(try await harness.session.watchDoc(current, context: .background)); #expect(watch.value == ["value": 3, "migrated": true]); #expect(await harness.storage.commits.count == commits)
        let values = SessionTestLog<JSONObject?>(); try watch.start { value, _, _ in values.append(value) }
        try await harness.session.commit({ tx in _ = try await tx.doc(current) }, context: .background); await watch.waitUntilIdle(); #expect(values.count == 0)
        try await harness.session.commit({ tx in try await tx.doc(current).set("value", 4) }, context: .background); await watch.waitUntilIdle(); #expect(values.values == [["value": 4, "migrated": true]]); _ = await watch.stop()
    }

    @Test("can replay every delivered exact operation batch from the acquisition revision") func exactReplay() async throws {
        let harness = try await openTestSession(); let token = try SessionDocToken<JSONObject>(kind: "watch.replay", version: 1, initial: { ["value": 0, "items": ["a", "b"]] })
        try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let replica = Mutex<JSONValue?>(watch.value.map(JSONValue.object))
        try watch.start { value, ops, _ in try replica.withLock { state in state = try Delta.applyImmutable(state, ops); #expect(state == value.map(JSONValue.object)) } }
        try await harness.session.commit({ tx in let draft = try await tx.doc(token); try draft.set("value", 3); _ = try draft.child("items")!.popFirst() }, context: .background)
        await watch.waitUntilIdle(); #expect(replica.withLock { $0 } == watch.value.map(JSONValue.object)); _ = await watch.stop()
    }

    @Test("continues after the tracker cache unloads") func cacheUnload() async throws {
        let (harness, token) = try await createObservationState(); let watch = try #require(try await harness.session.watchDoc(token, context: .background)); let baseline = watch.value; let reads = await harness.storage.documentReadCount
        try await harness.session.unloadDocuments(); #expect(try await harness.session.snapshot(token, context: .background) == baseline); #expect(await harness.storage.documentReadCount > reads)
        try watch.start { _, _, _ in }; try await setObservation(7, harness, token); await watch.waitUntilIdle(); #expect(watch.value?.value == 7); _ = await watch.stop()
    }
}
