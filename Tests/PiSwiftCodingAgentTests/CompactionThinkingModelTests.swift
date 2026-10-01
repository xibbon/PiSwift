import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@Test(.timeLimit(.minutes(1))) func compactionThinkingModelAnthropic() async throws {
    let apiKey = await resolveApiKey("anthropic") ?? API_KEY
    guard let apiKey else { return }

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let ctx = createTestSession(options: TestSessionOptions(model: model, thinkingLevel: .high, apiKey: apiKey))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Write down the first 10 prime numbers.")
    await ctx.session.agent.waitForIdle()

    let messages = ctx.session.messages
    #expect(messages.isEmpty == false)
    let assistantMessages = messages.filter { $0.role == "assistant" }
    #expect(assistantMessages.isEmpty == false)

    let result = try await ctx.session.compact()

    #expect(result.summary.isEmpty == false)
    #expect(result.tokensBefore > 0)

    let messagesAfterCompact = ctx.session.messages
    #expect(messagesAfterCompact.isEmpty == false)
    #expect(messagesAfterCompact.first?.role == "compactionSummary")
}

@Test(.timeLimit(.minutes(1))) func compactionThinkingModelAntigravity() async throws {
    guard hasAuthForProvider("google-antigravity") else { return }
    guard let apiKey = await resolveApiKey("google-antigravity") else { return }
    guard let model = getModel(provider: "google-antigravity", modelId: "claude-opus-4-5-thinking") else { return }

    let ctx = createTestSession(options: TestSessionOptions(model: model, thinkingLevel: .high, apiKey: apiKey))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Write down the first 10 prime numbers.")
    await ctx.session.agent.waitForIdle()

    let result = try await ctx.session.compact()
    #expect(result.summary.isEmpty == false)
    #expect(result.tokensBefore > 0)
}
