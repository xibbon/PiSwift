import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PiSwiftMCP

private let parityServer = URL(string: "https://auth.example/mcp")!
private let parityRoute = URL(string: "https://app.example/mcp/callback")!
private let parityDocument = URL(string: "https://app.example/oauth/client.json")!

private func parityMetadata() -> McpOAuthAuthorizationServerMetadata {
    McpOAuthAuthorizationServerMetadata(issuer: "https://auth.example",
        authorizationEndpoint: "https://auth.example/authorize",
        tokenEndpoint: "https://auth.example/token",
        registrationEndpoint: "https://auth.example/register",
        tokenEndpointAuthMethodsSupported: ["none"], codeChallengeMethodsSupported: ["S256"],
        clientIDMetadataDocumentSupported: true, authorizationResponseIssParameterSupported: true)
}

private func parityState(document: Bool = false) -> McpOAuthState {
    McpOAuthState(serverURL: parityServer.absoluteString,
        clientInformation: document ? nil : McpOAuthClientInformation(clientID: "client-1",
            metadata: McpOAuthClientMetadata(redirectURIs: [parityRoute.absoluteString])),
        tokens: McpOAuthTokens(accessToken: "access-1", tokenType: "Bearer", scope: "read", refreshToken: "refresh-1"),
        codeVerifier: "pending-verifier", oauthState: "pending-state",
        discovery: McpOAuthDiscoveryState(authorizationServerURL: "https://auth.example",
            authorizationServerMetadata: parityMetadata()))
}

private actor ParityHTTP: McpOAuthHTTPClient {
    enum Failure: Sendable { case oauth(String), network }
    private var failure: Failure?
    private let replaceClient: McpMemoryOAuthStateStore?
    private(set) var paths: [String] = []
    private(set) var tokenClients: [String] = []
    private(set) var verifiers: [String] = []

    init(failure: Failure? = nil, replaceClient: McpMemoryOAuthStateStore? = nil) {
        self.failure = failure
        self.replaceClient = replaceClient
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        func response(_ data: Data, status: Int = 200) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
        }
        if url.path.contains("oauth-protected-resource") {
            return response(Data(#"{"resource":"https://auth.example/mcp","authorization_servers":["https://auth.example"]}"#.utf8))
        }
        if url.path.contains("well-known") {
            return response(try JSONEncoder().encode(parityMetadata()))
        }
        guard url.path == "/token" else {
            Issue.record("Unexpected OAuth request: \(url)")
            return response(Data(#"{"error":"unexpected_request"}"#.utf8), status: 400)
        }
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let items = URLComponents(string: "https://example.test/?\(body)")?.queryItems ?? []
        func parameter(_ name: String) -> String? { items.first { $0.name == name }?.value }
        tokenClients.append(parameter("client_id") ?? "")
        if let verifier = parameter("code_verifier") { verifiers.append(verifier) }
        if parameter("grant_type") == "refresh_token", let failure {
            self.failure = nil
            if let replaceClient, var state = await replaceClient.load() {
                state.clientInformation = McpOAuthClientInformation(clientID: "client-new",
                    metadata: McpOAuthClientMetadata(redirectURIs: [parityRoute.absoluteString]))
                await replaceClient.save(state)
            }
            switch failure {
            case .network: throw URLError(.networkConnectionLost)
            case .oauth(let code):
                return response(try JSONEncoder().encode(["error": code]), status: 400)
            }
        }
        return response(Data(#"{"access_token":"access-2","token_type":"Bearer","refresh_token":"refresh-2"}"#.utf8))
    }
}

// Swift takes a host refresh operation instead of exposing the TypeScript factory.
// Keep this operation limited to the public refresh-only flow.
private func parityProvider(store: McpMemoryOAuthStateStore, http: ParityHTTP,
    document: Bool = false) -> McpStoredAuthProvider {
    let hook: McpOAuthClientMetadataDocumentProvider?
    if document {
        hook = { metadata in
            try .staticDocument(url: parityDocument, redirectURL: parityRoute, metadata: metadata)
        }
    } else {
        hook = nil
    }
    let oauth = McpOAuthProvider(serverURL: parityServer, redirectURL: parityRoute,
        clientMetadata: McpOAuthClientMetadata(), clientMetadataDocument: hook, store: store,
        onRedirect: { _ in Issue.record("Refresh must not open a browser") })
    return McpStoredAuthProvider(store: store) { _, _ in
        try await McpOAuthFlow.authorize(provider: oauth,
            options: McpOAuthFlowOptions(serverURL: parityServer, refreshOnly: true), http: http)
    }
}

private func parityReject(_ provider: McpStoredAuthProvider) async throws {
    try await provider.onUnauthorized(challenge: nil, serverURL: parityServer, rejectedToken: "access-1")
}

private func parityRequiresSignIn(_ provider: McpStoredAuthProvider) async throws {
    do {
        try await parityReject(provider)
        Issue.record("Expected authorizationRequired")
    } catch let error as McpOAuthError {
        guard case .authorizationRequired = error else { throw error }
    }
}

@Suite("createMcpAuthProvider parity")
struct M3AuthProviderParityTests {
    @Test("leaves a pending sign-in usable when the refresh fails")
    func pendingSignInSurvivesInvalidGrant() async throws {
        let store = McpMemoryOAuthStateStore()
        let pending = parityState()
        await store.save(pending)
        let http = ParityHTTP(failure: .oauth("invalid_grant"))
        try await parityRequiresSignIn(parityProvider(store: store, http: http))
        let state = await store.load()
        #expect(state?.oauthState == pending.oauthState)
        #expect(state?.codeVerifier == pending.codeVerifier)
        #expect(state?.clientInformation == pending.clientInformation)
        #expect(state?.tokens == nil)
        let authorization = McpSignInRedirect(authorizationURL: URL(string: "https://auth.example/authorize")!,
            redirectURL: parityRoute, state: "pending-state")
        try await McpOAuthSignIn.completeMcpSignIn(options:
            McpSignInOptions(serverURL: parityServer, redirectURL: parityRoute, store: store, http: http),
            authorization: authorization,
            response: McpAuthorizationResponse(code: "pending-code", state: "pending-state", iss: "https://auth.example"))
        #expect(await store.load()?.tokens?.accessToken == "access-2")
        #expect(await http.verifiers == ["pending-verifier"])
        #expect(await http.paths.allSatisfy { $0 == "/token" })
    }

    @Test("does not register a client to refresh")
    func refreshDoesNotRegisterClient() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState(document: true))
        let http = ParityHTTP()
        try await parityRequiresSignIn(parityProvider(store: store, http: http))
        #expect(await http.paths.isEmpty)
        #expect(await store.load()?.clientInformation == nil)
    }

    @Test("drops a rejected client and its tokens but keeps the pending sign-in")
    func pendingSignInSurvivesInvalidClient() async throws {
        let store = McpMemoryOAuthStateStore()
        let pending = parityState()
        await store.save(pending)
        let http = ParityHTTP(failure: .oauth("invalid_client"))
        try await parityRequiresSignIn(parityProvider(store: store, http: http))
        let state = await store.load()
        #expect(state?.oauthState == pending.oauthState)
        #expect(state?.codeVerifier == pending.codeVerifier)
        #expect(state?.clientInformation == nil)
        #expect(state?.tokens == nil)
        #expect(await http.tokenClients == ["client-1"])
        #expect(await http.paths.contains("/register") == false)
    }

    @Test("keeps a client stored while the rejected refresh ran")
    func preservesClientReplacedDuringRefresh() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP(failure: .oauth("invalid_client"), replaceClient: store)
        let provider = parityProvider(store: store, http: http)
        try await parityReject(provider)
        #expect(await store.load()?.clientInformation?.clientID == "client-new")
        #expect(await http.tokenClients == ["client-1", "client-new"])
        #expect(try await provider.token() == "access-2")
    }

    @Test("keeps the tokens and the pending sign-in after a server error")
    func pendingSignInSurvivesServerError() async throws {
        try await checkTransientFailure(.oauth("server_error"))
    }

    @Test("keeps the tokens and the pending sign-in after a network error")
    func pendingSignInSurvivesNetworkError() async throws {
        try await checkTransientFailure(.network)
    }

    private func checkTransientFailure(_ failure: ParityHTTP.Failure) async throws {
        let store = McpMemoryOAuthStateStore()
        let pending = parityState()
        await store.save(pending)
        let http = ParityHTTP(failure: failure)
        try await parityRequiresSignIn(parityProvider(store: store, http: http))
        let state = await store.load()
        #expect(state?.oauthState == pending.oauthState)
        #expect(state?.codeVerifier == pending.codeVerifier)
        #expect(state?.tokens == pending.tokens)
        #expect(state?.clientInformation == pending.clientInformation)
        #expect(await http.paths == ["/token"])
    }

    @Test("refreshes the tokens of a document that lists only the redirect URI passed (%s)",
        arguments: ["auto", "cimd"])
    func refreshesHostStaticDocument(_ registration: String) async throws {
        // Swift uses the same host static hook for both upstream registration settings.
        #expect(["auto", "cimd"].contains(registration))
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState(document: true))
        let http = ParityHTTP()
        let provider = parityProvider(store: store, http: http, document: true)
        try await parityReject(provider)
        #expect(try await provider.token() == "access-2")
        #expect(await store.load()?.clientInformation == nil)
        #expect(await http.tokenClients == [parityDocument.absoluteString])
        #expect(await http.paths == ["/token"])
    }
}
