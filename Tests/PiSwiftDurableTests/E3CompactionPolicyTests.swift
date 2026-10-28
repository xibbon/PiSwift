import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct E3CompactionPolicyTests {
    @Test func exactKeyOverlaysEachFieldAndKeepsZeroAndFalse() throws {
        let settings = resolveSettings(.init(compaction: .init(enabled: true, reserveTokens: 100,
            keepRecentTokens: 200, backgroundTokens: 300, modelOverrides: [
                "faux/faux-1": .init(enabled: false, reserveTokens: 0, backgroundTokens: 0),
                "other/faux-1": .init(keepRecentTokens: 1)
            ])))
        #expect(compactionPolicy(settings: settings, model: .init(provider: "faux", modelId: "faux-1")) ==
            .init(enabled: false, reserveTokens: 0, keepRecentTokens: 200, backgroundTokens: 0))
        #expect(compactionPolicy(settings: settings, model: .init(provider: "faux", modelId: "faux-10")) ==
            .init(enabled: true, reserveTokens: 100, keepRecentTokens: 200, backgroundTokens: 300))
        #expect(compactionPolicy(settings: settings, model: .init(provider: "other", modelId: "faux-1")) ==
            .init(enabled: true, reserveTokens: 100, keepRecentTokens: 1, backgroundTokens: 300))
        let decoded = try JSONValue(encoding: settings.compaction).decode(CompactionPolicy.self)
        #expect(decoded == settings.compaction)
        #expect(try JSONValue.object(["enabled": true, "reserveTokens": 1, "keepRecentTokens": 2, "backgroundTokens": 3])
            .decode(CompactionPolicy.self).modelOverrides == nil)
        let exact = resolveSettings(.init(compaction: .init(modelOverrides: ["faux/\u{e9}": .init(reserveTokens: 0)])))
        #expect(compactionPolicy(settings: exact, model: .init(provider: "faux", modelId: "e\u{301}")) == defaultCompactionPolicy)
    }

    // Upstream v1.4.0 harness-compaction.test.ts:2412.
    @Test(arguments: ["faux/faux-1", "faux/other"])
    func currentModelOverrideControlsBlockingThreshold(key: String) async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        chat.setup.updateSettings {
            $0.compaction = .init(enabled: true, reserveTokens: 0, keepRecentTokens: 150, backgroundTokens: 0,
                modelOverrides: [key: .init(reserveTokens: 300)])
        }
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        try await compactionTurn(chat, compactionText("u4", 200), "a4")
        #expect(chat.script.summaryRequests.count == (key == "faux/faux-1" ? 1 : 0))
        try await chat.harness.close(context: .background)
    }

    // Upstream v1.4.0 harness-compaction.test.ts:2429.
    @Test func requestModelOverrideEnablesOverflowRecovery() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction?.modelOverrides = ["faux/faux-1": .init(enabled: true)] }
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText)), .message(chatAssistant("fits"))])
        #expect(try await compactionNewInput(chat, tokens: 100).wait(context: .background).status == "done")
        #expect(chat.script.summaryRequests.count == 1)
        try await chat.harness.close(context: .background)
    }

    // Upstream v1.4.0 harness-compaction.test.ts:2441.
    @Test func compactionModelOverrideSelectsAndSizesSummary() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        chat.setup.updateSettings {
            $0.compaction?.keepRecentTokens = 100_000
            $0.compaction?.modelOverrides = ["faux/faux-1": .init(reserveTokens: 500, keepRecentTokens: 150)]
        }
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let task = try await chat.root.compact(context: .background)
        #expect(try await compactionOutcome(chat, task).status == "completed")
        #expect(chat.script.summaryRequests.first?.options?.maxTokens == 400)
        #expect(try await chat.root.context(context: .background).messages.dropFirst().map { textOf($0) } ==
            [compactionText("u3", 100), compactionText("a3", 100)])
        try await chat.harness.close(context: .background)
    }

    @Test func overflowUsesRequestModelAndSummaryUsesNewAgentModelWithLiveSettings() async throws {
        let setup = HarnessChatSetup(options: .init(models: [
            .init(id: "faux-1", contextWindow: 100_000, maxTokens: 900),
            .init(id: "faux-2", contextWindow: 100_000, maxTokens: 900)
        ]))
        let chat = try await compactionOpen(setup: setup)
        try await compactionHistory(chat)
        let response = HarnessGatedResponse(message: compactionFailure(compactionOverflowText))
        chat.script.appendAgent([response.step, .message(chatAssistant("fits"))])
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let input = try await compactionNewInput(chat, tokens: 100)
        await response.reached.wait()
        try await chat.root.configure(change: .init(model: .set(.init(provider: "faux", modelId: "faux-2"))), context: .background)
        setup.updateSettings {
            $0.compaction = .init(enabled: false, reserveTokens: 0, keepRecentTokens: 100_000, backgroundTokens: 0,
                modelOverrides: ["faux/faux-1": .init(enabled: true, keepRecentTokens: 150),
                                 "faux/faux-2": .init(reserveTokens: 500, keepRecentTokens: 150)])
        }
        response.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(chat.script.summaryRequests.count == 1)
        #expect(chat.script.summaryRequests.first?.model == "faux-2")
        #expect(chat.script.summaryRequests.first?.options?.maxTokens == 400)
        try await chat.harness.close(context: .background)
    }
}
