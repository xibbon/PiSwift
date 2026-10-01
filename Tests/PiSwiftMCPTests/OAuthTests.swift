import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PiSwiftMCP
#if canImport(CryptoKit)
import CryptoKit
#endif

private actor OAuthFixture: McpOAuthHTTPClient {
    nonisolated let origin = URL(string: "http://127.0.0.1:45454")!
    var requests: [URLRequest] = []
    var refreshCount = 0
    var tokenGrants: [String] = []
    var issuerOverride: String?
    var protectedResource = true
    var accessToken = "first-token"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let body: [String: Any]
        let status: Int
        switch path {
        case "/.well-known/oauth-protected-resource/mcp":
            if protectedResource {
                body = ["resource": "\(origin)/mcp", "authorization_servers": [origin.absoluteString], "scopes_supported": ["org:read"]]
                status = 200
            } else { body = [:]; status = 404 }
        case "/.well-known/oauth-authorization-server":
            body = ["issuer": issuerOverride ?? origin.absoluteString,
                    "authorization_endpoint": "\(origin)/authorize", "token_endpoint": "\(origin)/token",
                    "registration_endpoint": "\(origin)/register", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                    "token_endpoint_auth_methods_supported": ["none"], "code_challenge_methods_supported": ["S256"]]
            status = 200
        case "/register":
            var registration = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            registration["client_id"] = "test-client"
            body = registration
            status = 201
        case "/token":
            let parameters = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? []
            let parameter: (String) -> String? = { name in parameters.first { $0.name == name }?.value }
            tokenGrants.append(parameter("grant_type") ?? "")
            if parameter("grant_type") == "refresh_token" {
                refreshCount += 1
                body = ["access_token": "refreshed-token", "refresh_token": "next-refresh", "token_type": "Bearer", "expires_in": 3600]
                status = 200
            } else if parameter("code") == "test-code" {
                body = ["access_token": accessToken, "refresh_token": "refresh-token", "token_type": "Bearer"]
                status = 200
            } else {
                body = ["error": "invalid_grant"]
                status = 400
            }
        default:
            body = [:]
            status = 404
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url ?? origin, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    func setIssuer(_ value: String) { issuerOverride = value }
    func setProtectedResource(_ value: Bool) { protectedResource = value }
    func snapshot() -> ([URLRequest], Int, [String]) { (requests, refreshCount, tokenGrants) }
}

private actor RedirectRecorder {
    var value: URL?
    func save(_ url: URL) { value = url }
    func read() -> URL? { value }
}

private actor TestSignInPresenter: McpSignInPresenter {
    let callbackURL = URL(string: "http://127.0.0.1:6789/callback")!
    var authorizationURL: URL?

    func redirectURL(for state: String) -> URL { callbackURL }
    func present(authorizationURL: URL, state: String) -> URL {
        self.authorizationURL = authorizationURL
        return URL(string: "\(callbackURL)?code=test-code&state=\(state)")!
    }
    func opened() -> URL? { authorizationURL }
}

private func provider(_ fixture: OAuthFixture, store: McpMemoryOAuthStateStore = McpMemoryOAuthStateStore(),
                      clientID: String? = nil, recorder: RedirectRecorder) -> McpOAuthProvider {
    McpOAuthProvider(serverURL: URL(string: "http://127.0.0.1:45454/mcp")!,
        redirectURL: URL(string: "http://127.0.0.1:6789/callback")!,
        clientMetadata: McpOAuthClientMetadata(clientName: "pi-mcp-test"),
        clientID: clientID, store: store, onRedirect: { url in await recorder.save(url) })
}

@Test(.timeLimit(.minutes(1)))
func oauthDiscoveryRegistrationPKCECodeExchangeAndRefresh() async throws {
    let fixture = OAuthFixture()
    let recorder = RedirectRecorder()
    let oauth = provider(fixture, recorder: recorder)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    let result = try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: serverURL), http: fixture)
    #expect(result == .redirect)
    let authorization = try #require(await recorder.read())
    let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value: (String) -> String? = { name in query.first { $0.name == name }?.value }
    #expect(value("client_id") == "test-client")
    #expect(value("scope") == "org:read")
    #expect(value("resource") == serverURL.absoluteString)
    #expect(value("code_challenge_method") == "S256")
    #if canImport(CryptoKit)
    let verifier = try await oauth.codeVerifier()
    let digest = SHA256.hash(data: Data(verifier.utf8))
    let expectedChallenge = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(value("code_challenge") == expectedChallenge)
    #endif
    let state = try #require(await oauth.state())
    let callback = URL(string: "http://127.0.0.1:6789/callback?code=test-code&state=\(state)")!
    let tokens = try await McpOAuthFlow.completeRedirect(provider: oauth,
        callbackURL: callback, serverURL: serverURL, http: fixture)
    #expect(tokens.accessToken == "first-token")
    let auth = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    try await auth.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "first-token")
    #expect(try await auth.token() == "refreshed-token")
    let (requests, refreshes, _) = await fixture.snapshot()
    #expect(refreshes == 1)
    #expect(requests.contains { $0.url?.path == "/register" })
    #expect(requests.first?.value(forHTTPHeaderField: "MCP-Protocol-Version") == LATEST_PROTOCOL_VERSION)
}

@Test(.timeLimit(.minutes(1)))
func oauthSignInPresenterConnectsToCodeExchange() async throws {
    let fixture = OAuthFixture()
    let presenter = TestSignInPresenter()
    let oauth = try await McpOAuthSignIn.signIn(
        serverURL: URL(string: "http://127.0.0.1:45454/mcp")!, presenter: presenter,
        clientMetadata: McpOAuthClientMetadata(clientName: "pi-mcp-test"), http: fixture)
    #expect(try await oauth.tokens()?.accessToken == "first-token")
    #expect(await presenter.opened() != nil)
    let auth = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    await #expect(throws: McpOAuthError.self) {
        try await auth.onUnauthorized(challenge: "Bearer error=\"insufficient_scope\"",
            serverURL: URL(string: "http://127.0.0.1:45454/mcp")!, rejectedToken: "first-token")
    }
}

@Test(.timeLimit(.minutes(1)))
func oauthPasteRedirectFallbackCompletesSignIn() async throws {
    let fixture = OAuthFixture()
    let recorder = RedirectRecorder()
    let callbackURL = URL(string: "http://127.0.0.1:6789/callback")!
    let presenter = McpPasteRedirectPresenter(callbackURL: callbackURL,
        openAuthorizationURL: { url in await recorder.save(url) },
        pasteRedirectURL: {
            let authorization = try #require(await recorder.read())
            let state = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value)
            return "\(callbackURL)?code=test-code&state=\(state)"
        })
    let oauth = try await McpOAuthSignIn.signIn(
        serverURL: URL(string: "http://127.0.0.1:45454/mcp")!, presenter: presenter,
        clientMetadata: McpOAuthClientMetadata(clientName: "pi-mcp-test"), http: fixture)
    #expect(try await oauth.tokens()?.accessToken == "first-token")
}

@Test(.timeLimit(.minutes(1)))
func oauthConcurrentUnauthorizedRotatingRefreshToken() async throws {
    let fixture = OAuthFixture()
    await fixture.setProtectedResource(false)
    let recorder = RedirectRecorder()
    let store = McpMemoryOAuthStateStore()
    let oauth = provider(fixture, store: store, clientID: "client", recorder: recorder)
    try await oauth.saveTokens(McpOAuthTokens(accessToken: "a1", tokenType: "Bearer", refreshToken: "r1"))
    let auth = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    async let first: Void = auth.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    async let second: Void = auth.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    try await first
    try await second
    try await auth.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    let (_, refreshes, _) = await fixture.snapshot()
    #expect(refreshes == 1)
    #expect(try await oauth.tokens()?.refreshToken == "next-refresh")
    let expires = await store.load()?.tokensExpireAt ?? .distantPast
    #expect(expires > Date().addingTimeInterval(3500))
}

@Test(.timeLimit(.minutes(1)))
func oauthInsufficientScopeSkipsRefreshAndKeepsGrant() async throws {
    let fixture = OAuthFixture()
    await fixture.setProtectedResource(false)
    let recorder = RedirectRecorder()
    let oauth = provider(fixture, clientID: "client", recorder: recorder)
    try await oauth.saveTokens(McpOAuthTokens(accessToken: "a1", tokenType: "Bearer", refreshToken: "r1"))
    let auth = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    await #expect(throws: McpOAuthError.self) {
        try await auth.onUnauthorized(challenge: "Bearer error=\"insufficient_scope\", scope=\"repo admin\"",
                                      serverURL: serverURL, rejectedToken: "a1")
    }
    let query = URLComponents(url: try #require(await recorder.read()), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == "repo admin")
    #expect(try await oauth.tokens()?.accessToken == "a1")
    let (_, refreshes, _) = await fixture.snapshot()
    #expect(refreshes == 0)
}

@Test(.timeLimit(.minutes(1)))
func oauthStateBelongsToExactServerURL() async throws {
    let store = McpMemoryOAuthStateStore()
    let recorder = RedirectRecorder()
    let first = McpOAuthProvider(serverURL: URL(string: "https://one.example/mcp")!,
        redirectURL: URL(string: "http://127.0.0.1/callback")!,
        clientMetadata: McpOAuthClientMetadata(clientName: "test"), store: store,
        onRedirect: { url in await recorder.save(url) })
    try await first.saveTokens(McpOAuthTokens(accessToken: "secret", tokenType: "Bearer"))
    let second = McpOAuthProvider(serverURL: URL(string: "https://two.example/mcp")!,
        redirectURL: URL(string: "http://127.0.0.1/callback")!,
        clientMetadata: McpOAuthClientMetadata(clientName: "test"), store: store,
        onRedirect: { url in await recorder.save(url) })
    #expect(try await second.tokens() == nil)
}

@Test(.timeLimit(.minutes(1)))
func oauthRejectsIssuerMismatch() async throws {
    let fixture = OAuthFixture()
    await fixture.setIssuer("https://attacker.example")
    await #expect(throws: McpOAuthError.self) {
        _ = try await McpOAuthDiscovery.authorizationServerMetadata(issuer: fixture.origin, http: fixture)
    }
}

@Test(.timeLimit(.minutes(1)))
func oauthChallengeAndResourceValidation() throws {
    let challenge = McpOAuthDiscovery.parseWWWAuthenticate(
        "Bearer resource_metadata=\"https://auth.example/resource\", scope=\"repo admin\", error=insufficient_scope")
    #expect(challenge.scope == "repo admin")
    #expect(challenge.error == "insufficient_scope")
    #expect(challenge.resourceMetadataURL?.absoluteString == "https://auth.example/resource")
    #expect(try McpOAuthDiscovery.selectResource(serverURL: URL(string: "https://one.example/mcp/tools")!,
        metadata: McpOAuthProtectedResourceMetadata(resource: "https://one.example/mcp")) == "https://one.example/mcp")
    #expect(throws: McpOAuthError.self) {
        _ = try McpOAuthDiscovery.selectResource(serverURL: URL(string: "https://two.example/mcp")!,
            metadata: McpOAuthProtectedResourceMetadata(resource: "https://one.example/mcp"))
    }
}

#if os(macOS)
@Test(.timeLimit(.minutes(1)))
func macOSOAuthPresenterUsesSharedCallbackServer() async throws {
    let presenter = McpMacOSSignInPresenter(openAuthorizationURL: { authorizationURL in
        let redirect = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value)
        let callback = try #require(URL(string: "\(redirect)?code=ok&state=test-state"))
        _ = try await URLSession.shared.data(from: callback)
    })
    let redirect = try await presenter.redirectURL(for: "test-state")
    var components = URLComponents(string: "https://auth.example/authorize")!
    components.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect.absoluteString)]
    let received = try await presenter.present(authorizationURL: components.url!, state: "test-state")
    #expect(URLComponents(url: received, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "code" }?.value == "ok")
}
#endif
