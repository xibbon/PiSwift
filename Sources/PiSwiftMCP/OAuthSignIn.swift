import Foundation

private actor McpOAuthRedirectCapture {
    var url: URL?
    private var active = true
    func save(_ url: URL) { self.url = url }
    func isActive() -> Bool { active }
    func deactivate() { active = false }
}

/// Connects a host presenter to the OAuth flow, including the pasted redirect path.
public enum McpOAuthSignIn {
    @discardableResult
    public static func signIn(
        serverURL: URL, presenter: any McpSignInPresenter,
        clientMetadata: McpOAuthClientMetadata, clientID: String? = nil,
        clientSecret: String? = nil, clientMetadataURL: URL? = nil,
        store: any McpOAuthStateStore = McpMemoryOAuthStateStore(),
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient(),
        scope: String? = nil, resourceMetadataURL: URL? = nil,
        authorizationServerMetadataURL: URL? = nil
    ) async throws -> McpOAuthProvider {
        let stored = try await store.load()
        let state: String
        if stored?.serverURL == serverURL.absoluteString, let existing = stored?.oauthState {
            state = existing
        } else {
            var generator = SystemRandomNumberGenerator()
            state = (0..<32).map { _ in
                String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
            }.joined()
        }
        let redirectURL = try await presenter.redirectURL(for: state)
        let capture = McpOAuthRedirectCapture()
        let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
            clientMetadata: clientMetadata, clientID: clientID, clientSecret: clientSecret,
            clientMetadataURL: clientMetadataURL, initialState: state, store: store,
            onRedirect: { url in
                guard await capture.isActive() else { throw McpOAuthError.authorizationRequired }
                let callback = try await presenter.present(authorizationURL: url, state: state)
                await capture.save(callback)
            })
        do {
            let options = McpOAuthFlowOptions(serverURL: serverURL, scope: scope,
                resourceMetadataURL: resourceMetadataURL, authorizationServerMetadataURL: authorizationServerMetadataURL)
            let result = try await McpOAuthFlow.authorize(provider: provider, options: options, http: http)
            if result == .redirect {
                guard let callback = await capture.url else { throw McpOAuthError.invalidRedirect }
                _ = try await McpOAuthFlow.completeRedirect(provider: provider,
                    callbackURL: callback, options: options, http: http)
            }
            await capture.deactivate()
            await presenter.cancel()
            return provider
        } catch {
            await capture.deactivate()
            await presenter.cancel()
            throw error
        }
    }
}
