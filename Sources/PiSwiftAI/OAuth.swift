import Foundation
import Dispatch
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif

public struct OAuthCredentials: Sendable, Codable {
    public var refresh: String
    public var access: String
    public var expires: Double
    public var enterpriseUrl: String?
    public var projectId: String?
    public var email: String?
    public var accountId: String?

    public init(
        refresh: String,
        access: String,
        expires: Double,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil
    ) {
        self.refresh = refresh
        self.access = access
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
    }
}

public enum OAuthProvider: String, Sendable, CaseIterable {
    case anthropic = "anthropic"
    case githubCopilot = "github-copilot"
    case googleGeminiCli = "google-gemini-cli"
    case googleAntigravity = "google-antigravity"
    case openAICodex = "openai-codex"
}

public struct OAuthPrompt: Sendable {
    public var message: String
    public var placeholder: String?
    public var allowEmpty: Bool

    public init(message: String, placeholder: String? = nil, allowEmpty: Bool = false) {
        self.message = message
        self.placeholder = placeholder
        self.allowEmpty = allowEmpty
    }
}

public struct OAuthAuthInfo: Sendable {
    public var url: String
    public var instructions: String?

    public init(url: String, instructions: String? = nil) {
        self.url = url
        self.instructions = instructions
    }
}

public struct OAuthProviderInfo: Sendable {
    public var id: OAuthProvider
    public var name: String
    public var available: Bool

    public init(id: OAuthProvider, name: String, available: Bool) {
        self.id = id
        self.name = name
        self.available = available
    }
}

public struct OAuthLoginCallbacks: Sendable {
    public var onAuth: @MainActor @Sendable (OAuthAuthInfo) -> Void
    public var onPrompt: @MainActor @Sendable (OAuthPrompt) async throws -> String
    public var onProgress: (@MainActor @Sendable (String) -> Void)?
    public var onManualCodeInput: (@MainActor @Sendable () async throws -> String?)?
    public var signal: CancellationToken?

    public init(
        onAuth: @escaping @MainActor @Sendable (OAuthAuthInfo) -> Void,
        onPrompt: @escaping @MainActor @Sendable (OAuthPrompt) async throws -> String,
        onProgress: (@MainActor @Sendable (String) -> Void)? = nil,
        onManualCodeInput: (@MainActor @Sendable () async throws -> String?)? = nil,
        signal: CancellationToken? = nil
    ) {
        self.onAuth = onAuth
        self.onPrompt = onPrompt
        self.onProgress = onProgress
        self.onManualCodeInput = onManualCodeInput
        self.signal = signal
    }
}

public enum OAuthError: Error, LocalizedError {
    case missingCredentials(String)
    case missingProjectId(String)
    case missingAuthorizationCode
    case stateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case invalidToken
    case unsupportedPlatform(String)
    case notImplemented(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider):
            return "No OAuth credentials found for \(provider)"
        case .missingProjectId(let provider):
            return "\(provider) OAuth credentials missing projectId"
        case .missingAuthorizationCode:
            return "Missing authorization code"
        case .stateMismatch:
            return "State mismatch"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .refreshFailed(let message):
            return "OAuth token refresh failed: \(message)"
        case .invalidToken:
            return "OAuth token response missing required fields"
        case .unsupportedPlatform(let message):
            return "OAuth not supported on this platform: \(message)"
        case .notImplemented(let provider):
            return "OAuth provider not implemented: \(provider)"
        case .cancelled:
            return "Login cancelled"
        }
    }
}

public func getOAuthProviders() -> [OAuthProviderInfo] {
    #if canImport(Network)
    let networkAvailable = true
    #else
    let networkAvailable = false
    #endif
    return [
        OAuthProviderInfo(id: .anthropic, name: "Anthropic (Claude Pro/Max)", available: true),
        OAuthProviderInfo(id: .openAICodex, name: "ChatGPT Plus/Pro (Codex Subscription)", available: networkAvailable),
        OAuthProviderInfo(id: .githubCopilot, name: "GitHub Copilot", available: true),
    ]
}

public func refreshOAuthToken(provider: OAuthProvider, credentials: OAuthCredentials) async throws -> OAuthCredentials {
    switch provider {
    case .anthropic:
        return try await refreshAnthropicToken(credentials.refresh)
    case .githubCopilot:
        return try await refreshGitHubCopilotToken(credentials.refresh, enterpriseDomain: credentials.enterpriseUrl)
    case .googleGeminiCli:
        guard let projectId = credentials.projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        return try await refreshGoogleGeminiCliToken(credentials.refresh, projectId: projectId)
    case .googleAntigravity:
        guard let projectId = credentials.projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        return try await refreshAntigravityToken(credentials.refresh, projectId: projectId)
    case .openAICodex:
        return try await refreshOpenAICodexToken(credentials.refresh)
    }
}

public func getOAuthApiKey(
    provider: OAuthProvider,
    credentials: [String: OAuthCredentials]
) async throws -> (newCredentials: OAuthCredentials, apiKey: String)? {
    guard var creds = credentials[provider.rawValue] else {
        return nil
    }

    if nowMs() >= creds.expires {
        creds = try await refreshOAuthToken(provider: provider, credentials: creds)
    }

    let apiKey = try oauthApiKey(provider: provider, accessToken: creds.access, projectId: creds.projectId)
    return (creds, apiKey)
}

public func oauthApiKey(provider: OAuthProvider, accessToken: String, projectId: String?) throws -> String {
    if requiresProjectId(provider) {
        guard let projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        let payload: [String: String] = ["token": accessToken, "projectId": projectId]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? accessToken
    }
    return accessToken
}

public func oauthApiKey(provider: OAuthProvider, credentials: OAuthCredentials) throws -> String {
    try oauthApiKey(provider: provider, accessToken: credentials.access, projectId: credentials.projectId)
}

public func loginAnthropic(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let pkce = try generatePKCE()
    let authUrl = anthropicAuthorizeUrl(verifier: pkce.verifier, challenge: pkce.challenge)
    await callbacks.onAuth(OAuthAuthInfo(url: authUrl))

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    let authCode = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code:"))
    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }
    let parts = authCode.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let code = parts.first.map(String.init) ?? ""
    let state = parts.count > 1 ? String(parts[1]) : nil

    let token = try await exchangeAnthropicCode(code: code, state: state, verifier: pkce.verifier)
    return token
}

public func refreshAnthropicToken(_ refreshToken: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    let body: [String: Any] = [
        "grant_type": "refresh_token",
        "client_id": anthropicClientId(),
        "refresh_token": refreshToken,
    ]
    let response = try await postJson(url: url, body: body)
    let token: AnthropicTokenResponse = try decodeJson(response.data)
    return OAuthCredentials(
        refresh: token.refresh_token,
        access: token.access_token,
        expires: nowMs() + token.expires_in * 1000 - 5 * 60 * 1000
    )
}

public func loginOpenAICodex(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let flow = try createOpenAICodexAuthorizationFlow()
    let server = await OpenAICodexCallbackServer.start(state: flow.state)

    await callbacks.onAuth(OAuthAuthInfo(
        url: flow.url,
        instructions: "A browser window should open. Complete login to finish."
    ))

    defer {
        if let server {
            Task { await server.close() }
        }
    }

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    var code: String?
    if let server {
        code = await server.waitForCode(timeoutSeconds: 60, signal: callbacks.signal)
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
    }

    if code == nil, let manualInput = callbacks.onManualCodeInput {
        let value = try await manualInput()
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        if let value {
            let parsed = parseAuthorizationInput(value)
            if let parsedState = parsed.state, parsedState != flow.state {
                throw OAuthError.stateMismatch
            }
            code = parsed.code
        }
    }

    if code == nil {
        let input = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code (or full redirect URL):"))
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        let parsed = parseAuthorizationInput(input)
        if let parsedState = parsed.state, parsedState != flow.state {
            throw OAuthError.stateMismatch
        }
        code = parsed.code
    }

    guard let code, !code.isEmpty else {
        throw OAuthError.missingAuthorizationCode
    }

    let token = try await exchangeOpenAICode(code: code, verifier: flow.verifier)
    guard let accountId = openAICodexAccountId(from: token.access) else {
        throw OAuthError.invalidToken
    }

    return OAuthCredentials(
        refresh: token.refresh,
        access: token.access,
        expires: token.expires,
        accountId: accountId
    )
}

public func refreshOpenAICodexToken(_ refreshToken: String) async throws -> OAuthCredentials {
    let token = try await refreshOpenAICode(refreshToken: refreshToken)
    guard let accountId = openAICodexAccountId(from: token.access) else {
        throw OAuthError.invalidToken
    }
    return OAuthCredentials(
        refresh: token.refresh,
        access: token.access,
        expires: token.expires,
        accountId: accountId
    )
}

private struct PKCEPair {
    let verifier: String
    let challenge: String
}

private func generatePKCE() throws -> PKCEPair {
    let verifierBytes = randomBytes(count: 32)
    let verifier = base64UrlEncode(verifierBytes)

    let challengeData = try sha256(Data(verifier.utf8))
    let challenge = base64UrlEncode(challengeData)
    return PKCEPair(verifier: verifier, challenge: challenge)
}

private func sha256(_ data: Data) throws -> Data {
#if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    return Data(digest)
#else
    throw OAuthError.unsupportedPlatform("CryptoKit SHA256 not available")
#endif
}

private func base64UrlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64UrlDecode(_ input: String) -> Data? {
    var base64 = input
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let remainder = base64.count % 4
    if remainder == 2 {
        base64 += "=="
    } else if remainder == 3 {
        base64 += "="
    } else if remainder == 1 {
        return nil
    }

    return Data(base64Encoded: base64)
}

private func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}

private func randomBytes(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var rng = SystemRandomNumberGenerator()
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: 0...255, using: &rng)
    }
    return Data(bytes)
}

private func randomHex(count: Int) -> String {
    let bytes = randomBytes(count: count)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func requiresProjectId(_ provider: OAuthProvider) -> Bool {
    provider == .googleGeminiCli || provider == .googleAntigravity
}

private func anthropicClientId() -> String {
    let encoded = "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl"
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private func anthropicAuthorizeUrl(verifier: String, challenge: String) -> String {
    var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
    components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: anthropicClientId()),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: "https://console.anthropic.com/oauth/code/callback"),
        URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: verifier),
    ]
    return components.url?.absoluteString ?? "https://claude.ai/oauth/authorize"
}

private struct AnthropicTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
}

private func exchangeAnthropicCode(code: String, state: String?, verifier: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    var body: [String: Any] = [
        "grant_type": "authorization_code",
        "client_id": anthropicClientId(),
        "code": code,
        "redirect_uri": "https://console.anthropic.com/oauth/code/callback",
        "code_verifier": verifier,
    ]
    if let state {
        body["state"] = state
    }
    let response = try await postJson(url: url, body: body)
    let token: AnthropicTokenResponse = try decodeJson(response.data)
    return OAuthCredentials(
        refresh: token.refresh_token,
        access: token.access_token,
        expires: nowMs() + token.expires_in * 1000 - 5 * 60 * 1000
    )
}

private struct HttpResponse {
    let data: Data
    let status: Int
}

private func postJson(url: URL, body: [String: Any]) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw OAuthError.tokenExchangeFailed(message)
    }
    return HttpResponse(data: data, status: status)
}

private func postForm(url: URL, params: [String: String]) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let form = params
        .map { "\($0.key)=\(urlEncode($0.value))" }
        .joined(separator: "&")
    request.httpBody = form.data(using: .utf8)

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw OAuthError.tokenExchangeFailed(message)
    }
    return HttpResponse(data: data, status: status)
}

private func urlEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private func decodeJson<T: Decodable>(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}

private struct OpenAITokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
}

private struct OpenAICodexToken {
    let access: String
    let refresh: String
    let expires: Double
}

private func createOpenAICodexAuthorizationFlow() throws -> (verifier: String, state: String, url: String) {
    let pkce = try generatePKCE()
    let state = randomHex(count: 16)

    var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
    components.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: "app_EMoamEEZ73f0CkXaXp7hrann"),
        URLQueryItem(name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
        URLQueryItem(name: "scope", value: "openid profile email offline_access"),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        URLQueryItem(name: "originator", value: "codex_cli_rs"),
    ]
    let url = components.url?.absoluteString ?? "https://auth.openai.com/oauth/authorize"
    return (pkce.verifier, state, url)
}

private func exchangeOpenAICode(code: String, verifier: String) async throws -> OpenAICodexToken {
    let url = URL(string: "https://auth.openai.com/oauth/token")!
    let response = try await postForm(
        url: url,
        params: [
            "grant_type": "authorization_code",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": "http://localhost:1455/auth/callback",
        ]
    )
    let token: OpenAITokenResponse = try decodeJson(response.data)
    return OpenAICodexToken(
        access: token.access_token,
        refresh: token.refresh_token,
        expires: nowMs() + token.expires_in * 1000
    )
}

private func refreshOpenAICode(refreshToken: String) async throws -> OpenAICodexToken {
    let url = URL(string: "https://auth.openai.com/oauth/token")!
    let response = try await postForm(
        url: url,
        params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        ]
    )
    let token: OpenAITokenResponse = try decodeJson(response.data)
    return OpenAICodexToken(
        access: token.access_token,
        refresh: token.refresh_token,
        expires: nowMs() + token.expires_in * 1000
    )
}

private func parseAuthorizationInput(_ input: String) -> (code: String?, state: String?) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (nil, nil) }

    if let url = URL(string: trimmed),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        let code = components.queryItems?.first { $0.name == "code" }?.value
        let state = components.queryItems?.first { $0.name == "state" }?.value
        if code != nil || state != nil {
            return (code, state)
        }
    }

    if trimmed.contains("#") {
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = parts.first.map(String.init)
        let state = parts.count > 1 ? String(parts[1]) : nil
        return (code, state)
    }

    if trimmed.contains("code=") {
        let prefixed = "https://localhost/?" + trimmed
        if let url = URL(string: prefixed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let code = components.queryItems?.first { $0.name == "code" }?.value
            let state = components.queryItems?.first { $0.name == "state" }?.value
            return (code, state)
        }
    }

    return (trimmed, nil)
}

private func openAICodexAccountId(from accessToken: String) -> String? {
    guard let payload = decodeJwt(accessToken) else { return nil }
    guard let auth = payload["https://api.openai.com/auth"] as? [String: Any] else { return nil }
    let accountId = auth["chatgpt_account_id"] as? String
    return (accountId?.isEmpty == false) ? accountId : nil
}

private func decodeJwt(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    guard let data = base64UrlDecode(String(parts[1])) else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

#if canImport(Network)
private func oauthCallbackParameters(port: NWEndpoint.Port) -> NWParameters {
    let parameters = NWParameters.tcp
    let host = ProcessInfo.processInfo.environment["PI_OAUTH_CALLBACK_HOST"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let host, !host.isEmpty {
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
    }
    return parameters
}

private actor OpenAICodexCallbackServer {
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "pi.oauth.openai-codex")
    private var code: String?
    private var cancelled = false

    private init(listener: NWListener, state: String) {
        self.listener = listener
        self.state = state
    }

    static func start(state: String) async -> OpenAICodexCallbackServer? {
        guard let port = NWEndpoint.Port(rawValue: 1455) else { return nil }
        let listener: NWListener
        do {
            listener = try NWListener(using: oauthCallbackParameters(port: port), on: port)
        } catch {
            return nil
        }

        let server = OpenAICodexCallbackServer(listener: listener, state: state)
        let ready = await server.startListener()
        return ready ? server : nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if let code { return code }
            if cancelled { return nil }
            if signal?.isCancelled == true {
                cancelled = true
                return nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return code
    }

    func cancelWait() {
        cancelled = true
    }

    func close() {
        listener.cancel()
    }

    private func startListener() async -> Bool {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: true)
                case .failed:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private final class ConnectionState: Sendable {
        let buffer = LockedState(Data())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = ConnectionState()
        scheduleReceive(connection, state: state)
    }

    private func scheduleReceive(_ connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            var requestLine: String?
            state.buffer.withLock { buffer in
                if let data {
                    buffer.append(data)
                }
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    requestLine = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                }
            }
            if let requestLine {
                Task { await self?.handleRequestLine(requestLine, connection: connection) }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            Task { await self?.scheduleReceive(connection, state: state) }
        }
    }

    private func handleRequestLine(_ line: String, connection: NWConnection) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        let pathPart = String(parts[1])
        guard let url = URL(string: "http://localhost\(pathPart)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        guard components.path == "/auth/callback" else {
            sendResponse(connection, status: 404, body: "Not found")
            return
        }

        let receivedState = components.queryItems?.first { $0.name == "state" }?.value
        if receivedState != state {
            sendResponse(connection, status: 400, body: "State mismatch")
            return
        }

        guard let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value, !codeParam.isEmpty else {
            sendResponse(connection, status: 400, body: "Missing authorization code")
            return
        }

        code = codeParam
        sendResponse(connection, status: 200, body: openAICodexSuccessHtml())
    }

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText = status == 200 ? "OK" : "Error"
        let headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Pragma: no-cache",
            "",
            ""
        ]
        let header = headerLines.joined(separator: "\r\n")
        let responseData = header.data(using: .utf8, allowLossyConversion: false) ?? Data()
        connection.send(content: responseData + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#else
private final class OpenAICodexCallbackServer {
    static func start(state: String) async -> OpenAICodexCallbackServer? {
        nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        nil
    }

    func cancelWait() {}

    func close() {}
}
#endif

private func openAICodexSuccessHtml() -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Authentication successful</title>
    </head>
    <body>
      <p>Authentication successful. Return to your terminal to continue.</p>
    </body>
    </html>
    """
}

// MARK: - GitHub Copilot OAuth (Device Code Flow)

private func gitHubCopilotClientId() -> String {
    let encoded = "SXYxLmI1MDdhMDhjODdlY2ZlOTg="
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private let copilotHeaders: [String: String] = [
    "User-Agent": "GitHubCopilotChat/0.35.0",
    "Editor-Version": "vscode/1.107.0",
    "Editor-Plugin-Version": "copilot-chat/0.35.0",
    "Copilot-Integration-Id": "vscode-chat",
]

private struct DeviceCodeResponse {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let interval: Int
    let expiresIn: Int
}

/// Normalize a GitHub domain input to a hostname.
public func normalizeGitHubDomain(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    let urlString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: urlString), let host = url.host else {
        return nil
    }
    return host
}

private func gitHubUrls(domain: String) -> (deviceCodeUrl: URL, accessTokenUrl: URL, copilotTokenUrl: URL) {
    (
        deviceCodeUrl: URL(string: "https://\(domain)/login/device/code")!,
        accessTokenUrl: URL(string: "https://\(domain)/login/oauth/access_token")!,
        copilotTokenUrl: URL(string: "https://api.\(domain)/copilot_internal/v2/token")!
    )
}

/// Parse the proxy-ep from a Copilot token and convert to API base URL.
/// Token format: tid=...;exp=...;proxy-ep=proxy.individual.githubcopilot.com;...
private func getBaseUrlFromCopilotToken(_ token: String) -> String? {
    let pattern = "proxy-ep=([^;]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
          let range = Range(match.range(at: 1), in: token) else {
        return nil
    }
    let proxyHost = String(token[range])
    // Convert proxy.xxx to api.xxx
    let apiHost = proxyHost.hasPrefix("proxy.") ? "api." + proxyHost.dropFirst(6) : proxyHost
    return "https://\(apiHost)"
}

/// Get the GitHub Copilot API base URL from token or enterprise domain.
public func getGitHubCopilotBaseUrl(token: String?, enterpriseDomain: String?) -> String {
    if let token, let urlFromToken = getBaseUrlFromCopilotToken(token) {
        return urlFromToken
    }
    if let enterprise = enterpriseDomain {
        return "https://copilot-api.\(enterprise)"
    }
    return "https://api.individual.githubcopilot.com"
}

private func startDeviceFlow(domain: String) async throws -> DeviceCodeResponse {
    let urls = gitHubUrls(domain: domain)
    var request = URLRequest(url: urls.deviceCodeUrl)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "client_id": gitHubCopilotClientId(),
        "scope": "read:user"
    ])

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        let message = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw OAuthError.tokenExchangeFailed(message)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let deviceCode = json["device_code"] as? String,
          let userCode = json["user_code"] as? String,
          let verificationUri = json["verification_uri"] as? String,
          let interval = json["interval"] as? Int,
          let expiresIn = json["expires_in"] as? Int else {
        throw OAuthError.tokenExchangeFailed("Invalid device code response")
    }

    return DeviceCodeResponse(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        interval: interval,
        expiresIn: expiresIn
    )
}

private func pollForGitHubAccessToken(
    domain: String,
    deviceCode: String,
    intervalSeconds: Int,
    expiresIn: Int,
    signal: CancellationToken?
) async throws -> String {
    let urls = gitHubUrls(domain: domain)
    let deadline = Date().addingTimeInterval(Double(expiresIn))
    var intervalMs = max(1000, intervalSeconds * 1000)

    // RFC 8628 requires clients to wait the advertised interval before the
    // first poll; polling immediately after opening the browser is rejected by
    // GitHub's device-code endpoint.
    try await sleepMs(intervalMs, signal: signal)

    while Date() < deadline {
        if signal?.isCancelled == true {
            throw OAuthError.cancelled
        }

        var request = URLRequest(url: urls.accessTokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": gitHubCopilotClientId(),
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])

        let session = proxySession(for: request.url)
        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try await sleepMs(intervalMs, signal: signal)
            continue
        }

        if let accessToken = json["access_token"] as? String {
            return accessToken
        }

        if let error = json["error"] as? String {
            if error == "authorization_pending" {
                try await sleepMs(intervalMs, signal: signal)
                continue
            }
            if error == "slow_down" {
                // GitHub can include its new minimum interval in the response.
                // Use it when present; otherwise follow RFC 8628's +5 seconds.
                if let serverInterval = json["interval"] as? NSNumber, serverInterval.intValue > 0 {
                    intervalMs = max(1000, serverInterval.intValue * 1000)
                } else {
                    intervalMs += 5000
                }
                try await sleepMs(intervalMs, signal: signal)
                continue
            }
            throw OAuthError.tokenExchangeFailed("Device flow failed: \(error)")
        }

        try await sleepMs(intervalMs, signal: signal)
    }

    throw OAuthError.tokenExchangeFailed("Device flow timed out")
}

private func sleepMs(_ ms: Int, signal: CancellationToken?) async throws {
    if signal?.isCancelled == true {
        throw OAuthError.cancelled
    }
    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    if signal?.isCancelled == true {
        throw OAuthError.cancelled
    }
}

/// Refresh GitHub Copilot token (exchange GitHub access token for Copilot token).
public func refreshGitHubCopilotToken(_ refreshToken: String, enterpriseDomain: String?) async throws -> OAuthCredentials {
    let domain = enterpriseDomain ?? "github.com"
    let urls = gitHubUrls(domain: domain)

    var request = URLRequest(url: urls.copilotTokenUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
    for (key, value) in copilotHeaders {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        let message = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw OAuthError.refreshFailed(message)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["token"] as? String,
          let expiresAt = json["expires_at"] as? Int else {
        throw OAuthError.invalidToken
    }

    return OAuthCredentials(
        refresh: refreshToken,
        access: token,
        expires: Double(expiresAt) * 1000 - 5 * 60 * 1000,
        enterpriseUrl: enterpriseDomain
    )
}

/// Enable a model for the user's GitHub Copilot account.
private func enableGitHubCopilotModel(token: String, modelId: String, enterpriseDomain: String?) async -> Bool {
    let baseUrl = getGitHubCopilotBaseUrl(token: token, enterpriseDomain: enterpriseDomain)
    guard let url = URL(string: "\(baseUrl)/models/\(modelId)/policy") else {
        return false
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("chat-policy", forHTTPHeaderField: "openai-intent")
    request.setValue("chat-policy", forHTTPHeaderField: "x-interaction-type")
    for (key, value) in copilotHeaders {
        request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["state": "enabled"])

    do {
        let session = proxySession(for: request.url)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
        return false
    }
}

/// Enable all known GitHub Copilot models that may require policy acceptance.
private func enableAllGitHubCopilotModels(
    token: String,
    enterpriseDomain: String?,
    onProgress: (@MainActor @Sendable (String) -> Void)?
) async {
    let models = getModels(provider: .githubCopilot)
    await withTaskGroup(of: Void.self) { group in
        for model in models {
            group.addTask {
                let success = await enableGitHubCopilotModel(token: token, modelId: model.id, enterpriseDomain: enterpriseDomain)
                if let onProgress {
                    let message = success ? "Enabled \(model.id)" : "Failed to enable \(model.id)"
                    await onProgress(message)
                }
            }
        }
    }
}

/// Login with GitHub Copilot OAuth (device code flow).
public func loginGitHubCopilot(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    // Prompt for GitHub Enterprise URL
    let input = try await callbacks.onPrompt(OAuthPrompt(
        message: "GitHub Enterprise URL/domain (blank for github.com)",
        placeholder: "company.ghe.com",
        allowEmpty: true
    ))

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let enterpriseDomain = normalizeGitHubDomain(input)
    if !trimmed.isEmpty && enterpriseDomain == nil {
        throw OAuthError.tokenExchangeFailed("Invalid GitHub Enterprise URL/domain")
    }
    let domain = enterpriseDomain ?? "github.com"

    // Start device flow
    let device = try await startDeviceFlow(domain: domain)

    // Show verification URL and code to user
    await callbacks.onAuth(OAuthAuthInfo(
        url: device.verificationUri,
        instructions: "Enter code: \(device.userCode)"
    ))

    // Poll for access token
    let githubAccessToken = try await pollForGitHubAccessToken(
        domain: domain,
        deviceCode: device.deviceCode,
        intervalSeconds: device.interval,
        expiresIn: device.expiresIn,
        signal: callbacks.signal
    )

    // Exchange GitHub token for Copilot token
    let credentials = try await refreshGitHubCopilotToken(githubAccessToken, enterpriseDomain: enterpriseDomain)

    // Enable all models
    if let onProgress = callbacks.onProgress {
        await onProgress("Enabling models...")
    }
    await enableAllGitHubCopilotModels(
        token: credentials.access,
        enterpriseDomain: enterpriseDomain,
        onProgress: callbacks.onProgress
    )

    return credentials
}

// MARK: - Google Gemini CLI OAuth (Cloud Code Assist)

private func googleGeminiCliClientId() -> String {
    let encoded = "NjgxMjU1ODA5Mzk1LW9vOGZ0Mm9wcmRybnA5ZTNhcWY2YXYzaG1kaWIxMzVqLmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29t"
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private func googleGeminiCliClientSecret() -> String {
    let encoded = "R09DU1BYLTR1SGdNUG0tMW83U2stZ2VWNkN1NWNsWEZzeGw="
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private let googleGeminiCliScopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
]

private let googleGeminiCliRedirectUri = "http://localhost:8085/oauth2callback"

/// Refresh Google Gemini CLI (Cloud Code Assist) token.
public func refreshGoogleGeminiCliToken(_ refreshToken: String, projectId: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://oauth2.googleapis.com/token")!
    let response = try await postForm(
        url: url,
        params: [
            "client_id": googleGeminiCliClientId(),
            "client_secret": googleGeminiCliClientSecret(),
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
    )

    guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = json["access_token"] as? String,
          let expiresIn = json["expires_in"] as? Int else {
        throw OAuthError.invalidToken
    }

    let newRefresh = json["refresh_token"] as? String ?? refreshToken
    return OAuthCredentials(
        refresh: newRefresh,
        access: accessToken,
        expires: nowMs() + Double(expiresIn) * 1000 - 5 * 60 * 1000,
        projectId: projectId
    )
}

/// Get user email from Google access token.
private func getGoogleUserEmail(_ accessToken: String) async -> String? {
    guard let url = URL(string: "https://www.googleapis.com/oauth2/v1/userinfo?alt=json") else {
        return nil
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

    do {
        let session = proxySession(for: request.url)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    } catch {
        return nil
    }
}

/// Discover or provision a Google Cloud project for Gemini CLI.
private func discoverGeminiCliProject(accessToken: String, onProgress: (@MainActor @Sendable (String) -> Void)?) async throws -> String {
    let envProjectId = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
        ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]

    let headers: [String: String] = [
        "Authorization": "Bearer \(accessToken)",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "gl-node/22.17.0",
    ]

    let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    guard let url = URL(string: endpoint) else {
        throw OAuthError.tokenExchangeFailed("Invalid endpoint URL")
    }

    if let onProgress {
        await onProgress("Checking for existing Cloud Code Assist project...")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let body: [String: Any] = [
        "cloudaicompanionProject": envProjectId as Any,
        "metadata": [
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
            "duetProject": envProjectId as Any,
        ]
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)

    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Check if user has current tier and project
            if json["currentTier"] != nil {
                if let project = json["cloudaicompanionProject"] as? String, !project.isEmpty {
                    return project
                }
                if let envProjectId, !envProjectId.isEmpty {
                    return envProjectId
                }
                throw OAuthError.missingProjectId(
                    "This account requires setting GOOGLE_CLOUD_PROJECT environment variable. " +
                    "See https://goo.gle/gemini-cli-auth-docs#workspace-gca"
                )
            }

            // User needs onboarding - try to provision
            if let onProgress {
                await onProgress("Provisioning Cloud Code Assist project...")
            }
            return try await provisionGeminiCliProject(accessToken: accessToken, headers: headers, envProjectId: envProjectId, onProgress: onProgress)
        }
    }

    // Fallback to env var
    if let envProjectId, !envProjectId.isEmpty {
        return envProjectId
    }

    throw OAuthError.missingProjectId(
        "Could not discover Google Cloud project. " +
        "Try setting GOOGLE_CLOUD_PROJECT environment variable."
    )
}

private func provisionGeminiCliProject(
    accessToken: String,
    headers: [String: String],
    envProjectId: String?,
    onProgress: (@MainActor @Sendable (String) -> Void)?
) async throws -> String {
    let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:onboardUser"
    guard let url = URL(string: endpoint) else {
        throw OAuthError.tokenExchangeFailed("Invalid endpoint URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }

    var body: [String: Any] = [
        "tierId": "free-tier",
        "metadata": [
            "ideType": "IDE_UNSPECIFIED",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        ]
    ]

    if let envProjectId, !envProjectId.isEmpty {
        body["cloudaicompanionProject"] = envProjectId
        var metadata = body["metadata"] as? [String: Any] ?? [:]
        metadata["duetProject"] = envProjectId
        body["metadata"] = metadata
    }

    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let session = proxySession(for: request.url)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        if let envProjectId, !envProjectId.isEmpty {
            return envProjectId
        }
        throw OAuthError.tokenExchangeFailed("Failed to provision project")
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        if let envProjectId, !envProjectId.isEmpty {
            return envProjectId
        }
        throw OAuthError.tokenExchangeFailed("Invalid provision response")
    }

    // Check if operation is done
    if let done = json["done"] as? Bool, done {
        if let responseObj = json["response"] as? [String: Any],
           let project = responseObj["cloudaicompanionProject"] as? [String: Any],
           let projectId = project["id"] as? String {
            return projectId
        }
    }

    // Poll for operation completion
    if let operationName = json["name"] as? String {
        return try await pollGeminiCliOperation(operationName: operationName, headers: headers, envProjectId: envProjectId, onProgress: onProgress)
    }

    if let envProjectId, !envProjectId.isEmpty {
        return envProjectId
    }
    throw OAuthError.tokenExchangeFailed("Could not provision project")
}

private func pollGeminiCliOperation(
    operationName: String,
    headers: [String: String],
    envProjectId: String?,
    onProgress: (@MainActor @Sendable (String) -> Void)?
) async throws -> String {
    let endpoint = "https://cloudcode-pa.googleapis.com/v1internal/\(operationName)"
    guard let url = URL(string: endpoint) else {
        throw OAuthError.tokenExchangeFailed("Invalid operation URL")
    }

    for attempt in 0..<30 {
        if attempt > 0 {
            if let onProgress {
                await onProgress("Waiting for project provisioning (attempt \(attempt + 1))...")
            }
            try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = proxySession(for: request.url)
        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        if let done = json["done"] as? Bool, done {
            if let responseObj = json["response"] as? [String: Any],
               let project = responseObj["cloudaicompanionProject"] as? [String: Any],
               let projectId = project["id"] as? String {
                return projectId
            }
            break
        }
    }

    if let envProjectId, !envProjectId.isEmpty {
        return envProjectId
    }
    throw OAuthError.tokenExchangeFailed("Project provisioning timed out")
}

/// Login with Google Gemini CLI (Cloud Code Assist) OAuth.
public func loginGoogleGeminiCli(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let pkce = try generatePKCE()
    let state = randomHex(count: 16)

    // Build authorization URL
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
        URLQueryItem(name: "client_id", value: googleGeminiCliClientId()),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: googleGeminiCliRedirectUri),
        URLQueryItem(name: "scope", value: googleGeminiCliScopes.joined(separator: " ")),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
    ]
    let authUrl = components.url?.absoluteString ?? ""

    // Start callback server
    let server = await GoogleCallbackServer.start(port: 8085, path: "/oauth2callback", state: state)

    await callbacks.onAuth(OAuthAuthInfo(
        url: authUrl,
        instructions: "Complete the sign-in in your browser."
    ))

    defer {
        if let server {
            Task { await server.close() }
        }
    }

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    var code: String?
    if let server {
        code = await server.waitForCode(timeoutSeconds: 120, signal: callbacks.signal)
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
    }

    if code == nil, let manualInput = callbacks.onManualCodeInput {
        let value = try await manualInput()
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        if let value {
            let parsed = parseAuthorizationInput(value)
            if let parsedState = parsed.state, parsedState != state {
                throw OAuthError.stateMismatch
            }
            code = parsed.code
        }
    }

    if code == nil {
        let input = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code or redirect URL:"))
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        let parsed = parseAuthorizationInput(input)
        if let parsedState = parsed.state, parsedState != state {
            throw OAuthError.stateMismatch
        }
        code = parsed.code
    }

    guard let code, !code.isEmpty else {
        throw OAuthError.missingAuthorizationCode
    }

    // Exchange code for tokens
    if let onProgress = callbacks.onProgress {
        await onProgress("Exchanging authorization code for tokens...")
    }

    let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
    let tokenResponse = try await postForm(
        url: tokenUrl,
        params: [
            "client_id": googleGeminiCliClientId(),
            "client_secret": googleGeminiCliClientSecret(),
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": googleGeminiCliRedirectUri,
            "code_verifier": pkce.verifier,
        ]
    )

    guard let tokenJson = try? JSONSerialization.jsonObject(with: tokenResponse.data) as? [String: Any],
          let accessToken = tokenJson["access_token"] as? String,
          let refreshToken = tokenJson["refresh_token"] as? String,
          let expiresIn = tokenJson["expires_in"] as? Int else {
        throw OAuthError.invalidToken
    }

    // Get user email
    if let onProgress = callbacks.onProgress {
        await onProgress("Getting user info...")
    }
    let email = await getGoogleUserEmail(accessToken)

    // Discover project
    let projectId = try await discoverGeminiCliProject(accessToken: accessToken, onProgress: callbacks.onProgress)

    return OAuthCredentials(
        refresh: refreshToken,
        access: accessToken,
        expires: nowMs() + Double(expiresIn) * 1000 - 5 * 60 * 1000,
        projectId: projectId,
        email: email
    )
}

// MARK: - Antigravity OAuth

private func antigravityClientId() -> String {
    let encoded = "MTA3MTAwNjA2MDU5MS10bWhzc2luMmgyMWxjcmUyMzV2dG9sb2poNGc0MDNlcC5hcHBzLmdvb2dsZXVzZXJjb250ZW50LmNvbQ=="
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private func antigravityClientSecret() -> String {
    let encoded = "R09DU1BYLUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY="
    if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
        return decoded
    }
    return encoded
}

private let antigravityScopes = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs",
]

private let antigravityRedirectUri = "http://localhost:51121/oauth-callback"
private let antigravityDefaultProjectId = "rising-fact-p41fc"

/// Refresh Antigravity token.
public func refreshAntigravityToken(_ refreshToken: String, projectId: String) async throws -> OAuthCredentials {
    let url = URL(string: "https://oauth2.googleapis.com/token")!
    let response = try await postForm(
        url: url,
        params: [
            "client_id": antigravityClientId(),
            "client_secret": antigravityClientSecret(),
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
    )

    guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = json["access_token"] as? String,
          let expiresIn = json["expires_in"] as? Int else {
        throw OAuthError.invalidToken
    }

    let newRefresh = json["refresh_token"] as? String ?? refreshToken
    return OAuthCredentials(
        refresh: newRefresh,
        access: accessToken,
        expires: nowMs() + Double(expiresIn) * 1000 - 5 * 60 * 1000,
        projectId: projectId
    )
}

/// Discover project for Antigravity.
private func discoverAntigravityProject(accessToken: String, onProgress: (@MainActor @Sendable (String) -> Void)?) async -> String {
    let headers: [String: String] = [
        "Authorization": "Bearer \(accessToken)",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    ]

    let endpoints = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com"
    ]

    for endpoint in endpoints {
        guard let url = URL(string: "\(endpoint)/v1internal:loadCodeAssist") else {
            continue
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let body: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let session = proxySession(for: request.url)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Handle both string and object formats
            if let project = json["cloudaicompanionProject"] as? String, !project.isEmpty {
                return project
            }
            if let projectObj = json["cloudaicompanionProject"] as? [String: Any],
               let projectId = projectObj["id"] as? String {
                return projectId
            }
        } catch {
            continue
        }
    }

    // Use fallback project
    return antigravityDefaultProjectId
}

/// Login with Antigravity OAuth.
public func loginAntigravity(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    let pkce = try generatePKCE()
    let state = randomHex(count: 16)

    // Build authorization URL
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
        URLQueryItem(name: "client_id", value: antigravityClientId()),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: antigravityRedirectUri),
        URLQueryItem(name: "scope", value: antigravityScopes.joined(separator: " ")),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "access_type", value: "offline"),
        URLQueryItem(name: "prompt", value: "consent"),
    ]
    let authUrl = components.url?.absoluteString ?? ""

    // Start callback server
    let server = await GoogleCallbackServer.start(port: 51121, path: "/oauth-callback", state: state)

    await callbacks.onAuth(OAuthAuthInfo(
        url: authUrl,
        instructions: "Complete the sign-in in your browser."
    ))

    defer {
        if let server {
            Task { await server.close() }
        }
    }

    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    var code: String?
    if let server {
        code = await server.waitForCode(timeoutSeconds: 120, signal: callbacks.signal)
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
    }

    if code == nil, let manualInput = callbacks.onManualCodeInput {
        let value = try await manualInput()
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        if let value {
            let parsed = parseAuthorizationInput(value)
            if let parsedState = parsed.state, parsedState != state {
                throw OAuthError.stateMismatch
            }
            code = parsed.code
        }
    }

    if code == nil {
        let input = try await callbacks.onPrompt(OAuthPrompt(message: "Paste the authorization code or redirect URL:"))
        if callbacks.signal?.isCancelled == true {
            throw OAuthError.cancelled
        }
        let parsed = parseAuthorizationInput(input)
        if let parsedState = parsed.state, parsedState != state {
            throw OAuthError.stateMismatch
        }
        code = parsed.code
    }

    guard let code, !code.isEmpty else {
        throw OAuthError.missingAuthorizationCode
    }

    // Exchange code for tokens
    if let onProgress = callbacks.onProgress {
        await onProgress("Exchanging authorization code for tokens...")
    }

    let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!
    let tokenResponse = try await postForm(
        url: tokenUrl,
        params: [
            "client_id": antigravityClientId(),
            "client_secret": antigravityClientSecret(),
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": antigravityRedirectUri,
            "code_verifier": pkce.verifier,
        ]
    )

    guard let tokenJson = try? JSONSerialization.jsonObject(with: tokenResponse.data) as? [String: Any],
          let accessToken = tokenJson["access_token"] as? String,
          let refreshToken = tokenJson["refresh_token"] as? String,
          let expiresIn = tokenJson["expires_in"] as? Int else {
        throw OAuthError.invalidToken
    }

    // Get user email
    if let onProgress = callbacks.onProgress {
        await onProgress("Getting user info...")
    }
    let email = await getGoogleUserEmail(accessToken)

    // Discover project
    if let onProgress = callbacks.onProgress {
        await onProgress("Discovering project...")
    }
    let projectId = await discoverAntigravityProject(accessToken: accessToken, onProgress: callbacks.onProgress)

    return OAuthCredentials(
        refresh: refreshToken,
        access: accessToken,
        expires: nowMs() + Double(expiresIn) * 1000 - 5 * 60 * 1000,
        projectId: projectId,
        email: email
    )
}

// MARK: - Google OAuth Callback Server

#if canImport(Network)
private actor GoogleCallbackServer {
    private let listener: NWListener
    private let path: String
    private let state: String
    private let queue = DispatchQueue(label: "pi.oauth.google")
    private var code: String?
    private var cancelled = false

    private init(listener: NWListener, path: String, state: String) {
        self.listener = listener
        self.path = path
        self.state = state
    }

    static func start(port: UInt16, path: String, state: String) async -> GoogleCallbackServer? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let listener: NWListener
        do {
            listener = try NWListener(using: oauthCallbackParameters(port: nwPort), on: nwPort)
        } catch {
            return nil
        }

        let server = GoogleCallbackServer(listener: listener, path: path, state: state)
        let ready = await server.startListener()
        return ready ? server : nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if let code { return code }
            if cancelled { return nil }
            if signal?.isCancelled == true {
                cancelled = true
                return nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return code
    }

    func cancelWait() {
        cancelled = true
    }

    func close() {
        listener.cancel()
    }

    private func startListener() async -> Bool {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: true)
                case .failed:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private final class ConnectionState: Sendable {
        let buffer = LockedState(Data())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = ConnectionState()
        scheduleReceive(connection, state: state)
    }

    private func scheduleReceive(_ connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            var requestLine: String?
            state.buffer.withLock { buffer in
                if let data {
                    buffer.append(data)
                }
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    requestLine = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
                }
            }
            if let requestLine {
                Task { await self?.handleRequestLine(requestLine, connection: connection) }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            Task { await self?.scheduleReceive(connection, state: state) }
        }
    }

    private func handleRequestLine(_ line: String, connection: NWConnection) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        let pathPart = String(parts[1])
        guard let url = URL(string: "http://localhost\(pathPart)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }

        guard components.path == path else {
            sendResponse(connection, status: 404, body: "Not found")
            return
        }

        // Check for error
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            sendResponse(connection, status: 400, body: googleErrorHtml(error))
            return
        }

        let receivedState = components.queryItems?.first { $0.name == "state" }?.value
        if receivedState != state {
            sendResponse(connection, status: 400, body: "State mismatch")
            return
        }

        guard let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value, !codeParam.isEmpty else {
            sendResponse(connection, status: 400, body: "Missing authorization code")
            return
        }

        code = codeParam
        sendResponse(connection, status: 200, body: googleSuccessHtml())
    }

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let statusText = status == 200 ? "OK" : "Error"
        let headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Pragma: no-cache",
            "",
            ""
        ]
        let header = headerLines.joined(separator: "\r\n")
        let responseData = header.data(using: .utf8, allowLossyConversion: false) ?? Data()
        connection.send(content: responseData + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#else
private final class GoogleCallbackServer {
    static func start(port: UInt16, path: String, state: String) async -> GoogleCallbackServer? {
        nil
    }

    func waitForCode(timeoutSeconds: Int, signal: CancellationToken? = nil) async -> String? {
        nil
    }

    func cancelWait() {}

    func close() {}
}
#endif

private func googleSuccessHtml() -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Authentication Successful</title>
    </head>
    <body>
      <h1>Authentication Successful</h1>
      <p>You can close this window and return to the terminal.</p>
    </body>
    </html>
    """
}

private func googleErrorHtml(_ error: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Authentication Failed</title>
    </head>
    <body>
      <h1>Authentication Failed</h1>
      <p>Error: \(error)</p>
      <p>You can close this window.</p>
    </body>
    </html>
    """
}
