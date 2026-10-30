import Foundation
import Testing
@testable import PiSwiftAI

private actor OtherPayloadHTTPClient: ProviderHTTPClient {
    let body: Data
    var requests: [URLRequest] = []
    let rejectStrict: Bool

    init(api: Api, rejectStrict: Bool = false) {
        self.rejectStrict = rejectStrict
        switch api {
        case .anthropicMessages:
            body = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)
        case .googleGenerativeAI:
            body = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n".utf8)
        default:
            body = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        }
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        if rejectStrict && requests.count == 1 {
            return ProviderHTTPResponse(statusCode: 400, body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Too many strict tools (32). The maximum number of strict tools supported is 20."}}"#.utf8))
        }
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func otherPayloadStream(api: Api, client: OtherPayloadHTTPClient,
    tools: [AITool] = [], handler: @escaping PayloadHandler) -> AssistantMessageEventStream {
    let provider: String
    let id: String
    switch api {
    case .anthropicMessages: provider = "anthropic"; id = "claude-haiku-4-5"
    case .googleGenerativeAI: provider = "google"; id = "gemini-2.5-flash"
    default: provider = "mistral"; id = "mistral-large-latest"
    }
    let model = Model(id: id, name: "Test", api: api, provider: provider,
        baseUrl: "https://provider.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 100_000, maxTokens: 100, compat: OpenAICompat(supportsStrictTools: true))
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))], tools: tools))
    switch api {
    case .anthropicMessages:
        return streamAnthropic(model: model, context: context,
            options: AnthropicOptions(apiKey: "test", httpClient: client, onPayload: handler))
    case .googleGenerativeAI:
        return streamGoogle(model: model, context: context,
            options: GoogleOptions(apiKey: "test", httpClient: client, onPayload: handler))
    default:
        return streamMistral(model: model, context: context,
            options: MistralOptions(apiKey: "test", httpClient: client, onPayload: handler))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .googleGenerativeAI, .mistralConversations])
func otherProviderPayloadReplacementReachesTransport(_ api: Api) async throws {
    let client = OtherPayloadHTTPClient(api: api)
    let calls = LockedState(0)
    let result = await otherPayloadStream(api: api, client: client) { snapshot in
        calls.withLock { $0 += 1 }
        await Task.yield()
        var object = try #require(JSONSerialization.jsonObject(with: Data(snapshot.json.utf8)) as? [String: Any])
        object["speed"] = "fast"
        object["custom_extension"] = ["enabled": true]
        object["model"] = "replacement-model"
        let data = try JSONSerialization.data(withJSONObject: object)
        return PayloadSnapshot(json: try #require(String(data: data, encoding: .utf8)))
    }.result()
    #expect(result.stopReason == .stop)
    #expect(calls.withLock { $0 } == 1)
    let requests = await client.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["speed"] as? String == "fast")
    #expect(payload["custom_extension"] as? [String: Bool] == ["enabled": true])
    #expect(payload["model"] as? String == "replacement-model")
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .googleGenerativeAI, .mistralConversations])
func otherProviderNilPayloadKeepsOriginal(_ api: Api) async throws {
    let client = OtherPayloadHTTPClient(api: api)
    let seen = LockedState<String?>(nil)
    let result = await otherPayloadStream(api: api, client: client) { snapshot in
        seen.withLock { $0 = snapshot.json }
        return nil
    }.result()
    #expect(result.stopReason == .stop)
    let request = try #require(await client.requests.first)
    let body = try #require(request.httpBody)
    let expected = try #require(seen.withLock { $0 })
    #expect(String(data: body, encoding: .utf8) == expected)
}

private enum OtherPayloadFailure: Error, LocalizedError {
    case rejected
    var errorDescription: String? { "Payload handler rejected request" }
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .googleGenerativeAI, .mistralConversations])
func otherProviderPayloadErrorStopsBeforeTransport(_ api: Api) async {
    let client = OtherPayloadHTTPClient(api: api)
    let result = await otherPayloadStream(api: api, client: client) { _ in
        throw OtherPayloadFailure.rejected
    }.result()
    #expect(result.stopReason == .error)
    #expect(result.errorMessage?.contains("Payload handler rejected request") == true)
    #expect(await client.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .googleGenerativeAI, .mistralConversations])
func otherProviderInvalidPayloadStopsBeforeTransport(_ api: Api) async {
    let client = OtherPayloadHTTPClient(api: api)
    let result = await otherPayloadStream(api: api, client: client) { _ in
        PayloadSnapshot(json: "[]")
    }.result()
    #expect(result.stopReason == .error)
    #expect(await client.requests.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func anthropicPayloadReplacementRunsForStrictFallbackBody() async throws {
    let client = OtherPayloadHTTPClient(api: .anthropicMessages, rejectStrict: true)
    let calls = LockedState(0)
    let tool = AITool(name: "lookup", description: "Look up a value", parameters: [
        "type": AnyCodable("object"), "properties": AnyCodable(["value": ["type": "string"]]),
        "required": AnyCodable(["value"]),
    ], constrainedSampling: .jsonSchema(strict: .prefer))
    let result = await otherPayloadStream(api: .anthropicMessages, client: client, tools: [tool]) { snapshot in
        calls.withLock { $0 += 1 }
        var object = try #require(JSONSerialization.jsonObject(with: Data(snapshot.json.utf8)) as? [String: Any])
        object["speed"] = "fast"
        return PayloadSnapshot(json: try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8)))
    }.result()
    #expect(result.stopReason == .stop)
    #expect(calls.withLock { $0 } == 2)
    let requests = await client.requests
    #expect(requests.count == 2)
    let payloads = try requests.map { request in
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    #expect(payloads.allSatisfy { $0["speed"] as? String == "fast" })
    let firstTools = try #require(payloads.first?["tools"] as? [[String: Any]])
    let lastTools = try #require(payloads.last?["tools"] as? [[String: Any]])
    #expect(firstTools.first?["strict"] as? Bool == true)
    #expect(lastTools.first?["strict"] as? Bool != true)
}
