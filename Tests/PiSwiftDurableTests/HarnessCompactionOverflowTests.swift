import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessCompactionOverflowTests {
    // Upstream 1151.
    @Test func overflowCompactsAndRetriesSameAttempt() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        var policy = compactionManualPolicy; policy.enabled = true
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText)), .factory { _, _, _, _ in
            let live = try await compactionLive(chat)
            #expect(live.generation?.attempt == 1)
            return chatAssistant("fits")
        }])
        let input = try await compactionNewInput(chat, tokens: 100)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await compactionKinds(chat.root).suffix(5) == ["pi.user", "pi.assistant", "pi.compaction", "pi.system", "pi.assistant"])
        let request = try #require(chat.script.agentRequests.last)
        #expect(compactionFirstUser(request.messages).contains("SUMMARY"))
        #expect(!request.messages.contains { if case .assistant(let value) = $0 { return value.stopReason == .error }; return false })
        let entry = try #require(await allEntries(chat.root).first { $0.kind == "pi.compaction" })
        #expect(entry.data == .object(["reason": .string("overflow")]))
        try await chat.harness.close(context: .background)
    }
    // Upstream 1180.
    @Test func secondOverflowFailsWithErrorEntry() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        var policy = compactionManualPolicy; policy.enabled = true
        compactionSetPolicy(chat, policy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText)), .message(compactionFailure(compactionOverflowText))])
        let input = try await compactionNewInput(chat, tokens: 100)
        let result = try await input.wait(context: .background)
        let record = try JSONValue(encoding: result.record)
        #expect(result.reason == "model_error" && record["detail"] == .string(compactionOverflowText))
        #expect(try await compactionKinds(chat.root).filter { $0 == "pi.compaction" }.count == 1)
        #expect(try await compactionKinds(chat.root).last == "pi.assistant")
        try await chat.harness.close(context: .background)
    }
    // Upstream 1197.
    @Test func disabledCompactionDoesNotRetryOverflow() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        chat.script.appendAgent([.message(compactionFailure("overloaded: " + compactionOverflowText))])
        let input = try await compactionNewInput(chat, tokens: 100)
        #expect(try await input.wait(context: .background).reason == "model_error")
        #expect(chat.script.agentRequests.count == 4 && chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    // Upstream 1208.
    @Test func overflowAfterThresholdDoesNotCompactAgain() async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText))])
        let input = try await compactionNewInput(chat)
        #expect(try await input.wait(context: .background).reason == "model_error")
        #expect(chat.script.summaryRequests.count == 1)
        try await chat.harness.close(context: .background)
    }
    // Upstream 1236, all three loop cases.
    @Test(arguments: ["declines", "fails", "cannot cut"])
    func unsuccessfulCompactionKeepsOverflowText(how: String) async throws {
        let chat = try await compactionOpen()
        try await compactionTurn(chat, compactionText("u1", 100), compactionText("a1", 100))
        var policy = compactionManualPolicy; policy.enabled = true
        if how == "cannot cut" { policy.keepRecentTokens = 100_000 }
        compactionSetPolicy(chat, policy)
        if how == "declines" {
            try chat.setup.registry.install(Extension(name: "decline", hooks: [hook(CompactionHooks(beforeCompact: { _, _, _ in .decline }))]))
        } else if how == "fails" { chat.script.appendSummary([.message(compactionFailure("bad request"))]) }
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText))])
        let input = try await compactionNewInput(chat, tokens: 100)
        let result = try await input.wait(context: .background)
        let record = try JSONValue(encoding: result.record)
        #expect(result.reason == "model_error" && record["detail"] == .string(compactionOverflowText))
        #expect(chat.script.summaryRequests.count == (how == "fails" ? 1 : 0))
        try await chat.harness.close(context: .background)
    }
}
