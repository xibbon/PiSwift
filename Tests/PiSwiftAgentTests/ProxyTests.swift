import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test func proxyRequestPayloadPreservesStreamOptionSubset() throws {
    let model = Model(
        id: "gpt-test",
        name: "GPT Test",
        api: .openAIResponses,
        provider: KnownProvider.openai.rawValue,
        baseUrl: "https://api.openai.com/v1",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0.2),
        contextWindow: 128_000,
        maxTokens: 16_384
    )
    let context = Context(
        systemPrompt: "system",
        messages: [.user(UserMessage(content: .text("hello")))],
        tools: nil
    )
    let options = ProxyStreamOptions(
        temperature: 0.2,
        maxTokens: 100,
        reasoning: .high,
        authToken: "proxy-token",
        proxyUrl: "https://proxy.example",
        sessionId: "session-123",
        transport: .websocketCached,
        cacheRetention: .long,
        thinkingBudgets: [.low: 1024, .high: 8192],
        maxRetryDelayMs: 12_000,
        headers: ["X-Test": "yes"],
        metadata: ["traceId": AnyCodable("trace-1")]
    )

    let data = try encodeProxyRequestPayload(model: model, context: context, options: options)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let encodedOptions = try #require(json["options"] as? [String: Any])

    #expect(encodedOptions["temperature"] as? Double == 0.2)
    #expect(encodedOptions["maxTokens"] as? Int == 100)
    #expect(encodedOptions["reasoning"] as? String == "high")
    #expect(encodedOptions["sessionId"] as? String == "session-123")
    #expect(encodedOptions["transport"] as? String == "websocket-cached")
    #expect(encodedOptions["cacheRetention"] as? String == "long")
    #expect(encodedOptions["maxRetryDelayMs"] as? Int == 12_000)
    #expect((encodedOptions["headers"] as? [String: String])?["X-Test"] == "yes")
    #expect((encodedOptions["metadata"] as? [String: String])?["traceId"] == "trace-1")

    let budgets = try #require(encodedOptions["thinkingBudgets"] as? [String: Int])
    #expect(budgets["low"] == 1024)
    #expect(budgets["high"] == 8192)
}
