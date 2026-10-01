import Foundation
import Testing
@testable import PiSwiftAI

private actor A3PresentHTTPClient: ProviderHTTPClient {
    let response: ProviderHTTPResponse

    init(status: Int = 403, body: Data = Data(#"{"error":{"message":"captured"}}"#.utf8)) {
        response = ProviderHTTPResponse(statusCode: status,
            headers: ["content-type": status == 200 ? "text/event-stream" : "application/json"], body: body)
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { response }
}

private func a3Payload(_ snapshot: LockedState<String?>) throws -> [String: Any] {
    let json = try #require(snapshot.withLock { $0 })
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func a3SamplingModel(_ api: Api, samplingParams: [String: AnyCodable]? = nil) -> Model {
    Model(id: "custom-model", name: "Custom Model", api: api, provider: "custom-provider",
        baseUrl: api == .azureOpenAIResponses ? "https://fixture.openai.azure.com" : "https://example.invalid/v1",
        reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 16_384, samplingParams: samplingParams)
}

private let a3SampleContext = Context(messages: [.user(UserMessage(content: .text("Hello")))])

private func a3SamplingPayload(
    api: Api,
    modelSampling: [String: AnyCodable]? = nil,
    requestSampling: [String: AnyCodable]? = nil,
    temperature: Double? = nil,
    simple: Bool = false
) async throws -> [String: Any] {
    let captured = LockedState<String?>(nil)
    let client = A3PresentHTTPClient()
    let model = a3SamplingModel(api, samplingParams: modelSampling)
    let context = normalizeContext(a3SampleContext)
    if simple {
        let options = SimpleStreamOptions(temperature: temperature, samplingParams: requestSampling,
            apiKey: "test", httpClient: client,
            onPayload: { snapshot in captured.withLock { $0 = snapshot.json } }, maxRetries: 0)
        // Use the same mapper as streamSimple without touching its process-wide provider registry.
        let mapped = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test")
        _ = await streamOpenAICompletions(model: model, context: context, options: mapped).result()
    } else {
        let onPayload: PayloadHandler = { snapshot in captured.withLock { $0 = snapshot.json } }
        switch api {
        case .openAICompletions:
            _ = await streamOpenAICompletions(model: model, context: context,
                options: OpenAICompletionsOptions(temperature: temperature, samplingParams: requestSampling,
                    apiKey: "test", httpClient: client, onPayload: onPayload, maxRetries: 0)).result()
        case .openAIResponses:
            _ = await streamOpenAIResponses(model: model, context: context,
                options: OpenAIResponsesOptions(temperature: temperature, samplingParams: requestSampling,
                    apiKey: "test", httpClient: client, onPayload: onPayload, maxRetries: 0)).result()
        case .azureOpenAIResponses:
            _ = await streamAzureOpenAIResponses(model: model, context: context,
                options: AzureOpenAIResponsesOptions(temperature: temperature, samplingParams: requestSampling,
                    apiKey: "test", httpClient: client, onPayload: onPayload, maxRetries: 0)).result()
        case .anthropicMessages:
            _ = await streamAnthropic(model: model, context: context,
                options: AnthropicOptions(temperature: temperature, apiKey: "test", httpClient: client,
                    onPayload: onPayload, maxRetries: 0)).result()
        default:
            Issue.record("Unexpected API in sampling test")
        }
    }
    return try a3Payload(captured)
}

// Port of sampling-options.test.ts (#9506).
@Test(.timeLimit(.minutes(1))) func a3SamplingOptionsApplyToDirectAndSimpleStreams() async throws {
    let direct = try await a3SamplingPayload(api: .openAICompletions,
        requestSampling: ["top_p": AnyCodable(0.95), "top_k": AnyCodable(0), "min_p": AnyCodable(0)])
    #expect(direct["top_p"] as? Double == 0.95)
    #expect(direct["top_k"] as? Int == 0)
    #expect(direct["min_p"] as? Int == 0)

    let absent = try await a3SamplingPayload(api: .openAICompletions)
    #expect(absent["temperature"] == nil)
    #expect(absent["top_p"] == nil)

    for api in [Api.openAICompletions, .openAIResponses, .azureOpenAIResponses] {
        let payload = try await a3SamplingPayload(api: api,
            modelSampling: ["top_p": AnyCodable(0.95), "min_p": AnyCodable(0.05)],
            requestSampling: ["top_p": AnyCodable(0.5)])
        #expect(payload["top_p"] as? Double == 0.5)
        #expect(payload["min_p"] as? Double == 0.05)
    }

    let simple = try await a3SamplingPayload(api: .openAICompletions,
        requestSampling: ["top_p": AnyCodable(0.5)], simple: true)
    #expect(simple["top_p"] as? Double == 0.5)

    let override = try await a3SamplingPayload(api: .openAICompletions,
        requestSampling: ["temperature": AnyCodable(1)], temperature: 0)
    #expect(override["temperature"] as? Int == 1)

    let ignored = try await a3SamplingPayload(api: .anthropicMessages,
        requestSampling: ["top_p": AnyCodable(0.9), "top_k": AnyCodable(40)])
    #expect(ignored["top_p"] == nil)
    #expect(ignored["top_k"] == nil)
}

private func a3AnthropicSSE(_ events: [[String: Any]]) throws -> Data {
    var body = Data()
    for event in events {
        body.append(Data("event: \(event["type"] as? String ?? "error")\ndata: ".utf8))
        body.append(try JSONSerialization.data(withJSONObject: event))
        body.append(Data("\n\n".utf8))
    }
    return body
}

private func a3AnthropicCacheEvents(startDetail: [String: Int]?, deltaDetail: [String: Int]?) -> [[String: Any]] {
    var startUsage: [String: Any] = ["input_tokens": 100, "output_tokens": 0,
        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 1_000_000]
    if let startDetail { startUsage["cache_creation"] = startDetail }
    var deltaUsage: [String: Any] = ["input_tokens": 100, "output_tokens": 5,
        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 1_000_000]
    if let deltaDetail { deltaUsage["cache_creation"] = deltaDetail }
    return [
        ["type": "message_start", "message": ["id": "msg_test", "type": "message", "role": "assistant",
            "content": [], "model": "claude-opus-4-8", "usage": startUsage]],
        ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hi"]],
        ["type": "content_block_stop", "index": 0],
        ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": deltaUsage],
        ["type": "message_stop"],
    ]
}

// Port of anthropic-cache-write-1h-cost.test.ts (#9210).
@Test(.timeLimit(.minutes(1))) func a3AnthropicPricesOneHourCacheWritesFromStartOrDelta() async throws {
    let opus = try #require(getModel(provider: "anthropic", modelId: "claude-opus-4-8"))
    let cases: [(start: [String: Int]?, delta: [String: Int]?, oneHour: Int, expected: Double)] = [
        (["ephemeral_5m_input_tokens": 600_000, "ephemeral_1h_input_tokens": 400_000], nil, 400_000, 7.75),
        (nil, ["ephemeral_5m_input_tokens": 600_000, "ephemeral_1h_input_tokens": 400_000], 400_000, 7.75),
        (nil, nil, 0, 6.25),
    ]
    for item in cases {
        let client = A3PresentHTTPClient(status: 200,
            body: try a3AnthropicSSE(a3AnthropicCacheEvents(startDetail: item.start, deltaDetail: item.delta)))
        let result = await streamAnthropic(model: opus, context: normalizeContext(a3SampleContext),
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        #expect(result.stopReason == .stop)
        #expect(result.usage.cacheWrite == 1_000_000)
        #expect((result.usage.cacheWrite1h ?? 0) == item.oneHour)
        #expect(abs(result.usage.cost.cacheWrite - item.expected) < 0.000_000_1)
    }

    // Vercel AI Gateway reports the breakdown only in message_delta.
    let gateway = try #require(getModel(provider: "vercel-ai-gateway", modelId: "anthropic/claude-haiku-4.5"))
    let events: [[String: Any]] = [
        ["type": "message_start", "message": ["id": "msg_test", "type": "message", "role": "assistant",
            "content": [], "model": gateway.id, "usage": ["input_tokens": 0, "output_tokens": 0]]],
        ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": [
            "input_tokens": 3, "output_tokens": 4, "cache_creation_input_tokens": 6_535,
            "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 6_535],
        ]],
        ["type": "message_stop"],
    ]
    let client = A3PresentHTTPClient(status: 200, body: try a3AnthropicSSE(events))
    let result = await streamAnthropic(model: gateway, context: normalizeContext(a3SampleContext),
        options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
    #expect(result.stopReason == .stop)
    #expect(result.usage.cacheWrite == 6_535)
    #expect(result.usage.cacheWrite1h == 6_535)
    #expect(abs(result.usage.cost.cacheWrite - 6_535 * gateway.cost.input * 2 / 1_000_000) < 0.000_000_1)
}

// Port of the catalog assertion from anthropic-empty-thinking-signature-compat.test.ts (#10047).
@Test(.timeLimit(.minutes(1))) func a3QwenFlashPreservesEmptyThinkingSignaturesForZenAndGo() async throws {
    for provider in ["opencode", "opencode-go"] {
        let model = try #require(getModel(provider: provider, modelId: "qwen3.8-flash"))
        #expect(model.compat?.allowEmptySignature == true)
        let prior = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "internal reasoning",
            thinkingSignature: " "))], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        let context = Context(messages: [.user(UserMessage(content: .text("first"))), .assistant(prior),
            .user(UserMessage(content: .text("second")))])
        let captured = LockedState<String?>(nil)
        let options = SimpleStreamOptions(apiKey: "test", httpClient: A3PresentHTTPClient(),
            onPayload: { snapshot in captured.withLock { $0 = snapshot.json } }, maxRetries: 0)
        _ = await (try streamSimple(model: model, context: context, options: options)).result()
        let payload = try a3Payload(captured)
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let blocks = try #require(assistant["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "thinking")
        #expect(blocks[0]["thinking"] as? String == "internal reasoning")
        #expect(blocks[0]["signature"] as? String == "")
    }
}

@Test func a3CopilotOpus55OffersLowThroughMax() throws {
    let model = try #require(getModel(provider: "github-copilot", modelId: "claude-opus-5.5"))
    #expect(getSupportedThinkingLevels(model) == [.low, .medium, .high, .xhigh, .max])
}
