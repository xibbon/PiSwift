import Foundation
import Testing
import PiSwiftMCP
@testable import PiSwiftCodingAgent

#if os(macOS)
@Test("The MCP presenter factory accepts a callback timeout greater than 300 seconds")
func mcpPresenterFactoryAcceptsLongCallbackTimeout() async throws {
    let presenter = try makeMcpMacOSSignInPresenter(settings: .init(),
        callbackTimeoutSeconds: 600, openAuthorizationURL: { _ in })
    let redirect = try await presenter.redirectURL(for: "factory-timeout")
    #expect(redirect.port != nil)
    await presenter.cancel()
}

@Test("The MCP presenter factory rejects invalid callback timeouts",
    arguments: [0.0, -1.0, .infinity, -.infinity, .nan])
func mcpPresenterFactoryRejectsInvalidCallbackTimeout(seconds: Double) throws {
    #expect(throws: McpOAuthError.self) {
        _ = try makeMcpMacOSSignInPresenter(settings: .init(),
            callbackTimeoutSeconds: seconds, openAuthorizationURL: { _ in })
    }
}
#endif
