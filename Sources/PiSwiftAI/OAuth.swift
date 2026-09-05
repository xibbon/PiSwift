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
    public var availableModelIds: [String]?

    public init(
        refresh: String,
        access: String,
        expires: Double,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil,
        availableModelIds: [String]? = nil
    ) {
        self.refresh = refresh
        self.access = access
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
        self.availableModelIds = availableModelIds
    }
}

/// OAuth credentials refresh by default when less than five minutes remain.
public let defaultOAuthMinimumValidityMs = 5 * 60 * 1000.0

public enum OAuthProvider: String, Sendable, CaseIterable {
    case anthropic = "anthropic"
    case githubCopilot = "github-copilot"
    case googleGeminiCli = "google-gemini-cli"
    case googleAntigravity = "google-antigravity"
    case openAICodex = "openai-codex"
    case openRouter = "openrouter"
    case kimiCoding = "kimi-coding"
    case xai = "xai"
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
        OAuthProviderInfo(id: .openRouter, name: "OpenRouter OAuth", available: true),
        OAuthProviderInfo(id: .kimiCoding, name: "Kimi Code (subscription)", available: true),
        OAuthProviderInfo(id: .xai, name: "xAI (Grok/X subscription)", available: true),
    ]
}

public func refreshOAuthToken(
    provider: OAuthProvider,
    credentials: OAuthCredentials,
    signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    try throwIfOAuthCancelled(signal)
    switch provider {
    case .anthropic:
        return try await refreshAnthropicToken(credentials.refresh, signal: signal)
    case .githubCopilot:
        return try await refreshGitHubCopilotToken(credentials.refresh, enterpriseDomain: credentials.enterpriseUrl, signal: signal)
    case .googleGeminiCli:
        guard let projectId = credentials.projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        return try await refreshGoogleGeminiCliToken(credentials.refresh, projectId: projectId, signal: signal)
    case .googleAntigravity:
        guard let projectId = credentials.projectId else {
            throw OAuthError.missingProjectId(provider.rawValue)
        }
        return try await refreshAntigravityToken(credentials.refresh, projectId: projectId, signal: signal)
    case .openAICodex:
        return try await refreshOpenAICodexToken(credentials.refresh, signal: signal)
    case .openRouter:
        return credentials
    case .kimiCoding:
        return try await refreshKimiCodingToken(credentials.refresh, signal: signal)
    case .xai:
        return try await refreshXaiToken(credentials.refresh, signal: signal)
    }
}

public func getOAuthApiKey(
    provider: OAuthProvider,
    credentials: [String: OAuthCredentials],
    minimumValidityMs: Double? = nil,
    signal: CancellationToken? = nil
) async throws -> (newCredentials: OAuthCredentials, apiKey: String)? {
    guard var creds = credentials[provider.rawValue] else {
        return nil
    }

    if oauthCredentialNeedsRefresh(creds, minimumValidityMs: minimumValidityMs) {
        creds = try await refreshOAuthToken(provider: provider, credentials: creds, signal: signal)
    }

    let apiKey = try oauthApiKey(provider: provider, accessToken: creds.access, projectId: creds.projectId)
    return (creds, apiKey)
}

public func oauthCredentialNeedsRefresh(
    _ credentials: OAuthCredentials,
    minimumValidityMs: Double? = nil,
    now: Double = Date().timeIntervalSince1970 * 1000
) -> Bool {
    let requested = max(0, minimumValidityMs ?? 0)
    let minimum = max(defaultOAuthMinimumValidityMs, requested)
    return now + minimum >= credentials.expires
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

public func refreshAnthropicToken(_ refreshToken: String, signal: CancellationToken? = nil) async throws -> OAuthCredentials {
    let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    let body: [String: Any] = [
        "grant_type": "refresh_token",
        "client_id": anthropicClientId(),
        "refresh_token": refreshToken,
    ]
    let response = try await postJson(url: url, body: body, signal: signal)
    let token: AnthropicTokenResponse = try decodeJson(response.data)
    return OAuthCredentials(
        refresh: token.refresh_token,
        access: token.access_token,
        expires: nowMs() + token.expires_in * 1000 - defaultOAuthMinimumValidityMs
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

public func refreshOpenAICodexToken(_ refreshToken: String, signal: CancellationToken? = nil) async throws -> OAuthCredentials {
    let token = try await refreshOpenAICode(refreshToken: refreshToken, signal: signal)
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

private func throwIfOAuthCancelled(_ signal: CancellationToken?) throws {
    if signal?.isCancelled == true || Task.isCancelled {
        throw OAuthError.cancelled
    }
}

struct OAuthNetworkResponse: Sendable {
    let data: Data
    let status: Int
    var headers: [String: String] = [:]
}

private func oauthData(
    for request: URLRequest,
    signal: CancellationToken?,
    timeoutMs: Int? = nil
) async throws -> OAuthNetworkResponse {
    try throwIfOAuthCancelled(signal)
    let session = proxySession(for: request.url)
    let deadline = timeoutMs.map { nowMs() + Double($0) }

    do {
        return try await withThrowingTaskGroup(of: OAuthNetworkResponse.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let headers = (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { result, item in
                    if let name = item.key as? String { result[name] = String(describing: item.value) }
                } ?? [:]
                return OAuthNetworkResponse(data: data, status: status, headers: headers)
            }
            group.addTask {
                while true {
                    if signal?.isCancelled == true || Task.isCancelled {
                        throw OAuthError.cancelled
                    }
                    if let deadline, nowMs() >= deadline {
                        throw OAuthError.tokenExchangeFailed("OAuth request timed out")
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
            }

            guard let first = try await group.next() else {
                throw OAuthError.tokenExchangeFailed("OAuth request failed")
            }
            group.cancelAll()
            return first
        }
    } catch {
        if signal?.isCancelled == true || Task.isCancelled {
            throw OAuthError.cancelled
        }
        throw error
    }
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
        expires: nowMs() + token.expires_in * 1000 - defaultOAuthMinimumValidityMs
    )
}

private struct HttpResponse {
    let data: Data
    let status: Int
}

private func postJson(url: URL, body: [String: Any], signal: CancellationToken? = nil) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let response = try await oauthData(for: request, signal: signal)
    let data = response.data
    let status = response.status
    if status != 200 {
        let message = String(data: data, encoding: .utf8) ?? ""
        throw OAuthError.tokenExchangeFailed(message)
    }
    return HttpResponse(data: data, status: status)
}

private func postForm(url: URL, params: [String: String], signal: CancellationToken? = nil) async throws -> HttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let form = params
        .map { "\($0.key)=\(urlEncode($0.value))" }
        .joined(separator: "&")
    request.httpBody = form.data(using: .utf8)

    let response = try await oauthData(for: request, signal: signal)
    let data = response.data
    let status = response.status
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

private func refreshOpenAICode(refreshToken: String, signal: CancellationToken? = nil) async throws -> OpenAICodexToken {
    let url = URL(string: "https://auth.openai.com/oauth/token")!
    let response = try await postForm(
        url: url,
        params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        ],
        signal: signal
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

// MARK: - OpenRouter OAuth

private let openRouterAuthorizeUrl = "https://openrouter.ai/auth"
private let openRouterTokenUrl = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
private let openRouterLoginTimeoutMs = 5 * 60 * 1000
private let openRouterTokenExchangeTimeoutMs = 30_000

private func exchangeOpenRouterAuthorizationCode(
    code: String,
    verifier: String,
    signal: CancellationToken?
) async throws -> OAuthCredentials {
    try throwIfOAuthCancelled(signal)
    var request = URLRequest(url: openRouterTokenUrl)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "code": code,
        "code_verifier": verifier,
        "code_challenge_method": "S256",
    ])

    let response = try await oauthData(
        for: request,
        signal: signal,
        timeoutMs: openRouterTokenExchangeTimeoutMs
    )
    let body = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
    guard (200..<300).contains(response.status) else {
        let detail = (body?["error_description"] as? String)
            ?? (body?["message"] as? String)
            ?? (body?["error"] as? String)
            ?? ((body?["error"] as? [String: Any])?["message"] as? String)
        let suffix = detail.map { ": \($0)" } ?? ""
        throw OAuthError.tokenExchangeFailed(
            "OpenRouter OAuth key exchange failed (HTTP \(response.status))\(suffix)"
        )
    }
    guard let key = body?["key"] as? String, !key.isEmpty else {
        throw OAuthError.invalidToken
    }
    return OAuthCredentials(
        refresh: "",
        access: key,
        expires: 9_007_199_254_740_991
    )
}

private enum OpenRouterManualResult: Sendable {
    case input(String)
    case failed(String)
}

#if canImport(Network)
private enum OpenRouterCallbackResult: Sendable {
    case credential(OAuthCredentials)
    case failed(String)
}

private actor OpenRouterCallbackServer {
    private let listener: NWListener
    private let callbackHost: String
    private let callbackPath: String
    private let verifier: String
    private let signal: CancellationToken?
    private let queue = DispatchQueue(label: "pi.oauth.openrouter")
    private var result: OpenRouterCallbackResult?
    private var claimed = false
    private var callbackUrlValue: String?

    private init(
        listener: NWListener,
        callbackHost: String,
        callbackPath: String,
        verifier: String,
        signal: CancellationToken?
    ) {
        self.listener = listener
        self.callbackHost = callbackHost
        self.callbackPath = callbackPath
        self.verifier = verifier
        self.signal = signal
    }

    static func start(
        callbackPath: String,
        verifier: String,
        signal: CancellationToken?
    ) async -> OpenRouterCallbackServer? {
        let configuredHost = ProcessInfo.processInfo.environment["PI_OAUTH_CALLBACK_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = configuredHost.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        let port = NWEndpoint.Port.any
        let listener: NWListener
        do {
            listener = try NWListener(using: oauthCallbackParameters(port: port), on: port)
        } catch {
            return nil
        }
        let server = OpenRouterCallbackServer(
            listener: listener,
            callbackHost: host,
            callbackPath: callbackPath,
            verifier: verifier,
            signal: signal
        )
        return await server.startListener() ? server : nil
    }

    func callbackUrl() -> String? {
        callbackUrlValue
    }

    func takeResult() -> OpenRouterCallbackResult? {
        defer { result = nil }
        return result
    }

    func handOffToManualInput() -> Bool {
        guard !claimed else { return false }
        claimed = true
        listener.cancel()
        return true
    }

    func close() {
        listener.cancel()
    }

    private func startListener() async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = LockedState(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self else { return }
                    Task {
                        await self.setCallbackUrl()
                        let shouldResume = resumed.withLock { value in
                            guard !value else { return false }
                            value = true
                            return true
                        }
                        if shouldResume { continuation.resume(returning: true) }
                    }
                case .failed:
                    let shouldResume = resumed.withLock { value in
                        guard !value else { return false }
                        value = true
                        return true
                    }
                    if shouldResume { continuation.resume(returning: false) }
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

    private func setCallbackUrl() {
        guard let port = listener.port else { return }
        callbackUrlValue = "http://\(callbackHost):\(port.rawValue)\(callbackPath)"
    }

    private final class ConnectionState: Sendable {
        let buffer = LockedState(Data())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        scheduleReceive(connection, state: ConnectionState())
    }

    private func scheduleReceive(_ connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            var requestLine: String?
            state.buffer.withLock { buffer in
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    requestLine = String(data: buffer[..<range.lowerBound], encoding: .utf8)
                }
            }
            if let requestLine {
                Task { await self?.handleRequestLine(requestLine, connection: connection) }
            } else if isComplete {
                connection.cancel()
            } else {
                Task { await self?.scheduleReceive(connection, state: state) }
            }
        }
    }

    private func handleRequestLine(_ line: String, connection: NWConnection) async {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://\(callbackHost)\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendResponse(connection, status: 400, body: "Bad request")
            return
        }
        guard components.path == callbackPath else {
            sendResponse(connection, status: 404, body: "OAuth callback route not found.")
            return
        }
        guard !claimed else {
            sendResponse(connection, status: 409, body: "This OAuth callback has already been used.")
            return
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? error
            claimed = true
            result = .failed("OpenRouter authorization failed: \(description)")
            sendResponse(connection, status: 400, body: "OpenRouter authorization was denied.")
            return
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            sendResponse(connection, status: 400, body: "OpenRouter returned no authorization code.")
            return
        }
        claimed = true
        do {
            let credential = try await exchangeOpenRouterAuthorizationCode(
                code: code,
                verifier: verifier,
                signal: signal
            )
            result = .credential(credential)
            sendResponse(connection, status: 200, body: "Signed in to OpenRouter. You may now close this page.")
        } catch {
            result = .failed(error.localizedDescription)
            sendResponse(connection, status: 502, body: "OpenRouter key exchange failed: \(error.localizedDescription)")
        }
    }

    private func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        let statusText = status == 200 ? "OK" : "Error"
        let header = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(header.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#else
private final class OpenRouterCallbackServer {
    static func start(
        callbackPath: String,
        verifier: String,
        signal: CancellationToken?
    ) async -> OpenRouterCallbackServer? { nil }
    func callbackUrl() -> String? { nil }
    func close() {}
}
#endif

/// Login with OpenRouter PKCE and exchange the code for a permanent API key.
public func loginOpenRouter(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    try throwIfOAuthCancelled(callbacks.signal)
    let pkce = try generatePKCE()
    let callbackPath = "/oauth/callback/\(UUID().uuidString.lowercased())"
    let server = await OpenRouterCallbackServer.start(
        callbackPath: callbackPath,
        verifier: pkce.verifier,
        signal: callbacks.signal
    )
    let callbackUrl = await server?.callbackUrl()
        ?? "http://127.0.0.1:1\(callbackPath)"

    var components = URLComponents(string: openRouterAuthorizeUrl)!
    components.queryItems = [
        URLQueryItem(name: "callback_url", value: callbackUrl),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    let authorizeUrl = components.url?.absoluteString ?? openRouterAuthorizeUrl
    if let onProgress = callbacks.onProgress {
        await onProgress("Listening for OpenRouter OAuth callback on \(callbackUrl)")
    }
    await callbacks.onAuth(OAuthAuthInfo(
        url: authorizeUrl,
        instructions: "Complete sign-in in your browser. If the browser is on another machine, paste the final redirect URL here."
    ))

    let manualResult = LockedState<OpenRouterManualResult?>(nil)
    let manualTask = Task {
        do {
            let input = try await callbacks.onPrompt(OAuthPrompt(
                message: "Complete sign-in in your browser, or paste the authorization code / redirect URL here:",
                placeholder: callbackUrl
            ))
            manualResult.withLock { $0 = .input(input) }
        } catch {
            manualResult.withLock { $0 = .failed(error.localizedDescription) }
        }
    }
    defer {
        manualTask.cancel()
        if let server { Task { await server.close() } }
    }

    let deadline = nowMs() + Double(openRouterLoginTimeoutMs)
    while nowMs() < deadline {
        try throwIfOAuthCancelled(callbacks.signal)

        #if canImport(Network)
        if let callback = await server?.takeResult() {
            switch callback {
            case .credential(let credential):
                manualTask.cancel()
                return credential
            case .failed(let message):
                throw OAuthError.tokenExchangeFailed(message)
            }
        }
        #endif

        let hasManualResult = manualResult.withLock { $0 != nil }
        #if canImport(Network)
        var canUseManualResult = true
        if hasManualResult, let server {
            canUseManualResult = await server.handOffToManualInput()
        }
        #else
        let canUseManualResult = true
        #endif
        if canUseManualResult, let manual = manualResult.withLock({ result -> OpenRouterManualResult? in
            defer { result = nil }
            return result
        }) {
            switch manual {
            case .failed(let message):
                throw OAuthError.tokenExchangeFailed(message)
            case .input(let input):
                let parsed = parseAuthorizationInput(input)
                guard let code = parsed.code, !code.isEmpty else {
                    throw OAuthError.missingAuthorizationCode
                }
                if let onProgress = callbacks.onProgress {
                    await onProgress("Exchanging authorization code for an API key...")
                }
                return try await exchangeOpenRouterAuthorizationCode(
                    code: code,
                    verifier: pkce.verifier,
                    signal: callbacks.signal
                )
            }
        }
        try await sleepMs(25, signal: callbacks.signal)
    }
    throw OAuthError.tokenExchangeFailed("OpenRouter OAuth login timed out")
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
private let copilotApiVersion = "2026-06-01"

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
    return try await pollOAuthDeviceCodeFlow(
        intervalSeconds: Double(intervalSeconds),
        expiresInSeconds: Double(expiresIn),
        signal: signal
    ) {
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

        let response = try await oauthData(for: request, signal: signal)
        let data = response.data

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .pending
        }

        if let accessToken = json["access_token"] as? String {
            return .complete(accessToken)
        }

        if let error = json["error"] as? String {
            if error == "authorization_pending" {
                return .pending
            }
            if error == "slow_down" {
                let interval = (json["interval"] as? NSNumber)?.doubleValue
                return .slowDown(intervalSeconds: interval)
            }
            return .failed("Device flow failed: \(error)")
        }

        return .pending
    }
}

private enum OAuthDevicePollResult<Value: Sendable>: Sendable {
    case pending
    case slowDown(intervalSeconds: Double?)
    case complete(Value)
    case failed(String)
}

/// Shared RFC 8628 polling driver used by GitHub Copilot, xAI, and Kimi Code.
private func pollOAuthDeviceCodeFlow<Value: Sendable>(
    intervalSeconds: Double,
    expiresInSeconds: Double,
    signal: CancellationToken?,
    poll: @escaping @Sendable () async throws -> OAuthDevicePollResult<Value>
) async throws -> Value {
    let deadline = nowMs() + expiresInSeconds * 1000
    var intervalMs = max(1, Int(floor(intervalSeconds * 1000)))

    let initialRemaining = max(0, Int(floor(deadline - nowMs())))
    if initialRemaining > 0 {
        try await sleepMs(min(intervalMs, initialRemaining), signal: signal)
    }

    while nowMs() < deadline {
        try throwIfOAuthCancelled(signal)
        switch try await poll() {
        case .complete(let value):
            return value
        case .pending:
            break
        case .slowDown(let serverInterval):
            if let serverInterval, serverInterval.isFinite, serverInterval > 0 {
                intervalMs = max(1, Int(floor(serverInterval * 1000)))
            } else {
                intervalMs += 5000
            }
        case .failed(let message):
            throw OAuthError.tokenExchangeFailed(message)
        }

        let remaining = max(0, Int(floor(deadline - nowMs())))
        if remaining > 0 {
            try await sleepMs(min(intervalMs, remaining), signal: signal)
        }
    }

    throw OAuthError.tokenExchangeFailed("Device flow timed out")
}

private func sleepMs(_ ms: Int, signal: CancellationToken?) async throws {
    try throwIfOAuthCancelled(signal)
    do { try await abortableSleep(ms: Double(ms), signal: signal) }
    catch { try throwIfOAuthCancelled(signal); throw error }
    try throwIfOAuthCancelled(signal)
}

/// Refresh GitHub Copilot token (exchange GitHub access token for Copilot token).
public func refreshGitHubCopilotToken(
    _ refreshToken: String,
    enterpriseDomain: String?,
    signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    var credentials = try await refreshGitHubCopilotAccessToken(
        refreshToken,
        enterpriseDomain: enterpriseDomain,
        signal: signal
    )
    credentials.availableModelIds = try await fetchAvailableGitHubCopilotModelIds(
        token: credentials.access,
        enterpriseDomain: enterpriseDomain,
        signal: signal
    )
    return credentials
}

private func refreshGitHubCopilotAccessToken(
    _ refreshToken: String,
    enterpriseDomain: String?,
    signal: CancellationToken?
) async throws -> OAuthCredentials {
    let domain = enterpriseDomain ?? "github.com"
    let urls = gitHubUrls(domain: domain)

    var request = URLRequest(url: urls.copilotTokenUrl)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(refreshToken)", forHTTPHeaderField: "Authorization")
    for (key, value) in copilotHeaders {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let response = try await oauthData(for: request, signal: signal)
    let data = response.data

    guard response.status == 200 else {
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
        expires: Double(expiresAt) * 1000 - defaultOAuthMinimumValidityMs,
        enterpriseUrl: enterpriseDomain
    )
}

func parseAvailableCopilotModelIds(_ raw: Any, allowPolicyFallback: Bool) throws -> [String] {
    try parseGitHubCopilotModelCatalog(raw, allowPolicyFallback: allowPolicyFallback).availableModelIds
}

struct GitHubCopilotModelCatalog: Sendable {
    let availableModelIds: [String]
    let policyModelIds: [String]
}

func parseGitHubCopilotModelCatalog(_ raw: Any, allowPolicyFallback: Bool) throws -> GitHubCopilotModelCatalog {
    guard let root = raw as? [String: Any], let data = root["data"] as? [Any] else {
        throw OAuthError.tokenExchangeFailed("Invalid Copilot models response")
    }
    let knownIds = Set(getModels(provider: .githubCopilot).map(\.id))
    let models: [(id: String, picker: Bool, policy: String?)] = data.compactMap { rawItem in
        guard let item = rawItem as? [String: Any], let id = item["id"] as? String else { return nil }
        let supports = (item["capabilities"] as? [String: Any])?["supports"] as? [String: Any]
        guard supports?["tool_calls"] as? Bool != false else { return nil }
        return (id, item["model_picker_enabled"] as? Bool == true, (item["policy"] as? [String: Any])?["state"] as? String)
    }
    let pickerIds = models.filter { $0.picker && $0.policy != "disabled" }.map(\.id)
    let usePolicyFallback = allowPolicyFallback && pickerIds.isEmpty
    return GitHubCopilotModelCatalog(
        availableModelIds: usePolicyFallback ? models.filter { $0.policy == "enabled" }.map(\.id) : pickerIds,
        policyModelIds: models.filter { $0.policy == "unconfigured" && knownIds.contains($0.id) && ($0.picker || usePolicyFallback) }.map(\.id)
    )
}

private func fetchAvailableGitHubCopilotModelIds(token: String, enterpriseDomain: String?, signal: CancellationToken?) async throws -> [String] {
    try await fetchGitHubCopilotModels(token: token, enterpriseDomain: enterpriseDomain, signal: signal, maxRetries: 0, maxElapsedMs: 0).availableModelIds
}

private func fetchGitHubCopilotModels(token: String, enterpriseDomain: String?, signal: CancellationToken?, maxRetries: Int, maxElapsedMs: Int) async throws -> GitHubCopilotModelCatalog {
    let baseUrl = getGitHubCopilotBaseUrl(token: token, enterpriseDomain: enterpriseDomain)
    guard let url = URL(string: "\(baseUrl)/models") else { throw OAuthError.invalidToken }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(copilotApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
    for (key, value) in copilotHeaders { request.setValue(value, forHTTPHeaderField: key) }
    let response = try await fetchCopilotWithRateLimitRetry(request, signal: signal, maxRetries: maxRetries, maxElapsedMs: maxElapsedMs)
    guard (200..<300).contains(response.status) else { throw copilotResponseError(response) }
    return try parseGitHubCopilotModelCatalog(JSONSerialization.jsonObject(with: response.data), allowPolicyFallback: baseUrl == "https://api.individual.githubcopilot.com")
}

/// Enable a model for the user's GitHub Copilot account.
private func enableGitHubCopilotModel(token: String, modelId: String, enterpriseDomain: String?, signal: CancellationToken?) async throws -> Bool {
    let baseUrl = getGitHubCopilotBaseUrl(token: token, enterpriseDomain: enterpriseDomain)
    guard let url = URL(string: "\(baseUrl)/models/\(modelId)/policy") else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("chat-policy", forHTTPHeaderField: "openai-intent")
    request.setValue("chat-policy", forHTTPHeaderField: "x-interaction-type")
    for (key, value) in copilotHeaders { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["state": "enabled"])
    let response: OAuthNetworkResponse
    do {
        response = try await fetchCopilotWithRateLimitRetry(request, signal: signal, maxRetries: 2, maxElapsedMs: 5_000)
    } catch {
        try throwIfOAuthCancelled(signal)
        return false
    }
    if response.status == 429 { throw copilotResponseError(response) }
    return (200..<300).contains(response.status)
}

func enableGitHubCopilotModels(_ modelIds: [String], signal: CancellationToken?, enable: @Sendable (String) async throws -> Bool) async throws -> [String] {
    var enabled: [String] = []
    for modelId in modelIds {
        do {
            if try await enable(modelId) { enabled.append(modelId) }
        } catch {
            try throwIfOAuthCancelled(signal)
            break
        }
    }
    return enabled
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
    var credentials = try await refreshGitHubCopilotAccessToken(
        githubAccessToken,
        enterpriseDomain: enterpriseDomain,
        signal: callbacks.signal
    )

    let models = try await fetchGitHubCopilotModels(token: credentials.access, enterpriseDomain: enterpriseDomain,
        signal: callbacks.signal, maxRetries: 2, maxElapsedMs: 5_000)
    var enabledModelIds: [String] = []
    if !models.policyModelIds.isEmpty {
        if let onProgress = callbacks.onProgress { await onProgress("Enabling models...") }
        let token = credentials.access
        enabledModelIds = try await enableGitHubCopilotModels(models.policyModelIds, signal: callbacks.signal) { modelId in
            try await enableGitHubCopilotModel(token: token, modelId: modelId, enterpriseDomain: enterpriseDomain, signal: callbacks.signal)
        }
    }
    var seen = Set<String>()
    credentials.availableModelIds = (models.availableModelIds + enabledModelIds).filter { seen.insert($0).inserted }

    return credentials
}

// MARK: - xAI OAuth

private let xaiClientId = "b1a00492-073a-47ea-816f-4c329264a828"
private let xaiScope = "openid profile email offline_access grok-cli:access api:access"
private let xaiDeviceCodeUrl = URL(string: "https://auth.x.ai/oauth2/device/code")!
private let xaiTokenUrl = URL(string: "https://auth.x.ai/oauth2/token")!
private let xaiDefaultTokenLifetimeSeconds = 3600.0
private let xaiDefaultPollIntervalSeconds = 5.0

private struct XaiDeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let intervalSeconds: Double?
    let expiresInSeconds: Double
}

private struct XaiHttpResponse {
    let status: Int
    let body: [String: Any]

    var isSuccessful: Bool {
        (200..<300).contains(status)
    }
}

private func xaiRequiredString(_ body: [String: Any], field: String) throws -> String {
    guard let value = body[field] as? String, !value.isEmpty else {
        throw OAuthError.tokenExchangeFailed("Invalid xAI OAuth response field: \(field)")
    }
    return value
}

private func xaiPositiveNumber(_ body: [String: Any], field: String) throws -> Double {
    guard let value = body[field] as? NSNumber,
          value.doubleValue.isFinite,
          value.doubleValue > 0 else {
        throw OAuthError.tokenExchangeFailed("Invalid xAI OAuth response field: \(field)")
    }
    return value.doubleValue
}

private func validateXaiVerificationUri(_ raw: String) throws -> String {
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
        throw OAuthError.tokenExchangeFailed("Untrusted verification URI in xAI OAuth response")
    }
    return url.absoluteString
}

private func postXaiForm(
    url: URL,
    params: [String: String],
    signal: CancellationToken? = nil
) async throws -> XaiHttpResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    var components = URLComponents()
    components.queryItems = params.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
    }
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

    let response = try await oauthData(for: request, signal: signal)
    let data = response.data
    let status = response.status
    guard let json = try? JSONSerialization.jsonObject(with: data),
          let body = json as? [String: Any] else {
        throw OAuthError.tokenExchangeFailed("xAI OAuth returned invalid JSON (HTTP \(status))")
    }
    return XaiHttpResponse(status: status, body: body)
}

private func xaiRequestFailure(action: String, response: XaiHttpResponse) -> String {
    let error = response.body["error"] as? String
    let description = response.body["error_description"] as? String
    let detail = [error, description].compactMap { $0 }.joined(separator: ": ")
    let suffix = detail.isEmpty ? "" : ": \(detail)"
    return "xAI OAuth \(action) failed (HTTP \(response.status))\(suffix)"
}

private func parseXaiDeviceCode(_ body: [String: Any]) throws -> XaiDeviceCode {
    let interval = (body["interval"] as? NSNumber)?.doubleValue
    let intervalSeconds = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let verificationUriComplete: String?
    if let raw = body["verification_uri_complete"] as? String, !raw.isEmpty {
        verificationUriComplete = try validateXaiVerificationUri(raw)
    } else {
        verificationUriComplete = nil
    }

    return try XaiDeviceCode(
        deviceCode: xaiRequiredString(body, field: "device_code"),
        userCode: xaiRequiredString(body, field: "user_code"),
        verificationUri: validateXaiVerificationUri(xaiRequiredString(body, field: "verification_uri")),
        verificationUriComplete: verificationUriComplete,
        intervalSeconds: intervalSeconds,
        expiresInSeconds: xaiPositiveNumber(body, field: "expires_in")
    )
}

private func xaiCredentials(
    from body: [String: Any],
    previousRefreshToken: String? = nil
) throws -> OAuthCredentials {
    let accessToken = try xaiRequiredString(body, field: "access_token")
    let refreshToken: String
    if body["refresh_token"] == nil, let previousRefreshToken {
        refreshToken = previousRefreshToken
    } else {
        refreshToken = try xaiRequiredString(body, field: "refresh_token")
    }
    let expiresIn = try body["expires_in"] == nil
        ? xaiDefaultTokenLifetimeSeconds
        : xaiPositiveNumber(body, field: "expires_in")
    return OAuthCredentials(
        refresh: refreshToken,
        access: accessToken,
        expires: nowMs() + expiresIn * 1000 - defaultOAuthMinimumValidityMs
    )
}

private func requestXaiDeviceCode(signal: CancellationToken?) async throws -> XaiDeviceCode {
    let response = try await postXaiForm(
        url: xaiDeviceCodeUrl,
        params: [
            "client_id": xaiClientId,
            "scope": xaiScope,
            "referrer": "pi",
        ],
        signal: signal
    )
    guard response.isSuccessful else {
        throw OAuthError.tokenExchangeFailed(xaiRequestFailure(action: "device authorization", response: response))
    }
    return try parseXaiDeviceCode(response.body)
}

private func pollForXaiTokens(
    device: XaiDeviceCode,
    signal: CancellationToken?
) async throws -> OAuthCredentials {
    return try await pollOAuthDeviceCodeFlow(
        intervalSeconds: device.intervalSeconds ?? xaiDefaultPollIntervalSeconds,
        expiresInSeconds: device.expiresInSeconds,
        signal: signal
    ) {
        let response = try await postXaiForm(
            url: xaiTokenUrl,
            params: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": xaiClientId,
                "device_code": device.deviceCode,
            ],
            signal: signal
        )

        if response.isSuccessful {
            return try .complete(xaiCredentials(from: response.body))
        }

        switch response.body["error"] as? String {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(intervalSeconds: (response.body["interval"] as? NSNumber)?.doubleValue)
        case "access_denied", "authorization_denied":
            return .failed("xAI device authorization was denied")
        case "expired_token":
            return .failed("xAI device code expired")
        default:
            return .failed(xaiRequestFailure(action: "device token polling", response: response))
        }
    }
}

/// Login with xAI OAuth using the RFC 8628 device-code flow.
public func loginXai(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    if callbacks.signal?.isCancelled == true {
        throw OAuthError.cancelled
    }

    let device = try await requestXaiDeviceCode(signal: callbacks.signal)
    await callbacks.onAuth(OAuthAuthInfo(
        url: device.verificationUriComplete ?? device.verificationUri,
        instructions: "Enter code: \(device.userCode)"
    ))
    return try await pollForXaiTokens(device: device, signal: callbacks.signal)
}

/// Refresh an xAI OAuth token, retaining the old refresh token when xAI does not rotate it.
public func refreshXaiToken(_ refreshToken: String, signal: CancellationToken? = nil) async throws -> OAuthCredentials {
    let response = try await postXaiForm(
        url: xaiTokenUrl,
        params: [
            "grant_type": "refresh_token",
            "client_id": xaiClientId,
            "refresh_token": refreshToken,
        ],
        signal: signal
    )
    guard response.isSuccessful else {
        throw OAuthError.refreshFailed(xaiRequestFailure(action: "token refresh", response: response))
    }
    return try xaiCredentials(from: response.body, previousRefreshToken: refreshToken)
}

// MARK: - Kimi Code OAuth

private let kimiCodingClientId = "17e5f671-d194-4dfb-9706-5516cb48c098"
private let kimiCodingDefaultOAuthHost = "https://auth.kimi.com"
private let kimiCodingDefaultPollIntervalSeconds = 5.0
private let kimiCodingDefaultDeviceTimeoutSeconds = 15.0 * 60.0
private let kimiCodingRequestTimeoutMs = 30_000
private let kimiCodingRefreshMaxRetries = 3

private struct KimiCodingDeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let intervalSeconds: Double
    let expiresInSeconds: Double
}

private func kimiCodingOAuthHost() -> String {
    let env = ProcessInfo.processInfo.environment
    let override = env["KIMI_CODE_OAUTH_HOST"] ?? env["KIMI_OAUTH_HOST"]
    let host = override?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (host.flatMap { $0.isEmpty ? nil : $0 } ?? kimiCodingDefaultOAuthHost)
        .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
}

private func trustedKimiHttpUrl(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
        return nil
    }
    return url.absoluteString
}

private func kimiFormBody(_ fields: [String: String]) -> Data? {
    var components = URLComponents()
    components.queryItems = fields.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
    }
    return components.percentEncodedQuery?.data(using: .utf8)
}

private func requestKimiCoding(
    path: String,
    fields: [String: String],
    signal: CancellationToken?
) async throws -> OAuthNetworkResponse {
    guard let url = URL(string: kimiCodingOAuthHost() + path) else {
        throw OAuthError.tokenExchangeFailed("Invalid Kimi Code OAuth host")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(getPiUserAgent(), forHTTPHeaderField: "User-Agent")
    request.httpBody = kimiFormBody(fields)
    return try await oauthData(for: request, signal: signal, timeoutMs: kimiCodingRequestTimeoutMs)
}

private func kimiJson(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func startKimiCodingDeviceAuthorization(
    signal: CancellationToken?
) async throws -> KimiCodingDeviceAuthorization {
    let response = try await requestKimiCoding(
        path: "/api/oauth/device_authorization",
        fields: ["client_id": kimiCodingClientId],
        signal: signal
    )
    guard (200..<300).contains(response.status) else {
        let detail = String(data: response.data, encoding: .utf8) ?? ""
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        throw OAuthError.tokenExchangeFailed(
            "Kimi Code device authorization failed with status \(response.status)\(suffix)"
        )
    }

    let json = kimiJson(response.data)
    guard let deviceCode = json?["device_code"] as? String,
          !deviceCode.isEmpty,
          let userCode = json?["user_code"] as? String,
          !userCode.isEmpty,
          let verificationUri = trustedKimiHttpUrl(json?["verification_uri"]),
          let verificationUriComplete = trustedKimiHttpUrl(json?["verification_uri_complete"]) else {
        throw OAuthError.tokenExchangeFailed("Invalid Kimi Code device authorization response")
    }
    let interval = (json?["interval"] as? NSNumber)?.doubleValue
    let expiresIn = (json?["expires_in"] as? NSNumber)?.doubleValue
    return KimiCodingDeviceAuthorization(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: verificationUri,
        verificationUriComplete: verificationUriComplete,
        intervalSeconds: interval.map { $0.isFinite && $0 > 0 ? $0 : kimiCodingDefaultPollIntervalSeconds }
            ?? kimiCodingDefaultPollIntervalSeconds,
        expiresInSeconds: expiresIn.map { $0.isFinite && $0 > 0 ? $0 : kimiCodingDefaultDeviceTimeoutSeconds }
            ?? kimiCodingDefaultDeviceTimeoutSeconds
    )
}

private func kimiCodingCredentials(
    _ json: [String: Any]?,
    operation: String
) throws -> OAuthCredentials {
    guard let access = json?["access_token"] as? String,
          !access.isEmpty,
          let refresh = json?["refresh_token"] as? String,
          !refresh.isEmpty,
          let expiresIn = (json?["expires_in"] as? NSNumber)?.doubleValue,
          expiresIn.isFinite,
          expiresIn > 0 else {
        throw OAuthError.tokenExchangeFailed("Kimi Code token \(operation) response missing fields")
    }
    return OAuthCredentials(
        refresh: refresh,
        access: access,
        expires: nowMs() + expiresIn * 1000
    )
}

private func pollForKimiCodingToken(
    device: KimiCodingDeviceAuthorization,
    signal: CancellationToken?
) async throws -> OAuthCredentials {
    try await pollOAuthDeviceCodeFlow(
        intervalSeconds: device.intervalSeconds,
        expiresInSeconds: device.expiresInSeconds,
        signal: signal
    ) {
        let response = try await requestKimiCoding(
            path: "/api/oauth/token",
            fields: [
                "client_id": kimiCodingClientId,
                "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ],
            signal: signal
        )
        if response.status >= 500 {
            let detail = String(data: response.data, encoding: .utf8) ?? ""
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return .failed("Kimi Code device token request failed with status \(response.status)\(suffix)")
        }

        let json = kimiJson(response.data)
        if (200..<300).contains(response.status), json?["access_token"] is String {
            do {
                return .complete(try kimiCodingCredentials(json, operation: "poll"))
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        switch json?["error"] as? String {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(intervalSeconds: (json?["interval"] as? NSNumber)?.doubleValue)
        case "expired_token":
            return .failed("Kimi Code device authorization expired. Please restart login.")
        case "access_denied":
            return .failed("Kimi Code login was denied.")
        case let error?:
            let description = json?["error_description"] as? String
            let suffix = description.map { ": \(error): \($0)" } ?? ": \(error)"
            return .failed("Kimi Code device token request failed (status \(response.status))\(suffix)")
        case nil:
            return .failed("Kimi Code device token request failed (status \(response.status))")
        }
    }
}

/// Login with a Kimi Code subscription by using the RFC 8628 device flow.
public func loginKimiCoding(_ callbacks: OAuthLoginCallbacks) async throws -> OAuthCredentials {
    try throwIfOAuthCancelled(callbacks.signal)
    let device = try await startKimiCodingDeviceAuthorization(signal: callbacks.signal)
    await callbacks.onAuth(OAuthAuthInfo(
        url: device.verificationUriComplete,
        instructions: "Enter code: \(device.userCode)"
    ))
    return try await pollForKimiCodingToken(device: device, signal: callbacks.signal)
}

/// Refresh a Kimi Code OAuth token, with bounded retries for transient failures.
public func refreshKimiCodingToken(
    _ refreshToken: String,
    signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    var lastError: Error?
    for attempt in 0...kimiCodingRefreshMaxRetries {
        if attempt > 0 {
            try await sleepMs(1000 * (1 << (attempt - 1)), signal: signal)
        }
        try throwIfOAuthCancelled(signal)

        let response: OAuthNetworkResponse
        do {
            response = try await requestKimiCoding(
                path: "/api/oauth/token",
                fields: [
                    "client_id": kimiCodingClientId,
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                ],
                signal: signal
            )
        } catch {
            if signal?.isCancelled == true {
                throw OAuthError.cancelled
            }
            lastError = error
            continue
        }

        let json = kimiJson(response.data)
        if (200..<300).contains(response.status) {
            return try kimiCodingCredentials(json, operation: "refresh")
        }
        if response.status == 401 || response.status == 403 || (json?["error"] as? String) == "invalid_grant" {
            let description = (json?["error_description"] as? String).map { ": \($0)" } ?? ""
            throw OAuthError.refreshFailed(
                "Kimi Code token refresh unauthorized (status \(response.status))\(description)"
            )
        }
        if (response.status == 429 || response.status >= 500), attempt < kimiCodingRefreshMaxRetries {
            lastError = OAuthError.refreshFailed("Kimi Code token refresh failed with status \(response.status)")
            continue
        }
        let detail = String(data: response.data, encoding: .utf8) ?? ""
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        throw OAuthError.refreshFailed(
            "Kimi Code token refresh failed with status \(response.status)\(suffix)"
        )
    }
    throw lastError ?? OAuthError.refreshFailed("Kimi Code token refresh failed")
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
public func refreshGoogleGeminiCliToken(
    _ refreshToken: String,
    projectId: String,
    signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    let url = URL(string: "https://oauth2.googleapis.com/token")!
    let response = try await postForm(
        url: url,
        params: [
            "client_id": googleGeminiCliClientId(),
            "client_secret": googleGeminiCliClientSecret(),
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ],
        signal: signal
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
        expires: nowMs() + Double(expiresIn) * 1000 - defaultOAuthMinimumValidityMs,
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
        expires: nowMs() + Double(expiresIn) * 1000 - defaultOAuthMinimumValidityMs,
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
public func refreshAntigravityToken(
    _ refreshToken: String,
    projectId: String,
    signal: CancellationToken? = nil
) async throws -> OAuthCredentials {
    let url = URL(string: "https://oauth2.googleapis.com/token")!
    let response = try await postForm(
        url: url,
        params: [
            "client_id": antigravityClientId(),
            "client_secret": antigravityClientSecret(),
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ],
        signal: signal
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
        expires: nowMs() + Double(expiresIn) * 1000 - defaultOAuthMinimumValidityMs,
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
        expires: nowMs() + Double(expiresIn) * 1000 - defaultOAuthMinimumValidityMs,
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

private func copilotResponseError(_ response: OAuthNetworkResponse) -> OAuthError {
    OAuthError.refreshFailed("\(response.status): \(String(data: response.data, encoding: .utf8) ?? "")")
}

func copilotRetryDelayMs(retryAfter: String?, retry: Int, now: Double) -> Double? {
    guard let raw = retryAfter, !raw.isEmpty else { return 500 * pow(2, Double(retry)) }
    // Number.parseFloat accepts a numeric prefix. Match this before HTTP-date parsing.
    let pattern = #"^[\s]*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"#
    let seconds: Double? = raw.range(of: pattern, options: .regularExpression).flatMap { Double(raw[$0].trimmingCharacters(in: .whitespacesAndNewlines)) }
    let delay: Double
    if let seconds { delay = seconds * 1000 }
    else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        delay = date.timeIntervalSince1970 * 1000 - now
    }
    return delay.isFinite ? max(0, delay) : nil
}

private func fetchCopilotWithRateLimitRetry(_ request: URLRequest, signal: CancellationToken?, maxRetries: Int, maxElapsedMs: Int) async throws -> OAuthNetworkResponse {
    try await copilotRateLimitRetry(signal: signal, maxRetries: maxRetries, maxElapsedMs: maxElapsedMs,
        request: { timeout in try await oauthData(for: request, signal: signal, timeoutMs: timeout) })
}

func copilotRateLimitRetry(
    signal: CancellationToken?,
    maxRetries: Int,
    maxElapsedMs: Int,
    now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
    sleep: @Sendable (Double, CancellationToken?) async throws -> Void = { try await abortableSleep(ms: $0, signal: $1) },
    request: @Sendable (Int) async throws -> OAuthNetworkResponse
) async throws -> OAuthNetworkResponse {
    let deadline = maxRetries > 0 && maxElapsedMs > 0 ? now() + Double(maxElapsedMs) : nil
    for retry in 0...max(0, maxRetries) {
        try throwIfOAuthCancelled(signal)
        let remaining = deadline.map { $0 - now() }
        if let remaining, remaining <= 0 { throw OAuthError.tokenExchangeFailed("OAuth request timed out") }
        let timeout = min(5000, remaining.map { max(1, Int(ceil($0))) } ?? 5000)
        let response = try await request(timeout)
        guard response.status == 429, retry < maxRetries else { return response }
        let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
        guard let delay = copilotRetryDelayMs(retryAfter: retryAfter, retry: retry, now: now()) else { return response }
        if let deadline, delay >= deadline - now() { return response }
        try await sleep(delay, signal)
    }
    throw OAuthError.tokenExchangeFailed("Copilot request failed")
}
