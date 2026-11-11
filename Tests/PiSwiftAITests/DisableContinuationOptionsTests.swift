import Testing
@testable import PiSwiftAI

@Test(arguments: [nil, false, true] as [Bool?])
func anthropicSimpleOptionsPreserveContinuationControl(_ disabled: Bool?) {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))]))
    for reasoning: ReasoningEffort? in [nil, .high] {
        let mapped = mapAnthropicSimpleOptions(model: model, context: context,
            options: SimpleStreamOptions(reasoning: reasoning, disableContinuation: disabled), apiKey: "test")
        #expect(mapped.disableContinuation == disabled)
    }
}

@Test func bedrockSimpleOptionsPreserveSession() {
    let model = Model(id: "anthropic.claude-test", name: "Claude", api: .bedrockConverseStream,
        provider: KnownProvider.amazonBedrock.rawValue, baseUrl: "", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 8192)
    for reasoning: ReasoningEffort? in [nil, .high] {
        let mapped = mapBedrockSimpleOptions(model: model,
            options: SimpleStreamOptions(reasoning: reasoning, sessionId: "session"))
        #expect(mapped.sessionId == "session")
    }
}
