import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskBoundaryTests {
    // upstream harness-tasks.test.ts:1285,1386
    @Test(arguments: [false, true])
    func closeJoinsReservationWithoutStartingHandler(marked: Bool) async throws {
        let storage = ControlledStorage()
        let log = SessionTestLog<String>()
        let definition = harnessOneStep("test.reserve-close", run: { _, _, _ in log.append("run") }, abort: { _, _, _ in log.append("abort") })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        if marked {
            try await root.commit({ tx in
                let task = try #require(try await tx.task(id))
                try tx.setTask(task.replacing(abortRequested: true))
            }, context: .background)
        }
        let held = await storage.holdCommits()
        try harness.resume()
        await held.waitUntilEntered()
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        try await closing.value
        #expect(log.count == 0)
        let taskWrites = await storage.commits.flatMap { $0 }.compactMap { write -> TaskRecord? in
            if case .task(let task, _) = write, task.id == id { return task }; return nil
        }
        #expect(taskWrites.last?.state.status == "running")
        #expect(taskWrites.last?.abortRequested == marked)
    }

    // upstream harness-tasks.test.ts:1309; lifecycle:450
    @Test func closeRejectsRuntimeCommitAlreadyQueuedOnLine() async throws {
        let retained = Mutex<TaskRuntime?>(nil)
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let storage = ControlledStorage()
        let definition = harnessOneStep("test.queue-close") { _, runtime, _ in
            retained.withLock { $0 = runtime }; entered.release(); await runRelease.wait()
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let held = await storage.holdCommits()
        let blocker = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "block")) }, context: .background) }
        await held.waitUntilEntered()
        let runtime = try #require(retained.withLock { $0 })
        let queued = Task { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        _ = try await blocker.value
        await #expect(throws: (any Error).self) { try await queued.value }
        runRelease.release()
        try await closing.value
        let writes = await storage.commits.flatMap { $0 }
        #expect(!writes.contains { if case .task(let task, _) = $0 { return task.id == id && task.state.status == "terminal" }; return false })
    }

    // upstream harness-tasks.test.ts:1255
    @Test func closeWinsOverFailedPhaseStepQueuedOnLine() async throws {
        let storage = ControlledStorage()
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let definition = harnessOneStep("test.failed-step-close") { _, _, _ in
            entered.release(); await runRelease.wait(); throw TaskDefinitionError("would fault")
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let held = await storage.holdCommits()
        let blocker = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "block")) }, context: .background) }
        await held.waitUntilEntered()
        runRelease.release()
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        _ = try await blocker.value
        try await closing.value
        let writes = await storage.commits.flatMap { $0 }
        #expect(!writes.contains { if case .task(let task, _) = $0 { return task.id == id && task.state.status == "terminal" }; return false })
    }

    // upstream harness-tasks.test.ts:1175,973
    @Test func closeAfterProgressStartsNoNextPhaseOrAbortHandler() async throws {
        let entered = SessionTestGate()
        let runRelease = SessionTestGate()
        let log = SessionTestLog<String>()
        let definition = harnessOneStep("test.progress-close", run: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                log.append("run")
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
                entered.release(); await runRelease.wait()
            case .joined: log.append("joined")
            }
        }, abort: { _, _, _ in log.append("abort") })
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        runRelease.release()
        _ = try await aborting.value
        try await closing.value
        #expect(log.values == ["run"])
    }
}
