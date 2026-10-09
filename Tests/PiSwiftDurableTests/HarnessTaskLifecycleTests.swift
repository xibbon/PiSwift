import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskLifecycleTests {
    // upstream harness-tasks.test.ts:1010,1175; harness-lifecycle.test.ts:127,230
    @Test func closeSignalsAndJoinsHandlerWithoutWritingOutcome() async throws {
        let entered = SessionTestGate()
        let release = SessionTestGate()
        let ended = SessionTestLog<Bool>()
        let definition = harnessOneStep("test.close-join") { _, runtime, _ in
            entered.release()
            await release.wait()
            #expect(runtime.signal.aborted)
            ended.append(true)
        }
        let storage = ControlledStorage()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume()
        await entered.wait()
        let closed = settled { try await harness.close(context: .background) }
        try await harnessEventually { runtimeSealed(harness) }
        #expect(!closed.isSettled)
        release.release()
        try await harnessEventually { closed.isSettled }
        #expect(ended.values == [true])
        let writes = await storage.commits.flatMap { $0 }
        #expect(!writes.contains { if case .task(let task, _) = $0 { return task.id == id && task.state.status == "terminal" }; return false })
    }

    private func runtimeSealed(_ harness: Harness) -> Bool { harness.tasks.closing }

    // upstream harness-tasks.test.ts:929,973,1010,1067
    @Test func abortMarkRejectsRunCommitsAndJoinsBeforeReturning() async throws {
        let entered = SessionTestGate()
        let release = SessionTestGate()
        let retained = Mutex<TaskRuntime?>(nil)
        let log = SessionTestLog<String>()
        let definition = harnessOneStep("test.abort-join", run: { _, runtime, _ in
            retained.withLock { $0 = runtime }
            entered.release()
            await release.wait()
            log.append("run-end")
        }, abort: { _, runtime, context in
            log.append("abort")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "joined")) }, context: context)
        })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume()
        await entered.wait()
        let aborted = settled { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        let runtime = try #require(retained.withLock { $0 })
        #expect(runtime.signal.aborted)
        #expect(!aborted.isSettled)
        await #expect(throws: (any Error).self) {
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(99))) }, context: .background)
        }
        await #expect(throws: (any Error).self) {
            _ = try await runtime.memo("late", value: .number(99), context: .background)
        }
        release.release()
        try await harnessEventually { aborted.isSettled }
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .aborted(reason: "joined"))
        #expect(log.values == ["run-end", "abort"])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:1032,1107
    @Test(arguments: ["throw", "nothing", "terminal-then-throw"])
    func abortHandlerMustSettleAndCommittedOutcomeWins(mode: String) async throws {
        let definition = harnessOneStep("test.abort-contract", run: { _, _, _ in Issue.record("Marked task ran") }, abort: { _, runtime, context in
            if mode == "nothing" { return }
            if mode == "terminal-then-throw" {
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "written")) }, context: context)
            }
            throw TaskDefinitionError("abort broke")
        })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        _ = try await harness.abortTask(id: id, context: .background)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == (mode == "terminal-then-throw" ? "aborted" : "faulted"))
        if mode == "nothing", case .faulted(let error, _) = receipt.outcome {
            #expect(error.message.contains("returned without a terminal outcome"))
        }
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:886; harness-ownership.test.ts:462
    @Test func cancelledCallerWaitDoesNotCancelSharedWork() async throws {
        let clock = TestClock()
        let definition = harnessOneStep("test.wait-cancel") { _, runtime, context in
            try await runtime.sleep(until: 1_000, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        let caller = ChordContext.background.withCancel()
        let wait = Task { try await harness.waitForTask(id: id, context: caller.context) }
        try await harnessEventually { clock.pendingSleeperCount > 0 }
        caller.cancel()
        await #expect(throws: (any Error).self) { _ = try await wait.value }
        #expect(try await harness.getTask(id: id, context: .background)?.abortRequested == false)
        clock.advance(by: 1_000)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:746,774,797
    @Test func storageRejectedReservationRetriesOnNextCommit() async throws {
        let storage = ControlledStorage()
        let opened = try await openTasks(storage: storage, tasks: [])
        let root = try await opened.harness.root(context: .background)
        let definition = harnessOneStep("test.retry") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let id = try await harnessStart(root, definition)
        await storage.failNextCommit(StorageRejected("rejected reservation"))
        try opened.registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(definition)]))
        try opened.harness.resume()
        try await harnessEventually { opened.reports.count > 0 }
        #expect(try await opened.harness.getTask(id: id, context: .background)?.state.status == "pending")
        _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "wake")) }, context: .background)
        #expect(try await opened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await opened.harness.close(context: .background)
    }
}
