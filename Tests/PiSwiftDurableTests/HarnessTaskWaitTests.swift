import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskWaitTests {
    // upstream structured:439,499,507; tasks:258
    @Test(arguments: ["empty", "unowned-terminal", "subset"])
    func allSettledAllowsEmptyUnownedAndSequentialSubsets(mode: String) async throws {
        let child = harnessOneStep("test.wait-member") { task, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: task.input == 1 ? .failed(error: .init(message: "member failed")) : .completed(result: .number(2))) }, context: context)
        }
        let ids = SessionTestLog<TaskID>()
        let phases = SessionTestLog<Int>()
        let parent = harnessOneStep("test.wait-subsets") { task, runtime, context in
            phases.append(task.checkpoint.count)
            if task.checkpoint.count == 0 {
                try await runtime.commit({ tx, _ in
                    var on = ids.values
                    if mode == "subset" {
                        let first = try await tx.createTask(child, input: 1, options: .init(ownership: .task(taskId: runtime.taskId)))
                        let second = try await tx.createTask(child, input: 2, options: .init(ownership: .task(taskId: runtime.taskId)))
                        on = [first, second]
                    }
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, count: 1, ids: on)), on: mode == "subset" ? Array(on.prefix(1)) : on, policy: .allSettled)
                }, context: context)
            } else if mode == "subset" && task.checkpoint.count == 1 {
                try await runtime.commit({ _, _ in
                    .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, count: 2, ids: task.checkpoint.ids)), on: Array(task.checkpoint.ids.suffix(1)), policy: .allSettled)
                }, context: context)
            } else {
                let outcomes = try await runtime.outcomes(task.checkpoint.ids, context: context)
                #expect(outcomes.count == (mode == "empty" ? 0 : mode == "subset" ? 2 : 1))
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(3))) }, context: context)
            }
        }
        let clock = TestClock(now: 10)
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)], clock: clock)
        let root = try await harness.root(context: .background)
        if mode == "unowned-terminal" {
            let id = try await harnessStart(root, child, input: 1)
            _ = try await harness.waitForTask(id: id, context: .background)
            ids.append(id)
        }
        let id = try await harnessStart(root, parent)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == "completed")
        #expect(phases.values == (mode == "subset" ? [0, 1, 2] : [0, 1]))
        #expect(receipt.record.startedAt == 10)
        #expect(receipt.record.endedAt == 10)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks.test.ts:311
    @Test func keepsFirstRunTimestampThroughWaitAndStampsTerminalTime() async throws {
        let clock = TestClock(now: 1_000)
        let gate = SessionTestGate()
        let memberID = SessionTestLog<TaskID>()
        let member = harnessOneStep("test.timed-member") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let waiter = harnessOneStep("test.timed-waiter") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ _, _ in
                    .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)),
                             on: memberID.values, policy: .allSettled)
                }, context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(member), AnyTaskDefinition(waiter)], clock: clock)
        let root = try await harness.root(context: .background)
        let held = try await harnessStart(root, member)
        memberID.append(held)
        let id = try await harnessStart(root, waiter)
        for taskID in [held, id] {
            let record = try #require(try await harness.getTask(id: taskID, context: .background))
            #expect(record.startedAt == nil)
            #expect(record.endedAt == nil)
        }
        clock.advance(by: 1_000)
        try harness.resume()
        try await harnessEventually {
            let waiting = try await harness.getTask(id: id, context: .background)?.state.status == "waiting"
            let running = try await harness.getTask(id: held, context: .background)?.state.status == "running"
            return waiting && running
        }
        for taskID in [held, id] {
            let record = try #require(try await harness.getTask(id: taskID, context: .background))
            #expect(record.startedAt == 2_000)
            #expect(record.endedAt == nil)
        }
        clock.advance(by: 3_000)
        gate.release()
        for taskID in [held, id] {
            let receipt = try await harness.waitForTask(id: taskID, context: .background)
            #expect(receipt.record.startedAt == 2_000)
            #expect(receipt.record.endedAt == 5_000)
        }
        try await harness.close(context: .background)
    }

    // upstream structured:222,241,278
    @Test func rejectsInvalidChildOwnershipAndFinishingCommitChild() async throws {
        let child = harnessOneStep("test.invalid-child") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let parent = harnessOneStep("test.finishing-owner") { _, runtime, context in
            await #expect(throws: (any Error).self) {
                try await runtime.commit({ tx, _ in
                    _ = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    return .terminal(outcome: .completed(result: .number(1)))
                }, context: context)
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(child), AnyTaskDefinition(parent)])
        let root = try await harness.root(context: .background)
        let missing = try TaskID(90_000)
        await #expect(throws: (any Error).self) {
            _ = try await root.commit({ tx in try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: missing))) }, context: .background)
        }
        let pending = try await harnessStart(root, child)
        let other = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        await #expect(throws: (any Error).self) {
            _ = try await root.commit({ tx in try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: pending), conversationId: other.id)) }, context: .background)
        }
        await #expect(throws: (any Error).self) {
            _ = try await root.commit({ tx in try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: pending), background: true)) }, context: .background)
        }
        for state in ["completing", "marked"] {
            await #expect(throws: (any Error).self) {
                _ = try await root.commit({ tx in
                    let owner = try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
                    let record = try #require(await tx.currentTask(owner))
                    if state == "completing" { try tx.setTask(record.replacing(state: .completing(outcome: .completed(result: .number(1))))) }
                    else { try tx.setTask(record.replacing(abortRequested: true)) }
                    return try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: owner)))
                }, context: .background)
            }
        }
        let owner = try await harnessStart(root, parent)
        _ = try await harness.waitForTask(id: owner, context: .background)
        await #expect(throws: (any Error).self) {
            _ = try await root.commit({ tx in try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: owner))) }, context: .background)
        }
        try await harness.close(context: .background)
    }
}
