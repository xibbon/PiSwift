import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskIdleTests {
    // upstream harness-tasks.test.ts:818
    @Test func separateConversationIdleScopesIgnoreBackgroundAndCallerCancellation() async throws {
        let clock = TestClock()
        let definition = harnessOneStep("test.idle-scopes") { task, runtime, context in
            try await runtime.sleep(until: Int64(task.input), context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let other = try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        _ = try await harnessStart(root, definition, input: 100)
        let background = try await harnessStart(root, definition, input: 1_000, background: true)
        _ = try await harnessStart(other, definition, input: 200)
        let caller = PiSwiftChord.Context.background.withCancel()
        let cancelled = Task { try await harness.waitForIdle(context: caller.context) }
        try await harnessEventually { clock.pendingSleeperCount == 3 }
        caller.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        let already = PiSwiftChord.Context.background.withCancel()
        already.cancel()
        await #expect(throws: (any Error).self) { try await root.waitForIdle(context: already.context) }
        let rootIdle = Task { try await root.waitForIdle(context: .background) }
        let harnessIdle = settled { try await harness.waitForIdle(context: .background) }
        clock.advance(by: 100)
        try await rootIdle.value
        #expect(!harnessIdle.isSettled)
        clock.advance(by: 100)
        try await harnessEventually { harnessIdle.isSettled }
        #expect(try await harness.getTask(id: background, context: .background)?.state.status == "running")
        clock.advance(by: 800)
        _ = try await harness.waitForTask(id: background, context: .background)
        try await harness.close(context: .background)
        await #expect(throws: (any Error).self) { try await harness.waitForIdle(context: .background) }
        await #expect(throws: (any Error).self) { try await root.waitForIdle(context: .background) }
    }
}
