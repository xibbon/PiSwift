import Foundation
import Testing
@testable import PiSwiftAI

private actor AnthropicAuditHTTP: ProviderHTTPClient {
    let body: Data
    var requests: [URLRequest] = []
    init(events: [[String: Any]]) throws {
        var body = Data()
        for event in events {
            let type = event["type"] as? String ?? "error"
            body.append(Data("event: \(type)\ndata: ".utf8))
            body.append(try JSONSerialization.data(withJSONObject: event))
            body.append(Data("\n\n".utf8))
        }
        self.body = body
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: body)
    }
}

private func anthropicAuditModel(headers: ProviderHeaders? = nil, provider: String = "anthropic") -> Model {
    Model(id: "requested-model", name: "Requested", api: .anthropicMessages, provider: provider, baseUrl: "https://example.invalid",
        reasoning: true, input: [.text], cost: ModelCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4),
        contextWindow: 200_000, maxTokens: 4096, headers: headers,
        compat: OpenAICompat(supportsStrictTools: true, forceAdaptiveThinking: true, supportsMidConvoEffort: true,
            allowedFallbackModels: [
                AnthropicAllowedFallbackModel(provider: provider, model: "served-model", cost: ModelCost(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)),
                AnthropicAllowedFallbackModel(provider: "different-provider", model: "foreign-model", cost: ModelCost(input: 100, output: 200, cacheRead: 300, cacheWrite: 400)),
            ]))
}

private func anthropicAuditEvents(serving: String = "served-model", transformationMode: String = "replace", midOutput: Bool = false, errorAfterStart: Bool = false) -> [[String: Any]] {
    let initial = [["type": "thinking_dropped", "path": "messages.1.content.0", "reason": "prefix_binding_mismatch", "ignored": "secret"]]
    var events: [[String: Any]] = [["type": "message_start", "message": [
        "type": "message", "role": "assistant", "content": [], "id": "msg-audit", "model": serving,
        "usage": ["input_tokens": 1_000_000, "output_tokens": 0, "cache_read_input_tokens": 3_000_000, "cache_creation_input_tokens": 4_000_000],
        "input_transformations": initial,
    ]]]
    if errorAfterStart { events.append(["type": "error", "error": ["type": "api_error", "message": "fixture failure"]]); return events }
    let fallback: [String: Any] = ["type": "content_block_start", "index": 9,
        "content_block": ["type": "fallback", "from": ["model": "requested-model"], "to": ["model": serving]]]
    if !midOutput { events.append(fallback) }
    events.append(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "partial"]])
    if midOutput { events.append(fallback); return events }
    events.append(["type": "content_block_stop", "index": 0])
    var delta: [String: Any] = ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 2_000_000]]
    switch transformationMode {
    case "replace": delta["input_transformations"] = [["type": "thinking_dropped", "path": "messages.3.content.0", "reason": "model_binding_mismatch"]]
    case "empty": delta["input_transformations"] = []
    case "null": delta["input_transformations"] = NSNull()
    default: break
    }
    events += [delta, ["type": "message_stop"]]
    return events
}

private func anthropicAuditResult(_ client: AnthropicAuditHTTP, model: Model? = nil, options: AnthropicOptions? = nil, context: Context? = nil) async -> AssistantMessage {
    var options = options ?? AnthropicOptions()
    options.apiKey = options.apiKey ?? "fixture-key"
    options.httpClient = client
    return await streamAnthropic(model: model ?? anthropicAuditModel(),
        context: context ?? Context(messages: [.user(UserMessage(content: .text("hello")))]), options: options).result()
}

@Test(arguments: ["served-model", "foreign-model", "unknown-model", "requested-model"])
func anthropicServingModelControlsOutputAndMatchingFallbackCosts(_ serving: String) async throws {
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents(serving: serving))
    let result = await anthropicAuditResult(client)
    #expect(result.stopReason == .stop)
    #expect(result.model == serving)
    #expect(result.responseId == "msg-audit")
    #expect(result.content.count == 1)
    let multiplier: Double = serving == "served-model" ? 10 : 1
    #expect(result.usage.cost.input == multiplier)
    #expect(result.usage.cost.output == 4 * multiplier)
    #expect(result.usage.cost.cacheRead == 9 * multiplier)
    #expect(result.usage.cost.cacheWrite == 16 * multiplier)
    #expect(result.usage.cost.total == 30 * multiplier)
    #expect(result.usage.totalTokens == 10_000_000)
}

@Test func anthropicFallbackCostsAreAvailableWhenStreamErrorsEarly() async throws {
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents(errorAfterStart: true))
    let result = await anthropicAuditResult(client)
    #expect(result.stopReason == .error)
    #expect(result.model == "served-model")
    #expect(result.usage.cost.input == 10)
    #expect(result.usage.cost.cacheRead == 90)
    #expect(result.usage.cost.cacheWrite == 160)
    #expect(result.diagnostics == nil)
}

@Test(arguments: ["replace", "absent", "empty", "null"])
func anthropicFinalTransformationsReplaceRatherThanAppend(_ mode: String) async throws {
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents(transformationMode: mode))
    let result = await anthropicAuditResult(client)
    #expect(result.stopReason == .stop)
    if mode == "empty" { #expect(result.diagnostics == nil); return }
    let diagnostics = try #require(result.diagnostics)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].type == "anthropic_input_transformations")
    let transformations = try #require(diagnostics[0].details["transformations"]?.value as? [[String: Any]])
    #expect(transformations.count == 1)
    #expect(transformations[0]["path"] as? String == (mode == "replace" ? "messages.3.content.0" : "messages.1.content.0"))
    #expect(transformations[0]["ignored"] == nil)
}

@Test func anthropicMidOutputFallbackRetainsPartialTextAndFails() async throws {
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents(midOutput: true))
    let result = await anthropicAuditResult(client)
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "Anthropic performed an unsupported mid-output model fallback")
    guard case .text(let text) = try #require(result.content.first) else { Issue.record("Expected partial text"); return }
    #expect(text.text == "partial")
    #expect(result.diagnostics == nil)
}

@Test func anthropicManagedWirePayloadKeepsEffortBindingFallbacksAndStrictTools() async throws {
    let model = anthropicAuditModel()
    let history = AssistantMessage(content: [.text(TextContent(text: "previous"))], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop, providerThinkingLevel: "low")
    let tool = AITool(name: "lookup", description: "Look up a value", parameters: ["type": AnyCodable("object"),
        "title": AnyCodable("StrictLookupInput"), "properties": AnyCodable(["value": ["type": "string"], "optional": ["type": "number"]]),
        "required": AnyCodable(["value"])], constrainedSampling: .jsonSchema(strict: .prefer))
    let context = Context(messages: [.user(UserMessage(content: .text("one"))), .assistant(history), .user(UserMessage(content: .text("two")))], tools: [tool])
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents())
    let result = await anthropicAuditResult(client, model: model,
        options: AnthropicOptions(temperature: 0.3, thinkingEnabled: false, effort: .max, thinkingDisplay: .omitted), context: context)
    #expect(result.providerThinkingLevel == "max")
    let request = try #require(await client.requests.last)
    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["stream"] as? Bool == true)
    #expect(payload["temperature"] == nil)
    #expect(payload["output_config"] as? [String: String] == ["effort": "high"])
    let thinking = try #require(payload["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "adaptive")
    #expect(thinking["display"] as? String == "omitted")
    #expect(thinking["block_binding"] as? [String: String] == ["prefix_mismatch_behavior": "drop_block"])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let levels = messages.filter { $0["role"] as? String == "system" }.compactMap { ($0["output_config"] as? [String: String])?["effort"] }
    #expect(levels == ["low", "max"])
    #expect(payload["fallbacks"] as? [[String: String]] == [["model": "served-model"], ["model": "foreign-model"]])
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools.first?["strict"] as? Bool == true)
    let schema = try #require(tools.first?["input_schema"] as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(Set(schema["required"] as? [String] ?? []) == Set(["value", "optional"]))
    #expect(schema["title"] as? String == "StrictLookupInput")
    let optional = try #require((schema["properties"] as? [String: Any])?["optional"] as? [String: Any])
    #expect(optional["anyOf"] as? [[String: String]] == [["type": "number"], ["type": "null"]])
}

@Test func anthropicWireHeadersPreserveUserAgentAndBetaOverrides() async throws {
    let client = try AnthropicAuditHTTP(events: anthropicAuditEvents())
    _ = await anthropicAuditResult(client)
    #expect(await client.requests.last?.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
    let custom = try AnthropicAuditHTTP(events: anthropicAuditEvents())
    _ = await anthropicAuditResult(custom, model: anthropicAuditModel(headers: ["anthropic-beta": "model-beta"], provider: "kimi-coding"),
        options: AnthropicOptions(headers: ["User-Agent": "custom-client", "Anthropic-Beta": "custom-beta"]))
    #expect(await custom.requests.last?.value(forHTTPHeaderField: "User-Agent") == "custom-client")
    #expect(await custom.requests.last?.value(forHTTPHeaderField: "anthropic-beta") == "custom-beta")
    let suppressed = try AnthropicAuditHTTP(events: anthropicAuditEvents())
    _ = await anthropicAuditResult(suppressed, options: AnthropicOptions(headers: ["anthropic-beta": nil]))
    #expect(await suppressed.requests.last?.value(forHTTPHeaderField: "anthropic-beta") == nil)
}
