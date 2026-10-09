import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskFailFastTests {
    // upstream structured:384
    @Test func failFastMarksSiblingBeforeHeldFailureDrains() async throws {
        let clock = TestClock()
        let slowAbort = SessionTestGate()
        let hold = harnessHoldingTask(clock: clock, slowAbort: slowAbort)
        let members = SessionTestLog<TaskID>()
        let failed = harnessOneStep("test.held-failure") { _, runtime, context in
            try await runtime.commit({ tx, _ in
                _ = try await tx.createTask(hold, input: 99, options: .init(ownership: .task(taskId: runtime.taskId)))
                return nil
            }, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .failed(error: .init(message: "held failure"))) }, context: context)
        }
        let parent = harnessOneStep("test.failfast-held") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let first = try await tx.createTask(failed, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    let second = try await tx.createTask(hold, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    members.append(first); members.append(second)
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [first, second])), on: [first, second], policy: .failFast)
                }, context: context)
            case .joined:
                let results = try await runtime.outcomes(task.checkpoint.ids, context: context)
                #expect(results.map(\.status) == ["failed", "aborted"])
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(failed), AnyTaskDefinition(hold)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { members.count == 2 }
        let first = members.values[0]
        let second = members.values[1]
        #expect(try await harness.waitForTask(id: second, context: .background).outcome.status == "aborted")
        #expect(try await harness.getTask(id: first, context: .background)?.state.status == "completing")
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "waiting")
        slowAbort.release()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }
}
