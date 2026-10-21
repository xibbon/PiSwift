import Foundation
import Testing
@testable import PiSwiftAI

private func offModel(id: String = "custom-model", map: ThinkingLevelMap? = nil) -> Model {
    Model(id: id, name: "Managed Claude", api: .anthropicMessages, provider: "anthropic",
        baseUrl: "https://anthropic.invalid", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 100,
        compat: OpenAICompat(forceAdaptiveThinking: true, supportsMidConvoEffort: true), thinkingLevelMap: map)
}

private actor OffHTTPClient: ProviderHTTPClient {
    private(set) var body: Data?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        body = request.httpBody
        let text = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"off_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(text.utf8))
    }
}

private func offCapture(_ model: Model) async throws -> (AssistantMessage, [String: Any]) {
    var messages: [Message] = [.user(UserMessage(content: .text("one")))]
    for level in ["low", "medium"] {
        var assistant = AssistantMessage(content: [.text(TextContent(text: "answer"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        assistant.providerThinkingLevel = level
        messages += [.assistant(assistant), .user(UserMessage(content: .text("next")))]
    }
    let client = OffHTTPClient()
    let result = await streamAnthropic(model: model, context: normalizeContext(Context(messages: messages)),
        options: AnthropicOptions(apiKey: "test-key", httpClient: client, thinkingEnabled: false, maxRetries: 0)).result()
    let data = try #require(await client.body)
    return (result, try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
}

@Suite("Anthropic supported thinking off v1.3.0")
struct A2AnthropicThinkingOffTests {
    @Test(arguments: ["missing map", "missing off", "mapped off"])
    func sendsDisabledWithoutEffortOrBinding(_ kind: String) async throws {
        let map: ThinkingLevelMap? = kind == "missing map" ? nil
            : kind == "missing off" ? [.minimal: nil, .low: "low", .medium: "medium", .high: "high", .max: "max"]
            : [.off: "none", .high: "high"]
        let (message, payload) = try await offCapture(offModel(map: map))
        #expect(message.stopReason == .stop)
        #expect(message.providerThinkingLevel == nil)
        #expect(payload["thinking"] as? [String: String] == ["type": "disabled"])
        #expect(payload["output_config"] == nil)
        let markers = (payload["messages"] as? [[String: Any]] ?? []).filter { $0["output_config"] != nil }
        #expect(markers.isEmpty)
    }

    @Test func unsupportedOffKeepsManagedAdaptiveThinking() async throws {
        let (message, payload) = try await offCapture(offModel(map: [.off: nil, .high: "high"]))
        #expect(message.stopReason == .stop)
        #expect(message.providerThinkingLevel == "high")
        let thinking = try #require(payload["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["block_binding"] as? [String: String] == ["prefix_mismatch_behavior": "drop_block"])
        #expect(payload["output_config"] as? [String: String] == ["effort": "high"])
        let levels = (payload["messages"] as? [[String: Any]] ?? []).compactMap { ($0["output_config"] as? [String: String])?["effort"] }
        #expect(levels == ["low", "medium", "high"])
    }

    @Test(arguments: ["claude-opus-5", "claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1"])
    func modelMetadataControlsSupportedOff(_ id: String) async throws {
        // The runtime uses metadata. Catalog regeneration is in work order K1.
        let supported = id == "claude-opus-5" || id == "claude-haiku-5-5"
        let map: ThinkingLevelMap = supported ? [.high: "high"] : [.off: nil, .high: "high"]
        let (message, payload) = try await offCapture(offModel(id: id, map: map))
        #expect(message.stopReason == .stop)
        #expect((payload["thinking"] as? [String: Any])?["type"] as? String == (supported ? "disabled" : "adaptive"))
        #expect(message.providerThinkingLevel == (supported ? nil : "high"))
    }
}
