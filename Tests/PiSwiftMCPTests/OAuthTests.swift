import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Synchronization
@testable import PiSwiftMCP
#if canImport(CryptoKit)
import CryptoKit
#endif

private actor OAuthFixture: McpOAuthHTTPClient {
    enum Mode: Sendable, Equatable {
        case standard, emptyOptionalFields, invalidProtectedURL, emptyScopes, configuredMetadata, responseScope
        case clientMetadataDocument(iss: Bool?, metadataAvailable: Bool)
    }
    let mode: Mode
    init(mode: Mode = .standard) { self.mode = mode }

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
        var body: [String: Any]
        var status: Int
        switch path {
        case "/.well-known/oauth-protected-resource/mcp":
            if protectedResource {
                body = ["resource": "\(origin)/mcp",
                        "authorization_servers": [mode == .invalidProtectedURL ? "not a url" : origin.absoluteString],
                        "scopes_supported": mode == .emptyScopes ? [] : ["org:read"]]
                status = 200
            } else { body = [:]; status = 404 }
        case "/.well-known/oauth-authorization-server":
            body = ["issuer": issuerOverride ?? origin.absoluteString,
                    "authorization_endpoint": "\(origin)/authorize", "token_endpoint": "\(origin)/token",
                    "registration_endpoint": "\(origin)/register", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                    "token_endpoint_auth_methods_supported": ["none"], "code_challenge_methods_supported": ["S256"]]
            status = 200
        case "/idp/metadata.json", "/other/metadata.json":
            let prefix = path == "/idp/metadata.json" ? "idp" : "other"
            body = ["issuer": "https://\(prefix).example",
                    "authorization_endpoint": "\(origin)/\(prefix)/authorize",
                    "token_endpoint": "\(origin)/\(prefix)/token", "response_types_supported": ["code"]]
            status = mode == .configuredMetadata ? 200 : 404
        case "/register":
            var registration = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            registration["client_id"] = "test-client"
            if mode == .emptyOptionalFields { registration["client_secret"] = "" }
            body = registration
            status = 201
        case "/token", "/idp/token", "/other/token":
            let parameters = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? []
            let parameter: (String) -> String? = { name in parameters.first { $0.name == name }?.value }
            tokenGrants.append(parameter("grant_type") ?? "")
            if parameter("grant_type") == "refresh_token" {
                refreshCount += 1
                if mode == .emptyOptionalFields {
                    body = ["access_token": "refreshed-token", "refresh_token": "", "token_type": "Bearer", "expires_in": NSNull()]
                } else if mode == .responseScope {
                    body = ["access_token": "refreshed-token", "token_type": "Bearer", "scope": "server:refresh"]
                } else {
                    body = ["access_token": "refreshed-token", "refresh_token": "next-refresh", "token_type": "Bearer", "expires_in": 3600]
                }
                status = 200
            } else if parameter("code") == "test-code" {
                if mode == .emptyOptionalFields {
                    body = ["access_token": accessToken, "refresh_token": "refresh-token", "token_type": "Bearer", "scope": ""]
                } else if mode == .responseScope {
                    body = ["access_token": accessToken, "refresh_token": "refresh-token", "token_type": "Bearer", "scope": "server:code"]
                } else {
                    body = ["access_token": accessToken, "refresh_token": "refresh-token", "token_type": "Bearer"]
                }
                status = 200
            } else {
                body = ["error": "invalid_grant"]
                status = 400
            }
        default:
            body = [:]
            status = 404
        }
        if path == "/.well-known/oauth-authorization-server",
           case .clientMetadataDocument(let iss, let metadataAvailable) = mode {
            if metadataAvailable {
                body["client_id_metadata_document_supported"] = true
                if let iss { body["authorization_response_iss_parameter_supported"] = iss }
            } else {
                body = [:]
                status = 404
            }
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
    // Upstream v1.0.0 oauth.test.ts keeps the granted scopes during step-up.
    try await oauth.saveTokens(McpOAuthTokens(accessToken: "a1", tokenType: "Bearer", scope: "repo read:org", refreshToken: "r1"))
    let auth = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    await #expect(throws: McpOAuthError.self) {
        try await auth.onUnauthorized(challenge: "Bearer error=\"insufficient_scope\", scope=\"repo admin\"",
                                      serverURL: serverURL, rejectedToken: "a1")
    }
    let query = URLComponents(url: try #require(await recorder.read()), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "scope" }?.value == "repo read:org admin")
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


@Test(.timeLimit(.minutes(1)))
func oauthEmptyFieldsKeepRequestedScopeAndRefreshToken() async throws {
    let fixture = OAuthFixture(mode: .emptyOptionalFields)
    let recorder = RedirectRecorder()
    let store = McpMemoryOAuthStateStore()
    let oauth = provider(fixture, store: store, recorder: recorder)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    let adapter = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    let challenge = "Bearer resource_metadata=\"\(fixture.origin)/.well-known/oauth-protected-resource/mcp\", scope=\"\""
    await #expect(throws: McpOAuthError.self) {
        try await adapter.onUnauthorized(challenge: challenge, serverURL: serverURL, rejectedToken: "stale")
    }
    let authorization = try #require(await recorder.read())
    let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.first { $0.name == "scope" }?.value == "org:read")
    #expect(query?.first { $0.name == "resource" }?.value == serverURL.absoluteString)
    #expect(try await oauth.clientInformation()?.clientSecret == nil)
    let state = try #require(await oauth.state())
    let callback = URL(string: "http://127.0.0.1:6789/callback?code=test-code&state=\(state)")!
    let tokens = try await McpOAuthFlow.completeRedirect(provider: oauth, callbackURL: callback,
        options: McpOAuthFlowOptions(serverURL: serverURL), http: fixture)
    #expect(tokens.scope == "org:read")
    try await adapter.onUnauthorized(challenge: challenge, serverURL: serverURL, rejectedToken: tokens.accessToken)
    #expect(try await oauth.tokens() == McpOAuthTokens(accessToken: "refreshed-token", tokenType: "Bearer",
        scope: "org:read", refreshToken: "refresh-token"))
    #expect(await store.load()?.tokensExpireAt == nil)
    #expect(await fixture.snapshot().1 == 1)
}

@Test(.timeLimit(.minutes(1)))
func oauthBadProtectedURLFallsBackDuringConcurrentRefresh() async throws {
    let fixture = OAuthFixture(mode: .invalidProtectedURL)
    let oauth = provider(fixture, clientID: "client", recorder: RedirectRecorder())
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    try await oauth.saveTokens(McpOAuthTokens(accessToken: "a1", tokenType: "Bearer", scope: "old:scope", refreshToken: "r1"))
    let adapter = McpOAuthAuthAdapter(provider: oauth, http: fixture)
    async let first: Void = adapter.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    async let second: Void = adapter.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    try await first
    try await second
    try await adapter.onUnauthorized(challenge: "Bearer", serverURL: serverURL, rejectedToken: "a1")
    #expect(await fixture.snapshot().1 == 1)
    #expect(try await oauth.tokens()?.scope == "old:scope")
    let discovery = try #require(await oauth.discoveryState())
    #expect(discovery.authorizationServerURL == fixture.origin.absoluteString)
    #expect(discovery.resourceMetadata == nil)
}

@Test(.timeLimit(.minutes(1)))
func oauthConfiguredDocumentSkipsCacheAndKeepsCallbackOptions() async throws {
    let fixture = OAuthFixture(mode: .configuredMetadata)
    let recorder = RedirectRecorder()
    let oauth = provider(fixture, clientID: "client", recorder: recorder)
    let serverURL = URL(string: "http://127.0.0.1:45454/mcp")!
    let cached = McpOAuthDiscoveryState(authorizationServerURL: "https://cached.example",
        authorizationServerMetadata: McpOAuthAuthorizationServerMetadata(issuer: "https://cached.example",
            authorizationEndpoint: "https://cached.example/authorize", tokenEndpoint: "https://cached.example/token"))
    try await oauth.saveDiscoveryState(cached)
    var options = McpOAuthFlowOptions(serverURL: serverURL, scope: "custom:scope",
        resourceMetadataURL: URL(string: "\(fixture.origin)/.well-known/oauth-protected-resource/mcp"),
        authorizationServerMetadataURL: URL(string: "\(fixture.origin)/idp/metadata.json"))
    #expect(try await McpOAuthFlow.authorize(provider: oauth, options: options, http: fixture) == .redirect)
    let authorization = try #require(await recorder.read())
    #expect(authorization.path == "/idp/authorize")
    #expect(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "resource" }?.value == serverURL.absoluteString)
    #expect(try await oauth.discoveryState() == cached)
    let state = try #require(await oauth.state())
    let callback = URL(string: "http://127.0.0.1:6789/callback?code=test-code&state=\(state)&iss=https://idp.example")!
    let tokens = try await McpOAuthFlow.completeRedirect(provider: oauth, callbackURL: callback, options: options, http: fixture)
    #expect(tokens.scope == "custom:scope")
    #expect(await fixture.snapshot().0.contains { $0.url?.path == "/idp/token" })
    options.authorizationServerMetadataURL = URL(string: "\(fixture.origin)/other/metadata.json")
    options.skipRefresh = true
    #expect(try await McpOAuthFlow.authorize(provider: oauth, options: options, http: fixture) == .redirect)
    #expect(await recorder.read()?.path == "/other/authorize")
    #expect(try await oauth.discoveryState() == cached)
    let requests = await fixture.snapshot().0
    #expect(requests.filter { $0.url?.path == "/idp/metadata.json" }.count == 2)
    #expect(!requests.contains { $0.url?.host == "cached.example" || $0.url?.path == "/.well-known/oauth-authorization-server" })
}

@Test(.timeLimit(.minutes(1)))
func oauthConfiguredDocumentRejectsInsecureURLBeforeFetch() async throws {
    let fixture = OAuthFixture(mode: .configuredMetadata)
    let oauth = provider(fixture, clientID: "client", recorder: RedirectRecorder())
    do {
        _ = try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!,
                authorizationServerMetadataURL: URL(string: "http://idp.example/metadata.json")), http: fixture)
        Issue.record("Expected insecure endpoint error")
    } catch McpOAuthError.insecureEndpoint(let url) {
        #expect(url == "http://idp.example/metadata.json")
    }
    #expect(await fixture.snapshot().0.isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2, 3])
func oauthAuthorizationResponseIssuerCases(_ index: Int) async throws {
    let fixture = OAuthFixture()
    let oauth = provider(fixture, clientID: "client", recorder: RedirectRecorder())
    let iss = index == 0 ? "https://attacker.example" : (index == 2 ? fixture.origin.absoluteString : nil)
    let supported = index == 1 || index == 2
    try await oauth.saveCodeVerifier("verifier")
    try await oauth.saveDiscoveryState(McpOAuthDiscoveryState(authorizationServerURL: fixture.origin.absoluteString,
        authorizationServerMetadata: McpOAuthAuthorizationServerMetadata(issuer: fixture.origin.absoluteString,
            authorizationEndpoint: "\(fixture.origin)/authorize", tokenEndpoint: "\(fixture.origin)/token",
            authorizationResponseIssParameterSupported: supported)))
    let options = McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!,
        authorizationCode: "test-code", iss: iss, skipIssuerValidation: true)
    if index < 2 {
        do {
            _ = try await McpOAuthFlow.authorize(provider: oauth, options: options, http: fixture)
            Issue.record("Expected issuer mismatch")
        } catch McpOAuthError.issuerMismatch(let expected, let received) {
            #expect(expected == fixture.origin.absoluteString)
            #expect(received == iss)
        }
        #expect(await fixture.snapshot().2.isEmpty)
        #expect(try await oauth.tokens() == nil)
    } else {
        #expect(try await McpOAuthFlow.authorize(provider: oauth, options: options, http: fixture) == .authorized)
        #expect(await fixture.snapshot().2 == ["authorization_code"])
    }
}

@Test(.timeLimit(.minutes(1)))
func oauthSignInStoresExplicitRequestScope() async throws {
    let fixture = OAuthFixture()
    let oauth = try await McpOAuthSignIn.signIn(serverURL: URL(string: "\(fixture.origin)/mcp")!,
        presenter: TestSignInPresenter(), clientMetadata: McpOAuthClientMetadata(clientName: "test"),
        http: fixture, scope: "custom:scope")
    #expect(try await oauth.tokens()?.scope == "custom:scope")
}

@Test(.timeLimit(.minutes(1)))
func oauthEmptyScopesFallThroughToClientMetadata() async throws {
    let fixture = OAuthFixture(mode: .emptyScopes)
    let recorder = RedirectRecorder()
    let serverURL = URL(string: "\(fixture.origin)/mcp")!
    let oauth = McpOAuthProvider(serverURL: serverURL, redirectURL: URL(string: "http://127.0.0.1:6789/callback")!,
        clientMetadata: McpOAuthClientMetadata(scope: "client:scope"), clientID: "client",
        onRedirect: { await recorder.save($0) })
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: serverURL, scope: ""), http: fixture) == .redirect)
    let url = try #require(await recorder.read())
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value == "client:scope")
    #expect(McpOAuthDiscovery.parseWWWAuthenticate("Bearer scope=\"\"").scope == nil)
}

@Test(.timeLimit(.minutes(1)))
func oauthResponseScopeTakesPrecedenceOverFallback() async throws {
    let fixture = OAuthFixture(mode: .responseScope)
    let oauth = provider(fixture, clientID: "client", recorder: RedirectRecorder())
    let serverURL = URL(string: "\(fixture.origin)/mcp")!
    try await oauth.saveCodeVerifier("verifier")
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: serverURL, authorizationCode: "test-code", scope: "requested"), http: fixture) == .authorized)
    #expect(try await oauth.tokens()?.scope == "server:code")
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: serverURL), http: fixture) == .authorized)
    #expect(try await oauth.tokens()?.scope == "server:refresh")
}

@Test func oauthStepUpScopeKeepsUpstreamOrder() {
    #expect(McpOAuthFlow.stepUpScope(granted: "repo read:org", challenged: nil) == nil)
    #expect(McpOAuthFlow.stepUpScope(granted: "repo read:org", challenged: "") == nil)
    #expect(McpOAuthFlow.stepUpScope(granted: " repo  read:org\t", challenged: "repo\nadmin admin") == "repo read:org admin")
    #expect(McpOAuthFlow.stepUpScope(granted: nil, challenged: " admin ") == "admin")
}

@Test(arguments: ["null", "\"\""])
func oauthOptionalFieldsDecodeAsAbsent(_ absent: String) throws {
    let decoder = JSONDecoder()
    let tokens = try decoder.decode(McpOAuthTokens.self,
        from: Data("{\"access_token\":\"token\",\"token_type\":\"Bearer\",\"scope\":\(absent),\"refresh_token\":\(absent),\"id_token\":\(absent),\"expires_in\":\(absent)}".utf8))
    #expect(tokens == McpOAuthTokens(accessToken: "token", tokenType: "Bearer"))
    let client = try decoder.decode(McpOAuthClientInformation.self,
        from: Data("{\"client_id\":\"client\",\"client_secret\":\(absent),\"client_id_issued_at\":\(absent),\"client_secret_expires_at\":\(absent)}".utf8))
    #expect(client == McpOAuthClientInformation(clientID: "client"))
    let metadata = try decoder.decode(McpOAuthAuthorizationServerMetadata.self,
        from: Data("{\"issuer\":\"https://idp.example\",\"authorization_endpoint\":\"https://idp.example/authorize\",\"token_endpoint\":\"https://idp.example/token\",\"registration_endpoint\":\(absent),\"response_types_supported\":[\"code\"],\"scopes_supported\":null,\"authorization_response_iss_parameter_supported\":null}".utf8))
    #expect(metadata.registrationEndpoint == nil)
    #expect(metadata.scopesSupported == nil)
    #expect(metadata.authorizationResponseIssParameterSupported == nil)
    let resource = try decoder.decode(McpOAuthProtectedResourceMetadata.self,
        from: Data("{\"resource\":\"https://mcp.example/mcp\",\"authorization_servers\":null,\"scopes_supported\":null}".utf8))
    #expect(resource.authorizationServers == nil)
    #expect(resource.scopesSupported == nil)
}

private final class ClientDocumentHookRecorder: Sendable {
    private let values = Mutex<[McpOAuthAuthorizationServerMetadata?]>([])
    func record(_ metadata: McpOAuthAuthorizationServerMetadata?) { values.withLock { $0.append(metadata) } }
    func read() -> [McpOAuthAuthorizationServerMetadata?] { values.withLock { $0 } }
}

private let clientDocumentURL = URL(string: "https://host.example/oauth/client.json")!
private let clientDocumentRedirectURL = URL(string: "http://127.0.0.1:6789/callback")!

private func documentProvider(
    _ fixture: OAuthFixture, store: McpMemoryOAuthStateStore = McpMemoryOAuthStateStore(),
    recorder: RedirectRecorder = RedirectRecorder(), hook: @escaping McpOAuthClientMetadataDocumentProvider
) -> McpOAuthProvider {
    McpOAuthProvider(serverURL: URL(string: "\(fixture.origin)/mcp")!, redirectURL: clientDocumentRedirectURL,
        clientMetadata: McpOAuthClientMetadata(clientName: "document-test"), clientMetadataDocument: hook,
        store: store, onRedirect: { await recorder.save($0) })
}

private func oauthQuery(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private func oauthTokenParameter(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?
        .queryItems?.first { $0.name == name }?.value
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentSignInUsesDocumentWithoutSavingClient() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let store = McpMemoryOAuthStateStore()
    let recorder = RedirectRecorder()
    let calls = ClientDocumentHookRecorder()
    let issuer = fixture.origin.absoluteString
    let presenter = McpPasteRedirectPresenter(callbackURL: clientDocumentRedirectURL,
        openAuthorizationURL: { await recorder.save($0) }, pasteRedirectURL: {
            let url = try #require(await recorder.read())
            let state = try #require(oauthQuery(url, "state"))
            return "\(clientDocumentRedirectURL)?code=test-code&state=\(state)&iss=\(issuer)"
        })
    let oauth = try await McpOAuthSignIn.signIn(serverURL: URL(string: "\(fixture.origin)/mcp")!,
        presenter: presenter, clientMetadata: McpOAuthClientMetadata(clientName: "document-test"),
        clientMetadataDocument: { metadata, redirectURL in
            calls.record(metadata)
            #expect(redirectURL == clientDocumentRedirectURL)
            return try .staticDocument(url: clientDocumentURL, redirectURL: redirectURL, metadata: metadata)
        }, store: store, http: fixture)
    let authorization = try #require(await recorder.read())
    #expect(oauthQuery(authorization, "client_id") == clientDocumentURL.absoluteString)
    #expect(oauthQuery(authorization, "redirect_uri") == clientDocumentRedirectURL.absoluteString)
    #expect(try await oauth.clientInformation() == nil)
    #expect(await store.load()?.clientInformation == nil)
    #expect(try await oauth.tokens()?.accessToken == "first-token")
    #expect(calls.read().count == 2)
    #expect(calls.read().allSatisfy { $0?.authorizationResponseIssParameterSupported == true })
    let requests = await fixture.snapshot().0
    #expect(!requests.contains { $0.url?.path == "/register" || $0.url?.host == "host.example" })
    let token = try #require(requests.first { $0.url?.path == "/token" })
    #expect(oauthTokenParameter(token, "client_id") == clientDocumentURL.absoluteString)
    #expect(oauthTokenParameter(token, "redirect_uri") == clientDocumentRedirectURL.absoluteString)
    #expect(oauthTokenParameter(token, "client_secret") == nil)
    #expect(token.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentRefreshCallsHookAgainWithoutStoredClient() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let store = McpMemoryOAuthStateStore()
    let calls = ClientDocumentHookRecorder()
    let hook: McpOAuthClientMetadataDocumentProvider = { metadata in
        calls.record(metadata)
        return try .staticDocument(url: clientDocumentURL, redirectURL: clientDocumentRedirectURL, metadata: metadata)
    }
    let options = McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!)
    let initial = documentProvider(fixture, store: store, hook: hook)
    #expect(try await McpOAuthFlow.authorize(provider: initial, options: options, http: fixture) == .redirect)
    #expect(calls.read().count == 1)
    try await initial.saveTokens(McpOAuthTokens(accessToken: "old", tokenType: "Bearer", refreshToken: "refresh-token"))
    let refresh = documentProvider(fixture, store: store, hook: hook)
    #expect(try await McpOAuthFlow.authorize(provider: refresh, options: options, http: fixture) == .authorized)
    #expect(calls.read().count == 2)
    #expect(await store.load()?.clientInformation == nil)
    #expect(try await refresh.tokens()?.accessToken == "refreshed-token")
    let (requests, refreshes, _) = await fixture.snapshot()
    #expect(refreshes == 1)
    #expect(!requests.contains { $0.url?.path == "/register" })
    let token = try #require(requests.first { $0.url?.path == "/token" })
    #expect(oauthTokenParameter(token, "client_id") == clientDocumentURL.absoluteString)
    #expect(oauthTokenParameter(token, "grant_type") == "refresh_token")
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func oauthClientDocumentHookRunsWithNilOrUnadvertisedMetadata(_ metadataAvailable: Bool) async throws {
    let fixture = metadataAvailable ? OAuthFixture() : OAuthFixture(mode: .clientMetadataDocument(iss: nil, metadataAvailable: false))
    let recorder = RedirectRecorder()
    let calls = ClientDocumentHookRecorder()
    let oauth = documentProvider(fixture, recorder: recorder) { metadata in
        calls.record(metadata)
        return McpOAuthClientMetadataDocument(url: clientDocumentURL, redirectURL: clientDocumentRedirectURL)
    }
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture) == .redirect)
    let values = calls.read()
    try #require(values.count == 1)
    #expect((values[0] != nil) == metadataAvailable)
    #expect(values[0]?.clientIDMetadataDocumentSupported == nil)
    let authorization = try #require(await recorder.read())
    #expect(oauthQuery(authorization, "client_id") == clientDocumentURL.absoluteString)
    #expect(try await oauth.clientInformation() == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: ["http://host.example/client.json", "https://host.example/", "https://host.example"])
func oauthClientDocumentRejectsInvalidURL(_ value: String) async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let url = try #require(URL(string: value))
    let oauth = documentProvider(fixture) { _ in McpOAuthClientMetadataDocument(url: url, redirectURL: clientDocumentRedirectURL) }
    do {
        _ = try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture)
        Issue.record("Expected invalid client metadata URL")
    } catch McpOAuthError.invalidMetadata(let field) {
        #expect(field == "client metadata URL")
    }
    #expect(try await oauth.clientInformation() == nil)
    #expect(await fixture.snapshot().0.allSatisfy { $0.httpMethod != "POST" })
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentRejectsRedirectMismatch() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let oauth = documentProvider(fixture) { _ in
        McpOAuthClientMetadataDocument(url: clientDocumentURL, redirectURL: URL(string: "http://127.0.0.1:6789/other")!)
    }
    do {
        _ = try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture)
        Issue.record("Expected client metadata redirect mismatch")
    } catch McpOAuthError.invalidMetadata(let field) {
        #expect(field == "client metadata redirect URL")
    }
    #expect(await fixture.snapshot().0.allSatisfy { $0.httpMethod != "POST" })
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1, 2, 3, 4, 5])
func oauthStaticClientDocumentRejectsUnsupportedPublicClientsFirst(_ index: Int) async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: false, metadataAvailable: true))
    var metadata = try #require(try await McpOAuthDiscovery.authorizationServerMetadata(issuer: fixture.origin, http: fixture))
    switch index {
    case 1: metadata.clientIDMetadataDocumentSupported = nil
    case 2: metadata.clientIDMetadataDocumentSupported = false
    case 3: metadata.tokenEndpointAuthMethodsSupported = nil
    case 4: metadata.tokenEndpointAuthMethodsSupported = []
    case 5: metadata.tokenEndpointAuthMethodsSupported = ["client_secret_post"]
    default: break
    }
    let message = "The authorization server does not support Client ID Metadata Documents for public clients; remove oauth.clientRegistration \"cimd\""
    do {
        _ = try McpOAuthClientMetadataDocument.staticDocument(url: clientDocumentURL,
            redirectURL: clientDocumentRedirectURL, metadata: index == 0 ? nil : metadata)
        Issue.record("Expected public client support error")
    } catch McpOAuthError.clientMetadataDocumentUnsupported(let received) {
        #expect(received == message)
        #expect(McpOAuthError.clientMetadataDocumentUnsupported(received).errorDescription == message)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [Optional<Bool>.none, false])
func oauthStaticClientDocumentRequiresIssuerSupport(_ iss: Bool?) async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: iss, metadataAvailable: true))
    let metadata = try #require(try await McpOAuthDiscovery.authorizationServerMetadata(issuer: fixture.origin, http: fixture))
    let message = "The authorization server does not send the iss parameter in authorization responses (RFC 9207), which oauth.clientRegistration \"cimd\" requires; remove oauth.clientRegistration to use dynamic client registration, or set oauth.clientId"
    do {
        _ = try McpOAuthClientMetadataDocument.staticDocument(url: clientDocumentURL, redirectURL: clientDocumentRedirectURL, metadata: metadata)
        Issue.record("Expected RFC 9207 support error")
    } catch McpOAuthError.clientMetadataDocumentUnsupported(let received) {
        #expect(received == message)
        #expect(McpOAuthError.clientMetadataDocumentUnsupported(received).errorDescription == message)
    }
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentCodeExchangeWithoutClientFailsAfterHook() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let calls = ClientDocumentHookRecorder()
    let oauth = documentProvider(fixture) { metadata in calls.record(metadata); return nil }
    do {
        _ = try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!,
                authorizationCode: "test-code", iss: fixture.origin.absoluteString), http: fixture)
        Issue.record("Expected missing client information")
    } catch McpOAuthError.invalidMetadata(let field) {
        #expect(field == "client information missing during code exchange")
    }
    #expect(calls.read().count == 1)
    #expect(await fixture.snapshot().0.allSatisfy { $0.httpMethod != "POST" })
}

@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func oauthClientDocumentStoredOrConfiguredClientSkipsHook(_ configured: Bool) async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let recorder = RedirectRecorder()
    let oauth = McpOAuthProvider(serverURL: URL(string: "\(fixture.origin)/mcp")!,
        redirectURL: clientDocumentRedirectURL, clientMetadata: McpOAuthClientMetadata(),
        clientID: configured ? "existing-client" : nil, clientMetadataDocument: { _ in
            Issue.record("The document hook must not run when client information is present")
            throw McpOAuthError.invalidMetadata("unexpected hook call")
        }, onRedirect: { await recorder.save($0) })
    if !configured { try await oauth.saveClientInformation(McpOAuthClientInformation(clientID: "existing-client")) }
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture) == .redirect)
    let url = try #require(await recorder.read())
    #expect(oauthQuery(url, "client_id") == "existing-client")
    #expect(await fixture.snapshot().0.allSatisfy { $0.httpMethod != "POST" })
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentNilHookRegistersAndSavesClient() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: true, metadataAvailable: true))
    let calls = ClientDocumentHookRecorder()
    let oauth = documentProvider(fixture) { metadata in calls.record(metadata); return nil }
    #expect(try await McpOAuthFlow.authorize(provider: oauth,
        options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture) == .redirect)
    #expect(calls.read().count == 1)
    #expect(try await oauth.clientInformation()?.clientID == "test-client")
    #expect(await fixture.snapshot().0.contains { $0.url?.path == "/register" })
}

@Test(.timeLimit(.minutes(1)))
func oauthClientDocumentHookErrorStopsFlow() async throws {
    let fixture = OAuthFixture(mode: .clientMetadataDocument(iss: false, metadataAvailable: true))
    let oauth = documentProvider(fixture) { metadata in
        try .staticDocument(url: clientDocumentURL, redirectURL: clientDocumentRedirectURL, metadata: metadata)
    }
    do {
        _ = try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: URL(string: "\(fixture.origin)/mcp")!), http: fixture)
        Issue.record("Expected document hook error")
    } catch McpOAuthError.clientMetadataDocumentUnsupported(let message) {
        #expect(message.contains("iss parameter in authorization responses (RFC 9207)"))
    }
    #expect(await fixture.snapshot().0.allSatisfy { $0.httpMethod != "POST" })
}

@Test func oauthRequiredAndInvalidOptionalFieldsStillFail() {
    let decoder = JSONDecoder()
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(McpOAuthTokens.self, from: Data(#"{"access_token":"","token_type":"Bearer"}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(McpOAuthTokens.self, from: Data(#"{"access_token":"token","token_type":"Bearer","scope":42}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(McpOAuthProtectedResourceMetadata.self, from: Data(#"{"resource":"https://mcp.example","authorization_servers":""}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try decoder.decode(McpOAuthAuthorizationServerMetadata.self,
            from: Data(#"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/authorize","token_endpoint":"https://idp.example/token","response_types_supported":["code"],"registration_endpoint":"not a url"}"#.utf8))
    }
}
