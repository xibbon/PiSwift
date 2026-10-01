import Foundation
import Testing
@testable import PiSwiftAI

private actor A4CaptureHTTP: ProviderHTTPClient {
    private var request: URLRequest?
    private let body: Data

    init(body: Data = Data(#"{"error":{"message":"captured"}}"#.utf8)) { self.body = body }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 403, body: body)
    }

    func captured() -> URLRequest? { request }
}

private actor A4AnthropicSSEHTTP: ProviderHTTPClient {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let events: [[String: Any]] = [
            ["type": "message_start", "message": [
                "type": "message", "role": "assistant", "content": [], "id": "msg-1", "model": "requested-model",
                "usage": ["input_tokens": 100, "output_tokens": 0, "cache_creation_input_tokens": 1_000_000,
                    "cache_creation": ["ephemeral_1h_input_tokens": 400_000]],
            ]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ]
        var body = Data()
        for event in events {
            body.append(Data("event: \(event["type"] as? String ?? "error")\ndata: ".utf8))
            body.append(try JSONSerialization.data(withJSONObject: event))
            body.append(Data("\n\n".utf8))
        }
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: body)
    }
}

private func a4Model(api: Api, provider: String, compat: OpenAICompat? = nil) -> Model {
    Model(id: "requested-model", name: "Requested", api: api, provider: provider,
        baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1.25),
        contextWindow: 16_000, maxTokens: 1024, compat: compat)
}

private func a4Request(api: Api, provider: String, sessionId: String? = nil,
                       cacheRetention: CacheRetention = .short, headers: ProviderHeaders? = nil,
                       compat: OpenAICompat? = nil, simple: Bool = false) async throws -> URLRequest {
    let client = A4CaptureHTTP()
    let model = a4Model(api: api, provider: provider, compat: compat)
    let context = Context(messages: [.user(UserMessage(content: .text("hello")))])
    if api == .googleGenerativeAI {
        let transcript = normalizeContext(context)
        if simple {
            let options = try mapGoogleSimpleOptionsValidated(model: model,
                options: SimpleStreamOptions(apiKey: "fixture-key", httpClient: client,
                    cacheRetention: cacheRetention, sessionId: sessionId, headers: headers, maxRetries: 0),
                apiKey: "fixture-key")
            _ = await streamGoogle(model: model, context: transcript, options: options).result()
        } else {
            _ = await streamGoogle(model: model, context: transcript,
                options: GoogleOptions(apiKey: "fixture-key", httpClient: client,
                    sessionId: sessionId, headers: headers, maxRetries: 0)).result()
        }
        return try #require(await client.captured())
    }
    if simple {
        _ = await (try streamSimple(model: model, context: context,
            options: SimpleStreamOptions(apiKey: "fixture-key", httpClient: client,
                cacheRetention: cacheRetention, sessionId: sessionId, headers: headers, maxRetries: 0))).result()
    } else {
        _ = await (try stream(model: model, context: context,
            options: StreamOptions(apiKey: "fixture-key", httpClient: client,
                cacheRetention: cacheRetention, sessionId: sessionId, headers: headers, maxRetries: 0))).result()
    }
    return try #require(await client.captured())
}

// Port of opencode-provider-headers.test.ts: direct and simple dispatch share the
// case-insensitive, non-overwriting session-header rule, even with caching off.
@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .googleGenerativeAI, .openAICompletions, .openAIResponses], [false, true])
func a4OpenCodeSessionHeaderAcrossAdapters(api: Api, simple: Bool) async throws {
    for provider in ["opencode", "opencode-go"] {
        let request = try await a4Request(api: api, provider: provider, sessionId: "conversation-1",
            cacheRetention: CacheRetention.none, simple: simple)
        #expect(request.value(forHTTPHeaderField: "x-opencode-session") == "conversation-1")
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["opencode", "opencode-go"])
func a4OpenCodeSessionHeaderPreservesCallerOverride(provider: String) async throws {
    for header: ProviderHeaders in [["X-OpenCode-Session": "caller-value"], ["X-OpenCode-Session": nil]] {
        let merged = openCodeSessionHeaders(model: a4Model(api: .anthropicMessages, provider: provider),
            sessionId: "generated-value", headers: header)
        #expect(merged?["X-OpenCode-Session"] == header["X-OpenCode-Session"])
        #expect(merged?.count == 1)
    }
    #expect(openCodeSessionHeaders(model: a4Model(api: .anthropicMessages, provider: provider),
        sessionId: nil, headers: ["x-custom": "value"])?["x-opencode-session"] == nil)
}

// Port of fireworks-models.test.ts OpenRouter and Fireworks affinity cases.
@Test(.timeLimit(.minutes(1))) func a4AnthropicOpenRouterAffinityUsesOnlySessionIdHeader() async throws {
    let request = try await a4Request(api: .anthropicMessages, provider: "openrouter", sessionId: "route-1")
    #expect(request.value(forHTTPHeaderField: "x-session-id") == "route-1")
    #expect(request.value(forHTTPHeaderField: "x-session-affinity") == nil)

    let disabled = try await a4Request(api: .anthropicMessages, provider: "openrouter", sessionId: "route-2",
        cacheRetention: CacheRetention.none)
    #expect(disabled.value(forHTTPHeaderField: "x-session-id") == nil)

    let overridden = try await a4Request(api: .anthropicMessages, provider: "openrouter", sessionId: "route-3",
        compat: OpenAICompat(sendSessionAffinityHeaders: false))
    #expect(overridden.value(forHTTPHeaderField: "x-session-id") == nil)
}

@Test(.timeLimit(.minutes(1))) func a4AnthropicFireworksAffinityRequiresCompatFlag() async throws {
    let request = try await a4Request(api: .anthropicMessages, provider: "fireworks", sessionId: "fireworks-1",
        compat: OpenAICompat(sendSessionAffinityHeaders: true))
    #expect(request.value(forHTTPHeaderField: "x-session-affinity") == "fireworks-1")
    let uncached = try await a4Request(api: .anthropicMessages, provider: "fireworks", sessionId: "fireworks-2",
        cacheRetention: CacheRetention.none, compat: OpenAICompat(sendSessionAffinityHeaders: true))
    #expect(uncached.value(forHTTPHeaderField: "x-session-affinity") == nil)
}

// Port of openai-completions-prompt-cache.test.ts Baseten catalog assertion.
@Test(.timeLimit(.minutes(1))) func a4BasetenCatalogAffinityReachesCompletionsRequest() async throws {
    let model = try #require(getModels(provider: .baseten).first { $0.compat?.sendSessionAffinityHeaders == true })
    let client = A4CaptureHTTP()
    _ = await streamOpenAICompletions(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
        options: OpenAICompletionsOptions(apiKey: "fixture-key", httpClient: client,
            cacheRetention: .short, sessionId: "baseten-1", maxRetries: 0)).result()
    let request = try #require(await client.captured())
    #expect(request.value(forHTTPHeaderField: "x-session-affinity") == "baseten-1")
    #expect(request.value(forHTTPHeaderField: "x-client-request-id") == "baseten-1")
    let uncached = A4CaptureHTTP()
    _ = await streamOpenAICompletions(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
        options: OpenAICompletionsOptions(apiKey: "fixture-key", httpClient: uncached,
            cacheRetention: CacheRetention.none, sessionId: "baseten-2", maxRetries: 0)).result()
    let uncachedRequest = try #require(await uncached.captured())
    #expect(uncachedRequest.value(forHTTPHeaderField: "x-session-affinity") == nil)
}

@Test(.timeLimit(.minutes(1))) func a4OpenRouterCompletionsAffinityRespectsCacheRetention() async throws {
    let compat = OpenAICompat(sendSessionAffinityHeaders: true, sessionAffinityFormat: .openrouter)
    let cached = try await a4Request(api: .openAICompletions, provider: "openrouter",
        sessionId: "openrouter-1", compat: compat)
    #expect(cached.value(forHTTPHeaderField: "x-session-id") == "openrouter-1")
    #expect(cached.value(forHTTPHeaderField: "x-session-affinity") == nil)
    let uncached = try await a4Request(api: .openAICompletions, provider: "openrouter",
        sessionId: "openrouter-2", cacheRetention: CacheRetention.none, compat: compat)
    #expect(uncached.value(forHTTPHeaderField: "x-session-id") == nil)
}

// Port of bedrock-cache-write-1h-cost.test.ts; the 1h detail is a subset of cacheWrite.
@Test func a4BedrockOneHourWritesUseSeparateRateWithoutChangingTokenTotal() throws {
    let model = a4Model(api: .bedrockConverseStream, provider: "amazon-bedrock")
    var output = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .pending)
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    let metadata: [String: Any] = ["usage": [
        "inputTokens": 100, "outputTokens": 5, "totalTokens": 1_000_105,
        "cacheWriteInputTokens": 1_000_000,
        "cacheDetails": [["ttl": "1h", "inputTokens": 150_000],
                         ["ttl": "5m", "inputTokens": 600_000],
                         ["ttl": "1h", "inputTokens": 250_000]],
    ]]
    try processBedrockFixture(type: "metadata", payload: JSONSerialization.data(withJSONObject: metadata),
        model: model, output: &output, state: &state, stream: stream)
    #expect(output.usage.cacheWrite == 1_000_000)
    #expect(output.usage.cacheWrite1h == 400_000)
    #expect(output.usage.totalTokens == 1_000_105)
    #expect(output.usage.cost.cacheWrite == (600_000 * model.cost.cacheWrite + 400_000 * model.cost.input * 2) / 1_000_000)
    let restored = usageFromJSONObject(usageToJSONObject(output.usage))
    #expect(restored.cacheWrite1h == 400_000)
}

@Test func a4ResponseModelRoundTripsWithoutReplacingRequestedModel() {
    let message = AssistantMessage(content: [], api: .anthropicMessages, provider: "anthropic",
        model: "requested", responseModel: "served",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let restored = assistantMessageFromJSONObject(assistantMessageToJSONObject(message))
    #expect(restored.model == "requested")
    #expect(restored.responseModel == "served")
}

@Test(.timeLimit(.minutes(1))) func a4AnthropicOneHourUsageDetailUsesSeparateRate() async {
    let model = a4Model(api: .anthropicMessages, provider: "anthropic")
    let result = await streamAnthropic(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
        options: AnthropicOptions(apiKey: "fixture-key", httpClient: A4AnthropicSSEHTTP(),
            cacheRetention: .short, maxRetries: 0)).result()
    #expect(result.usage.cacheWrite == 1_000_000)
    #expect(result.usage.cacheWrite1h == 400_000)
    #expect(result.usage.cost.cacheWrite == (600_000 * model.cost.cacheWrite + 400_000 * model.cost.input * 2) / 1_000_000)
}

// Upstream anthropic-messages.ts preserves unsigned thinking for compatible relays.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func a4AnthropicUnsignedThinkingReplayFollowsCompat(allowEmptySignature: Bool) async throws {
    let model = Model(id: "requested-model", name: "Requested", api: .anthropicMessages,
        provider: "vercel-ai-gateway", baseUrl: "https://example.invalid/v1",
        reasoning: true, input: [.text], cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
        contextWindow: 16_000, maxTokens: 1024,
        compat: OpenAICompat(allowEmptySignature: allowEmptySignature))
    let earlier = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "private thought"))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let captured = LockedState<String?>(nil)
    let client = A4CaptureHTTP()
    _ = await streamAnthropic(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("start"))),
            .assistant(earlier), .user(UserMessage(content: .text("continue")))])),
        options: AnthropicOptions(apiKey: "fixture-key", httpClient: client,
            cacheRetention: .short, onPayload: { snapshot in captured.withLock { $0 = snapshot.json } },
            maxRetries: 0)).result()
    let json = try #require(captured.withLock { $0 })
    let body = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
    let blocks = try #require(assistant["content"] as? [[String: Any]])
    #expect(blocks.first?["type"] as? String == (allowEmptySignature ? "thinking" : "text"))
    if allowEmptySignature { #expect(blocks.first?["signature"] as? String == "") }
}

@Test(.timeLimit(.minutes(1))) func a4AzureResponsesErrorUsesActualProviderName() async {
    let client = A4CaptureHTTP(body: Data())
    let model = Model(id: "deployment", name: "Azure deployment", api: .azureOpenAIResponses,
        provider: "azure-openai-responses", baseUrl: "https://fixture.openai.azure.com",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 16_000, maxTokens: 1024)
    let result = await streamAzureOpenAIResponses(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
        options: AzureOpenAIResponsesOptions(apiKey: "fixture-key", httpClient: client, maxRetries: 0)).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("Azure OpenAI API error") == true)
}
