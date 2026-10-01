import Foundation

/// Supplies an access token to the streamable HTTP transport and handles an auth challenge.
public protocol McpAuthProvider: Sendable {
    func token() async throws -> String?
    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws
}
