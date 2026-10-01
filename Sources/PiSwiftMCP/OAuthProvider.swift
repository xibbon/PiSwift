import Foundation

public struct McpOAuthState: Codable, Sendable, Equatable {
    public var serverURL: String
    public var clientInformation: McpOAuthClientInformation?
    public var tokens: McpOAuthTokens?
    public var tokensExpireAt: Date?
    public var codeVerifier: String?
    public var oauthState: String?
    public var discovery: McpOAuthDiscoveryState?

    public init(serverURL: String, clientInformation: McpOAuthClientInformation? = nil,
                tokens: McpOAuthTokens? = nil, tokensExpireAt: Date? = nil,
                codeVerifier: String? = nil, oauthState: String? = nil,
                discovery: McpOAuthDiscoveryState? = nil) {
        self.serverURL = serverURL
        self.clientInformation = clientInformation
        self.tokens = tokens
        self.tokensExpireAt = tokensExpireAt
        self.codeVerifier = codeVerifier
        self.oauthState = oauthState
        self.discovery = discovery
    }
}

public protocol McpOAuthStateStore: Sendable {
    func load() async throws -> McpOAuthState?
    func save(_ state: McpOAuthState) async throws
}

public actor McpMemoryOAuthStateStore: McpOAuthStateStore {
    private var value: McpOAuthState?

    public init() {}
    public func load() -> McpOAuthState? { value }
    public func save(_ state: McpOAuthState) { value = state }
}

/// Holds OAuth state for one exact MCP server URL.
public actor McpOAuthProvider: McpOAuthClientProvider {
    public nonisolated let redirectURL: URL
    public nonisolated let clientMetadata: McpOAuthClientMetadata
    public nonisolated let clientMetadataURL: URL?

    private let serverURL: URL
    private let configuredClient: McpOAuthClientInformation?
    private let initialState: String?
    private let store: any McpOAuthStateStore
    private let onRedirect: @Sendable (URL) async throws -> Void

    public init(
        serverURL: URL, redirectURL: URL, clientMetadata: McpOAuthClientMetadata,
        clientID: String? = nil, clientSecret: String? = nil,
        clientMetadataURL: URL? = nil, initialState: String? = nil,
        store: any McpOAuthStateStore = McpMemoryOAuthStateStore(),
        onRedirect: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.serverURL = serverURL
        self.redirectURL = redirectURL
        self.clientMetadataURL = clientMetadataURL
        self.initialState = initialState
        var metadata = clientMetadata
        if metadata.redirectURIs.isEmpty { metadata.redirectURIs = [redirectURL.absoluteString] }
        if metadata.grantTypes == nil { metadata.grantTypes = ["authorization_code", "refresh_token"] }
        if metadata.responseTypes == nil { metadata.responseTypes = ["code"] }
        if metadata.tokenEndpointAuthMethod == nil {
            metadata.tokenEndpointAuthMethod = clientSecret == nil ? "none" : "client_secret_post"
        }
        self.clientMetadata = metadata
        self.configuredClient = clientID.map {
            McpOAuthClientInformation(clientID: $0, clientSecret: clientSecret, metadata: metadata)
        }
        self.store = store
        self.onRedirect = onRedirect
    }

    public func state() async throws -> String? {
        var value = try await ownState()
        if let existing = value.oauthState { return existing }
        var generator = SystemRandomNumberGenerator()
        let random = initialState ?? (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        value.oauthState = random
        try await store.save(value)
        return random
    }

    public func clientInformation() async throws -> McpOAuthClientInformation? {
        if let configuredClient { return configuredClient }
        return try await ownState().clientInformation
    }

    public func saveClientInformation(_ information: McpOAuthClientInformation) async throws {
        if configuredClient != nil { return }
        var value = try await ownState()
        value.clientInformation = information
        try await store.save(value)
    }

    public func tokens() async throws -> McpOAuthTokens? { try await ownState().tokens }

    public func saveTokens(_ tokens: McpOAuthTokens) async throws {
        var value = try await ownState()
        value.tokens = tokens
        value.tokensExpireAt = tokens.expiresIn.map { Date().addingTimeInterval($0) }
        try await store.save(value)
    }

    public func redirectToAuthorization(_ url: URL) async throws { try await onRedirect(url) }

    public func saveCodeVerifier(_ verifier: String) async throws {
        var value = try await ownState()
        value.codeVerifier = verifier
        try await store.save(value)
    }

    public func codeVerifier() async throws -> String {
        guard let verifier = try await ownState().codeVerifier, !verifier.isEmpty else {
            throw McpOAuthError.missingCodeVerifier
        }
        return verifier
    }

    public func invalidateCredentials(_ kind: McpOAuthCredentialKind) async throws {
        var value = try await ownState()
        if kind == .all || kind == .client { value.clientInformation = nil }
        if kind == .all || kind == .tokens { value.tokens = nil; value.tokensExpireAt = nil }
        if kind == .all || kind == .verifier { value.codeVerifier = nil }
        if kind == .all || kind == .discovery { value.discovery = nil }
        if kind == .all { value.oauthState = nil }
        try await store.save(value)
    }

    public func saveDiscoveryState(_ state: McpOAuthDiscoveryState) async throws {
        var value = try await ownState()
        value.discovery = state
        try await store.save(value)
    }

    public func discoveryState() async throws -> McpOAuthDiscoveryState? { try await ownState().discovery }

    private func ownState() async throws -> McpOAuthState {
        if let value = try await store.load(), value.serverURL == serverURL.absoluteString { return value }
        return McpOAuthState(serverURL: serverURL.absoluteString)
    }
}
