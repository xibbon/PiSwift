import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

struct HarnessTaskCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case run, joined }
    var phase: Phase = .run
    var count: Int = 0
    var ids: [TaskID] = []
}
typealias HarnessTestTask = TaskDefinition<Int, HarnessTaskCheckpoint, Int, NoTaskHooks>
private struct HarnessEntryResult: Codable, Sendable { let entryId: EntryID }

func harnessOneStep(_ name: String, version: Double = 1,
                    run: @escaping HarnessTestTask.Handler,
                    abort: @escaping HarnessTestTask.Handler = { _, runtime, context in
                        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
                    }) -> HarnessTestTask {
    HarnessTestTask(name: name, version: version, initial: { _ in HarnessTaskCheckpoint() }, phase: run, abort: abort)
}
func harnessStart(_ conversation: Conversation, _ definition: HarnessTestTask,
                  input: Int = 0, background: Bool = false) async throws -> TaskID {
    try await conversation.commit({ tx in
        try await tx.createTask(definition, input: input, options: .init(ownership: .conversation(), background: background))
    }, context: .background)
}
func harnessEventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw TaskDefinitionError("Condition was not reached before the deadline") }
        await Task.yield()
    }
}
func harnessOpen(_ tasks: [AnyTaskDefinition], storage: any DurableStorage = MemoryStorage(),
                 registry: Registry = Registry(), clock: any DurableClock = SystemDurableClock()) async throws -> Harness {
    if !tasks.isEmpty { try registry.install(Extension(name: "tasks", tasks: tasks)) }
    return try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry, clock: clock), context: .background)
}

@Suite struct HarnessTaskTests {
    // upstream harness-tasks.test.ts:87,161
    @Test func checkpointProgressUsesOneRuntimeAndValueEquality() async throws {
        let seen = SessionTestLog<Int>()
        let runtimes = SessionTestLog<ObjectIdentifier>()
        let definition = harnessOneStep("test.counter") { task, runtime, context in
            seen.append(task.checkpoint.count)
            runtimes.append(ObjectIdentifier(runtime))
            try await runtime.commit({ _, current in
                guard case .running(let raw, _) = current.state else { throw TaskDefinitionError("Not running") }
                var checkpoint = try raw.decode(HarnessTaskCheckpoint.self)
                checkpoint.count += 1
                if checkpoint.count == task.input { return .terminal(outcome: .completed(result: .number(Double(checkpoint.count)))) }
                return .running(checkpoint: try JSONValue(encoding: checkpoint))
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition, input: 3)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: .number(3)))
        #expect(seen.values == [0, 1, 2])
        #expect(Set(runtimes.values).count == 1)
        #expect(try await harness.waitForTask(id: id, context: .background) == receipt)
        #expect(try await harness.abortTask(id: id, context: .background) == .terminal)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:121,145,1107
    @Test(arguments: ["no-progress", "throw", "terminal-then-throw", "equal-array"])
    func phaseFaultRules(mode: String) async throws {
        let definition = harnessOneStep("test.fault") { task, runtime, context in
            switch mode {
            case "no-progress": return
            case "equal-array":
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: task.checkpoint)) }, context: context)
            case "terminal-then-throw":
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(9))) }, context: context)
                throw TaskDefinitionError("after terminal")
            default: throw TaskDefinitionError("phase broke")
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        if mode == "terminal-then-throw" { #expect(receipt.outcome == .completed(result: .number(9))) }
        else {
            guard case .faulted(let error, _) = receipt.outcome else { Issue.record("Expected fault"); try await harness.close(context: .background); return }
            #expect(error.message.contains(mode == "throw" ? "phase broke" : "returned without durable progress"))
        }
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:189,523,580
    @Test func memoFirstWriterWinsAndRuntimeEnds() async throws {
        let retained = Mutex<TaskRuntime?>(nil)
        let values = SessionTestLog<JSONValue>()
        let childID = Mutex<TaskID?>(nil)
        let progress = try TaskDocToken<JSONObject>(kind: "test.memo-progress", version: 1, initial: { ["lines": .array([])] })
        let child = harnessOneStep("test.memo-child") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(0))) }, context: context)
        }
        let definition = TaskDefinition<Int, HarnessTaskCheckpoint, HarnessEntryResult, NoTaskHooks>(
            name: "test.memo", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
                retained.withLock { $0 = runtime }
                switch task.checkpoint.phase {
                case .run:
                    #expect(try await runtime.memo("answer", context: context) == nil)
                    // Both calls race for the durable first write. Swift can admit either call first.
                    async let first = runtime.memo("answer", value: .number(1), context: context)
                    async let second = runtime.memo("answer", value: .number(2), context: context)
                    let winners = try await [first, second]
                    let winner = try #require(winners[0])
                    #expect(winners[1] == winner)
                    #expect(winner == .number(1) || winner == .number(2))
                    #expect(try await runtime.memo("answer", context: context) == winner)
                    values.append(winner)
                    try await runtime.commit({ tx, _ in
                        try await tx.doc(progress, taskId: task.id).set("lines", .array([.string("wrote")]))
                        let id = try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
                        childID.withLock { $0 = id }
                        return .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)))
                    }, context: context)
                case .joined:
                    #expect(task.record.memos == ["answer": values.values[0]])
                    #expect(try await runtime.snapshot(progress, taskId: task.id, context: context) == ["lines": .array([.string("wrote")])])
                    try await runtime.commit({ tx, current in
                        let entry = try await tx.appendEntry(current.conversationId, value: EntryDraft(kind: "test.note", data: .string("done")))
                        return .terminal(outcome: .completed(result: try JSONValue(encoding: HarnessEntryResult(entryId: entry.id))))
                    }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
            })
        let storage = ControlledStorage()
        let harness = try await harnessOpen([AnyTaskDefinition(definition), AnyTaskDefinition(child)], storage: storage)
        let root = try await harness.root(context: .background)
        let conversation = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let id = try await conversation.commit({ tx in
            try await tx.createTask(definition, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        try await harness.waitForIdle(context: .background)
        guard case .completed(let result, _) = receipt.outcome else { Issue.record("Expected completed result"); try await harness.close(context: .background); return }
        let answer = try result.decode(HarnessEntryResult.self)
        let entry = try #require(try await harness.commit({ tx in try await tx.entry(answer.entryId) }, context: .background))
        #expect(entry.kind == "test.note")
        #expect(entry.data == .string("done"))
        #expect(entry.conversationId == conversation.id)
        #expect(entry.byTaskId == id)
        #expect(conversation.id != root.id)
        let createdChild = try #require(childID.withLock { $0 })
        #expect(try await harness.waitForTask(id: createdChild, context: .background).record.conversationId == conversation.id)
        let writes = await storage.commits
        #expect(writes.contains { batch in
            let hasEntry = batch.contains { if case .entry(let value, _) = $0 { return value.id == answer.entryId }; return false }
            let hasResult = batch.contains { if case .task(let value, _) = $0 { return value.id == id && value.state.status == "terminal" }; return false }
            return hasEntry && hasResult
        })
        #expect(try await harness.getTask(id: id, context: .background)?.memos == nil)
        #expect(try await harness.snapshot(progress, taskId: id, context: .background) == nil)
        let runtime = try #require(retained.withLock { $0 })
        await #expect(throws: (any Error).self) {
            _ = try await runtime.memo("late", value: .number(3), context: .background)
        }
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:692,712
    @Test func absoluteSleepUsesTestClockAndAbortCancelsSleep() async throws {
        let clock = TestClock(now: 100)
        let entered = SessionTestGate()
        let definition = harnessOneStep("test.sleep") { _, runtime, context in
            entered.release()
            try await runtime.sleep(until: 200, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        let wait = Task { try await harness.waitForTask(id: id, context: .background) }
        await entered.wait()
        try await harnessEventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 99)
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "running")
        clock.advance(by: 1)
        #expect(try await wait.value.outcome == .completed(result: .number(1)))
        let aborted = try await harnessStart(root, definition)
        _ = try await harness.abortTask(id: aborted, context: .background)
        #expect(try await harness.waitForTask(id: aborted, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:818; lifecycle:533,565
    @Test func readsStayPausedAndProgressEnablesScheduling() async throws {
        let runs = SessionTestLog<Int>()
        let definition = harnessOneStep("test.paused") { _, runtime, context in
            runs.append(1)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        _ = try await harness.getTask(id: id, context: .background)
        _ = try await harness.inspect(context: .background)
        _ = try await root.context(context: .background)
        #expect(runs.count == 0)
        _ = try await harness.waitForTask(id: id, context: .background)
        #expect(runs.count == 1)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:868,886
    @Test func unknownTaskWaitAndCloseRejectWaiters() async throws {
        let harness = try await harnessOpen([])
        let id = try TaskID(90_000)
        #expect(try await harness.getTask(id: id, context: .background) == nil)
        await #expect(throws: (any Error).self) { _ = try await harness.waitForTask(id: id, context: .background) }
        await #expect(throws: (any Error).self) { _ = try await harness.abortTask(id: id, context: .background) }
        try await harness.close(context: .background)
        await #expect(throws: (any Error).self) { _ = try await harness.waitForTask(id: id, context: .background) }
    }
    // upstream harness-tasks.test.ts:856
    @Test func pagesNewestTasksFirst() async throws {
        let definition = harnessOneStep("test.pages") { _, _, _ in }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        var ids: [TaskID] = []
        for _ in 0..<5 { ids.append(try await harnessStart(root, definition)) }
        let first = try await harness.commit({ tx in try await tx.scanTasks(.init(order: .descending), limit: 2) }, context: .background)
        #expect(first.items.map(\.id) == [ids[4], ids[3]])
        let second = try await harness.commit({ tx in try await tx.scanTasks(.init(), limit: 2, cursor: first.next) }, context: .background)
        #expect(second.items.map(\.id) == [ids[2], ids[1]])
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:161
    @Test func checkpointArraysMakeValueProgressThenFaultOnEqualCopy() async throws {
        let lengths = SessionTestLog<Int>()
        let definition = harnessOneStep("test.collect") { task, runtime, context in
            lengths.append(task.checkpoint.ids.count)
            var next = task.checkpoint
            if next.ids.count < 2 { next.ids.append(try TaskID(Int64(next.ids.count + 1))) }
            let checkpoint = try JSONValue(encoding: next)
            try await runtime.commit({ _, _ in .running(checkpoint: checkpoint) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)])
        let root = try await harness.root(context: .background)
        let receipt = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        #expect(lengths.values == [0, 1, 2])
        #expect(receipt.outcome == .faulted(error: .init(message: "Task test.collect phase run returned without durable progress")))
        try await harness.close(context: .background)
    }

}
