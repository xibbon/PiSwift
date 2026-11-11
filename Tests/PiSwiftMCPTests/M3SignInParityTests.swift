import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PiSwiftMCP

private let parityServer = URL(string: "https://auth.example/mcp")!
private let parityRedirect = URL(string: "https://app.example/callback")!
private let parityOther = URL(string: "https://relay.example/callback")!

private func parityState() -> McpOAuthState {
    McpOAuthState(serverURL: parityServer.absoluteString,
        clientInformation: McpOAuthClientInformation(clientID: "client-old", metadata:
            McpOAuthClientMetadata(redirectURIs: [parityRedirect.absoluteString])),
        tokens: McpOAuthTokens(accessToken: "old", tokenType: "Bearer", scope: "read", refreshToken: "refresh"),
        codeVerifier: "verifier", oauthState: "pending",
        discovery: McpOAuthDiscoveryState(authorizationServerURL: "https://auth.example",
            authorizationServerMetadata: McpOAuthAuthorizationServerMetadata(issuer: "https://auth.example",
                authorizationEndpoint: "https://auth.example/authorize", tokenEndpoint: "https://auth.example/token",
                registrationEndpoint: "https://auth.example/register")))
}

private actor ParityHTTP: McpOAuthHTTPClient {
    enum Mode: Sendable { case success, rejectRefresh, stall }
    let mode: Mode
    var requests: [URLRequest] = []
    var entered = false
    init(_ mode: Mode = .success) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        entered = true
        if mode == .stall { try await Task.sleep(for: .seconds(600)) }
        let refresh = String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token")
        let body: Data
        let status: Int
        if request.url?.path == "/register" {
            var value = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            value["client_id"] = "client-new"
            body = try JSONSerialization.data(withJSONObject: value)
            status = 201
        } else if refresh && mode == .rejectRefresh {
            body = Data(#"{"error":"invalid_grant"}"#.utf8)
            status = 400
        } else {
            body = Data(#"{"access_token":"new","token_type":"Bearer","refresh_token":"rotated"}"#.utf8)
            status = 200
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func parityOptions(_ store: any McpOAuthStateStore, _ http: ParityHTTP,
                           redirect: URL = parityRedirect) -> McpSignInOptions {
    McpSignInOptions(serverURL: parityServer, redirectURL: redirect, store: store, http: http)
}
private func parityQuery(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite("M3 sign-in parity", .timeLimit(.minutes(1)))
struct M3SignInParityTests {
    @Test("refuses to complete with another redirect URI than the authorization request")
    func rejectsRedirectDrift() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP()
        let authorization = McpSignInRedirect(authorizationURL: URL(string: "https://auth.example/authorize")!,
                                              redirectURL: parityRedirect, state: "pending")
        await #expect(throws: McpSignInResponseError.self) {
            try await McpOAuthSignIn.completeMcpSignIn(options: parityOptions(store, http, redirect: parityOther),
                authorization: authorization, response: McpAuthorizationResponse(code: "code", state: "pending"))
        }
        #expect(await http.requests.isEmpty)
    }

    @Test("refreshes with the stored client from another redirect URI")
    func refreshesStoredClientOnOtherRoute() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP()
        #expect(try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http, redirect: parityOther)) == .authorized)
        #expect(await store.load()?.clientInformation?.clientID == "client-old")
        let requests = await http.requests
        #expect(requests.count == 1)
        #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("client_id=client-old"))
    }

    @Test("keeps the client for a browser step on its redirect URI")
    func keepsClientOnSameRoute() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP(.rejectRefresh)
        guard case .redirect(let authorization) = try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http)) else {
            Issue.record("Expected a browser step"); return
        }
        #expect(parityQuery(authorization.authorizationURL, "client_id") == "client-old")
        #expect(await http.requests.count == 1)
    }

    @Test("drops the client and its tokens for a browser step on another redirect URI")
    func replacesClientOnOtherRoute() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP(.rejectRefresh)
        guard case .redirect(let authorization) = try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http, redirect: parityOther)) else {
            Issue.record("Expected a browser step"); return
        }
        #expect(parityQuery(authorization.authorizationURL, "client_id") == "client-new")
        let state = await store.load()
        #expect(state?.clientInformation?.metadata?.redirectURIs == [parityOther.absoluteString])
        #expect(state?.tokens == nil)
        #expect(await http.requests.map { $0.url!.path } == ["/token", "/register"])
    }

    @Test("asks for the granted scope plus the challenged one on a step-up, without refreshing")
    func completesStepUpWithCombinedScope() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP()
        var options = parityOptions(store, http)
        options.challenge = McpOAuthChallenge(scope: "write", error: "insufficient_scope")
        guard case .redirect(let authorization) = try await McpOAuthSignIn.startMcpSignIn(options: options) else {
            Issue.record("Expected a browser step"); return
        }
        #expect(authorization.scope == "read write")
        #expect(await http.requests.isEmpty)
        try await McpOAuthSignIn.completeMcpSignIn(options: options, authorization: authorization,
            response: McpAuthorizationResponse(code: "code", state: authorization.state))
        #expect(await store.load()?.tokens?.scope == "read write")
        let requests = await http.requests
        #expect(requests.count == 1)
        #expect(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("grant_type=authorization_code"))
    }

    @Test("fails at once with an aborted signal")
    func cancelledStartDoesNoWork() async throws {
        let store = McpMemoryOAuthStateStore()
        let http = ParityHTTP()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http))
        }
        await #expect(throws: McpSignInCancelledError.self) { try await task.value }
        #expect(await http.requests.isEmpty)
    }

    @Test("cancels a start whose request does not answer")
    func cancelsStartRequest() async throws {
        let store = McpMemoryOAuthStateStore()
        var state = parityState()
        state.tokens = nil; state.clientInformation = nil
        await store.save(state)
        let http = ParityHTTP(.stall)
        let task = Task { try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http)) }
        while !(await http.entered) { await Task.yield() }
        task.cancel()
        await #expect(throws: McpSignInCancelledError.self) { try await task.value }
    }

    @Test("cancels a completion whose token request does not answer")
    func cancelsCompletionRequest() async throws {
        let store = McpMemoryOAuthStateStore()
        await store.save(parityState())
        let http = ParityHTTP(.stall)
        let authorization = McpSignInRedirect(authorizationURL: URL(string: "https://auth.example/authorize")!,
                                              redirectURL: parityRedirect, state: "pending")
        let task = Task { try await McpOAuthSignIn.completeMcpSignIn(options: parityOptions(store, http),
            authorization: authorization, response: McpAuthorizationResponse(code: "code", state: "pending")) }
        while !(await http.entered) { await Task.yield() }
        task.cancel()
        await #expect(throws: McpSignInCancelledError.self) { try await task.value }
    }
}

private actor ParityHeldStore: McpOAuthServerStore {
    var state: McpOAuthState? = parityState()
    var entered = false
    var released = false
    var finished = false
    func load() -> McpOAuthState? { state }
    func save(_ state: McpOAuthState) { self.state = state }
    func release() { released = true }
    func withRefreshLock<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        entered = true
        while !released { await Task.yield() }
        defer { finished = true }
        return try await operation()
    }
}

extension M3SignInParityTests {
    @Test("cancels at once while another process holds the refresh lock, and refreshes nothing")
    func cancelsBeforeLateLockArrives() async throws {
        let store = ParityHeldStore()
        let http = ParityHTTP()
        let task = Task { try await McpOAuthSignIn.startMcpSignIn(options: parityOptions(store, http)) }
        while !(await store.entered) { await Task.yield() }
        task.cancel()
        await #expect(throws: McpSignInCancelledError.self) { try await task.value }
        #expect(await http.requests.isEmpty)
        await store.release()
        while !(await store.finished) { await Task.yield() }
        #expect(await http.requests.isEmpty)
        #expect(await store.load()?.tokens?.accessToken == "old")
        #expect(await store.load()?.oauthState == "pending")
    }
}
