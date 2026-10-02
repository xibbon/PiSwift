import Foundation
import Testing
@testable import PiSwiftAI

private func a1OAuthBody(_ request: URLRequest) throws -> [String: String] {
    if let body = request.httpBody {
        return try JSONSerialization.jsonObject(with: body) as? [String: String] ?? [:]
    }
    guard let stream = request.httpBodyStream else { return [:] }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        if count <= 0 { break }
        data.append(contentsOf: bytes[..<count])
    }
    return try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
}

@Suite("A1 Anthropic OAuth")
struct A1AnthropicOAuthTests {
    @Test(.timeLimit(.minutes(1))) func offersBrowserFirstAndExchangesTheSelectedCopyCode() async throws {
        try await codexRequestLock.withLock {
            let auth = LockedState<OAuthAuthInfo?>(nil)
            let prompts = LockedState<[OAuthSelectPrompt]>([])
            let requestBodies = LockedState<[[String: String]]>([])
            MockURLProtocol.allowedHosts.withLock { $0 = ["platform.claude.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
                requestBodies.withLock { $0.append((try? a1OAuthBody(request)) ?? [:]) }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"access-token","refresh_token":"refresh-token","expires_in":3600}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in auth.withLock { $0 = info } },
                onPrompt: { prompt in
                    #expect(prompt.message == "Paste the code Anthropic shows after you sign in:")
                    #expect(prompt.placeholder == "code#state")
                    let info = try #require(auth.withLock { $0 })
                    let state = try #require(URLComponents(string: info.url)?.queryItems?.first { $0.name == "state" }?.value)
                    return "copied-code#\(state)"
                },
                onSelect: { prompt in prompts.withLock { $0.append(prompt) }; return "copy_code" }
            )
            let credentials = try await loginAnthropicOAuth(callbacks)
            #expect(credentials.access == "access-token")
            #expect(credentials.refresh == "refresh-token")
            #expect(prompts.withLock { $0 } == [OAuthSelectPrompt(
                message: "Select Anthropic login method:",
                options: [
                    OAuthSelectOption(id: "browser", label: "Browser login (default)"),
                    OAuthSelectOption(id: "copy_code", label: "Copy code login (headless)"),
                ]
            )])
            let info = try #require(auth.withLock { $0 })
            #expect(info.instructions == "Complete login in your browser, then copy the code Anthropic shows and paste it here.")
            let query = URLComponents(string: info.url)?.queryItems ?? []
            #expect(query.first { $0.name == "redirect_uri" }?.value == "https://platform.claude.com/oauth/code/callback")
            let bodies = requestBodies.withLock { $0 }
            #expect(bodies.count == 1)
            #expect(bodies.first?["grant_type"] == "authorization_code")
            #expect(bodies.first?["code"] == "copied-code")
            #expect(bodies.first?["state"] == query.first { $0.name == "state" }?.value)
            #expect(bodies.first?["code_verifier"] == query.first { $0.name == "state" }?.value)
            #expect(bodies.first?["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelsWhenLoginMethodSelectionIsCancelled() async {
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in Issue.record("Must not start login") },
            onPrompt: { _ in Issue.record("Must not prompt for code"); return "" },
            onSelect: { _ in throw OAuthError.cancelled }
        )
        do { _ = try await loginAnthropicOAuth(callbacks); Issue.record("Expected cancellation") }
        catch { #expect(error.localizedDescription == "Login cancelled") }
    }

    @Test(.timeLimit(.minutes(1))) func unknownMethodDoesNotStartLogin() async {
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in Issue.record("Must not start login") },
            onPrompt: { _ in Issue.record("Must not prompt for code"); return "" },
            onSelect: { _ in "unknown" }
        )
        do { _ = try await loginAnthropicOAuth(callbacks); Issue.record("Expected unknown method") }
        catch { #expect(error.localizedDescription == "Unknown Anthropic login method: unknown") }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledSignalIsCheckedAfterMethodSelection() async {
        let signal = CancellationToken()
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in Issue.record("Must not start login") }, onPrompt: { _ in "" },
            signal: signal,
            onSelect: { _ in signal.cancel(); return "copy_code" }
        )
        do { _ = try await loginAnthropicOAuth(callbacks); Issue.record("Expected cancellation") }
        catch { #expect(error.localizedDescription == "Login cancelled") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["", "code#wrong-state"])
    func copyCodeRejectsMissingCodeOrForeignState(input: String) async {
        let callbacks = OAuthLoginCallbacks(onAuth: { _ in }, onPrompt: { _ in input })
        do { _ = try await loginAnthropicCopyCode(callbacks); Issue.record("Expected invalid input") }
        catch { #expect(error.localizedDescription == (input.isEmpty ? "Missing authorization code" : "OAuth state mismatch")) }
    }

    @Test func oauthPagesUseTheTaggedColorLogo() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 800 800\" aria-hidden=\"true\"><path fill=\"#F09082\" d=\"M165.29 165.29H517.36V400H400V282.65H165.29Z\"/><path fill=\"#4D9ABF\" d=\"M165.29 282.65H282.65V400H400V517.36H282.65V634.72H165.29Z\"/><path fill=\"#F1BE58\" d=\"M517.36 400H634.72V634.72H517.36Z\"/></svg>"
        #expect(OAuthPage.success("Signed in.").contains(svg))
        #expect(OAuthPage.error("Failed.").contains(svg))
    }

    #if canImport(Network)
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func defaultAndSelectedBrowserLoginKeepTheLocalRedirect(useSelect: Bool) async throws {
        try await codexRequestLock.withLock {
            let auth = LockedState<OAuthAuthInfo?>(nil)
            let body = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["platform.claude.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                body.withLock { $0 = (try? a1OAuthBody(request)) ?? [:] }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            var callbacks = OAuthLoginCallbacks(
                onAuth: { info in auth.withLock { $0 = info } },
                onPrompt: { _ in
                    let info = try #require(auth.withLock { $0 })
                    let state = try #require(URLComponents(string: info.url)?.queryItems?.first { $0.name == "state" }?.value)
                    return "manual-code#\(state)"
                }
            )
            if useSelect { callbacks.onSelect = { _ in "browser" } }
            let result = try await loginAnthropicOAuth(callbacks, callbackPort: 0)
            #expect(result.access == "access")
            let redirect = try #require(body.withLock { $0["redirect_uri"] })
            #expect(redirect.hasPrefix("http://localhost:"))
            #expect(redirect.hasSuffix("/callback"))
        }
    }
    #endif
}
