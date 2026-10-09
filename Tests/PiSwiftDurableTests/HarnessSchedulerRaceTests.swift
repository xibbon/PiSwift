import Synchronization
import Dispatch
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessSchedulerRaceTests {
    // upstream harness-tasks.test.ts:623
    @Test func runtimeCommitsBeforeAndAfterTheStep() async throws {
        let entered = SessionTestGate(), release = SessionTestGate(), lineEntered = SessionTestGate(), lineRelease = SessionTestGate()
        let retained = Mutex<TaskRuntime?>(nil)
        let definition = harnessOneStep("test.commit-order") { _, runtime, _ in
            retained.withLock { $0 = runtime }; entered.release(); await release.wait()
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        try await harnessEventually { !harness.tasks.state.withLock { $0.pumping } }
        let blocker = Task { try await harness.commit({ _ in lineEntered.release(); await lineRelease.wait() }, context: .background) }
        await lineEntered.wait()
        let runtime = try #require(retained.withLock { $0 })
        let before = Task { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .string("before"))) }, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount == 1 }
        release.release()
        try await harnessEventually { harness.session.line.queuedCount == 2 }
        let after = Task { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .string("after"))) }, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount == 3 }
        lineRelease.release(); try await blocker.value; try await before.value
        await #expect(throws: (any Error).self) { try await after.value }
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .string("before")))
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:774
    @Test func wakeupDuringRejectedReservationIsKept() async throws {
        let storage = ControlledStorage(), registry = Registry()
        let first = harnessOneStep("test.wake-first") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let late = harnessOneStep("test.wake-late") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(first)], registry: registry)
        let harness = opened.harness, root = try await harness.root(context: .background)
        let firstID = try await harnessStart(root, first), lateID = try await harnessStart(root, late)
        let held = await storage.holdCommits()
        await storage.failNextCommit(StorageRejected("busy"))
        try harness.resume(); await held.waitUntilEntered()
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(late)]))
        await held.release()
        #expect(try await harness.waitForTask(id: firstID, context: .background).outcome.status == "completed")
        #expect(try await harness.waitForTask(id: lateID, context: .background).outcome.status == "completed")
        #expect(opened.reports.count == 1)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:797
    @Test func rejectedFaultWriteRerunsTheTask() async throws {
        let storage = ControlledStorage(), runs = Mutex(0)
        let definition = harnessOneStep("test.retry-fault") { _, _, _ in
            let run = runs.withLock { $0 += 1; return $0 }
            if run == 1 { await storage.failNextCommit(StorageRejected("busy")) }
            throw TaskDefinitionError("boom")
        }
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(definition)])
        let harness = opened.harness, root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .faulted(error: .init(message: "boom")))
        #expect(runs.withLock { $0 } == 2)
        #expect(opened.reports.count == 1)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:1067
    @Test func repeatedAbortLeavesAbortInvocationSignalAlone() async throws {
        let runEntered = SessionTestGate(), runRelease = SessionTestGate(), abortEntered = SessionTestGate(), abortRelease = SessionTestGate()
        let aborts = Mutex(0), signalWasAborted = Mutex(false)
        let definition = harnessOneStep("test.abort-repeat", run: { _, _, _ in runEntered.release(); await runRelease.wait() }, abort: { _, runtime, context in
            aborts.withLock { $0 += 1 }; abortEntered.release(); await abortRelease.wait()
            signalWasAborted.withLock { $0 = runtime.signal.aborted }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "once")) }, context: context)
        })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]), root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        try harness.resume(); await runEntered.wait()
        let caller = ChordContext.background.withCancel()
        let first = Task { try await harness.abortTask(id: id, context: caller.context) }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        caller.cancel(TaskDefinitionError("caller gave up"))
        await #expect(throws: TaskDefinitionError.self) { _ = try await first.value }
        runRelease.release(); await abortEntered.wait()
        #expect(try await harness.abortTask(id: id, context: .background) == .marked)
        abortRelease.release()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "once"))
        #expect(aborts.withLock { $0 } == 1); #expect(!signalWasAborted.withLock { $0 })
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:1127
    @Test func abortQueuedDuringReservationStopsTheFirstPhase() async throws {
        let storage = ControlledStorage(), ran = Mutex(false)
        let definition = harnessOneStep("test.mark-reserved") { _, _, _ in ran.withLock { $0 = true } }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage), root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        let held = await storage.holdCommits()
        try harness.resume(); await held.waitUntilEntered()
        let marking = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        await held.release()
        #expect(try await marking.value == .marked)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        #expect(!ran.withLock { $0 })
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:1148
    @Test func durableAbortMarkWinsOverQueuedFaultStep() async throws {
        let entered = SessionTestGate(), release = SessionTestGate(), lineEntered = SessionTestGate(), lineRelease = SessionTestGate()
        let definition = harnessOneStep("test.mark-fault") { _, _, _ in entered.release(); await release.wait(); throw TaskDefinitionError("would fault") }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]), root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        try await harnessEventually { !harness.tasks.state.withLock { $0.pumping } }
        let blocker = Task { try await harness.commit({ _ in lineEntered.release(); await lineRelease.wait() }, context: .background) }
        await lineEntered.wait()
        let marking = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount == 1 }
        release.release()
        try await harnessEventually { harness.session.line.queuedCount == 2 }
        lineRelease.release(); try await blocker.value
        #expect(try await marking.value == .marked)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }
}

private final class StepSnapshotBarrier: RegistryReader, Sendable {
    let registry: Registry
    let entered = SessionTestGate()
    let barrier = DispatchSemaphore(value: 0)
    let armed = Mutex(false)
    init(_ registry: Registry) { self.registry = registry }
    func snapshot() -> RegistrySnapshot {
        let block = armed.withLock { armed in let block = armed; armed = false; return block }
        if block { entered.release(); barrier.wait() }
        return registry.snapshot()
    }
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void { registry.subscribe(listener) }
}

extension HarnessSchedulerRaceTests {
    // upstream harness-tasks.test.ts:1342; pause exactly inside the step's snapshot refresh.
    @Test func closeDuringContinuingStepStopsDispatch() async throws {
        let registry = Registry(), reader = StepSnapshotBarrier(registry), log = SessionTestLog<String>()
        let definition = harnessOneStep("test.close-inside-step") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                log.append("run")
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
                reader.armed.withLock { $0 = true }
            case .joined: log.append("joined")
            }
        }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: reader), context: .background)
        let root = try await harness.root(context: .background)
        _ = try await harnessStart(root, definition)
        try harness.resume(); await reader.entered.wait()
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        reader.barrier.signal(); try await closing.value
        #expect(log.values == ["run"])
    }

    // upstream harness-tasks.test.ts:1222
    @Test func closeSealsBeforeSignalCallbacksAndClosesWatchesBeforeJoining() async throws {
        let notes = try SessionDocToken<JSONObject>(kind: "test.reentrant-notes", version: 1, initial: { JSONObject() })
        let reference = Mutex<Harness?>(nil), callback = Mutex<Task<Void, any Error>?>(nil)
        let entered = SessionTestGate(), end = Mutex<WatchEnd?>(nil)
        let definition = harnessOneStep("test.reentrant-close") { _, runtime, _ in
            let watch = try #require(try await runtime.watchDoc(notes, context: .background))
            runtime.signal.addAbortListener { _ in
                if let harness = reference.withLock({ $0 }) {
                    callback.withLock { $0 = Task { try await harness.commit({ _ in }, context: .background) } }
                }
            }
            entered.release()
            let reason = await watch.closed
            end.withLock { $0 = reason }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        reference.withLock { $0 = harness }
        let root = try await harness.root(context: .background)
        try await harness.commit({ tx in _ = try await tx.doc(notes) }, context: .background)
        _ = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait(); try await harness.close(context: .background)
        let queued = try #require(callback.withLock { $0 })
        await #expect(throws: (any Error).self) { try await queued.value }
        guard case .sessionClosed? = end.withLock({ $0 }) else { Issue.record("Watch did not close with Session"); return }
    }

    // upstream harness-tasks.test.ts:886; queued cancelled and closed waits must reject.
    @Test(arguments: [false, true])
    func waitQueuedOnLineRejectsAtCancellationOrClose(close: Bool) async throws {
        let runEntered = SessionTestGate(), runRelease = SessionTestGate(), lineEntered = SessionTestGate(), lineRelease = SessionTestGate()
        let definition = harnessOneStep("test.queued-wait") { _, _, _ in runEntered.release(); await runRelease.wait() }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]), root = try await harness.root(context: .background), id = try await harnessStart(root, definition)
        try harness.resume(); await runEntered.wait()
        try await harnessEventually { !harness.tasks.state.withLock { $0.pumping } }
        let blocker = Task { try await harness.commit({ _ in lineEntered.release(); await lineRelease.wait() }, context: .background) }
        await lineEntered.wait()
        let caller = ChordContext.background.withCancel()
        let waiter = Task { try await harness.waitForTask(id: id, context: caller.context) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing: Task<Void, any Error>?
        if close {
            closing = Task { try await harness.close(context: .background) }
            try await harnessEventually { harness.tasks.closing }
        } else { closing = nil; caller.cancel() }
        lineRelease.release(); try await blocker.value
        await #expect(throws: (any Error).self) { _ = try await waiter.value }
        runRelease.release()
        if let closing { try await closing.value } else { try await harness.close(context: .background) }
    }
}
