import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct E3CompactionPolicyTests {
    @Test func conversationLayersResolveInTaggedOrder() {
        // v1.5.2 durable/test/harness-compaction.test.ts:2461-2495.
        let ref = ModelRef(provider: "faux", modelId: "faux-1")
        let base = resolveSettings(.init(compaction: .init(reserveTokens: 100)))
        #expect(compactionPolicy(settings: base, model: ref,
            conversation: .init(reserveTokens: 500)).reserveTokens == 500)
        let hostModel = resolveSettings(.init(compaction: .init(reserveTokens: 100,
            modelOverrides: ["faux/faux-1": .init(reserveTokens: 250)])))
        #expect(compactionPolicy(settings: hostModel, model: ref,
            conversation: .init(reserveTokens: 500)).reserveTokens == 250)
        #expect(compactionPolicy(settings: hostModel, model: ref,
            conversation: .init(reserveTokens: 500,
                modelOverrides: ["faux/faux-1": .init(reserveTokens: 125)])).reserveTokens == 125)
        #expect(compactionPolicy(settings: base, model: ref,
            conversation: .init(reserveTokens: 500,
                modelOverrides: ["faux/other": .init(reserveTokens: 125)])).reserveTokens == 500)
    }

    @Test func conversationDisableWinsExceptOwnModelOverride() {
        // v1.5.2 durable/test/harness-compaction.test.ts:2497-2519.
        let ref = ModelRef(provider: "faux", modelId: "faux-1")
        let settings = resolveSettings(.init(compaction: .init(enabled: true,
            modelOverrides: ["faux/faux-1": .init(enabled: true)])))
        #expect(compactionPolicy(settings: settings, model: ref).enabled)
        #expect(!compactionPolicy(settings: settings, model: ref, conversation: .init(enabled: false)).enabled)
        #expect(compactionPolicy(settings: settings, model: ref,
            conversation: .init(enabled: false,
                modelOverrides: ["faux/faux-1": .init(enabled: true)])).enabled)
    }

    @Test(.timeLimit(.minutes(1))) func conversationPolicySetsSummaryBudget() async throws {
        // v1.5.2 durable/test/harness-compaction.test.ts:2461-2495.
        let cases: [(CompactionPolicyOverrides, CompactionPolicyOverrides, Int)] = [
            (.init(), .init(reserveTokens: 500), 400),
            (.init(modelOverrides: ["faux/faux-1": .init(reserveTokens: 250)]), .init(reserveTokens: 500), 200),
            (.init(modelOverrides: ["faux/faux-1": .init(reserveTokens: 250)]),
             .init(reserveTokens: 500, modelOverrides: ["faux/faux-1": .init(reserveTokens: 125)]), 100),
            (.init(), .init(reserveTokens: 500, modelOverrides: ["faux/other": .init(reserveTokens: 125)]), 400)
        ]
        for (host, conversation, expected) in cases {
            let chat = try await compactionOpen()
            try await compactionHistory(chat)
            chat.setup.updateSettings { $0.compaction = .init(enabled: false, reserveTokens: 1000,
                keepRecentTokens: 150, backgroundTokens: 0, modelOverrides: host.modelOverrides) }
            try await chat.root.configure(change: .init(compaction: .set(conversation)), context: .background)
            chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
            let task = try await chat.root.compact(context: .background)
            #expect(try await compactionOutcome(chat, task).status == "completed")
            #expect(chat.script.summaryRequests.first?.options?.maxTokens == expected)
            try await chat.harness.close(context: .background)
        }
    }

    @Test(.timeLimit(.minutes(1))) func conversationDisableChangesThresholdBeforeTaskCreation() async throws {
        // v1.5.2 durable/test/harness-compaction.test.ts:2497-2519.
        for variant in 0..<3 {
            let chat = try await compactionOpen(contextWindow: 1000)
            try await compactionHistory(chat)
            chat.setup.updateSettings { $0.compaction = .init(enabled: true, reserveTokens: 0,
                keepRecentTokens: 150, backgroundTokens: 0,
                modelOverrides: ["faux/faux-1": .init(enabled: true, reserveTokens: 300)]) }
            if variant == 1 {
                try await chat.root.configure(change: .init(compaction: .set(.init(enabled: false))), context: .background)
            } else if variant == 2 {
                try await chat.root.configure(change: .init(compaction: .set(.init(enabled: false,
                    modelOverrides: ["faux/faux-1": .init(enabled: true)]))), context: .background)
            }
            chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
            try await compactionTurn(chat, compactionText("u4", 200), "a4")
            #expect(chat.script.summaryRequests.count == (variant == 1 ? 0 : 1))
            try await chat.harness.close(context: .background)
        }
    }

    @Test(.timeLimit(.minutes(1))) func conversationDisableSkipsOverflowCompaction() async throws {
        // v1.5.2 durable/test/harness-compaction.test.ts:2520-2531.
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.compaction?.enabled = true }
        try await chat.root.configure(change: .init(compaction: .set(.init(enabled: false))), context: .background)
        chat.script.appendAgent([.message(compactionFailure(compactionOverflowText))])
        let input = try await compactionNewInput(chat, tokens: 100)
        #expect(try await input.wait(context: .background).status == "unanswered")
        #expect(chat.script.summaryRequests.isEmpty)
        try await chat.harness.close(context: .background)
    }
    @Test(.timeLimit(.minutes(1))) func conversationPolicyStoresRejectsAndClears() async throws {
        // v1.5.2 durable/test/harness-compaction.test.ts:2532-2550.
        let setup = HarnessChatSetup()
        let opened = try await openChat(setup: setup)
        let policy = CompactionPolicyOverrides(keepRecentTokens: 0,
            modelOverrides: ["faux/faux-1": .init(reserveTokens: 10)])
        try await opened.root.configure(change: .init(compaction: .set(policy)), context: .background)
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id,
            context: .background)?.compaction == policy)
        do {
            try await opened.root.configure(change: .init(compaction: .set(.init(reserveTokens: -1))), context: .background)
            Issue.record("Negative token count was accepted")
        } catch { #expect(String(describing: error).contains("reserveTokens")) }
        do {
            try await opened.root.configure(change: .init(compaction: .set(.init(modelOverrides: [
                "faux/faux-1": .init(backgroundTokens: -1)]))), context: .background)
            Issue.record("Negative model token count was accepted")
        } catch { #expect(String(describing: error).contains("backgroundTokens")) }
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id,
            context: .background)?.compaction == policy)
        try await opened.root.configure(change: .init(compaction: .clear), context: .background)
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id,
            context: .background)?.compaction == nil)
        try await opened.harness.close(context: .background)
    }
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
