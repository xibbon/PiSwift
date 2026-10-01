import Foundation
import Testing
@testable import PiSwiftAI

private actor TranscriptCaptureClient: ProviderHTTPClient {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: 500, body: Data("captured".utf8))
    }
    func body() -> Data? { requests.last?.httpBody }
}
private func transcriptProviderModel(_ api: Api) -> Model {
    Model(id: "transcript-test", name: "Transcript", api: api, provider: api == .anthropicMessages ? "anthropic" : "openai",
        baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 32_000, maxTokens: 100)
}

// Explicit `.short` retention: other tests set PI_CACHE_RETENTION=long concurrently (their EnvLock only
// serializes writers), and the env var otherwise adds `prompt_cache_retention` to the Completions body.
@Test(.timeLimit(.minutes(1))) func transcriptProviderBodiesGolden() async throws {
    let plain = Context(systemPrompt: "Base", messages: [.user(UserMessage(content: .text("hello")))])
    let anthropicClient = TranscriptCaptureClient()
    _ = await streamAnthropic(model: transcriptProviderModel(.anthropicMessages), context: normalizeContext(plain),
        options: AnthropicOptions(maxTokens: 100, apiKey: "test", httpClient: anthropicClient, maxRetries: 0)).result()
    let anthropicBody = try #require(await anthropicClient.body())
    let anthropicObject = try #require(JSONSerialization.jsonObject(with: anthropicBody) as? [String: Any])
    let expectedAnthropic: [String: Any] = [
        "model": "transcript-test", "max_tokens": 100, "stream": true,
        "system": [["type": "text", "text": "Base", "cache_control": ["type": "ephemeral"]]],
        "messages": [["role": "user", "content": [["type": "text", "text": "hello", "cache_control": ["type": "ephemeral"]]]]]
    ]
    #expect(try JSONSerialization.data(withJSONObject: anthropicObject, options: [.sortedKeys]) ==
            JSONSerialization.data(withJSONObject: expectedAnthropic, options: [.sortedKeys]))

    let openAIClient = TranscriptCaptureClient()
    _ = await streamOpenAICompletions(model: transcriptProviderModel(.openAICompletions), context: normalizeContext(plain),
        options: OpenAICompletionsOptions(maxTokens: 100, apiKey: "test", httpClient: openAIClient, cacheRetention: .short, maxRetries: 0)).result()
    let openAIBody = try #require(await openAIClient.body())
    let openAIObject = try #require(JSONSerialization.jsonObject(with: openAIBody) as? [String: Any])
    let expectedOpenAI: [String: Any] = [
        "model": "transcript-test", "max_completion_tokens": 100, "stream": true, "store": false,
        "stream_options": ["include_usage": true],
        "messages": [["role": "system", "content": "Base"], ["role": "user", "content": "hello"]]
    ]
    #expect(try JSONSerialization.data(withJSONObject: openAIObject, options: [.sortedKeys]) ==
            JSONSerialization.data(withJSONObject: expectedOpenAI, options: [.sortedKeys]),
            "actual body: \(String(decoding: openAIBody, as: UTF8.self))")
}

@Test(.timeLimit(.minutes(1))) func transcriptLaterSystemCollapsesForProviders() async throws {
    let context = Context(systemPrompt: "Base", messages: [
        .user(UserMessage(content: .text("hello"))),
        .system(SystemMessage(content: .text("Later"), sections: SystemPromptSections([("section", "value")]), timestamp: 1))
    ])
    let client = TranscriptCaptureClient()
    _ = await streamAnthropic(model: transcriptProviderModel(.anthropicMessages), context: normalizeContext(context),
        options: AnthropicOptions(maxTokens: 100, apiKey: "test", httpClient: client, maxRetries: 0)).result()
    let body = try #require(await client.body())
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let systemBlocks = try #require(object["system"] as? [[String: Any]])
    #expect(systemBlocks.first?["text"] as? String == "Base\n\nLater\n\nvalue")
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
}
