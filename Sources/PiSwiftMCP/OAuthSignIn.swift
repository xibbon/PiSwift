import Foundation
import PiSwiftAI

private actor McpOAuthRedirectCapture {
    var url: URL?
    func save(_ url: URL) { self.url = url }
}

/// Connects a host presenter to the OAuth flow, including the pasted redirect path.
public enum McpOAuthSignIn {
    /// The document hook receives the presenter's redirect URL.
    /// The host must ensure that its document lists this URI; the library cannot verify it.
    @discardableResult
    public static func signIn(
        serverURL: URL, presenter: any McpSignInPresenter,
        clientMetadata: McpOAuthClientMetadata, clientID: String? = nil,
        clientSecret: String? = nil,
        clientMetadataDocument: (@Sendable (McpOAuthAuthorizationServerMetadata?, URL) throws -> McpOAuthClientMetadataDocument?)? = nil,
        store: any McpOAuthStateStore = McpMemoryOAuthStateStore(),
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient(),
        scope: String? = nil, resourceMetadataURL: URL? = nil,
        authorizationServerMetadataURL: URL? = nil
    ) async throws -> McpOAuthProvider {
        var generator = SystemRandomNumberGenerator()
        let state = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        do {
            let redirectURL = try await presenter.redirectURL(for: state)
            let document: McpOAuthClientMetadataDocumentProvider?
            if let hook = clientMetadataDocument {
                document = { metadata in try hook(metadata, redirectURL) }
            } else { document = nil }
            let options = McpSignInOptions(serverURL: serverURL, redirectURL: redirectURL, initialState: state,
                store: store, clientMetadata: clientMetadata, clientID: clientID, clientSecret: clientSecret,
                clientMetadataDocument: document, challenge: McpOAuthChallenge(resourceMetadataURL: resourceMetadataURL), scope: scope,
                authorizationServerMetadataURL: authorizationServerMetadataURL, http: http)
            switch try await startMcpSignIn(options: options) {
            case .authorized: break
            case .redirect(let authorization):
                let url = try await presenter.present(authorizationURL: authorization.authorizationURL,
                                                      state: authorization.state)
                let response = try responseFromRedirectURL(url, redirectURL: authorization.redirectURL)
                try await completeMcpSignIn(options: options, authorization: authorization, response: response)
            }
            await presenter.cancel()
            return makeProvider(options)
        } catch {
            await presenter.cancel()
            throw error
        }
    }
}

/// Options shared by both parts of a sign-in. Keep the store and redirect URI the same.
public struct McpSignInOptions: Sendable {
    public var replaceRegisteredClientForDocument: Bool
    public var initialState: String?
    public var serverURL: URL
    public var redirectURL: URL
    public var store: any McpOAuthStateStore
    public var clientMetadata: McpOAuthClientMetadata
    public var clientID: String?
    public var clientSecret: String?
    public var clientMetadataDocument: McpOAuthClientMetadataDocumentProvider?
    public var challenge: McpOAuthChallenge?
    public var scope: String?
    public var authorizationServerMetadataURL: URL?
    public var http: any McpOAuthHTTPClient

    public init(serverURL: URL, redirectURL: URL, initialState: String? = nil,
                replaceRegisteredClientForDocument: Bool = false,
                store: any McpOAuthStateStore = McpMemoryOAuthStateStore(),
                clientMetadata: McpOAuthClientMetadata = McpOAuthClientMetadata(),
                clientID: String? = nil, clientSecret: String? = nil,
                clientMetadataDocument: McpOAuthClientMetadataDocumentProvider? = nil,
                challenge: McpOAuthChallenge? = nil, scope: String? = nil,
                authorizationServerMetadataURL: URL? = nil,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.replaceRegisteredClientForDocument = replaceRegisteredClientForDocument
        self.initialState = initialState
        self.serverURL = serverURL; self.redirectURL = redirectURL; self.store = store
        self.clientMetadata = clientMetadata; self.clientID = clientID; self.clientSecret = clientSecret
        self.clientMetadataDocument = clientMetadataDocument; self.challenge = challenge; self.scope = scope
        self.authorizationServerMetadataURL = authorizationServerMetadataURL; self.http = http
    }
}

public struct McpSignInRedirect: Codable, Sendable, Equatable {
    public let kind: String
    public var authorizationURL: URL
    public var redirectURL: URL
    public var state: String
    public var scope: String?
    public init(authorizationURL: URL, redirectURL: URL, state: String, scope: String? = nil) {
        self.kind = "redirect"
        self.authorizationURL = authorizationURL; self.redirectURL = redirectURL
        self.state = state; self.scope = scope
    }
}

public enum McpSignInStart: Sendable, Equatable {
    case authorized
    case redirect(McpSignInRedirect)
}

public struct McpAuthorizationResponse: Codable, Sendable, Equatable {
    public var code: String
    public var state: String
    public var iss: String?
    public init(code: String, state: String, iss: String? = nil) {
        self.code = code; self.state = state; self.iss = iss
    }
}

public struct McpSignInCancelledError: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Sign-in cancelled" }
}

public struct McpSignInResponseError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

public extension McpOAuthSignIn {
    static func responseFromRedirectURL(_ url: URL, redirectURL: URL) throws -> McpAuthorizationResponse {
        guard url.scheme == redirectURL.scheme, url.host == redirectURL.host,
              url.port == redirectURL.port, url.path == redirectURL.path else { throw McpOAuthError.invalidRedirect }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        func value(_ name: String) -> String? { items?.first { $0.name == name }?.value }
        if let error = value("error") {
            throw McpOAuthError.authorization(code: error, message: value("error_description") ?? error,
                                             uri: value("error_uri"))
        }
        guard let code = value("code"), !code.isEmpty, let state = value("state") else {
            throw McpOAuthError.invalidRedirect
        }
        return McpAuthorizationResponse(code: code, state: state, iss: value("iss"))
    }

    static func startMcpSignIn(options: McpSignInOptions) async throws -> McpSignInStart {
        do {
            try Task.checkCancellation()
            let stepUp = options.challenge?.error == "insufficient_scope"
            if !stepUp {
                let cancellation = McpSignInCancellation()
                let refresh: @Sendable () async throws -> McpOAuthFlowResult = {
                    if cancellation.isCancelled { return .redirect }
                    guard let state = try await options.store.load(),
                          state.serverURL == options.serverURL.absoluteString,
                          state.tokens?.refreshToken != nil else { return .redirect }
                    if options.replaceRegisteredClientForDocument, options.clientID == nil,
                       state.clientInformation != nil { return .redirect }
                    let provider = makeProvider(options)
                    var flow = flowOptions(options)
                    flow.refreshOnly = true
                    return try await McpOAuthFlow.authorize(provider: provider, options: flow, http: options.http)
                }
                do {
                    let result: McpOAuthFlowResult
                    if let locked = options.store as? any McpOAuthServerStore {
                        result = try await withTaskCancellationHandler {
                            try await waitForSignInRefresh {
                                try await locked.withRefreshLock {
                                    if cancellation.isCancelled { return .redirect }
                                    return try await refresh()
                                }
                            }
                        } onCancel: { cancellation.cancel() }
                    } else {
                        result = try await withTaskCancellationHandler {
                            try await waitForSignInRefresh(refresh)
                        } onCancel: { cancellation.cancel() }
                    }
                    if result == .authorized { return .authorized }
                } catch is McpRefreshLockBusyError { }
            }
            try Task.checkCancellation()
            let stored = try await options.store.load()
            if var state = stored, state.serverURL == options.serverURL.absoluteString {
                state.oauthState = nil
                if options.clientID == nil,
                   (options.replaceRegisteredClientForDocument ||
                    state.clientInformation?.metadata?.redirectURIs.contains(options.redirectURL.absoluteString) != true) {
                    state.clientInformation = nil; state.tokens = nil; state.tokensExpireAt = nil
                }
                try await options.store.save(state)
            }
            let capture = McpOAuthRedirectCapture()
            let provider = makeProvider(options, onRedirect: { await capture.save($0) })
            var flow = flowOptions(options)
            flow.skipRefresh = true
            flow.scope = mergeSignInScopes(options.scope, stepUp
                ? McpOAuthFlow.stepUpScope(granted: stored?.tokens?.scope, challenged: options.challenge?.scope)
                : options.challenge?.scope)
            _ = try await McpOAuthFlow.authorize(provider: provider, options: flow, http: options.http)
            guard let url = await capture.url, let state = try await provider.state() else {
                throw McpSignInResponseError(message: "OAuth flow did not produce an authorization URL")
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            return .redirect(McpSignInRedirect(authorizationURL: url,
                redirectURL: items?.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:)) ?? options.redirectURL,
                state: state, scope: items?.first { $0.name == "scope" }?.value))
        } catch {
            if Task.isCancelled || error is CancellationError { throw McpSignInCancelledError() }
            throw error
        }
    }

    static func completeMcpSignIn(options: McpSignInOptions, authorization: McpSignInRedirect,
                                  response: McpAuthorizationResponse) async throws {
        do {
            try Task.checkCancellation()
            guard response.state == authorization.state else {
                throw McpSignInResponseError(message: "The authorization response belongs to a different sign-in")
            }
            let stored = try await options.store.load()
            guard stored?.serverURL == options.serverURL.absoluteString,
                  stored?.oauthState == authorization.state else {
                throw McpSignInResponseError(message: "Another sign-in to this MCP server started since; sign in again")
            }
            var flow = flowOptions(options)
            flow.scope = authorization.scope; flow.authorizationCode = response.code; flow.iss = response.iss
            flow.authorizationRedirectURL = authorization.redirectURL
            _ = try await McpOAuthFlow.authorize(provider: makeProvider(options), options: flow, http: options.http)
        } catch {
            if Task.isCancelled || error is CancellationError { throw McpSignInCancelledError() }
            throw error
        }
    }

    private static func makeProvider(_ options: McpSignInOptions,
        onRedirect: @escaping @Sendable (URL) async throws -> Void = { _ in }) -> McpOAuthProvider {
        McpOAuthProvider(serverURL: options.serverURL, redirectURL: options.redirectURL,
            clientMetadata: options.clientMetadata, clientID: options.clientID, clientSecret: options.clientSecret,
            clientMetadataDocument: options.clientMetadataDocument, initialState: options.initialState, store: options.store, onRedirect: onRedirect)
    }

    private static func flowOptions(_ options: McpSignInOptions) -> McpOAuthFlowOptions {
        McpOAuthFlowOptions(serverURL: options.serverURL, scope: options.scope,
            resourceMetadataURL: options.challenge?.resourceMetadataURL,
            authorizationServerMetadataURL: options.authorizationServerMetadataURL)
    }
}

private func mergeSignInScopes(_ scopes: String?...) -> String? {
    var seen = Set<String>()
    let result = scopes.compactMap { $0 }.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        .filter { seen.insert($0).inserted }.joined(separator: " ")
    return result.isEmpty ? nil : result
}

private final class McpSignInCancellation: Sendable {
    private let cancelled = LockedState(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

private struct McpSignInWaiterState: Sendable {
    var continuation: CheckedContinuation<McpOAuthFlowResult, any Error>?
    var result: Result<McpOAuthFlowResult, any Error>?
}

private final class McpSignInRefreshWaiter: Sendable {
    private let state = LockedState(McpSignInWaiterState())
    func install(_ continuation: CheckedContinuation<McpOAuthFlowResult, any Error>) {
        let ready: Result<McpOAuthFlowResult, any Error>? = state.withLock { value in
            if let result = value.result { return result }
            value.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }
    func finish(_ result: Result<McpOAuthFlowResult, any Error>) {
        let pending = state.withLock { value in
            guard value.result == nil else { return nil as CheckedContinuation<McpOAuthFlowResult, any Error>? }
            value.result = result
            let pending = value.continuation; value.continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

private func waitForSignInRefresh(
    _ operation: @escaping @Sendable () async throws -> McpOAuthFlowResult
) async throws -> McpOAuthFlowResult {
    let waiter = McpSignInRefreshWaiter()
    Task.detached {
        do { waiter.finish(.success(try await operation())) }
        catch { waiter.finish(.failure(error)) }
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { waiter.install($0) }
    } onCancel: { waiter.finish(.failure(McpSignInCancelledError())) }
}
