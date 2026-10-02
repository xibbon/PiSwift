import Foundation
import Testing
@testable import PiSwiftAI

private let a1FederationSSE = Data("""
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"claude-test","usage":{"input_tokens":1,"output_tokens":0}}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}


""".utf8)

private actor A1FederationHTTP: ProviderHTTPClient {
    var requests: [URLRequest] = []
    let tokenResponses: [ProviderHTTPResponse]
    let messageStatuses: [Int]
    var exchanges = 0
    var messages = 0

    init(tokenResponses: [ProviderHTTPResponse] = [], messageStatuses: [Int] = []) {
        self.tokenResponses = tokenResponses
        self.messageStatuses = messageStatuses
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        if request.url?.path.hasSuffix("/v1/oauth/token") == true {
            let index = exchanges
            exchanges += 1
            if index < tokenResponses.count { return tokenResponses[index] }
            return ProviderHTTPResponse(statusCode: 200, body: Data("{\"access_token\":\"federated-\(exchanges)\",\"expires_in\":3600}".utf8))
        }
        let index = messages
        messages += 1
        let status = index < messageStatuses.count ? messageStatuses[index] : 200
        return ProviderHTTPResponse(statusCode: status, body: status == 200 ? a1FederationSSE : Data("unauthorized".utf8))
    }

    func captured() -> [URLRequest] { requests }
}

private struct A1FederationFile {
    let url: URL
    let env: [String: String]
    var config: AnthropicFederationConfig { AnthropicFederationConfig(env: env)! }

    init(token: String = "  header.payload.signature\n", optional: Bool = true) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("a1-federation-\(UUID().uuidString).jwt")
        try token.write(to: url, atomically: true, encoding: .utf8)
        var values = ["ANTHROPIC_FEDERATION_RULE_ID": "fdrl_test", "ANTHROPIC_ORGANIZATION_ID": "org-test",
                      "ANTHROPIC_IDENTITY_TOKEN_FILE": url.path]
        if optional {
            values["ANTHROPIC_SERVICE_ACCOUNT_ID"] = "svac_test"
            values["ANTHROPIC_WORKSPACE_ID"] = "wrkspc_test"
        }
        env = values
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func a1FederationModel(provider: String = "anthropic", base: String = "https://api.anthropic.com",
                               headers: ProviderHeaders? = nil) -> Model {
    Model(id: "claude-test", name: "Claude Test", api: .anthropicMessages, provider: provider,
          baseUrl: base, reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 100_000, maxTokens: 4096,
          headers: headers)
}

private func a1FederationContext() -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "System prompt.", messages: [.user(UserMessage(content: .text("Hello")))]))
}

@Suite("A1 Anthropic federation SDK", .timeLimit(.minutes(1)))
struct A1AnthropicFederationSDKTests {
    @Test func exchangesOnceAcrossThreeRequests() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        for _ in 0..<3 {
            let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
                options: AnthropicOptions(env: file.env, httpClient: client, maxRetries: 0)).result()
            #expect(message.stopReason == .stop)
        }
        let requests = await client.captured()
        #expect(requests.filter { $0.url?.path == "/v1/oauth/token" }.count == 1)
        let messages = requests.filter { $0.url?.path == "/v1/messages" }
        #expect(messages.count == 3)
        for request in messages {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer federated-1")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            #expect(request.value(forHTTPHeaderField: "anthropic-beta")?.contains("oauth-2025-04-20") == true)
            #expect(request.value(forHTTPHeaderField: "anthropic-beta")?.contains("claude-code-20250219") != true)
            #expect(request.value(forHTTPHeaderField: "x-app") == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
            #expect(request.value(forHTTPHeaderField: "anthropic-workspace-id") == nil)
        }
        let exchange = try #require(requests.first)
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20,oidc-federation-2026-04-01")
        #expect(exchange.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
        let exchangeBody = try #require(exchange.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: exchangeBody) as? [String: String])
        #expect(body == ["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": "header.payload.signature",
                         "federation_rule_id": "fdrl_test", "organization_id": "org-test",
                         "service_account_id": "svac_test", "workspace_id": "wrkspc_test"])
    }

    @Test(arguments: ["Authorization", "X-API-KEY", "cF-aIg-AuThOrIzAtIoN"])
    func headerOwnedAuthSkipsExchange(name: String) async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, apiKey: "", httpClient: client,
                                      headers: [name: "Bearer auth-token"], maxRetries: 0)).result()
        #expect(message.stopReason == .stop)
        let requests = await client.captured()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: name) == "Bearer auth-token")
        if name.lowercased() != "x-api-key" { #expect(request.value(forHTTPHeaderField: "x-api-key") == nil) }
    }

    @Test func explicitKeyWinsOverFederation() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, apiKey: "explicit-key", httpClient: client, maxRetries: 0)).result()
        #expect(message.stopReason == .stop)
        let requests = await client.captured()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "x-api-key") == "explicit-key")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func modelHeaderOwnedAuthSkipsExchange() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        let model = a1FederationModel(headers: ["Authorization": "Bearer model-token"])
        let message = await streamAnthropic(model: model, context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, httpClient: client, maxRetries: 0)).result()
        #expect(message.stopReason == .stop)
        let requests = await client.captured()
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer model-token")
        #expect(requests.first?.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func otherAnthropicProvidersDoNotFederate() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        let message = await streamAnthropic(model: a1FederationModel(provider: "kimi-coding"), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, httpClient: client, maxRetries: 0)).result()
        #expect(message.stopReason == .error)
        #expect(await client.captured().isEmpty)
    }

    @Test func unauthorizedRequestRefreshesAndRetriesOnce() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP(messageStatuses: [401, 200])
        let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, httpClient: client, maxRetries: 0)).result()
        #expect(message.stopReason == .stop)
        let requests = await client.captured()
        #expect(requests.map { $0.url?.path } == ["/v1/oauth/token", "/v1/messages", "/v1/oauth/token", "/v1/messages"])
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer federated-2")
    }

    @Test func secondUnauthorizedResponseStops() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP(messageStatuses: [401, 401, 200])
        let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, httpClient: client, maxRetries: 0)).result()
        #expect(message.stopReason == .error)
        #expect(await client.captured().count == 4)
    }

    @Test func federationBetaSurvivesHeaderDeletion() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        let message = await streamAnthropic(model: a1FederationModel(), context: a1FederationContext(),
            options: AnthropicOptions(env: file.env, httpClient: client, headers: ["anthropic-beta": nil], maxRetries: 0)).result()
        #expect(message.stopReason == .stop)
        #expect(await client.captured().last?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }
}

@Suite("A1 Anthropic federation configuration and exchange", .timeLimit(.minutes(1)))
struct A1AnthropicFederationTests {
    @Test func envBagRequiresAllThreeVariablesAndKeepsOptionalValues() throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        #expect(anthropicFederationEnv(env: file.env.merging(["OTHER": "ignored"]) { _, rhs in rhs }) == file.env)
        #expect(file.config.federationRuleId == "fdrl_test")
        #expect(file.config.organizationId == "org-test")
        #expect(file.config.identityTokenFile == file.url.path)
        #expect(file.config.serviceAccountId == "svac_test")
        #expect(file.config.workspaceId == "wrkspc_test")
        for name in ["ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE"] {
            var partial = file.env
            partial[name] = nil
            #expect(anthropicFederationEnv(env: partial) == nil)
            partial[name] = ""
            #expect(AnthropicFederationConfig(env: partial) == nil)
        }
    }

    @Test func serviceAccountAndWorkspaceAreOptional() async throws {
        let file = try A1FederationFile(optional: false)
        defer { file.remove() }
        #expect(file.config.serviceAccountId == nil)
        #expect(file.config.workspaceId == nil)
        let client = A1FederationHTTP()
        _ = try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com/", client: client)
        let request = try #require(await client.captured().first)
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: String])
        #expect(body["service_account_id"] == nil)
        #expect(body["workspace_id"] == nil)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/oauth/token")
    }

    @Test func authCheckAcceptsOnlyNonemptyCredentials() {
        #expect(hasRequestAuth(apiKey: "key", headers: nil))
        for name in ["AUTHORIZATION", "X-API-KEY", "cf-aig-authorization"] {
            #expect(hasRequestAuth(apiKey: "", headers: [name: " token "]))
            #expect(!hasRequestAuth(apiKey: nil, headers: [name: " \n "]))
            #expect(!hasRequestAuth(apiKey: nil, headers: [name: nil]))
        }
        #expect(!hasRequestAuth(apiKey: nil, headers: ["x-unrelated": "value"]))
    }

    @Test func readsRotatedFileOnEveryExchange() async throws {
        let file = try A1FederationFile(token: "first")
        defer { file.remove() }
        let client = A1FederationHTTP()
        _ = try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        try " second\n".write(to: file.url, atomically: true, encoding: .utf8)
        _ = try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        let assertions = try await client.captured().map { request in
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
            return body?["assertion"]
        }
        #expect(assertions == ["first", "second"])
    }

    @Test(arguments: ["http://api.anthropic.com", "ftp://localhost", "not a url"])
    func rejectsUnsafeTokenEndpoint(base: String) async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        await #expect(throws: AnthropicFederationError.self) {
            try await exchangeAnthropicFederationToken(config: file.config, baseUrl: base, client: client)
        }
        #expect(await client.captured().isEmpty)
    }

    @Test(arguments: ["http://localhost:8000", "http://127.0.0.1:8000", "http://[::1]:8000"])
    func allowsLoopbackTokenEndpoint(base: String) async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP()
        #expect(try await exchangeAnthropicFederationToken(config: file.config, baseUrl: base, client: client).value == "federated-1")
    }

    @Test(arguments: [" \n ", String(repeating: "a", count: 16 * 1024 + 1)])
    func rejectsEmptyAndOversizedAssertions(assertion: String) async throws {
        let file = try A1FederationFile(token: assertion)
        defer { file.remove() }
        let client = A1FederationHTTP()
        await #expect(throws: AnthropicFederationError.self) {
            try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        }
        #expect(await client.captured().isEmpty)
    }

    @Test func missingFileFailsBeforeExchange() async throws {
        let file = try A1FederationFile()
        file.remove()
        let client = A1FederationHTTP()
        await #expect(throws: AnthropicFederationError.self) {
            try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        }
        #expect(await client.captured().isEmpty)
    }

    @Test func exchangeErrorsRedactTokenFieldsAndGiveWorkspaceHint() async throws {
        let file = try A1FederationFile(optional: false)
        defer { file.remove() }
        let response = ProviderHTTPResponse(statusCode: 401, headers: ["Request-Id": "req-1"],
            body: Data(#"{"error":"invalid_grant","error_description":"rule mismatch","error_uri":"https://example.invalid/help","assertion":"secret-jwt","access_token":"secret-token"}"#.utf8))
        let client = A1FederationHTTP(tokenResponses: [response])
        do {
            _ = try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
            Issue.record("Expected token exchange failure")
        } catch let error as AnthropicFederationError {
            #expect(error.statusCode == 401)
            #expect(error.requestId == "req-1")
            #expect(error.message.contains("Token exchange failed with status 401 (request-id req-1)"))
            #expect(error.message.contains("invalid_grant"))
            #expect(error.message.contains("ANTHROPIC_WORKSPACE_ID"))
            #expect(!error.message.contains("secret-jwt"))
            #expect(!error.message.contains("secret-token"))
        }
    }

    @Test(arguments: ["not-json", #"{"expires_in":3600}"#, #"{"access_token":"token","token_type":"MAC","expires_in":3600}"#,
                      #"{"access_token":"token"}"#, #"{"access_token":"token","expires_in":"Infinity"}"#,
                      #"{"access_token":"token","token_type":1,"expires_in":3600}"#,
                      #"{"access_token":"token","token_type":{},"expires_in":3600}"#])
    func validatesTokenResponses(body: String) async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP(tokenResponses: [ProviderHTTPResponse(statusCode: 200, body: Data(body.utf8))])
        await #expect(throws: AnthropicFederationError.self) {
            try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        }
    }

    @Test(arguments: ["3600", "\"3600\"", "null", "\"\"", "false", "true", "[]", "[\"3600\"]"])
    func acceptsSDKNumberExpiryConversion(expires: String) async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP(tokenResponses: [ProviderHTTPResponse(statusCode: 200,
            body: Data("{\"access_token\":\"token\",\"token_type\":\"bEaReR\",\"expires_in\":\(expires)}".utf8))])
        #expect(try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client).value == "token")
    }

    @Test func rejectsTokenResponseAboveOneMiB() async throws {
        let file = try A1FederationFile()
        defer { file.remove() }
        let client = A1FederationHTTP(tokenResponses: [ProviderHTTPResponse(statusCode: 200,
            body: Data(repeating: 97, count: (1 << 20) + 1))])
        await #expect(throws: AnthropicFederationError.self) {
            try await exchangeAnthropicFederationToken(config: file.config, baseUrl: "https://api.anthropic.com", client: client)
        }
    }
}

private actor A1FederationExchangeGate {
    private var count = 0
    private var pending: [CheckedContinuation<AnthropicFederationToken, Error>] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

    func exchange() async throws -> AnthropicFederationToken {
        count += 1
        let ready = waiting.filter { $0.0 <= count }
        waiting.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiting.append((target, $0)) }
    }

    func release(_ result: Result<AnthropicFederationToken, Error>) {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume(with: result) }
    }

    func calls() -> Int { count }
}

@Suite("A1 Anthropic federation token cache", .timeLimit(.minutes(1)))
struct A1AnthropicFederationCacheTests {
    private func key(base: String = "https://api.anthropic.com", workspace: String = "workspace") -> AnthropicFederationCacheKey {
        AnthropicFederationCacheKey(baseUrl: base, config: AnthropicFederationConfig(env: [
            "ANTHROPIC_FEDERATION_RULE_ID": "rule", "ANTHROPIC_ORGANIZATION_ID": "org",
            "ANTHROPIC_IDENTITY_TOKEN_FILE": "/unused/cache-test.jwt", "ANTHROPIC_WORKSPACE_ID": workspace
        ])!)
    }

    @Test func concurrentInitialRequestsShareOneExchange() async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let gate = A1FederationExchangeGate()
        let key = key()
        let pending = Task {
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<20 {
                    group.addTask { try await cache.token(key: key) { try await gate.exchange() } }
                }
                var tokens: [String] = []
                for try await token in group { tokens.append(token) }
                return tokens
            }
        }
        await gate.waitForCalls(1)
        await gate.release(.success(AnthropicFederationToken(value: "shared", expiresAt: 1000)))
        #expect(try await pending.value == Array(repeating: "shared", count: 20))
        #expect(await gate.calls() == 1)
    }

    @Test func above120SecondsUsesCachedTokenWithoutRefresh() async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let calls = LockedState(0)
        let key = key()
        let exchange: @Sendable () async throws -> AnthropicFederationToken = {
            calls.withLock { $0 += 1 }
            return AnthropicFederationToken(value: "cached", expiresAt: 221)
        }
        #expect(try await cache.token(key: key, exchange: exchange) == "cached")
        #expect(try await cache.token(key: key, exchange: exchange) == "cached")
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [120.0, 31.0])
    func advisoryWindowReturnsCachedTokenBeforeRefreshCompletes(remaining: Double) async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let key = key()
        _ = try await cache.token(key: key) { AnthropicFederationToken(value: "cached", expiresAt: 100 + remaining) }
        let gate = A1FederationExchangeGate()
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "cached")
        await gate.waitForCalls(1)
        for _ in 0..<3 {
            #expect(try await cache.token(key: key) { try await gate.exchange() } == "cached")
        }
        #expect(await gate.calls() == 1)
        await gate.release(.success(AnthropicFederationToken(value: "refreshed", expiresAt: 1000)))
        await cache.waitForPendingRefresh(key: key)
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "refreshed")
    }

    @Test(arguments: [30.0, 29.0, 0.0, -1.0])
    func mandatoryWindowBlocksForRefreshedToken(remaining: Double) async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let key = key()
        _ = try await cache.token(key: key) { AnthropicFederationToken(value: "cached", expiresAt: 100 + remaining) }
        let gate = A1FederationExchangeGate()
        let finished = LockedState(false)
        let pending = Task {
            let token = try await cache.token(key: key) { try await gate.exchange() }
            finished.withLock { $0 = true }
            return token
        }
        await gate.waitForCalls(1)
        #expect(!finished.withLock { $0 })
        await gate.release(.success(AnthropicFederationToken(value: "refreshed", expiresAt: 1000)))
        #expect(try await pending.value == "refreshed")
    }

    @Test func advisoryFailureKeepsTokenAndUsesFiveSecondBackoff() async throws {
        let clock = LockedState(100.0)
        let cache = AnthropicFederationTokenCache(clock: { clock.withLock { $0 } })
        let key = key()
        _ = try await cache.token(key: key) { AnthropicFederationToken(value: "cached", expiresAt: 220) }
        let gate = A1FederationExchangeGate()
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "cached")
        await gate.waitForCalls(1)
        await gate.release(.failure(AnthropicFederationError("exchange failed")))
        await cache.waitForPendingRefresh(key: key)
        clock.withLock { $0 = 104.99 }
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "cached")
        #expect(await gate.calls() == 1)
        clock.withLock { $0 = 105 }
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "cached")
        await gate.waitForCalls(2)
        await gate.release(.success(AnthropicFederationToken(value: "refreshed", expiresAt: 1000)))
        await cache.waitForPendingRefresh(key: key)
        #expect(try await cache.token(key: key) { try await gate.exchange() } == "refreshed")
    }

    @Test func mandatoryRefreshIgnoresAdvisoryBackoffAndThrowsOnFailure() async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let key = key()
        _ = try await cache.token(key: key) { AnthropicFederationToken(value: "cached", expiresAt: 220) }
        let calls = LockedState(0)
        let failure: @Sendable () async throws -> AnthropicFederationToken = {
            calls.withLock { $0 += 1 }
            throw AnthropicFederationError("exchange failed")
        }
        #expect(try await cache.token(key: key, exchange: failure) == "cached")
        await cache.waitForPendingRefresh(key: key)
        await #expect(throws: AnthropicFederationError.self) {
            try await cache.token(key: key, now: 190, exchange: failure)
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func distinctBaseUrlsAndConfigsHaveDistinctTokens() async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let keys = [key(), key(base: "https://other.example"), key(workspace: "other")]
        let calls = LockedState(0)
        for key in keys {
            _ = try await cache.token(key: key) {
                calls.withLock { $0 += 1 }
                return AnthropicFederationToken(value: key.baseUrl + (key.config.workspaceId ?? ""), expiresAt: 1000)
            }
        }
        for key in keys {
            #expect(try await cache.token(key: key) { throw AnthropicFederationError("must use cached token") }
                == key.baseUrl + (key.config.workspaceId ?? ""))
        }
        #expect(calls.withLock { $0 } == 3)
    }

    @Test func forceRefreshAndResetDiscardCachedTokens() async throws {
        let cache = AnthropicFederationTokenCache(clock: { 100 })
        let key = key()
        let calls = LockedState(0)
        let exchange: @Sendable () async throws -> AnthropicFederationToken = {
            let count = calls.withLock { $0 += 1; return $0 }
            return AnthropicFederationToken(value: "token-\(count)", expiresAt: 1000)
        }
        #expect(try await cache.token(key: key, exchange: exchange) == "token-1")
        #expect(try await cache.token(key: key, forceRefresh: true, exchange: exchange) == "token-2")
        await cache.reset()
        #expect(try await cache.token(key: key, exchange: exchange) == "token-3")
    }
}
