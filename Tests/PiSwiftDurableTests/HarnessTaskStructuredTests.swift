import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskStructuredTests {
    // upstream harness-structured.test.ts:202,338,384,499,507
    @Test(arguments: [JoinPolicy.allSettled, .failFast])
    func joinsOwnedChildrenAndReadsOrderedOutcomes(policy: JoinPolicy) async throws {
        let child = harnessOneStep("test.child") { task, runtime, context in
            try await runtime.commit({ _, _ in
                task.input == 0 ? .terminal(outcome: .failed(error: .init(message: "child failed"))) : .terminal(outcome: .completed(result: .number(Double(task.input))))
            }, context: context)
        }
        let parent = harnessOneStep("test.parent") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let first = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    let second = try await tx.createTask(child, input: 1, options: .init(ownership: .task(taskId: runtime.taskId)))
                    let cp = HarnessTaskCheckpoint(phase: .joined, ids: [first, second])
                    return .waiting(checkpoint: try JSONValue(encoding: cp), on: [first, second], policy: policy)
                }, context: context)
            case .joined:
                let outcomes = try await runtime.outcomes(task.checkpoint.ids, context: context)
                #expect(outcomes.count == 2)
                #expect(outcomes[0].status == "failed")
                #expect(outcomes[1].status == "completed" || outcomes[1].status == "aborted")
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(2)))
        try await harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:542,1329
    @Test func holdsOutcomeUntilOwnedWorkDrains() async throws {
        let gate = SessionTestGate()
        let childIDs = SessionTestLog<TaskID>()
        let child = harnessOneStep("test.hold-child") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let parent = harnessOneStep("test.hold-parent") { _, runtime, context in
            try await runtime.commit({ tx, _ in
                childIDs.append(try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: runtime.taskId))))
                return nil
            }, context: context)
            try await runtime.commit({ _, _ in
                return .terminal(outcome: .completed(result: .number(7)))
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)])
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "completing" }
        #expect(childIDs.count == 1)
        #expect(try await harness.getTask(id: id, context: .background)?.endedAt == nil)
        gate.release()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(7)))
        try await harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:462,732
    @Test(arguments: ["self", "owner", "missing", "failFast-unowned", "abort-wait"])
    func validatesWaitSets(mode: String) async throws {
        let other = harnessOneStep("test.other") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let unrelatedID = Mutex<TaskID?>(nil)
        let run: HarnessTestTask.Handler = { task, runtime, context in
            let on: [TaskID]
            switch mode {
            case "self", "abort-wait": on = [runtime.taskId]
            case "owner": on = [try TaskID(Int64(task.input))]
            case "missing": on = [try TaskID(80_000)]
            default: on = [try #require(unrelatedID.withLock { $0 })]
            }
            try await runtime.commit({ _, _ in
                .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: on,
                         policy: mode == "failFast-unowned" ? .failFast : .allSettled)
            }, context: context)
        }
        let definition = harnessOneStep("test.invalid-wait", run: run, abort: run)
        let harness = try await harnessOpen([AnyTaskDefinition(definition), AnyTaskDefinition(other)])
        let root = try await harness.root(context: .background)
        unrelatedID.withLock { $0 = nil }
        let otherID = try await harnessStart(root, other)
        unrelatedID.withLock { $0 = otherID }
        let id: TaskID
        if mode == "owner" {
            id = try await root.commit({ tx in try await tx.createTask(definition, input: Int(otherID.rawValue), options: .init(ownership: .task(taskId: otherID))) }, context: .background)
        } else { id = try await harnessStart(root, definition) }
        if mode == "abort-wait" { _ = try await harness.abortTask(id: id, context: .background) }
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == "faulted")
        try await harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:799, ownership:188,239
    @Test func conversationAbortKeepsBackgroundAndDirectAbortCrossesIt() async throws {
        let clock = TestClock()
        let definition = harnessOneStep("test.background") { _, runtime, context in
            try await runtime.sleep(until: 100_000, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let foreground = try await harnessStart(root, definition)
        let background = try await harnessStart(root, definition, background: true)
        try await root.abort(context: .background)
        #expect(try await harness.waitForTask(id: foreground, context: .background).outcome.status == "aborted")
        #expect(try await harness.getTask(id: background, context: .background)?.abortRequested == false)
        try await root.waitForIdle(context: .background)
        _ = try await harness.abortTask(id: background, context: .background)
        #expect(try await harness.waitForTask(id: background, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:670,705
    @Test func abortRunsBottomUp() async throws {
        let clock = TestClock()
        let log = SessionTestLog<String>()
        let grandchild = harnessOneStep("test.abort-grandchild", run: { _, runtime, context in
            try await runtime.sleep(until: 100_000, context: context)
        }, abort: { _, runtime, context in
            log.append("grandchild")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
        let child = harnessOneStep("test.abort-child", run: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let id = try await tx.createTask(grandchild, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [id])), on: [id], policy: .allSettled)
                }, context: context)
            case .joined: throw TaskDefinitionError("Unexpected child run")
            }
        }, abort: { _, runtime, context in
            log.append("child")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
        let parent = harnessOneStep("test.abort-parent", run: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let id = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [id])), on: [id], policy: .allSettled)
                }, context: context)
            case .joined: throw TaskDefinitionError("Unexpected run")
            }
        }, abort: { _, runtime, context in
            log.append("parent")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child), AnyTaskDefinition(grandchild)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        _ = try await harness.abortTask(id: id, context: .background)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "aborted")
        #expect(log.values == ["grandchild", "child", "parent"])
        try await harness.close(context: .background)
    }
}
