import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessCompactionOutcomeTests {
    // harness-compaction.test.ts:732
    @Test func noRangeCompletesWithoutSummary() async throws {
        let chat = try await compactionOpen(); try await compactionTurn(chat, "hi", "hello")
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)) == .completed(result: .object([:])))
        #expect(chat.script.summaryRequests.isEmpty)
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:742
    @Test func firstHookDecisionWinsAndThrownHookIsReported() async throws {
        let chat = try await compactionOpen(), seen = Mutex<[CompactionHookInput]>([]), declined = Mutex(false)
        try chat.setup.registry.install(Extension(name: "compaction-hooks", hooks: [
            hook(CompactionHooks(beforeCompact: { _, _, _ in throw TaskDefinitionError("hook broke") })),
            hook(CompactionHooks(beforeCompact: { input, _, _ in seen.withLock { $0.append(input) }; return .summary("FROM HOOK") })),
            hook(CompactionHooks(beforeCompact: { _, _, _ in declined.withLock { $0 = true }; return .decline }))
        ]))
        try await compactionHistory(chat)
        #expect(try await compactionOutcome(chat, chat.root.compact(instructions: "why", context: .background)).status == "completed")
        #expect(chat.script.summaryRequests.isEmpty && !declined.withLock { $0 })
        #expect(try await compactionFirstUser(chat.root.context(context: .background).messages).contains("<summary>\nFROM HOOK\n</summary>"))
        #expect(chat.setup.reports.values.map { String(describing: $0) } == ["hook broke"])
        let input = try #require(seen.withLock { $0.first })
        #expect(input.reason == .manual && input.instructions == "why")
        #expect(input.entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.user", "pi.assistant"])
        #expect(input.messages.filter { $0.role != "system" }.map { textOf($0) ?? "" } == [compactionText("u1", 100), compactionText("a1", 100), compactionText("u2", 100), compactionText("a2", 100)])
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:781
    @Test func declineCompletesWithoutSummary() async throws {
        let chat = try await compactionOpen()
        try chat.setup.registry.install(Extension(name: "decline", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in .decline }))]))
        try await compactionHistory(chat)
        #expect(try await compactionOutcome(chat, chat.root.compact(context: .background)) == .completed(result: .object([:])))
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:793
    @Test func missingModelFailsAndRemovesLiveStatus() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        try await chat.root.configure(change: .init(model: .clear), context: .background)
        let outcome = try await compactionOutcome(chat, chat.root.compact(context: .background))
        if case .failed(let error, _, _) = outcome { #expect(error.detail?["reason"] == .string("no_model")) }
        else { Issue.record("Expected a no_model failure") }
        #expect(try await compactionLive(chat).compactions == nil)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:812
    @Test func retryPinsRequestAndCountsEachAttemptOnce() async throws {
        let single = try await compactionOpen(); try await compactionHistory(single)
        try await single.root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        single.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let onceBefore = try await compactionInputUsage(single)
        _ = try await compactionOutcome(single, single.root.compact(context: .background))
        let once = try await compactionInputUsage(single) - onceBefore
        #expect(once > 0); try await single.harness.close(context: .background)

        let clock = TestClock(now: 1000), chat = try await compactionOpen(clock: clock)
        try await compactionHistory(chat)
        try await chat.root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        chat.setup.updateSettings { $0.stream = .init(timeoutMs: 1234, deferred: DeferredRequest()) }
        chat.script.appendSummary([
            .factory { _, _, _, _ in
                try await chat.root.configure(change: .init(thinkingLevel: .set(.low)), context: .background)
                chat.setup.updateSettings { $0.stream = .init(timeoutMs: 1) }
                return compactionFailure("overloaded")
            },
            .message(chatAssistant("SUMMARY"))
        ])
        let before = try await compactionInputUsage(chat), id = try await chat.root.compact(context: .background)
        try await compactionAdvanceRetry(chat, clock)
        #expect(try await compactionOutcome(chat, id).status == "completed")
        #expect(chat.script.summaryRequests.count == 2)
        #expect(try await compactionInputUsage(chat) - before == 2 * once)
        let sessionId = try #require(await chat.harness.snapshot(ProviderDoc, conversationId: chat.root.id, context: .background)).sessionId
        for request in chat.script.summaryRequests {
            #expect(request.options?.reasoning == .high && request.options?.timeoutMs == 1234 && request.options?.cacheRetention == CacheRetention.none && request.options?.sessionId == sessionId && request.options?.deferred == nil)
        }
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:852; decision=decline, decision=summary("HOOK").
    @Test(arguments: [false, true]) func hookDecisionDoesNotAddUsage(supply: Bool) async throws {
        let chat = try await compactionOpen()
        try chat.setup.registry.install(Extension(name: "hook-usage", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in supply ? .summary("HOOK") : .decline }))]))
        try await compactionHistory(chat)
        let before = try await compactionInputUsage(chat)
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        #expect(try await compactionInputUsage(chat) == before)
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:864
    @Test func summaryCapsOutputBudgetAndOmitsTools() async throws {
        let chat = try await compactionOpen()
        let tool = try ToolRegistration(name: "read", description: "read", parameters: [:]) { _, _, _ in ToolExecutionResult(content: []) }
        try chat.setup.registry.install(Extension(name: "read-tool", tools: [tool]))
        try await chat.root.configure(change: .init(tools: .set(.exact([tool]))), context: .background)
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction?.reserveTokens = 2000 }; chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        let request = try #require(chat.script.summaryRequests.first)
        #expect(request.options?.maxTokens == 900 && request.messages.count == 2)
        #expect(!request.messages.contains { if case .system(let system) = $0 { system.toolsAdded != nil } else { false } })
        try await chat.harness.close(context: .background)
    }
    // harness-compaction.test.ts:905; all five source arguments are retained.
    @Test(arguments: ["retries run out", "a non-retryable error", "a length stop", "a tool call", "empty text"])
    func invalidModelResponseFailsWithoutSummary(name: String) async throws {
        let response: AssistantMessage, expected: String
        switch name {
        case "retries run out": response = compactionFailure("overloaded"); expected = "Summarization failed: overloaded"
        case "a non-retryable error": response = compactionFailure("bad request"); expected = "Summarization failed: bad request"
        case "a length stop": response = chatAssistant("partial", reason: .length); expected = "Summarization hit the token limit; the summary is incomplete"
        case "a tool call":
            var call = chatAssistant(""); call.content = [.toolCall(ToolCall(id: "read-call", name: "read", arguments: [:]))]
            response = call; expected = "Summarization attempted to call a tool"
        default: response = chatAssistant("  "); expected = "Summarization produced no text"
        }
        let clock = TestClock(now: 1000), chat = try await compactionOpen(clock: clock)
        try await compactionHistory(chat); chat.script.appendSummary(Array(repeating: .message(response), count: 3))
        let id = try await chat.root.compact(context: .background)
        if name == "retries run out" {
            for attempt in 1...2 {
                try await eventually { try await compactionLive(chat).compactions?.contains { $0.attempt == attempt && $0.retry != nil } == true }
                clock.advance(by: 100_000)
            }
        }
        let outcome = try await compactionOutcome(chat, id)
        if case .failed(let error, _, _) = outcome { #expect(error.message == expected && error.detail?["reason"] == .string("model_error")) }
        else { Issue.record("Expected a model_error failure") }
        #expect(chat.script.summaryRequests.count == (name == "retries run out" ? 3 : 1))
        #expect(try await compactionLive(chat).compactions == nil)
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        try await chat.harness.close(context: .background)
    }
}
