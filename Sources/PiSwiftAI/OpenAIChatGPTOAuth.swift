import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

private let chatGPTResource = "https://api.openai.com/v1"
private let chatGPTScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
private let chatGPTDirectScope = "chatgpt.tokens.use.direct"
private let chatGPTTokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!

struct ChatGPTAuthorizationResult: Sendable {
    let code: String
    let clientId: String
}

private func chatGPTRandomValue() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    var rng = SystemRandomNumberGenerator()
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func chatGPTAuthorizationResult(_ components: URLComponents, expectedState: String) throws -> ChatGPTAuthorizationResult {
    let value: (String) -> String? = { name in components.queryItems?.first { $0.name == name }?.value }
    guard let code = value("code"), !code.isEmpty else {
        throw OAuthCallbackFailure(message: "Missing authorization code")
    }
    guard let state = value("state"), !state.isEmpty else {
        throw OAuthCallbackFailure(message: "Missing OAuth state")
    }
    guard state == expectedState else { throw OAuthCallbackFailure(message: "OAuth state mismatch") }
    guard let clientId = value("client_id")?.trimmingCharacters(in: .whitespacesAndNewlines), !clientId.isEmpty else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth registration callback did not contain an issued client ID")
    }
    return ChatGPTAuthorizationResult(code: code, clientId: clientId)
}

func chatGPTManualResult(_ input: String, expectedState: String, redirectUri: String) throws -> ChatGPTAuthorizationResult {
    guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let expected = URL(string: redirectUri),
          url.scheme != nil, url.host != nil else {
        throw OAuthCallbackFailure(message: "Paste the full callback URL from the browser")
    }
    guard url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port,
          url.path == expected.path else {
        throw OAuthCallbackFailure(message: "The pasted callback URL must start with \(redirectUri)")
    }
    if let error = components.queryItems?.first(where: { $0.name == "error" })?.value, !error.isEmpty {
        throw OAuthCallbackFailure(message: "ChatGPT authorization failed: \(error)")
    }
    return try chatGPTAuthorizationResult(components, expectedState: expectedState)
}

#if canImport(Network)
/// ChatGPT parses pasted URLs before racing them with the browser callback.
/// This differs from the shared helper, which hands off raw pasted input.
private func waitForChatGPTAuthorization(
    callbacks: OAuthLoginCallbacks, callback: OAuthCallbackServer<ChatGPTAuthorizationResult>?,
    state: String, redirectUri: String
) async throws -> ChatGPTAuthorizationResult {
    try Task.checkCancellation()
    let prompt = OAuthPrompt(
        message: "Complete login in your browser, or paste the final redirect URL here:",
        placeholder: redirectUri
    )
    guard let callback else {
        let input = try await callbacks.onPrompt(prompt)
        return try chatGPTManualResult(input, expectedState: state, redirectUri: redirectUri)
    }
    let race = OAuthCallbackRace<ChatGPTAuthorizationResult>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.add(Task {
                do {
                    try Task.checkCancellation()
                    let input = try await callbacks.onPrompt(prompt)
                    race.finish(.success(try chatGPTManualResult(input, expectedState: state, redirectUri: redirectUri)))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.add(Task {
                do {
                    if let authorization = try await callback.wait() {
                        race.finish(.success(authorization))
                    }
                } catch {
                    race.finish(.failure(error))
                }
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}
#endif

private func chatGPTDeviceHostId(_ deviceId: String?) throws -> String {
    let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    guard let deviceId, deviceId.range(of: pattern, options: .regularExpression) != nil else {
        throw OAuthCallbackFailure(message: "Sign in with ChatGPT requires a device ID (UUID) for this installation")
    }
    return "urn:uuid:\(deviceId.lowercased())"
}

private func chatGPTTokenRequest(
    _ fields: [String: String], signal: CancellationToken?, tokenURL: URL
) async throws -> [String: Any] {
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
    let response = try await oauthData(for: request, signal: signal)
    let body = String(data: response.data, encoding: .utf8) ?? ""
    guard (200..<300).contains(response.status) else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth token request failed (\(response.status)): \(body)")
    }
    guard let token = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth token response must be an object")
    }
    return token
}

private func chatGPTTokenString(_ token: [String: Any], field: String) throws -> String {
    guard let value = token[field] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth token response has invalid \(field)")
    }
    return value
}

private func chatGPTCredential(_ token: [String: Any], clientId: String) throws -> OAuthCredentials {
    let access = try chatGPTTokenString(token, field: "access_token")
    let refresh = try chatGPTTokenString(token, field: "refresh_token")
    let scope = try chatGPTTokenString(token, field: "scope")
    guard let expiresIn = token["expires_in"] as? Double, expiresIn.isFinite, expiresIn > 0 else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth token response has invalid expires_in")
    }
    let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
    guard scopes.contains(chatGPTDirectScope) else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth grant did not include \(chatGPTDirectScope)")
    }
    return OAuthCredentials(
        refresh: refresh, access: access, expires: nowMs() + expiresIn * 1000 - 180_000,
        clientId: clientId, scopes: scopes
    )
}

private func exchangeChatGPTCode(
    _ authorization: ChatGPTAuthorizationResult, verifier: String, redirectUri: String,
    signal: CancellationToken?, tokenURL: URL
) async throws -> OAuthCredentials {
    let token = try await chatGPTTokenRequest([
        "grant_type": "authorization_code", "client_id": authorization.clientId,
        "code": authorization.code, "code_verifier": verifier,
        "redirect_uri": redirectUri, "resource": chatGPTResource
    ], signal: signal, tokenURL: tokenURL)
    guard let idToken = token["id_token"] as? String,
          !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OAuthCallbackFailure(message: "OpenAI OAuth token response did not contain an ID token")
    }
    return try chatGPTCredential(token, clientId: authorization.clientId)
}

public func refreshOpenAIChatGPTToken(
    _ credential: OAuthCredentials, signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    try await refreshOpenAIChatGPTToken(credential, signal: signal, tokenURL: chatGPTTokenURL)
}

func refreshOpenAIChatGPTToken(
    _ credential: OAuthCredentials, signal: CancellationToken?, tokenURL: URL
) async throws -> OAuthCredentials {
    guard let clientId = credential.clientId, !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OAuthCallbackFailure(message: "Stored OpenAI OAuth credential does not contain an issued client ID; reconnect ChatGPT")
    }
    let token = try await chatGPTTokenRequest([
        "grant_type": "refresh_token", "client_id": clientId,
        "refresh_token": credential.refresh, "resource": chatGPTResource
    ], signal: signal, tokenURL: tokenURL)
    return try chatGPTCredential(token, clientId: clientId)
}

public func loginOpenAIChatGPT(
    _ callbacks: OAuthLoginCallbacks, callbackPort: UInt16 = 1455
) async throws -> OAuthCredentials {
    try await loginOpenAIChatGPT(callbacks, callbackPort: callbackPort, tokenURL: chatGPTTokenURL)
}

func loginOpenAIChatGPT(
    _ callbacks: OAuthLoginCallbacks, callbackPort: UInt16, tokenURL: URL
) async throws -> OAuthCredentials {
    let hostId = try chatGPTDeviceHostId(callbacks.getDeviceId?())
    #if canImport(CryptoKit)
    let verifier = chatGPTRandomValue()
    let digest = SHA256.hash(data: Data(verifier.utf8))
    let challenge = Data(digest).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #else
    throw OAuthError.unsupportedPlatform("CryptoKit SHA256 not available")
    #endif
    let state = chatGPTRandomValue()
    let nonce = chatGPTRandomValue()
    let fallbackRedirectUri = "http://127.0.0.1:\(callbackPort)/auth/callback"
    #if canImport(Network)
    let callback: OAuthCallbackServer<ChatGPTAuthorizationResult>?
    do {
        callback = try await OAuthCallbackServer.start(
            providerName: "ChatGPT", host: oauthCallbackHost(), port: callbackPort,
            path: "/auth/callback", redirectHost: "127.0.0.1",
            mode: .chatGPT, signal: callbacks.signal
        ) { components in
            try chatGPTAuthorizationResult(components, expectedState: state)
        }
    } catch {
        callback = nil
        if let onProgress = callbacks.onProgress {
            await onProgress("Could not listen on \(fallbackRedirectUri); paste the final redirect URL to continue. \(error.localizedDescription)")
        }
    }
    let redirectUri = await callback?.redirectUri() ?? fallbackRedirectUri
    defer { if let callback { Task { await callback.close() } } }
    #else
    let redirectUri = fallbackRedirectUri
    #endif
    var authorize = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
    authorize.queryItems = [
        URLQueryItem(name: "client_id", value: "dynamic_agent_client"),
        URLQueryItem(name: "agent_name_hint", value: "Pi"),
        URLQueryItem(name: "ext_agent_host_id", value: hostId),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirectUri),
        URLQueryItem(name: "resource", value: chatGPTResource),
        URLQueryItem(name: "scope", value: chatGPTScope),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "nonce", value: nonce),
    ]
    await callbacks.onAuth(OAuthAuthInfo(
        url: authorize.url?.absoluteString ?? "",
        instructions: "Complete sign-in in your browser. If the callback does not complete, paste the final redirect URL here."
    ))
    #if canImport(Network)
    let authorization = try await waitForChatGPTAuthorization(
        callbacks: callbacks, callback: callback, state: state, redirectUri: redirectUri
    )
    #else
    let input = try await callbacks.onPrompt(OAuthPrompt(message: "Complete login in your browser, or paste the final redirect URL here:", placeholder: redirectUri))
    let authorization = try chatGPTManualResult(input, expectedState: state, redirectUri: redirectUri)
    #endif
    if let onProgress = callbacks.onProgress { await onProgress("Exchanging authorization code for tokens...") }
    return try await exchangeChatGPTCode(authorization, verifier: verifier, redirectUri: redirectUri, signal: callbacks.signal, tokenURL: tokenURL)
}
