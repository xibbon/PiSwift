import Foundation
import OpenAI
import Testing
@testable import PiSwiftAI

private actor A4CompletionsClient: ProviderHTTPClient {
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        let frame = "data: {\"id\":\"test\",\"created\":0,\"model\":\"test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(frame.utf8))
    }

    func lastRequest() -> URLRequest? { request }
}

private func a4Model(
    id: String = "test",
    api: Api = .openAICompletions,
    provider: String = "custom",
    input: [ModelInput] = [.text],
    compat: OpenAICompat? = nil,
    thinkingLevelMap: ThinkingLevelMap? = nil
) -> PiSwiftAI.Model {
    PiSwiftAI.Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.invalid/v1",
          reasoning: true, input: input, cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 8_192, compat: compat, thinkingLevelMap: thinkingLevelMap)
}

private func a4JSON(_ data: Data?) throws -> [String: Any] {
    let body = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// Port of the tagged cache-retention cases: explicit mode uses ttl for long and mode for none.
@Test func a4ResponsesExplicitCacheFields() throws {
    let gpt56 = try #require(getModel(provider: "openai", modelId: "gpt-5.6-sol"))
    #expect(gpt56.compat?.supportsExplicitPromptCacheMode == true)
    let compat = OpenAICompat(supportsExplicitPromptCacheMode: true)
    #expect(getPromptCacheRetention(baseUrl: "https://api.openai.com/v1", cacheRetention: .long, compat: compat) == nil)
    for (retention, expected) in [(CacheRetention.long, "ttl"), (.none, "mode"), (.short, "absent")] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-5.6", "input": []])
        let middleware = OpenAIResponsesCacheMiddleware(
            sessionId: "session", cacheRetention: retention, promptCacheRetention: nil,
            sessionAffinityFormat: .openai, supportsExplicitPromptCacheMode: true
        )
        let payload = try a4JSON(middleware.intercept(request: request).httpBody)
        let options = payload["prompt_cache_options"] as? [String: String]
        if expected == "ttl" { #expect(options?["ttl"] == "30m") }
        if expected == "mode" { #expect(options?["mode"] == "explicit") }
        if expected == "absent" { #expect(options == nil) }
        #expect(payload["prompt_cache_retention"] == nil)
    }
}

// Port of tagged getCompat: unknown compatible endpoints have no strict tool capability.
@Test func a4UnknownCompletionsEndpointOmitsStrict() async throws {
    let tool = AITool(name: "lookup", description: "lookup", parameters: ["type": AnyCodable("object")])
    let client = A4CompletionsClient()
    _ = await streamOpenAICompletions(model: a4Model(),
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))], tools: [tool])),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, cacheRetention: .short)).result()
    let payload = try a4JSON(await client.lastRequest()?.httpBody)
    let tools = try #require(payload["tools"] as? [[String: Any]])
    let function = try #require(tools[0]["function"] as? [String: Any])
    #expect(function["strict"] == nil)
}

@Test func a4OpenRouterCompletionsDetectsSessionAffinity() async throws {
    let client = A4CompletionsClient()
    let model = a4Model(provider: "openrouter")
    _ = await streamOpenAICompletions(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hi")))])),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client,
            cacheRetention: .short, sessionId: "session-openrouter")).result()
    let request = try #require(await client.lastRequest())
    #expect(request.value(forHTTPHeaderField: "x-session-id") == "session-openrouter")
}

@Test func a4UnknownResponsesEndpointDisablesStrict() throws {
    let tool = AITool(name: "lookup", description: "lookup", parameters: ["type": AnyCodable("object")])
    let model = a4Model(api: .openAIResponses)
    let query = try buildResponsesQuery(model: model, context: Context(messages: [], tools: [tool]),
        options: OpenAIResponsesOptions(cacheRetention: .short))
    let payload = try a4JSON(JSONEncoder().encode(query))
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools[0]["strict"] as? Bool == false)
    let capable = a4Model(api: .openAIResponses, compat: OpenAICompat(supportsStrictMode: true))
    let constrained = AITool(name: "lookup", description: "lookup", parameters: ["type": AnyCodable("object")],
        constrainedSampling: .jsonSchema(strict: .require))
    let capableQuery = try buildResponsesQuery(model: capable,
        context: Context(messages: [], tools: [constrained]), options: OpenAIResponsesOptions(cacheRetention: .short))
    let capablePayload = try a4JSON(JSONEncoder().encode(capableQuery))
    let capableTools = try #require(capablePayload["tools"] as? [[String: Any]])
    #expect(capableTools[0]["strict"] as? Bool == true)
}

// Port of the Codex default-off effort branch in openai-codex-responses.ts.
@Test func a4CodexOffEffortUsesMapAndHonorsNull() {
    for (map, expected) in [(nil, "none"), ([.off: "low"] as ThinkingLevelMap, "low"), ([.off: nil] as ThinkingLevelMap, nil)] {
        let model = a4Model(api: .openAICodexResponses, provider: "openai-codex", thinkingLevelMap: map)
        var body: [String: Any] = ["model": model.id, "input": []]
        transformCodexRequestBody(&body, options: OpenAICodexRequestOptions(), prompt: nil, model: model)
        #expect((body["reasoning"] as? [String: String])?["effort"] == expected)
        let simple = mapOpenAICodexResponsesSimpleOptions(model: model,
            options: SimpleStreamOptions(cacheRetention: .short), apiKey: "test")
        #expect(simple.reasoningEffort == nil)
    }
}

@Test func a4MistralMediumAndGLMUseReasoningEffort() {
    // Upstream #9678: the thinking-level map, not the model ID, selects reasoning_effort.
    for id in ["mistral-medium-future", "zai-glm-5-2"] {
        let model = a4Model(id: id, api: .mistralConversations, provider: "mistral",
            thinkingLevelMap: [.off: "none", .high: "high"])
        let options = mapMistralSimpleOptions(model: model,
            options: SimpleStreamOptions(reasoning: .high), apiKey: "test")
        #expect(options.reasoningEffort == "high")
        #expect(options.promptMode == nil)
    }
}

@Test func a4ImageOnlyCompletionsHasNoEmptyTextPart() async throws {
    let client = A4CompletionsClient()
    let image = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
    let user = UserMessage(content: .blocks([.text(TextContent(text: "")), .image(image)]))
    _ = await streamOpenAICompletions(model: a4Model(input: [.text, .image]),
        context: normalizeContext(Context(messages: [.user(user)])),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, cacheRetention: .short)).result()
    let payload = try a4JSON(await client.lastRequest()?.httpBody)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let userMessage = try #require(messages.first { $0["role"] as? String == "user" })
    let parts = try #require(userMessage["content"] as? [[String: Any]])
    #expect(parts.count == 1)
    #expect(parts[0]["type"] as? String == "image_url")
}

@Test func a4ResponsesErrorNamesProvider() {
    #expect(describeOpenAIError(OpenAIError.emptyData, provider: "openrouter").contains("openrouter API"))
    #expect(describeOpenAIError(OpenAIError.emptyData, provider: "openai").contains("OpenAI API"))
}

// The v0.87.1 catalog generator sets unsigned replay and distinct Fireworks effort levels.
@Test func a4GatewayAndFireworksCatalogMetadata() throws {
    let vercel = try #require(getModel(provider: "vercel-ai-gateway", modelId: "moonshotai/kimi-k3"))
    #expect(vercel.compat?.allowEmptySignature == true)
    let deepSeek = try #require(getModel(provider: "fireworks", modelId: "accounts/fireworks/models/deepseek-v4p1-flash"))
    #expect(deepSeek.compat?.forceAdaptiveThinking == true)
    #expect(getSupportedThinkingLevels(deepSeek) == [.off, .low, .high, .max])
    let qwen = try #require(getModel(provider: "fireworks", modelId: "accounts/fireworks/models/qwen3p8-max"))
    #expect(getSupportedThinkingLevels(qwen) == [.off, .low, .medium, .xhigh])
    let glm = try #require(getModel(provider: "fireworks", modelId: "accounts/fireworks/models/glm-5p3"))
    #expect(getSupportedThinkingLevels(glm) == [.low, .high, .max])
    let kimi = try #require(getModel(provider: "fireworks", modelId: "accounts/fireworks/models/kimi-k3"))
    #expect(getSupportedThinkingLevels(kimi) == [.low, .high, .max])
}
