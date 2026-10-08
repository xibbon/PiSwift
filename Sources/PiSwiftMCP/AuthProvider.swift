import Foundation

/// Supplies an access token to the streamable HTTP transport and handles an auth challenge.
public protocol McpAuthProvider: Sendable {
    /// Returns the token for the next request. This can refresh the token over the network.
    /// Session close uses the token from the last request and does not call this method.
    func token() async throws -> String?
    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws
}
