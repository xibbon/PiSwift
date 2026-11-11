import PiSwiftChord
import Synchronization
import Testing
@testable import PiSwiftDurable

private struct TaskWatchWriter: Sendable {
    let harness: Harness
    let storage: ControlledStorage
    let root: Conversation
    let id: TaskID
    let token: TaskDocToken<JSONObject>
    let finish: SessionTestGate
    func endTask() async throws {
        finish.release()
        _ = try await harness.waitForTask(id: id, context: .background)
    }
}

private func openTaskWatchWriter() async throws -> TaskWatchWriter {
    let storage = ControlledStorage(); let finish = SessionTestGate(); let written = SessionTestGate()
    let token = try TaskDocToken<JSONObject>(kind: "test.observers.progress", version: 1,
        initial: { ["lines": []] }, checkpointWhen: { _, _, _ in false })
    let definition = harnessOneStep("test.observers.writer") { task, runtime, context in
        try await runtime.commit({ tx, _ in
            try await tx.doc(token, taskId: task.id).child("lines")!.append("started")
            return nil
        }, context: context)
        written.release(); await finish.wait()
        try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: 0)) }, context: context)
    }
    let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
    let root = try await harness.root(context: .background); let id = try await harnessStart(root, definition)
    try harness.resume(); await written.wait()
    return TaskWatchWriter(harness: harness, storage: storage, root: root, id: id, token: token, finish: finish)
}

// v1.5.2 CH3 harness-observers.test.ts:282–468, task documents.
@Suite(.timeLimit(.minutes(1))) struct SessionTaskWatchCH3Tests {
    @Test("a watch delivers retirement of the commit that ends its task, then ends") func retirementThenEnd() async throws {
        // upstream :283
        let h = try await openTaskWatchWriter()
        let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
        #expect(watch.value == ["lines": ["started"]])
        let calls = SessionTestLog<WatchCall<JSONObject>>()
        try watch.start { call, _ in calls.append(call) }
        try await h.endTask(); #expect(await watch.closed == .ended)
        #expect(calls.values == [.value(value: ["lines": ["started"]], ops: [], retired: true)])
        #expect(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background) == nil)
        try await h.harness.close(context: .background)
    }

    @Test("an observer gets retirement then its end at publication") func observerRetirementThenEnd() async throws {
        // upstream :303
        let h = try await openTaskWatchWriter(); let calls = SessionTestLog<String>(); let ended = SessionTestGate()
        _ = try await h.harness.observeDoc(h.token, taskId: h.id, observer: Observer(advance: { call, _ in
            #expect(call == .value(value: ["lines": ["started"]], ops: [], retired: true))
            calls.append("retire")
        }, end: { end in #expect(end == .ended); calls.append("end"); ended.release() }), context: .background)
        // Swift can resume the task waiter while later publication listeners still run.
        try await h.endTask(); await ended.wait(); #expect(calls.values == ["retire", "end"])
        try await h.harness.close(context: .background); #expect(calls.values == ["retire", "end"])
    }

    @Test("keeps no task document watch alive once its task ended") func releaseEndedWatch() async throws {
        // upstream :330
        let h = try await openTaskWatchWriter()
        func acquire() async throws -> SessionObserverWeak<Watch<JSONObject>> {
            let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
            try watch.start { _, _ in }; return SessionObserverWeak(watch)
        }
        let weak = try await acquire(); #expect(weak.value != nil)
        try await h.endTask()
        // Join the worker before the weak reference check. closed resolves during worker cleanup.
        if let watch = weak.value { _ = await watch.closed; await watch.waitUntilIdle() }
        #expect(weak.value == nil); #expect(h.harness.session.documentCacheSizes.attached == 0)
        try await h.harness.close(context: .background)
    }

    @Test("an unstarted watch ends with Harness close and retains no Harness") func unstartedClose() async throws {
        // upstream :352
        func acquire() async throws -> (Watch<JSONObject>, SessionObserverWeak<Harness>) {
            let h = try await openTaskWatchWriter()
            let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
            try await h.endTask(); try await h.harness.close(context: .background)
            return (watch, SessionObserverWeak(h.harness))
        }
        let (watch, weak) = try await acquire()
        #expect(await watch.closed == .ended); #expect(throws: WatchError.stopped) { try watch.start { _, _ in } }
        #expect(weak.value == nil)
    }

    @Test("an unstarted watch fails with its Harness after the task ends") func unstartedFailure() async throws {
        // upstream :373
        let h = try await openTaskWatchWriter()
        let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
        try await h.endTask(); await h.storage.failNextCommit(TaskDefinitionError("disk gone"))
        await #expect(throws: (any Error).self) {
            _ = try await h.root.commit({ tx in try await tx.appendEntry(h.root.id, value: EntryDraft(kind: "note")) }, context: .background)
        }
        #expect(await watch.closed == .failed(.message("disk gone")))
        _ = await h.harness.closed
    }

    @Test("a busy watch fails with Harness before its retirement call") func busyFailure() async throws {
        // upstream :386
        let h = try await openTaskWatchWriter(); let entered = SessionTestGate(); let release = SessionTestGate()
        defer { release.release() }
        let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
        let calls = SessionTestLog<JSONObject>()
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { calls.append(value) }
            entered.release(); await release.wait()
        }
        try await h.harness.session.commit({ tx in try await tx.doc(h.token, taskId: h.id).child("lines")!.append("more") }, context: .background)
        await entered.wait(); try await h.endTask()
        await h.storage.failNextCommit(TaskDefinitionError("disk gone"))
        await #expect(throws: (any Error).self) {
            _ = try await h.root.commit({ tx in try await tx.appendEntry(h.root.id, value: EntryDraft(kind: "note")) }, context: .background)
        }
        #expect(await watch.closed == .failed(.message("disk gone")))
        release.release(); await watch.waitUntilIdle()
        #expect(calls.values == [["lines": ["started", "more"]]])
        _ = await h.harness.closed
    }

    @Test("a retirement call ends only after that call returns") func retirementInFlight() async throws {
        // upstream :417. An observer in the terminal commit checks that the listener has not returned.
        let h = try await openTaskWatchWriter(); let entered = SessionTestGate(); let release = SessionTestGate()
        defer { release.release() }
        let returned = Mutex(false)
        let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
        try watch.start { _, _ in entered.release(); await release.wait(); returned.withLock { $0 = true } }
        try await h.harness.session.commit({ tx in try await tx.retireDoc(h.token, taskId: h.id) }, context: .background)
        await entered.wait(); try await h.endTask()
        #expect(!returned.withLock { $0 })
        release.release(); #expect(await watch.closed == .ended); #expect(returned.withLock { $0 })
        try await h.harness.close(context: .background)
    }

    @Test("listener changes retain no Harness") func callsDoNotRetainHarness() async throws {
        // upstream :441. Swift calls contain only Sendable values, operations, and the retirement flag.
        func acquire() async throws -> ([WatchCall<JSONObject>], SessionObserverWeak<Harness>) {
            let h = try await openTaskWatchWriter(); let calls = SessionTestLog<WatchCall<JSONObject>>()
            let watch = try #require(try await h.harness.watchDoc(h.token, taskId: h.id, context: .background))
            try watch.start { call, _ in calls.append(call) }
            try await h.harness.session.commit({ tx in try await tx.doc(h.token, taskId: h.id).child("lines")!.append("more") }, context: .background)
            await watch.waitUntilIdle(); try await h.endTask(); _ = await watch.closed; await watch.waitUntilIdle()
            try await h.harness.close(context: .background)
            return (calls.values, SessionObserverWeak(h.harness))
        }
        let (calls, harness) = try await acquire(); #expect(calls.count == 2); #expect(harness.value == nil)
    }
}
