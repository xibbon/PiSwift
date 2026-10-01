import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func v087User(_ text: String) -> AgentMessage {
    .user(UserMessage(content: .text(text), timestamp: 0))
}

private func v087Assistant(_ text: String, usageTokens: Int = 11) -> AgentMessage {
    .assistant(AssistantMessage(content: [.text(TextContent(text: text))], api: .anthropicMessages,
                                provider: "anthropic", model: "test", usage: Usage(input: usageTokens - 1,
                                output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: usageTokens),
                                stopReason: .stop, timestamp: 0))
}

private let v087Settings = CompactionSettings(enabled: true, reserveTokens: 16_384, keepRecentTokens: 1)

@Test func projectedEstimateDropsUsageStaleAfterEdit() throws {
    let session = SessionManager.inMemory()
    let user = session.appendMessage(v087User(String(repeating: "discarded input ", count: 2_000)))
    let assistant = session.appendMessage(v087Assistant("small answer", usageTokens: 10_001))
    try session.appendContextEdit(user, nil)
    let estimate = estimateProjectedContextTokens(session.buildSessionProjection(), session.getBranch())
    #expect(estimate.usageTokens == 0)
    #expect(estimate.tokens < 100)
    try session.appendContextEdit(assistant, nil)
    #expect(estimateProjectedContextTokens(session.buildSessionProjection(), session.getBranch()).tokens == 0)
}

@Test func projectedEstimateKeepsUsageRecordedAfterEdit() throws {
    let session = SessionManager.inMemory()
    let user = session.appendMessage(v087User("original"))
    try session.appendContextEdit(user, .text("edited"))
    session.appendMessage(v087Assistant("answer", usageTokens: 4_100))
    session.appendMessage(v087User("next"))
    let estimate = estimateProjectedContextTokens(session.buildSessionProjection(), session.getBranch())
    #expect(estimate.usageTokens == 4_100)
    #expect(estimate.trailingTokens == 1)
    #expect(estimate.tokens == 4_101)
}

@Test func projectedEstimateDropsUsageAfterLaterCompaction() throws {
    let session = SessionManager.inMemory()
    let user = session.appendMessage(v087User("small input"))
    try session.appendContextEdit(user, .text("edited input"))
    session.appendMessage(v087Assistant("answer", usageTokens: 50_001))
    session.appendCompaction("small summary", user, 50_001)
    let estimate = estimateProjectedContextTokens(session.buildSessionProjection(), session.getBranch())
    #expect(estimate.usageTokens == 0)
    #expect(estimate.tokens < 100)
}

@Test func projectedCutKeepsReplacedInputBeforeFirstRequest() throws {
    let session = SessionManager.inMemory()
    session.appendMessage(v087User("old request"))
    session.appendMessage(v087Assistant("old answer"))
    let replaced = session.appendMessage(v087User("original input"))
    let abandoned = session.appendMessage(v087Assistant("answered original input"))
    try session.appendContextEdit(replaced, .text(String(repeating: "NEW-INSTRUCTION ", count: 100)))
    try session.appendContextEdit(abandoned, nil)
    session.appendCustomEntry("bookkeeping", ["source": "test"])
    let preparation = prepareCompaction(session.getBranch(), v087Settings)
    #expect(preparation?.firstKeptEntryId == replaced)
    #expect((preparation?.messagesToSummarize.description ?? "").contains("NEW-INSTRUCTION") == false)
    #expect((preparation?.turnPrefixMessages.description ?? "").contains("NEW-INSTRUCTION") == false)
}

@Test func projectedCutKeepsUnsentInputAheadOfMetadata() {
    let session = SessionManager.inMemory()
    session.appendMessage(v087User("old request"))
    session.appendMessage(v087Assistant("old answer"))
    let instruction = session.appendCustomMessage("next-work", .text(String(repeating: "UNSENT-INSTRUCTION ", count: 100)), false)
    session.appendCustomEntry("bookkeeping", ["source": "test"])
    let preparation = prepareCompaction(session.getBranch(), v087Settings)
    #expect(preparation?.firstKeptEntryId == instruction)
    #expect((preparation?.messagesToSummarize.description ?? "").contains("UNSENT-INSTRUCTION") == false)
}

@Test func projectedCutAdvancesPastOmittedRecoveryAttempt() throws {
    let session = SessionManager.inMemory()
    session.appendMessage(v087User(String(repeating: "recovery input ", count: 100)))
    let attempt = session.appendMessage(v087Assistant("failed attempt"))
    try session.appendContextEdit(attempt, nil)
    session.appendCustomEntry("bookkeeping", ["source": "test"])
    let preparation = prepareCompaction(session.getBranch(), v087Settings)
    #expect(preparation?.firstKeptEntryId == attempt)
    #expect(preparation?.turnPrefixMessages.count == 1)
}

@Test func projectedCutOmitsEditedContentFromSummary() throws {
    let session = SessionManager.inMemory()
    let omitted = session.appendMessage(v087User(String(repeating: "OMIT-ME ", count: 100)))
    session.appendMessage(v087Assistant(String(repeating: "old answer ", count: 100)))
    try session.appendContextEdit(omitted, nil)
    session.appendMessage(v087User("keep"))
    session.appendMessage(v087Assistant("suffix"))
    let preparation = prepareCompaction(session.getBranch(), v087Settings)
    #expect(preparation != nil)
    #expect((preparation?.messagesToSummarize.description ?? "").contains("OMIT-ME") == false)
    #expect((preparation?.turnPrefixMessages.description ?? "").contains("OMIT-ME") == false)
}

@Test func projectedCompactionDoesNotSummarizeSystemMessages() throws {
    let session = SessionManager.inMemory()
    let system = SystemMessage(content: .text(""), sections: SystemPromptSections([("preamble", "current prompt")]))
    session.appendMessage(.system(system))
    let user = session.appendMessage(v087User("one long turn"))
    let assistant = session.appendMessage(v087Assistant("assistant suffix"))
    let preparation = try #require(prepareCompaction(session.getBranch(), v087Settings))
    #expect(preparation.firstKeptEntryId == assistant)
    #expect(preparation.isSplitTurn)
    #expect(preparation.messagesToSummarize.isEmpty)
    #expect(preparation.turnPrefixMessages.count == 1)
    #expect(user != assistant)
}

@Test func omittedCustomMessageDoesNotCountAsRecoveryAttempt() throws {
    let session = SessionManager.inMemory()
    session.appendMessage(v087User(String(repeating: "unanswered input ", count: 100)))
    let custom = session.appendCustomMessage("temporary", .text("temporary context"), false)
    try session.appendContextEdit(custom, nil)
    #expect(prepareCompaction(session.getBranch(), v087Settings) == nil)
}

@Test(.timeLimit(.minutes(1))) func splitTurnPromptSeparatesConversationAndInstructions() async throws {
    let prompts = LockedState([String]())
    let model = Model(id: "compaction-test", name: "Compaction", api: .openAICompletions,
                      provider: "openai", baseUrl: "https://example.invalid", reasoning: false,
                      input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                      contextWindow: 10_000, maxTokens: 500)
    let preparation = CompactionPreparation(firstKeptEntryId: "kept", messagesToSummarize: [],
        turnPrefixMessages: [v087User("continue this work")], isSplitTurn: true, tokensBefore: 100,
        previousSummary: "previous checkpoint", fileOps: createFileOps(), settings: v087Settings)
    let result = try await compact(preparation, model, "test", streamFn: { _, context, _ in
        for message in context.messages {
            if case .user(let user) = message, case .blocks(let blocks) = user.content {
                for block in blocks {
                    if case .text(let text) = block { prompts.withLock { $0.append(text.text) } }
                }
            }
        }
        let response = AssistantMessage(content: [.text(TextContent(text: "prefix checkpoint"))],
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 5, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 7), stopReason: .stop)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: response))
        stream.end(response)
        return stream
    })
    #expect(result.summary.contains("previous checkpoint"))
    #expect(result.summary.contains("prefix checkpoint"))
    let prompt = try #require(prompts.withLock { $0.first })
    #expect(prompt.contains("# Conversation\n"))
    #expect(prompt.contains("\n# Instructions\n"))
    #expect(prompt.contains("Later messages are stored separately and do not need to be reconstructed."))
    #expect(prompt.contains("Do not infer or recreate later messages."))
    #expect(prompt.contains("PREFIX of a turn") == false)
}
