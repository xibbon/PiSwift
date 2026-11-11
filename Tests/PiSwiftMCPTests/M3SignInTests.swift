import Foundation
import Testing
@testable import PiSwiftMCP

@Test("refuses a response with another state")
func m3SignInRejectsResponseState() async throws {
    let server = URL(string: "https://mcp.example/mcp")!
    let redirect = URL(string: "https://app.example/callback")!
    let store = McpMemoryOAuthStateStore()
    try await store.save(McpOAuthState(serverURL: server.absoluteString, oauthState: "current"))
    let options = McpSignInOptions(serverURL: server, redirectURL: redirect, store: store)
    let authorization = McpSignInRedirect(authorizationURL: URL(string: "https://auth.example/authorize")!,
                                        redirectURL: redirect, state: "current")
    do {
        try await McpOAuthSignIn.completeMcpSignIn(options: options, authorization: authorization,
            response: McpAuthorizationResponse(code: "code", state: "other"))
        Issue.record("Accepted another state")
    } catch let error as McpSignInResponseError {
        #expect(error.message == "The authorization response belongs to a different sign-in")
    }
}

@Test("refuses to complete a superseded sign-in from a persisted redirect")
func m3SignInRejectsSupersededState() async throws {
    let server = URL(string: "https://mcp.example/mcp")!
    let redirect = URL(string: "https://app.example/callback")!
    let store = McpMemoryOAuthStateStore()
    try await store.save(McpOAuthState(serverURL: server.absoluteString, oauthState: "new"))
    let old = McpSignInRedirect(authorizationURL: URL(string: "https://auth.example/authorize")!,
                              redirectURL: redirect, state: "old", scope: "read write")
    let authorization = try JSONDecoder().decode(McpSignInRedirect.self, from: JSONEncoder().encode(old))
    #expect(authorization == old)
    do {
        try await McpOAuthSignIn.completeMcpSignIn(
            options: McpSignInOptions(serverURL: server, redirectURL: redirect, store: store),
            authorization: authorization, response: McpAuthorizationResponse(code: "code", state: "old"))
        Issue.record("Accepted a superseded sign-in")
    } catch let error as McpSignInResponseError {
        #expect(error.message == "Another sign-in to this MCP server started since; sign in again")
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor M3SignInHTTP: McpOAuthHTTPClient {
    private(set) var requests = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        return (Data(#"{"access_token":"new","token_type":"Bearer","refresh_token":"rotated","expires_in":3600}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func m3SignInStoredState(server: URL, redirect: URL) -> McpOAuthState {
    McpOAuthState(serverURL: server.absoluteString,
        clientInformation: McpOAuthClientInformation(clientID: "registered", metadata:
            McpOAuthClientMetadata(redirectURIs: [redirect.absoluteString])),
        tokens: McpOAuthTokens(accessToken: "old", tokenType: "Bearer", scope: "read", refreshToken: "refresh"),
        codeVerifier: "pending-verifier", oauthState: "pending-state",
        discovery: McpOAuthDiscoveryState(authorizationServerURL: "https://auth.example",
            authorizationServerMetadata: McpOAuthAuthorizationServerMetadata(issuer: "https://auth.example",
                authorizationEndpoint: "https://auth.example/authorize", tokenEndpoint: "https://auth.example/token")))
}

@Test("refreshes the stored tokens instead of redirecting and keeps pending sign-in state")
func m3SignInRefreshesStoredTokens() async throws {
    let server = URL(string: "https://mcp.example/mcp")!
    let redirect = URL(string: "https://app.example/callback")!
    let store = McpMemoryOAuthStateStore()
    await store.save(m3SignInStoredState(server: server, redirect: redirect))
    let http = M3SignInHTTP()
    let result = try await McpOAuthSignIn.startMcpSignIn(options:
        McpSignInOptions(serverURL: server, redirectURL: redirect, store: store, http: http))
    #expect(result == .authorized)
    let state = await store.load()
    #expect(state?.tokens?.refreshToken == "rotated")
    #expect(state?.oauthState == "pending-state")
    #expect(state?.codeVerifier == "pending-verifier")
    #expect(await http.requests == 1)
}

@Test("gives every browser sign-in a fresh state and requests the granted scope on step-up")
func m3SignInFreshBrowserState() async throws {
    let server = URL(string: "https://mcp.example/mcp")!
    let redirect = URL(string: "https://app.example/callback")!
    let store = McpMemoryOAuthStateStore()
    await store.save(m3SignInStoredState(server: server, redirect: redirect))
    let http = M3SignInHTTP()
    let options = McpSignInOptions(serverURL: server, redirectURL: redirect, store: store,
        challenge: McpOAuthChallenge(scope: "write", error: "insufficient_scope"), scope: "configured", http: http)
    guard case .redirect(let first) = try await McpOAuthSignIn.startMcpSignIn(options: options),
          case .redirect(let second) = try await McpOAuthSignIn.startMcpSignIn(options: options) else {
        Issue.record("Expected browser steps"); return
    }
    #expect(first.state != second.state)
    #expect(first.scope == "configured read write")
    #expect(await http.requests == 0)
}

private enum M3SignInStoreError: Error { case storage }
private actor M3SignInLockedStore: McpOAuthServerStore {
    var state: McpOAuthState
    let busy: Bool
    init(state: McpOAuthState, busy: Bool) { self.state = state; self.busy = busy }
    func load() -> McpOAuthState? { state }
    func save(_ state: McpOAuthState) { self.state = state }
    func withRefreshLock<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        if busy { throw McpRefreshLockBusyError() }
        throw M3SignInStoreError.storage
    }
}

@Test("goes to the browser step only when the refresh lock is busy")
func m3SignInBusyLockBrowserFallback() async throws {
    let server = URL(string: "https://mcp.example/mcp")!
    let redirect = URL(string: "https://app.example/callback")!
    let state = m3SignInStoredState(server: server, redirect: redirect)
    let http = M3SignInHTTP()
    let store = M3SignInLockedStore(state: state, busy: true)
    guard case .redirect = try await McpOAuthSignIn.startMcpSignIn(options:
        McpSignInOptions(serverURL: server, redirectURL: redirect, store: store, http: http)) else {
        Issue.record("Expected a browser step"); return
    }
    #expect(await http.requests == 0)
    let failing = M3SignInLockedStore(state: state, busy: false)
    await #expect(throws: M3SignInStoreError.self) {
        _ = try await McpOAuthSignIn.startMcpSignIn(options:
            McpSignInOptions(serverURL: server, redirectURL: redirect, store: failing, http: http))
    }
}

@Test("pasted redirect responses must use the authorization redirect path")
func m3SignInResponsePath() throws {
    let redirect = URL(string: "https://app.example/callback")!
    #expect(throws: McpOAuthError.self) {
        try McpOAuthSignIn.responseFromRedirectURL(
            URL(string: "https://app.example/other?code=code&state=state")!, redirectURL: redirect)
    }
    let response = try McpOAuthSignIn.responseFromRedirectURL(
        URL(string: "https://app.example/callback?code=code&state=state&iss=https%3A%2F%2Fauth.example")!,
        redirectURL: redirect)
    #expect(response == McpAuthorizationResponse(code: "code", state: "state", iss: "https://auth.example"))
}
