import Foundation
import Testing
@testable import PiSwiftAI

enum PayloadRoute: CaseIterable, Sendable {
    case completions, zai, responses, azure, codex

    var api: Api {
        switch self {
        case .completions, .zai: .openAICompletions
        case .responses: .openAIResponses
        case .azure: .azureOpenAIResponses
        case .codex: .openAICodexResponses
        }
    }
}

private actor PayloadHTTPClient: ProviderHTTPClient {
    let retry: Bool
    private(set) var bodies: [Data] = []

    init(retry: Bool = false) { self.retry = retry }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        if retry && bodies.count == 1 {
            return ProviderHTTPResponse(statusCode: 503, headers: ["retry-after-ms": "0"], body: Data())
        }
        let body = request.url?.path.hasSuffix("/responses") == true
            ? "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"service_tier\":\"fast\"}}\n\n"
            : "data: {\"id\":\"test\",\"created\":0,\"model\":\"test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}

private func payloadStream(_ route: PayloadRoute, client: PayloadHTTPClient,
    handler: PayloadHandler?) throws -> AssistantMessageEventStream {
    let provider: String
    switch route {
    case .zai: provider = "zai"
    case .azure: provider = "azure"
    case .codex: provider = "openai-codex"
    default: provider = "openai"
    }
    let model = Model(id: "gpt-5-mini", name: "Test", api: route.api, provider: provider,
        baseUrl: "https://provider.invalid/v1", reasoning: false, input: [.text],
        cost: ModelCost(input: 1, output: 1, cacheRead: 0, cacheWrite: 0),
        contextWindow: 100_000, maxTokens: 100,
        compat: route == .zai ? OpenAICompat(thinkingFormat: .zai) : nil)
    let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test-account"}}"#.utf8).base64EncodedString()
    return try streamSimple(model: model,
        context: Context(messages: [.user(UserMessage(content: .text("Hello")))]),
        options: SimpleStreamOptions(apiKey: route == .codex ? "e30.\(claims).signature" : "sk-test",
            httpClient: client, transport: .sse, onPayload: handler, maxRetries: 1))
}

@Suite("Provider payload replacement", .timeLimit(.minutes(1)))
struct ProviderPayloadTests {
    @Test(arguments: PayloadRoute.allCases)
    func replacementReachesTransport(_ route: PayloadRoute) async throws {
        let client = PayloadHTTPClient()
        let calls = LockedState(0)
        let stream = try payloadStream(route, client: client) { snapshot in
            calls.withLock { $0 += 1 }
            await Task.yield()
            var payload = try #require(JSONSerialization.jsonObject(with: Data(snapshot.json.utf8)) as? [String: Any])
            payload["service_tier"] = "fast"
            payload["custom_field"] = ["enabled": true]
            payload["model"] = "replacement-model"
            let data = try JSONSerialization.data(withJSONObject: payload)
            return PayloadSnapshot(json: String(decoding: data, as: UTF8.self))
        }
        let result = await stream.result()
        #expect(result.stopReason == .stop)
        #expect(calls.withLock { $0 } == 1)
        let bodies = await client.bodies
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["service_tier"] as? String == "fast")
        #expect(payload["custom_field"] as? [String: Bool] == ["enabled": true])
        #expect(payload["model"] as? String == "replacement-model")
    }

    @Test(arguments: PayloadRoute.allCases)
    func nilKeepsOriginalBytes(_ route: PayloadRoute) async throws {
        let client = PayloadHTTPClient()
        let seen = LockedState<String?>(nil)
        let stream = try payloadStream(route, client: client) { snapshot in
            seen.withLock { $0 = snapshot.json }
            return nil
        }
        #expect(await stream.result().stopReason == .stop)
        let body = try #require(await client.bodies.first)
        #expect(String(decoding: body, as: UTF8.self) == seen.withLock { $0 })
    }

    @Test(arguments: PayloadRoute.allCases)
    func retriesUseReplacementWithoutCallingHandlerAgain(_ route: PayloadRoute) async throws {
        let client = PayloadHTTPClient(retry: true)
        let calls = LockedState(0)
        // Keep the exact bytes, including spacing and key order, on both attempts.
        let replacement = #"{ "model": "test", "stream": true, "service_tier": "fast" }"#
        let stream = try payloadStream(route, client: client) { _ in
            calls.withLock { $0 += 1 }
            return PayloadSnapshot(json: replacement)
        }
        #expect(await stream.result().stopReason == .stop)
        #expect(calls.withLock { $0 } == 1)
        #expect(await client.bodies == [Data(replacement.utf8), Data(replacement.utf8)])
    }

    @Test(arguments: PayloadRoute.allCases)
    func callbackErrorStopsBeforeTransport(_ route: PayloadRoute) async throws {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "Payload callback failed" }
        }
        let client = PayloadHTTPClient()
        let stream = try payloadStream(route, client: client) { _ in throw Failure() }
        let result = await stream.result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Payload callback failed") == true)
        #expect(await client.bodies.isEmpty)
    }

    @Test(arguments: PayloadRoute.allCases, ["[]", "null", "{invalid"])
    func invalidReplacementStopsBeforeTransport(_ route: PayloadRoute, json: String) async throws {
        let client = PayloadHTTPClient()
        let stream = try payloadStream(route, client: client) { _ in PayloadSnapshot(json: json) }
        #expect(await stream.result().stopReason == .error)
        #expect(await client.bodies.isEmpty)
    }
}
