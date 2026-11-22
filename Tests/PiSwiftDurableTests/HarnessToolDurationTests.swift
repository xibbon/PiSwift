import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

@Suite struct HarnessToolDurationTests {
    // v1.6.0 harness-nested-tools.test.ts:1189–1191,1204–1211.
    @Test func missingNestedCallHasDurationInItsResultAndSlot() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(clock: clock)
        try setup.registry.install(Extension(name: "audit", hooks: [hook(ToolHooks(afterTool: { call, _, _, _ in
            if call.name == "missing" { clock.advance(by: 35) }
            return nil
        }))]))
        let batch = try ToolRegistration(name: "batch", description: "Calls a missing tool",
            parameters: ["type": "object", "properties": [:]], execute: { _, api, context in
                let result = try await api.executeTool("missing", arguments: [:], context: context, options: .init(key: "missing"))
                #expect(result.isError && result.durationMs == 35)
                let stored = try await api.snapshot(NestedCallDoc, taskId: api.taskId, key: "missing", context: context)
                #expect(stored?.result == result)
                let live = try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)
                let slot = try #require(live?.nestedTools?.first)
                #expect(slot.taskId == result.taskId && slot.status == .done)
                #expect(slot.summary == .init(isError: true, durationMs: 35, error: "Tool missing is not available"))
                return .result(.init())
            })
        try installHarnessTool(batch, setup: setup)
        let (opened, entries) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let result = try #require(harnessToolResults(entries).first)
        #expect(!result.isError && result.durationMs == 35)
        try await opened.harness.close(context: .background)
    }

    // v1.6.0 tool.ts:1174–1178. The resumed tool uses its original start time.
    @Test(.timeLimit(.minutes(1))) func durationIncludesCrashDowntimeAndSafeReplay() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-duration.sqlite").path
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(clock: clock), firstAttempt = HarnessChatSignal(), runs = Mutex(0)
        let tool = try ToolRegistration(name: "echo", description: "Runs again after a crash",
            parameters: ["type": "object", "properties": [:]], replay: .safe, execute: { _, _, context in
                let count = runs.withLock { count in count += 1; return count }
                if count == 1 {
                    clock.advance(by: 35)
                    firstAttempt.signal()
                    try await harnessToolAwaitAbort(context)
                }
                clock.advance(by: 55)
                return .result(.init(output: []))
            })
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await generationSubmit(first)
        try await eventually { firstAttempt.isSignalled }
        let taskID = try #require(try await generationLive(first)?.tools?.first?.taskId)
        #expect(try await first.harness.getTask(id: taskID, context: .background)?.startedAt == 1_000)
        first.harness.session.fail(TaskDefinitionError("Test crash"))
        _ = await first.harness.closed

        clock.advance(by: 500)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let resumed = try #require(try await second.harness.submission(id: submission.id, context: .background))
        #expect(try await resumed.wait(context: .background).status == "done")
        #expect(runs.withLock { $0 } == 2)
        let result = try #require(try harnessToolResults(await allEntries(second.root)).first)
        #expect(!result.isError && result.durationMs == 590 && result.timestamp == 1_590)
        #expect(try await second.harness.getTask(id: taskID, context: .background)?.startedAt == 1_000)
        try await second.harness.close(context: .background)
    }
}
