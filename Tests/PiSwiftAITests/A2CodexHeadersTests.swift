import Foundation
import Testing
@testable import PiSwiftAI

private actor A2CodexHTTP: ProviderHTTPClient {
    private var request: URLRequest?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 403, body: Data(#"{"error":{"message":"captured"}}"#.utf8))
    }

    func captured() -> URLRequest? { request }
}

private func a2CodexToken() throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: [
        "https://api.openai.com/auth": ["chatgpt_account_id": "account-a2"],
    ])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private func a2CodexRequest(modelHeaders: ProviderHeaders? = nil, callerHeaders: ProviderHeaders? = nil,
                            sessionId: String? = nil, cacheRetention: CacheRetention = .short) async throws -> URLRequest {
    let client = A2CodexHTTP()
    let model = Model(id: "codex-test", name: "Codex", api: .openAICodexResponses,
        provider: "openai-codex", baseUrl: "https://example.invalid/backend-api", reasoning: false,
        input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 16_000, maxTokens: 1024, headers: modelHeaders)
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))]))
    let options = OpenAICodexResponsesOptions(apiKey: try a2CodexToken(), httpClient: client,
        cacheRetention: cacheRetention, sessionId: sessionId, transport: .sse,
        headers: callerHeaders, maxRetries: 0)
    _ = await streamOpenAICodexResponses(model: model, context: context, options: options).result()
    return try #require(await client.captured())
}

// Port of v1.1.0 openai-codex-stream.test.ts: model and caller fields can replace defaults.
@Test func a2CodexSSEHeaderPrecedence() async throws {
    let request = try await a2CodexRequest(
        modelHeaders: ["originator": "my-app", "User-Agent": "model-agent", "X-Model": "kept"],
        callerHeaders: ["user-agent": "my-app/1.0", "authorization": "Bearer ignored",
            "CHATGPT-ACCOUNT-ID": "ignored", "OPENAI-BETA": "ignored",
            "ACCEPT": "ignored", "Content-Type": "ignored"])
    #expect(request.value(forHTTPHeaderField: "originator") == "my-app")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "my-app/1.0")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(try a2CodexToken())")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account-a2")
    #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
    #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "X-Model") == "kept")
}

@Test func a2CodexDefaultsAndDeletion() async throws {
    let defaults = try await a2CodexRequest()
    #expect(defaults.value(forHTTPHeaderField: "originator") == "pi")
    #expect(defaults.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
    let request = try await a2CodexRequest(
        modelHeaders: ["Originator": "model", "USER-AGENT": "model", "X-Delete": "model"],
        callerHeaders: ["originator": nil, "user-agent": nil, "x-delete": nil,
            "authorization": nil, "CHATGPT-ACCOUNT-ID": nil, "openai-beta": nil,
            "ACCEPT": nil, "CONTENT-TYPE": nil])
    #expect(request.value(forHTTPHeaderField: "originator") == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
    #expect(request.value(forHTTPHeaderField: "X-Delete") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(try a2CodexToken())")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "account-a2")
    #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
    #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
}

@Test func a2CodexSSESessionFields() async throws {
    let request = try await a2CodexRequest(
        callerHeaders: ["SESSION-ID": "ignored", "X-CLIENT-REQUEST-ID": nil],
        sessionId: String(repeating: "x", count: 70))
    #expect(request.value(forHTTPHeaderField: "session-id") == String(repeating: "x", count: 64))
    #expect(request.value(forHTTPHeaderField: "x-client-request-id") == String(repeating: "x", count: 64))
    #expect(request.value(forHTTPHeaderField: "session_id") == nil)
    #expect(request.value(forHTTPHeaderField: "conversation_id") == nil)
    let absent = try await a2CodexRequest(sessionId: "ignored", cacheRetention: .none)
    #expect(absent.value(forHTTPHeaderField: "session-id") == nil)
    #expect(absent.value(forHTTPHeaderField: "x-client-request-id") == nil)
}

// Upstream retains caller fields when SSE has no session and does not filter x-api-key.
@Test func a2CodexSSEKeepsOtherCallerFields() async throws {
    let request = try await a2CodexRequest(callerHeaders: [
        "session-id": "caller-session", "x-client-request-id": "caller-request", "x-api-key": "caller-key",
    ])
    #expect(request.value(forHTTPHeaderField: "session-id") == "caller-session")
    #expect(request.value(forHTTPHeaderField: "x-client-request-id") == "caller-request")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "caller-key")
}

// URLSession supplies the WebSocket connection. Test the exact fields given to that connection.
@Test func a2CodexWebSocketHeaders() throws {
    let base = try buildOpenAICodexHeaders(
        baseHeaders: ["ORIGINATOR": "model", "User-Agent": "model", "Content-Type": "model"],
        additionalHeaders: ["user-agent": "caller", "accept": "caller", "openai-beta": "caller",
            "authorization": nil, "CHATGPT-ACCOUNT-ID": "ignored", "SESSION-ID": "ignored",
            "X-CLIENT-REQUEST-ID": nil], accessToken: a2CodexToken())
    #expect(base["chatgpt-account-id"] == "account-a2")
    #expect(base["CHATGPT-ACCOUNT-ID"] == nil)
    let headers = buildCodexWebSocketHeaders(baseHeaders: base, requestId: "ws-session")
    #expect(providerHeaderValue(headers, name: "originator") == "model")
    #expect(providerHeaderValue(headers, name: "User-Agent") == "caller")
    #expect(providerHeaderValue(headers, name: "Authorization") == "Bearer \(try a2CodexToken())")
    #expect(providerHeaderValue(headers, name: "chatgpt-account-id") == "account-a2")
    #expect(providerHeaderValue(headers, name: "accept") == nil)
    #expect(providerHeaderValue(headers, name: "content-type") == nil)
    #expect(providerHeaderValue(headers, name: "OpenAI-Beta") == "responses_websockets=2026-02-06")
    #expect(providerHeaderValue(headers, name: "session-id") == "ws-session")
    #expect(providerHeaderValue(headers, name: "x-client-request-id") == "ws-session")
    #expect(providerHeaderValue(headers, name: "session_id") == nil)
    #expect(providerHeaderValue(headers, name: "conversation_id") == nil)
    #expect(headers.keys.filter { $0.lowercased() == "openai-beta" }.count == 1)
}

@Test func a2CodexWebSocketRequestID() throws {
    #expect(try codexWebSocketRequestId(sessionId: "session") == "session")
    let first = try codexWebSocketRequestId(sessionId: nil)
    let second = try codexWebSocketRequestId(sessionId: nil)
    #expect(UUID(uuidString: first) != nil)
    #expect(first.split(separator: "-")[2].first == "7")
    #expect(first != second)
    let headers = buildCodexWebSocketHeaders(baseHeaders: [:], requestId: first)
    #expect(providerHeaderValue(headers, name: "session-id") == first)
    #expect(providerHeaderValue(headers, name: "x-client-request-id") == first)
}
