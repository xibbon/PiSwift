import Foundation
import Testing
@testable import PiSwiftAI

private func a2OAuthBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[..<count])
    }
    return data
}

private func a2OAuthForm(_ request: URLRequest) -> [String: String] {
    let form = String(decoding: a2OAuthBodyData(request), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(form)")?.queryItems ?? []).compactMap {
        item in item.value.map { (item.name, $0) }
    })
}

#if canImport(Network)
@Suite("A2 OAuth v1.1.0", .serialized)
struct A2OAuthV110Tests {
    @Test(.timeLimit(.minutes(1))) func chatGPTUsesTheAppNameAndKeepsTheDefault() async throws {
        try await codexRequestLock.withLock {
            let auth = LockedState<String?>(nil)
            let exchanged = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                exchanged.withLock { $0 = a2OAuthForm(request) }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"id_token":"id","scope":"openid chatgpt.tokens.use.direct"}"#.utf8))
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            for agentName in [nil, "my-app"] as [String?] {
                let callbacks = OAuthLoginCallbacks(
                    onAuth: { info in auth.withLock { $0 = info.url } },
                    onPrompt: { _ in
                        let url = try #require(auth.withLock { $0 })
                        let query = URLComponents(string: url)?.queryItems ?? []
                        let state = try #require(query.first { $0.name == "state" }?.value)
                        let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                        return "\(redirect)?code=authorization-code&state=\(state)&client_id=oaiapp_issued"
                    },
                    getDeviceId: { "12345678-1234-1234-1234-123456789abc" },
                    agentName: agentName
                )
                let credentials = try await loginOpenAIChatGPT(callbacks, callbackPort: 0)
                let url = try #require(auth.withLock { $0 })
                let query = URLComponents(string: url)?.queryItems ?? []
                #expect(query.first { $0.name == "agent_name_hint" }?.value == (agentName ?? "Pi"))
                #expect(credentials.clientId == "oaiapp_issued")
                #expect(exchanged.withLock { $0["client_id"] } == "oaiapp_issued")
                #expect(exchanged.withLock { $0["redirect_uri"] } == query.first { $0.name == "redirect_uri" }?.value)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func codexUsesTheAppNameAndKeepsTheDefault() async throws {
        try await codexRequestLock.withLock {
            let auth = LockedState<String?>(nil)
            let exchanged = LockedState<[String: String]>([:])
            let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct"}}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let token = "header.\(payload).signature"
            MockURLProtocol.allowedHosts.withLock { $0 = ["auth.openai.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                exchanged.withLock { $0 = a2OAuthForm(request) }
                let body = try JSONSerialization.data(withJSONObject: [
                    "access_token": token, "refresh_token": "refresh", "expires_in": 3600
                ])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            } }
            URLProtocol.registerClass(MockURLProtocol.self)
            defer {
                URLProtocol.unregisterClass(MockURLProtocol.self)
                MockURLProtocol.allowedHosts.withLock { $0 = [] }
                MockURLProtocol.requestHandler.withLock { $0 = nil }
            }
            for agentName in [nil, "my-app"] as [String?] {
                let callbacks = OAuthLoginCallbacks(
                    onAuth: { info in auth.withLock { $0 = info.url } },
                    onPrompt: { _ in
                        let url = try #require(auth.withLock { $0 })
                        let query = URLComponents(string: url)?.queryItems ?? []
                        let state = try #require(query.first { $0.name == "state" }?.value)
                        let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                        return "\(redirect)?code=pasted-code&state=\(state)"
                    },
                    agentName: agentName
                )
                let credentials = try await loginOpenAICodex(callbacks, callbackPort: 0)
                let url = try #require(auth.withLock { $0 })
                let query = URLComponents(string: url)?.queryItems ?? []
                #expect(query.first { $0.name == "originator" }?.value == (agentName ?? "pi"))
                #expect(credentials.accountId == "acct")
                #expect(exchanged.withLock { $0["code"] } == "pasted-code")
                #expect(exchanged.withLock { $0["redirect_uri"] } == query.first { $0.name == "redirect_uri" }?.value)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func anthropicUsesTheFreePreferredPortForBrowserLogin() async throws {
        try await codexRequestLock.withLock {
            let auth = LockedState<String?>(nil)
            let callbackTask = LockedState<Task<(Int, String), Never>?>(nil)
            let exchanged = LockedState<[String: String]>([:])
            MockURLProtocol.allowedHosts.withLock { $0 = ["platform.claude.com"] }
            MockURLProtocol.requestHandler.withLock { $0 = { request in
                let body = (try JSONSerialization.jsonObject(with: a2OAuthBodyData(request)) as? [String: String]) ?? [:]
                exchanged.withLock { $0 = body }
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
                onAuth: { info in auth.withLock { $0 = info.url } },
                onPrompt: { prompt in
                    let url = try #require(auth.withLock { $0 })
                    let query = URLComponents(string: url)?.queryItems ?? []
                    let redirect = try #require(query.first { $0.name == "redirect_uri" }?.value)
                    let state = try #require(query.first { $0.name == "state" }?.value)
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
            // Keep fixed-port coverage. Port 0 alone cannot detect fixed bind errors.
            let credentials = try await loginAnthropic(callbacks)
            let url = try #require(auth.withLock { $0 })
            let redirect = URLComponents(string: url)?.queryItems?.first { $0.name == "redirect_uri" }?.value
            #expect(redirect == "http://localhost:53692/callback")
            #expect(exchanged.withLock { $0["redirect_uri"] } == redirect)
            #expect(exchanged.withLock { $0["code"] } == "browser-code")
            #expect(credentials.access == "access")
            let task = try #require(callbackTask.withLock { $0 })
            let (status, page) = await task.value
            #expect(status == 200)
            #expect(page.contains("Signed in to Anthropic."))
        }
    }
}
#endif
