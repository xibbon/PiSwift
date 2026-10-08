import Foundation
import Testing
@testable import PiSwiftAI

private func a5BodyData(_ request: URLRequest) -> Data {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer[..<count])
        }
        data = bytes
    } else {
        data = Data()
    }
    return data
}

private func a5Form(_ request: URLRequest) -> [String: String] {
    let data = a5BodyData(request)
    let form = String(decoding: data, as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(form)")?.queryItems ?? []).compactMap {
        item in item.value.map { (item.name, $0) }
    })
}

@Suite("A5 ChatGPT OAuth", .serialized)
struct A5ChatGPTOAuthTests {
    private let redirect = "http://127.0.0.1:1455/auth/callback"

    @Test(.timeLimit(.minutes(1))) func cancelledChatGPTLoginSettlesWhilePromptWaits() async throws {
        let signal = CancellationToken()
        let promptStarted = AsyncStream<Void>.makeStream()
        let finished = LockedState(false)
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in },
            onPrompt: { _ in
                promptStarted.continuation.yield(())
                try await Task.sleep(for: .seconds(3600))
                return "unused"
            },
            signal: signal,
            getDeviceId: { "12345678-1234-1234-1234-123456789ABC" }
        )
        let task = Task {
            defer { finished.withLock { $0 = true } }
            return try await loginOpenAIChatGPT(callbacks, callbackPort: 0)
        }
        for await _ in promptStarted.stream { break }
        task.cancel()
        for _ in 0..<100 {
            if finished.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished.withLock { $0 })
        // Abort the server after the assertion to release an unfixed login wait.
        signal.cancel()
        promptStarted.continuation.finish()
        do { _ = try await task.value; Issue.record("Expected task cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func credentialCodingPreservesNewFieldsAndReadsLegacyData() throws {
        let credentials = OAuthCredentials(
            refresh: "refresh", access: "access", expires: 1234,
            clientId: "issued", scopes: ["openid", "chatgpt.tokens.use.direct"]
        )
        let encoded = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(OAuthCredentials.self, from: encoded)
        #expect(decoded.clientId == "issued")
        #expect(decoded.scopes == ["openid", "chatgpt.tokens.use.direct"])
        let legacy = try JSONDecoder().decode(OAuthCredentials.self, from: Data(#"{"refresh":"r","access":"a","expires":1234}"#.utf8))
        #expect(legacy.clientId == nil)
        #expect(legacy.scopes == nil)
    }

    @Test func manualPasteRequiresFullTrustedCallbackAndIssuedClient() throws {
        let valid = try chatGPTManualResult("\(redirect)?code=code&state=state&client_id=issued", expectedState: "state", redirectUri: redirect)
        #expect(valid.code == "code")
        #expect(valid.clientId == "issued")
        for (input, expected) in [
            ("code", "Paste the full callback URL from the browser"),
            ("http://127.0.0.1:1456/auth/callback?code=x&state=state&client_id=id", "The pasted callback URL must start with"),
            ("\(redirect)?error=access_denied", "ChatGPT authorization failed: access_denied"),
            ("\(redirect)?state=state&client_id=id", "Missing authorization code"),
            ("\(redirect)?code=x&client_id=id", "Missing OAuth state"),
            ("\(redirect)?code=x&state=wrong&client_id=id", "OAuth state mismatch"),
            ("\(redirect)?code=x&state=state", "OpenAI OAuth registration callback did not contain an issued client ID"),
        ] {
            do { _ = try chatGPTManualResult(input, expectedState: "state", redirectUri: redirect); Issue.record("Expected rejection: \(input)") }
            catch { #expect(error.localizedDescription.contains(expected)) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func deviceIdIsRequiredBeforeAuthorization() async {
        let sawAuth = LockedState(false)
        let callbacks = OAuthLoginCallbacks(onAuth: { _ in sawAuth.withLock { $0 = true } }, onPrompt: { _ in "" })
        do { _ = try await loginOpenAIChatGPT(callbacks, callbackPort: 0); Issue.record("Expected missing device ID") }
        catch { #expect(error.localizedDescription == "Sign in with ChatGPT requires a device ID (UUID) for this installation") }
        #expect(!sawAuth.withLock { $0 })
        let invalid = OAuthLoginCallbacks(onAuth: { _ in sawAuth.withLock { $0 = true } }, onPrompt: { _ in "" }, getDeviceId: { "not-a-uuid" })
        do { _ = try await loginOpenAIChatGPT(invalid, callbackPort: 0); Issue.record("Expected invalid device ID") }
        catch { #expect(error.localizedDescription.contains("requires a device ID")) }
        #expect(!sawAuth.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1))) func dynamicClientManualLoginAndRefresh() async throws {
        try await codexRequestLock.withLock {
            let authorizationURL = LockedState<URL?>(nil)
            let exchange = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let form = a5Form(request)
                if form["grant_type"] == "authorization_code" {
                    exchange.withLock { $0 = form }
                }
                let url = request.url!
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"access_token":"oauth-access","refresh_token":"rotated","expires_in":3600,"id_token":"id","scope":"openid chatgpt.tokens.use.direct"}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let before = nowMs()
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in authorizationURL.withLock { $0 = URL(string: info.url) } },
                onPrompt: { _ in
                    let url = try #require(authorizationURL.withLock { $0 })
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let state = try #require(query.first { $0.name == "state" }?.value)
                    let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                    return "\(redirect)?code=authorization-code&state=\(state)&client_id=oaiapp_issued"
                },
                getDeviceId: { "12345678-1234-1234-1234-123456789ABC" }
            )
            let credential = try await loginOpenAIChatGPT(callbacks, callbackPort: 0)
            let url = try #require(authorizationURL.withLock { $0 })
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func param(_ key: String) -> String? { query.first { $0.name == key }?.value }
            #expect(param("client_id") == "dynamic_agent_client")
            #expect(param("agent_name_hint") == "Pi")
            #expect(param("ext_agent_host_id") == "urn:uuid:12345678-1234-1234-1234-123456789abc")
            #expect(param("scope")?.contains("chatgpt.tokens.use.direct") == true)
            #expect(param("resource") == "https://api.openai.com/v1")
            #expect(param("code_challenge_method") == "S256")
            #expect(exchange.withLock { $0["client_id"] } == "oaiapp_issued")
            #expect(exchange.withLock { $0["resource"] } == "https://api.openai.com/v1")
            #expect(exchange.withLock { $0["redirect_uri"] } == param("redirect_uri"))
            #expect(credential.clientId == "oaiapp_issued")
            #expect(credential.scopes == ["openid", "chatgpt.tokens.use.direct"])
            #expect(credential.expires >= before + 3_400_000)
            let refreshed = try await refreshOpenAIChatGPTToken(credential, signal: nil)
            #expect(refreshed.clientId == "oaiapp_issued")
            #expect(refreshed.refresh == "rotated")
        }
    }

    @Test(.timeLimit(.minutes(1))) func browserCallbackUsesIssuedClientAndShowsSuccessPage() async throws {
        try await codexRequestLock.withLock {
            let callbackTask = LockedState<Task<(Int, String), Never>?>(nil)
            let exchanged = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                exchanged.withLock { $0 = a5Form(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"id_token":"id","scope":"chatgpt.tokens.use.direct"}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in
                    let query = URLComponents(string: info.url)?.queryItems ?? []
                    let redirect = query.first { $0.name == "redirect_uri" }?.value ?? ""
                    let state = query.first { $0.name == "state" }?.value ?? ""
                    let task = Task { () -> (Int, String) in
                        var parts = URLComponents(string: redirect)!
                        parts.queryItems = [
                            URLQueryItem(name: "code", value: "browser-code"),
                            URLQueryItem(name: "state", value: state),
                            URLQueryItem(name: "client_id", value: "issued-browser")
                        ]
                        guard let url = parts.url,
                              let (data, response) = try? await URLSession.shared.data(from: url) else { return (0, "") }
                        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
                    }
                    callbackTask.withLock { $0 = task }
                },
                onPrompt: { _ in try await Task.sleep(for: .seconds(10)); return "" },
                getDeviceId: { "12345678-1234-1234-1234-123456789abc" }
            )
            let credential = try await loginOpenAIChatGPT(callbacks, callbackPort: 0)
            #expect(credential.clientId == "issued-browser")
            #expect(exchanged.withLock { $0["client_id"] } == "issued-browser")
            let task = try #require(callbackTask.withLock { $0 })
            let (status, page) = await task.value
            #expect(status == 200)
            #expect(page.contains("ChatGPT authentication completed. You can close this window."))
        }
    }

    @Test(.timeLimit(.minutes(1))) func missingDirectScopeAndIdTokenAreRejected() async throws {
        try await codexRequestLock.withLock {
            let responseBody = LockedState(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"id_token":"id","scope":"openid"}"#)
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(responseBody.withLock { $0 }.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            // Refresh requires a granted direct scope and a rotated refresh token.
            let credential = OAuthCredentials(refresh: "old", access: "old", expires: 0, clientId: "issued")
            do { _ = try await refreshOpenAIChatGPTToken(credential, signal: nil); Issue.record("Expected missing scope") }
            catch { #expect(error.localizedDescription.contains("did not include chatgpt.tokens.use.direct")) }
            responseBody.withLock { $0 = #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"# }
            let auth = LockedState<URL?>(nil)
            let missingIdCallbacks = OAuthLoginCallbacks(
                onAuth: { info in auth.withLock { $0 = URL(string: info.url) } },
                onPrompt: { _ in
                    let url = try #require(auth.withLock { $0 })
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let state = try #require(query.first { $0.name == "state" }?.value)
                    let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                    return "\(redirect)?code=x&state=\(state)&client_id=issued"
                },
                getDeviceId: { "12345678-1234-1234-1234-123456789abc" }
            )
            do { _ = try await loginOpenAIChatGPT(missingIdCallbacks, callbackPort: 0); Issue.record("Expected missing ID token") }
            catch { #expect(error.localizedDescription.contains("did not contain an ID token")) }
        }
    }
}

#if canImport(Network)
@Suite("A5 Anthropic and Codex OAuth", .serialized)
struct A5OtherOAuthTests {
    @Test(.timeLimit(.minutes(1))) func anthropicBrowserCallbackAndRefreshUsePlatformEndpoint() async throws {
        try await codexRequestLock.withLock {
            let callbackTask = LockedState<Task<(Int, String), Never>?>(nil)
            let redirectUri = LockedState<String?>(nil)
            let captured = LockedState<[[String: String]]>([])
            MockURLProtocol.allowedHosts.withLock { $0 = ["platform.claude.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let data = a5BodyData(request)
                let body = (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
                captured.withLock { $0.append(body) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in
                    let query = URLComponents(string: info.url)?.queryItems ?? []
                    let redirect = query.first { $0.name == "redirect_uri" }?.value ?? ""
                    let state = query.first { $0.name == "state" }?.value ?? ""
                    redirectUri.withLock { $0 = redirect }
                    let task = Task { () -> (Int, String) in
                        var components = URLComponents(string: redirect)!
                        components.queryItems = [URLQueryItem(name: "code", value: "browser-code"), URLQueryItem(name: "state", value: state)]
                        guard let url = components.url,
                              let (data, response) = try? await URLSession.shared.data(from: url) else { return (0, "") }
                        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
                    }
                    callbackTask.withLock { $0 = task }
                },
                onPrompt: { _ in try await Task.sleep(for: .seconds(10)); return "" }
            )
            let credential = try await loginAnthropic(callbacks, callbackPort: 0)
            #expect(credential.access == "access")
            let task = try #require(callbackTask.withLock { $0 })
            let (status, page) = await task.value
            #expect(status == 200)
            #expect(page.contains("Signed in to Anthropic."))
            let exchanged = captured.withLock { $0.first }
            #expect(exchanged?["code"] == "browser-code")
            // pi-mono v1.1.0 checks the effective URI after free-port fallback.
            #expect(exchanged?["redirect_uri"] == redirectUri.withLock { $0 })
            _ = try await refreshAnthropicToken("refresh")
            let refreshed = captured.withLock { $0.last }
            #expect(refreshed?["grant_type"] == "refresh_token")
            #expect(refreshed?["scope"] == nil)
        }
    }

    // pi-mono v1.1.0 (#10571) uses a free callback port before the paste fallback.
    @Test(.timeLimit(.minutes(1))) func anthropicFallsBackToFreePortWhenPreferredPortIsInUse() async throws {
        try await codexRequestLock.withLock {
            let occupied = try await OAuthCallbackServer<String>.start(providerName: "Occupied", port: 53692, path: "/occupied") { _ in "" }
            defer { Task { await occupied.close() } }
            let auth = LockedState<URL?>(nil)
            let callbackTask = LockedState<Task<(Int, String), Never>?>(nil)
            let form = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["platform.claude.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let data = a5BodyData(request)
                let body = (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
                form.withLock { $0 = body }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in auth.withLock { $0 = URL(string: info.url) } },
                onPrompt: { prompt in
                    let url = try #require(auth.withLock { $0 })
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let state = try #require(query.first { $0.name == "state" }?.value)
                    let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                    #expect(prompt.placeholder == redirect)
                    let task = Task { () -> (Int, String) in
                        var components = URLComponents(string: redirect)!
                        components.host = "127.0.0.1"
                        components.queryItems = [URLQueryItem(name: "code", value: "browser-code"), URLQueryItem(name: "state", value: state)]
                        guard let callbackURL = components.url,
                              let (data, response) = try? await URLSession.shared.data(from: callbackURL) else { return (0, "") }
                        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
                    }
                    callbackTask.withLock { $0 = task }
                    try await Task.sleep(for: .seconds(10))
                    return ""
                }
            )
            let credential = try await loginAnthropic(callbacks)
            #expect(credential.access == "access")
            let url = try #require(auth.withLock { $0 })
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
            let components = try #require(URLComponents(string: redirect))
            #expect(components.host == "localhost")
            #expect(components.path == "/callback")
            #expect(components.port != 53692)
            #expect(form.withLock { $0["code"] } == "browser-code")
            #expect(form.withLock { $0["redirect_uri"] } == redirect)
            let task = try #require(callbackTask.withLock { $0 })
            let (status, page) = await task.value
            #expect(status == 200)
            #expect(page.contains("Signed in to Anthropic."))
            let scope = query.first { $0.name == "scope" }?.value ?? ""
            #expect(scope.split(separator: " ").count == 6)
        }
    }

    @Test(.timeLimit(.minutes(1))) func codexProviderErrorRedirectDoesNotWaitForPrompt() async throws {
        let callbackTask = LockedState<Task<Int, Never>?>(nil)
        let callbacks = OAuthLoginCallbacks(
            onAuth: { info in
                let query = URLComponents(string: info.url)?.queryItems ?? []
                let redirect = query.first { $0.name == "redirect_uri" }?.value ?? ""
                let state = query.first { $0.name == "state" }?.value ?? ""
                let task = Task { () -> Int in
                    var parts = URLComponents(string: redirect)!
                    parts.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "error_description", value: "User denied access")]
                    if let url = parts.url, let (_, response) = try? await URLSession.shared.data(from: url) {
                        return (response as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    return 0
                }
                callbackTask.withLock { $0 = task }
            },
            onPrompt: { _ in try await Task.sleep(for: .seconds(10)); return "" }
        )
        do { _ = try await loginOpenAICodex(callbacks, callbackPort: 0); Issue.record("Expected provider error") }
        catch { #expect(error.localizedDescription == "OpenAI authorization failed: User denied access") }
        let task = try #require(callbackTask.withLock { $0 })
        #expect(await task.value == 400)
    }

    @Test(.timeLimit(.minutes(1))) func codexFallsBackToPastedRedirectWhenPortIsInUse() async throws {
        try await codexRequestLock.withLock {
            let occupied = try await OAuthCallbackServer<String>.start(providerName: "Occupied", port: 0, path: "/occupied") { _ in "" }
            defer { Task { await occupied.close() } }
            let port = try #require(URL(string: await occupied.redirectUri())?.port)
            let auth = LockedState<URL?>(nil)
            let exchanged = LockedState<[String: String]>([:])
            let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct"}}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let jwt = "header.\(payload).signature"
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                exchanged.withLock { $0 = a5Form(request) }
                let body = try JSONSerialization.data(withJSONObject: [
                    "access_token": jwt, "refresh_token": "refresh", "expires_in": 3600
                ])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            let callbacks = OAuthLoginCallbacks(
                onAuth: { info in auth.withLock { $0 = URL(string: info.url) } },
                onPrompt: { _ in
                    let url = try #require(auth.withLock { $0 })
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let state = try #require(query.first { $0.name == "state" }?.value)
                    let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                    return "\(redirect)?code=pasted-code&state=\(state)"
                }
            )
            let credential = try await loginOpenAICodex(callbacks, callbackPort: UInt16(port))
            #expect(credential.accountId == "acct")
            #expect(exchanged.withLock { $0["code"] } == "pasted-code")
            #expect(exchanged.withLock { $0["redirect_uri"] } == "http://localhost:\(port)/auth/callback")
        }
    }
}
#endif
