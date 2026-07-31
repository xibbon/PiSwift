import Foundation

// MARK: - OAuth Token Types

public struct OAuthTokens: Sendable {
    public var accessToken: String
    public var tokenType: String
    public var refreshToken: String?
    public var expiresIn: Int?

    public init(accessToken: String, tokenType: String = "bearer", refreshToken: String? = nil, expiresIn: Int? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

// MARK: - Host Authorization

/// Supplies an HTTP Authorization header for OAuth-protected MCP servers.
/// The host owns sign-in, refresh, and secure credential storage. Returning
/// `nil` rejects the connection without reading from an ambient token store.
public protocol McpAuthorizationProvider: Sendable {
    func authorizationHeader(
        for serverName: String,
        configuration: ServerEntry
    ) async -> String?
}

/// Optional capability for hosts that keep OAuth credentials. The adapter
/// never deletes credentials itself; `/mcp logout` and native hosts call this
/// only when the host explicitly supplies a mutable provider.
public protocol McpMutableAuthorizationProvider: McpAuthorizationProvider {
    func clearAuthorization(
        for serverName: String,
        configuration: ServerEntry
    ) async
}
