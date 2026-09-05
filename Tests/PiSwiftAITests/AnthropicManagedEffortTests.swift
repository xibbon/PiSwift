import Foundation
import Testing
@testable import PiSwiftAI

private func managedEffortModel(managed: Bool = true, adaptive: Bool = true, provider: String = "anthropic") -> Model {
    Model(id: "custom-model", name: "Custom", api: .anthropicMessages, provider: provider,
          baseUrl: "https://example.invalid", reasoning: true, input: [.text],
          cost: ModelCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4),
          contextWindow: 200_000, maxTokens: 32_000,
          compat: OpenAICompat(forceAdaptiveThinking: adaptive, supportsMidConvoEffort: managed))
}

private func effortAssistant(provider: String = "anthropic", level: String? = nil, api: Api = .anthropicMessages) -> AssistantMessage {
    var result = AssistantMessage(content: [.thinking(ThinkingContent(thinking: "reasoning", thinkingSignature: "signature")), .text(TextContent(text: "answer"))],
        api: api, provider: provider, model: "custom-model", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    result.providerThinkingLevel = level
    return result
}

private func managedPayload(model: Model, effort: ThinkingLevel? = nil, history: [AssistantMessage] = [], enabled: Bool? = true, display: ThinkingDisplay? = nil) throws -> [String: Any] {
    var contextMessages: [Message] = [.user(UserMessage(content: .text("one")))]
    var messages: [[String: Any]] = [["role": "user", "content": "one"]]
    for assistant in history {
        contextMessages.append(.assistant(assistant))
        contextMessages.append(.user(UserMessage(content: .text("next"))))
        messages.append(["role": "assistant", "content": [["type": "text", "text": "answer"]]])
        messages.append(["role": "user", "content": "next"])
    }
    let body = try JSONSerialization.data(withJSONObject: ["messages": messages, "temperature": 0.5, "stream": false])
    let options = AnthropicOptions(thinkingEnabled: enabled, effort: effort, thinkingDisplay: display)
    return try #require(JSONSerialization.jsonObject(with: prepareAnthropicRawPayload(body, model: model, context: Context(messages: contextMessages), options: options)) as? [String: Any])
}

private func markers(_ payload: [String: Any]) -> [String] {
    (payload["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "system" }
        .compactMap { ($0["output_config"] as? [String: String])?["effort"] }
}

@Test(arguments: [ThinkingLevel.low, .medium, .high, .xhigh, .max])
func anthropicManagedPreservesNativeEffort(_ effort: ThinkingLevel) throws {
    let payload = try managedPayload(model: managedEffortModel(), effort: effort)
    #expect(markers(payload) == [effort.rawValue])
    #expect(payload["stream"] as? Bool == true)
    #expect(payload["output_config"] as? [String: String] == ["effort": "high"])
    #expect(payload["temperature"] == nil)
}

@Test func anthropicManagedReconstructsHistoricalPrefix() throws {
    let model = managedEffortModel()
    let first = try managedPayload(model: model, effort: .low)
    let second = try managedPayload(model: model, effort: .high, history: [effortAssistant(level: "low")])
    let prefix = try #require(first["messages"] as? [[String: Any]])
    let messages = try #require(second["messages"] as? [[String: Any]])
    #expect(NSArray(array: Array(messages.prefix(prefix.count))).isEqual(to: prefix))
    #expect(markers(second) == ["low", "high"])
}

@Test func anthropicManagedIgnoresLegacyAndForeignMarkers() throws {
    let payload = try managedPayload(model: managedEffortModel(), effort: .medium, history: [
        effortAssistant(), effortAssistant(provider: "other", level: "low"), effortAssistant(level: "invalid"),
        effortAssistant(level: "high", api: .openAIResponses),
    ])
    #expect(markers(payload) == ["medium"])
}

@Test func anthropicManagedDoesNotDeduplicateMarkers() throws {
    let payload = try managedPayload(model: managedEffortModel(), effort: .low,
                                    history: [effortAssistant(level: "low"), effortAssistant(level: "low")])
    #expect(markers(payload) == ["low", "low", "low"])
}

@Test(arguments: [true, false])
func anthropicManagedAlwaysEnablesBinding(_ enabled: Bool) throws {
    let payload = try managedPayload(model: managedEffortModel(adaptive: false), enabled: enabled)
    #expect(markers(payload) == ["high"])
    let thinking = try #require(payload["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "adaptive")
    #expect(thinking["display"] as? String == "summarized")
    #expect(thinking["block_binding"] as? [String: String] == ["prefix_mismatch_behavior": "drop_block"])
}

@Test func anthropicUnsupportedEffortRemainsTopLevel() throws {
    let payload = try managedPayload(model: managedEffortModel(managed: false), effort: .low, display: .omitted)
    #expect(markers(payload).isEmpty)
    #expect(payload["thinking"] as? [String: String] == ["type": "adaptive", "display": "omitted"])
    #expect(payload["output_config"] as? [String: String] == ["effort": "low"])
}

@Test func anthropicAdaptiveUsesCompatInsteadOfModelName() throws {
    let payload = try managedPayload(model: managedEffortModel(managed: false, adaptive: false), effort: .max)
    let thinking = try #require(payload["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "enabled")
    #expect(thinking["budget_tokens"] as? Int == 1024)
    #expect(payload["output_config"] == nil)
}

@Test func anthropicBetaManagedAndDisabledThinking() {
    let context = Context(messages: [])
    let options = AnthropicOptions(thinkingEnabled: false)
    let features = anthropicBetaFeatures(model: managedEffortModel(), context: context, options: options) ?? []
    #expect(features.contains("mid-conversation-output-config-2026-07-01"))
    #expect(features.contains("thinking-binding-controls-2026-08-01"))
    #expect(!features.contains("interleaved-thinking-2025-05-14"))
}

@Test func anthropicBetaOverrideTrimsAndDeduplicates() {
    let options = AnthropicOptions(headers: ["ANTHROPIC-BETA": " custom , custom, another, "])
    #expect(anthropicBetaFeatures(model: managedEffortModel(), context: Context(messages: []), options: options) == ["custom", "another"])
}

@Test func anthropicBetaNullAndEmptySuppressDefaults() {
    let cases: [ProviderHeaders] = [["anthropic-beta": nil], ["Anthropic-Beta": ""]]
    for headers in cases {
        #expect(anthropicBetaFeatures(model: managedEffortModel(), context: Context(messages: []), options: AnthropicOptions(headers: headers)) == nil)
    }
}

@Test func anthropicRawDecoderReadsServingModelAndTransformations() throws {
    let lines = [
        "event: message_start", #"data: {"type":"message_start","message":{"type":"message","role":"assistant","content":[],"id":"m","model":"fallback-model","usage":{"input_tokens":1,"output_tokens":0},"input_transformations":[{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch","extra":"ignored"}]}}"#, "",
        "event: message_delta", #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1},"input_transformations":[{"type":"thinking_dropped","path":"messages.3.content.0","reason":"model_binding_mismatch"}]}"#, "",
        "event: message_stop", #"data: {"type":"message_stop"}"#, "",
    ]
    let events = try decodeAnthropicSSEEvents(lines)
    #expect(events[0].servingModel == "fallback-model")
    #expect(events[0].inputTransformations?.first?["extra"] == nil)
    #expect(events[1].inputTransformations?.first?["path"]?.value as? String == "messages.3.content.0")
}

private actor EffortHTTPClient: ProviderHTTPClient {
    let body: Data
    var request: URLRequest?
    init(events: [[String: Any]]) throws {
        body = try Data(events.map { event in
            let json = String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
            return "event: \(event["type"] as! String)\ndata: \(json)\n\n"
        }.joined().utf8)
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func effortEvents(fallbackAfterContent: Bool = false) -> [[String: Any]] {
    var events: [[String: Any]] = [
        ["type": "message_start", "message": ["type": "message", "role": "assistant", "content": [], "id": "message", "model": "serving-model", "usage": ["input_tokens": 10, "output_tokens": 0],
            "input_transformations": [["type": "thinking_dropped", "path": "messages.1.content.0", "reason": "prefix_binding_mismatch"]]]],
    ]
    let fallback: [String: Any] = ["type": "content_block_start", "index": 3, "content_block": ["type": "fallback", "from": ["model": "custom-model"], "to": ["model": "serving-model"]]]
    if !fallbackAfterContent { events.append(fallback) }
    events.append(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "partial"]])
    if fallbackAfterContent { events.append(fallback) }
    events += [
        ["type": "content_block_stop", "index": 0],
        ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 5],
            "input_transformations": [["type": "thinking_dropped", "path": "messages.3.content.0", "reason": "model_binding_mismatch"]]],
        ["type": "message_stop"],
    ]
    return events
}

@Test func anthropicManagedTransportAndFinalTransformations() async throws {
    let client = try EffortHTTPClient(events: effortEvents())
    let result = await streamAnthropic(model: managedEffortModel(), context: Context(messages: [.user(UserMessage(content: .text("one")))]),
        options: AnthropicOptions(apiKey: "test-key", httpClient: client, effort: .low)).result()
    #expect(result.stopReason == .stop)
    #expect(result.model == "serving-model")
    #expect(result.providerThinkingLevel == "low")
    let diagnostic = try #require(result.diagnostics?.first)
    #expect(diagnostic.type == "anthropic_input_transformations")
    let transformations = try #require(diagnostic.details["transformations"]?.value as? [[String: Any]])
    #expect(transformations.first?["path"] as? String == "messages.3.content.0")
    let request = try #require(await client.request)
    #expect(request.value(forHTTPHeaderField: "anthropic-beta")?.contains("thinking-binding-controls-2026-08-01") == true)
    let requestBody = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(markers(payload) == ["low"])
    #expect(payload["stream"] as? Bool == true)
}

@Test func anthropicRejectsFallbackAfterOutput() async throws {
    let client = try EffortHTTPClient(events: effortEvents(fallbackAfterContent: true))
    let result = await streamAnthropic(model: managedEffortModel(), context: Context(messages: []),
        options: AnthropicOptions(apiKey: "test-key", httpClient: client)).result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("unsupported mid-output model fallback") == true)
    #expect(result.diagnostics == nil)
}

@Test func anthropicFallbackPricesRequireProviderAndModelMatch() {
    let base = managedEffortModel()
    let cost = ModelCost(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
    let model = Model(id: base.id, name: base.name, api: base.api, provider: base.provider, baseUrl: base.baseUrl,
        reasoning: base.reasoning, input: base.input, cost: base.cost, contextWindow: base.contextWindow, maxTokens: base.maxTokens,
        compat: OpenAICompat(allowedFallbackModels: [
            AnthropicAllowedFallbackModel(provider: "other", model: "wrong-provider", cost: cost),
            AnthropicAllowedFallbackModel(provider: "anthropic", model: "serving-model", cost: cost),
        ]))
    #expect(anthropicUsageModel(model, servingModel: "serving-model").cost.input == 10)
    #expect(anthropicUsageModel(model, servingModel: "wrong-provider").cost.input == 1)
    #expect(anthropicUsageModel(model, servingModel: "unknown").cost.input == 1)
    #expect(anthropicUsageModel(model, servingModel: base.id).cost.input == 1)
}
