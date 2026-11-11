import Foundation
import PiSwiftMCP
import Testing

@Test("takes a pasted redirect URL while waiting for the callback")
func m3LoopbackTakesPastedRedirect() async throws {
    let redirect = URL(string: "http://127.0.0.1:1234/callback")!
    let presenter = McpPasteRedirectPresenter(callbackURL: redirect,
        openAuthorizationURL: { _ in },
        pasteRedirectURL: { "  http://127.0.0.1:1234/callback?code=pasted&state=state-1  " })
    let result = try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "state-1")
    let response = try McpOAuthSignIn.responseFromRedirectURL(result, redirectURL: redirect)
    #expect(response.code == "pasted")
    #expect(response.state == "state-1")
}

@Test("cancels the wait, and an empty paste cancels too")
func m3LoopbackEmptyPasteCancels() async throws {
    let redirect = URL(string: "http://127.0.0.1:1234/callback")!
    let presenter = McpPasteRedirectPresenter(callbackURL: redirect,
        openAuthorizationURL: { _ in }, pasteRedirectURL: { " \n " })
    await #expect(throws: McpSignInCancelledError.self) {
        try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "state-1")
    }
}

@Test("reads the code, state, and issuer")
func m3LoopbackReadsCodeStateIssuer() throws {
    let redirect = URL(string: "http://127.0.0.1:1234/callback/server-id")!
    let result = try McpOAuthSignIn.responseFromRedirectURL(
        URL(string: "http://127.0.0.1:1234/callback/server-id?code=c&state=state-1&iss=x")!, redirectURL: redirect)
    #expect(result == McpAuthorizationResponse(code: "c", state: "state-1", iss: "x"))
}

@Test("rejects another state, another redirect path, and errors")
func m3LoopbackRejectsWrongPathAndErrors() throws {
    let redirect = URL(string: "http://127.0.0.1:1234/callback/server-id")!
    #expect(throws: McpOAuthError.self) {
        try McpOAuthSignIn.responseFromRedirectURL(
            URL(string: "http://127.0.0.1:1234/callback?code=c&state=state-1")!, redirectURL: redirect)
    }
    #expect(throws: McpOAuthError.self) {
        try McpOAuthSignIn.responseFromRedirectURL(
            URL(string: "http://127.0.0.1:1234/callback/server-id?error=access_denied")!, redirectURL: redirect)
    }
    #expect(throws: McpOAuthError.self) {
        try McpOAuthSignIn.responseFromRedirectURL(URL(string: "code=c")!, redirectURL: redirect)
    }
}
