import Foundation
import CryptoKit
import PiSwiftMCP
#if os(macOS)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Upstream stores the complete registration response, including its redirect URIs.
// PiSwiftMCP's wire client-information value keeps metadata outside its CodingKeys.
private struct StoredMcpOAuthClientInformation: Codable, Sendable {
    var information: McpOAuthClientInformation

    init(_ information: McpOAuthClientInformation) { self.information = information }

    init(from decoder: any Decoder) throws {
        information = try McpOAuthClientInformation(from: decoder)
        information.metadata = try? McpOAuthClientMetadata(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try information.encode(to: encoder)
        try information.metadata?.encode(to: encoder)
    }
}

private struct StoredMcpOAuthState: Codable, Sendable {
    var serverUrl: String
    var clientInformation: StoredMcpOAuthClientInformation?
    var tokens: McpOAuthTokens?
    var tokensExpireAt: Date?
    var codeVerifier: String?
    var oauthState: String?
    var discovery: McpOAuthDiscoveryState?

    init(_ state: McpOAuthState) {
        serverUrl = state.serverURL
        clientInformation = state.clientInformation.map(StoredMcpOAuthClientInformation.init)
        tokens = state.tokens
        tokensExpireAt = state.tokensExpireAt
        codeVerifier = state.codeVerifier
        oauthState = state.oauthState
        discovery = state.discovery
    }

    var state: McpOAuthState {
        McpOAuthState(serverURL: serverUrl, clientInformation: clientInformation?.information,
            tokens: tokens, tokensExpireAt: tokensExpireAt, codeVerifier: codeVerifier,
            oauthState: oauthState, discovery: discovery)
    }
}

private actor McpRefreshGate {
    private var held: Set<String> = []

    func acquire(_ key: String) async throws {
        while held.contains(key) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        held.insert(key)
    }

    func release(_ key: String) { held.remove(key) }
}

/// Shared `mcp-auth.json` storage. A file lock protects each read and write.
public final class McpOAuthCredentialStore: Sendable {
    private static let refreshGate = McpRefreshGate()
    private let backend: any AuthStorageBackend
    private let lockDirectory: URL?

    public init(agentDir: URL) {
        backend = FileAuthStorageBackend(agentDir.appendingPathComponent("mcp-auth.json").path)
        lockDirectory = agentDir
    }

    public init(backend: any AuthStorageBackend, lockDirectory: URL? = nil) {
        self.backend = backend
        self.lockDirectory = lockDirectory
    }

    public func forServer(name: String, url: URL) -> any McpOAuthStateStore {
        ServerStore(owner: self, key: Self.key(name: name, url: url), legacyKey: Self.key(url))
    }

    /// Load state and take over a legacy URL-only entry, if present.
    public func state(name: String, url: URL) throws -> McpOAuthState? {
        try load(key: Self.key(name: name, url: url), legacyKey: Self.key(url))
    }

    /// Read tokens without taking over a legacy entry.
    public func tokens(name: String, url: URL) throws -> McpOAuthTokens? {
        let key = Self.key(name: name, url: url)
        let legacyKey = Self.key(url)
        return try backend.withLock { current in
            let states = try Self.parse(current)
            return AuthStorageLockResult(result: (states[key] ?? states[legacyKey])?.tokens)
        }
    }

    /// Remove named state, or the legacy state this server would take over.
    @discardableResult
    public func remove(name: String, url: URL) throws -> Bool {
        let key = Self.key(name: name, url: url)
        let legacyKey = Self.key(url)
        return try backend.withLock { current in
            var states = try Self.parse(current)
            let stored = states[key] != nil ? key : legacyKey
            let removed = states.removeValue(forKey: stored) != nil
            return AuthStorageLockResult(result: removed, next: removed ? try Self.encode(states) : nil)
        }
    }

    // Compatibility for hosts built against the URL-only API. New callers must supply the name.
    public func forServer(_ serverURL: URL) -> any McpOAuthStateStore { forServer(name: "", url: serverURL) }
    public func state(for serverURL: URL) throws -> McpOAuthState? { try state(name: "", url: serverURL) }
    public func tokens(for serverURL: URL) throws -> McpOAuthTokens? { try tokens(name: "", url: serverURL) }
    @discardableResult
    public func remove(_ serverURL: URL) throws -> Bool { try remove(name: "", url: serverURL) }

    public func withRefreshLock<Result: Sendable>(
        name: String, url: URL, _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let key = Self.key(name: name, url: url)
        try await Self.refreshGate.acquire(key)
        do {
            let value: Result
            if let lockDirectory {
                let digest = SHA256.hash(data: Data(key.utf8))
                let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
                let lock = FileAuthStorageBackend(lockDirectory.appendingPathComponent("mcp-auth-refresh-\(hash)").path)
                value = try await lock.withLockAsync { _ in
                    AuthStorageLockResult(result: try await operation())
                }
            } else {
                value = try await operation()
            }
            await Self.refreshGate.release(key)
            return value
        } catch {
            await Self.refreshGate.release(key)
            throw error
        }
    }

    public func withRefreshLock<Result: Sendable>(
        for serverURL: URL, _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withRefreshLock(name: "", url: serverURL, operation)
    }

    private func load(key: String, legacyKey: String) throws -> McpOAuthState? {
        try backend.withLock { current in
            var states = try Self.parse(current)
            if let stored = states[key] { return AuthStorageLockResult(result: stored.state) }
            guard let legacy = states.removeValue(forKey: legacyKey) else {
                return AuthStorageLockResult(result: nil)
            }
            states[key] = legacy
            return AuthStorageLockResult(result: legacy.state, next: try Self.encode(states))
        }
    }

    private static func key(name: String, url: URL) -> String {
        name.isEmpty ? key(url) : mcpNamespace(name) + "|" + key(url)
    }

    private func save(_ state: McpOAuthState, key: String) throws {
        try backend.withLock { current in
            var states = try Self.parse(current)
            states[key] = StoredMcpOAuthState(state)
            return AuthStorageLockResult(result: (), next: try Self.encode(states))
        }
    }

    private static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.path.isEmpty == true { components?.path = "/" }
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private static func parse(_ content: String?) throws -> [String: StoredMcpOAuthState] {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let data = Data(content.utf8)
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([String: StoredMcpOAuthState].self, from: data)
    }

    private static func encode(_ states: [String: StoredMcpOAuthState]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(states), as: UTF8.self) + "\n"
    }

    private struct ServerStore: McpOAuthStateStore {
        let owner: McpOAuthCredentialStore
        let key: String
        let legacyKey: String

        func load() async throws -> McpOAuthState? {
            try owner.load(key: key, legacyKey: legacyKey)
        }

        func save(_ state: McpOAuthState) async throws {
            try owner.save(state, key: key)
        }
    }
}

private struct TimedMcpOAuthHTTPClient: McpOAuthHTTPClient {
    let base: any McpOAuthHTTPClient

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var bounded = request
        bounded.timeoutInterval = 15
        return try await base.send(bounded)
    }
}

private let mcpMissingClientMetadataDocument = "oauth.clientRegistration \"cimd\" needs a Client ID Metadata Document URL from the host application"

/// The host document must list the presenter's redirect URI. The library cannot check its contents.
private func mcpClientMetadataDocumentProvider(
    settings: McpOAuthConfig, url: URL?, redirectURL: URL
) -> McpOAuthClientMetadataDocumentProvider? {
    guard settings.clientRegistration == .cimd else { return nil }
    return { metadata in
        guard let url else { throw McpRuntimeError.invalidConfig(mcpMissingClientMetadataDocument) }
        return try McpOAuthClientMetadataDocument.staticDocument(
            url: url, redirectURL: redirectURL, metadata: metadata)
    }
}

/// Sends stored tokens and refreshes them before expiry or after HTTP 401.
public actor McpServerAuthProvider: McpAuthProvider {
    private let serverURL: URL
    private let name: String
    private let credentials: McpOAuthCredentialStore
    private let settingsResolver: @Sendable () throws -> McpOAuthConfig
    private let http: any McpOAuthHTTPClient
    private let clientMetadataDocumentURL: URL?
    private var refreshTask: Task<Void, Error>?
    public private(set) var challenge: McpOAuthChallenge?

    public init(name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: McpOAuthConfig = .init(),
                clientMetadataDocumentURL: URL? = nil,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.serverURL = serverURL
        self.name = name
        self.credentials = credentials
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.settingsResolver = { settings }
        self.http = TimedMcpOAuthHTTPClient(base: http)
    }

    public init(name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: @escaping @Sendable () throws -> McpOAuthConfig,
                clientMetadataDocumentURL: URL? = nil,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.serverURL = serverURL
        self.name = name
        self.credentials = credentials
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.settingsResolver = settings
        self.http = TimedMcpOAuthHTTPClient(base: http)
    }

    public func token() async throws -> String? {
        _ = try? await refreshTask?.value
        let state = try credentials.state(name: name, url: serverURL)
        let token = state?.tokens?.accessToken
        if let expiry = state?.tokensExpireAt,
           expiry.timeIntervalSinceNow <= 30,
           state?.tokens?.refreshToken != nil {
            try? await refresh(staleToken: token, challenge: nil)
            return try credentials.tokens(name: name, url: serverURL)?.accessToken
        }
        return token
    }

    public func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        let parsed = McpOAuthDiscovery.parseWWWAuthenticate(challenge)
        self.challenge = parsed
        if parsed.error == "insufficient_scope" { throw McpOAuthError.authorizationRequired }
        try await refresh(staleToken: rejectedToken, challenge: parsed)
    }

    public func settled() async { _ = try? await refreshTask?.value }

    private func refresh(staleToken: String?, challenge: McpOAuthChallenge?) async throws {
        if refreshTask == nil {
            let credentials = self.credentials
            let serverURL = self.serverURL
            let name = self.name
            let settingsResolver = self.settingsResolver
            let http = self.http
            let clientMetadataDocumentURL = self.clientMetadataDocumentURL
            refreshTask = Task {
                try await credentials.withRefreshLock(name: name, url: serverURL) {
                    let stored = try credentials.state(name: name, url: serverURL)
                    if stored?.tokens?.accessToken != staleToken { return }
                    guard stored?.tokens?.refreshToken != nil else { throw McpOAuthError.authorizationRequired }
                    let settings = try settingsResolver()
                    let registered = stored?.clientInformation?.metadata?.redirectURIs.first
                    let redirect = settings.callbackUrl ?? registered ?? "http://127.0.0.1/callback"
                    guard let redirectURL = URL(string: redirect) else { throw McpOAuthError.invalidRedirect }
                    let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
                        clientMetadata: McpOAuthClientMetadata(clientName: settings.clientName ?? "pi"),
                        clientID: settings.clientId, clientSecret: settings.clientSecret,
                        clientMetadataDocument: mcpClientMetadataDocumentProvider(
                            settings: settings, url: clientMetadataDocumentURL, redirectURL: redirectURL),
                        store: credentials.forServer(name: name, url: serverURL), onRedirect: { _ in })
                    let result = try await McpOAuthFlow.authorize(provider: provider,
                        options: McpOAuthFlowOptions(serverURL: serverURL,
                            scope: challenge?.scope, resourceMetadataURL: challenge?.resourceMetadataURL,
                            authorizationServerMetadataURL: settings.authServerMetadataUrl.flatMap(URL.init(string:))),
                        http: http)
                    if result == .redirect { throw McpOAuthError.authorizationRequired }
                }
            }
        }
        defer { refreshTask = nil }
        try await refreshTask?.value
    }
}

/// Run interactive OAuth for one server. The presenter supplies macOS loopback or an iOS host flow.
public func signInMcpServer(
    name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore, settings: McpOAuthConfig = .init(),
    challenge: McpOAuthChallenge? = nil, presenter: any McpSignInPresenter,
    clientMetadataDocumentURL: URL? = nil,
    http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
) async throws {
    if settings.clientRegistration == .cimd, clientMetadataDocumentURL == nil {
        throw McpRuntimeError.invalidConfig(mcpMissingClientMetadataDocument)
    }
    let store = credentials.forServer(name: name, url: serverURL)
    let previous = try await store.load()
    if var stored = previous {
        stored.oauthState = nil
        try await store.save(stored)
    }
    var generator = SystemRandomNumberGenerator()
    let state = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    let redirectURL = try await presenter.redirectURL(for: state)
    if let expected = settings.callbackUrl {
        let parts = URLComponents(string: expected)
        let actual = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        if parts?.scheme != actual?.scheme || parts?.host != actual?.host ||
            parts?.path != actual?.path ||
            (parts?.port != nil && parts?.port != actual?.port) {
            throw McpOAuthError.invalidRedirect
        }
    }
    if let expectedPort = settings.callbackPort, redirectURL.port != expectedPort {
        throw McpOAuthError.invalidRedirect
    }
    if var stored = try await store.load() {
        let keepClient = settings.clientId != nil || (settings.clientRegistration == .cimd
            ? stored.clientInformation == nil
            : stored.clientInformation?.metadata?.redirectURIs.contains(redirectURL.absoluteString) == true)
        if !keepClient {
            stored.clientInformation = nil
            stored.tokens = nil
            stored.tokensExpireAt = nil
            try await store.save(stored)
        }
    }
    let stepUp = challenge?.error == "insufficient_scope"
    let challengedScope = stepUp
        ? McpOAuthFlow.stepUpScope(granted: previous?.tokens?.scope, challenged: challenge?.scope)
        : challenge?.scope
    let combinedScope = [settings.scope, challengedScope].compactMap { $0 }
        .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    var seen: Set<String> = []
    let scope = combinedScope.filter { seen.insert($0).inserted }.joined(separator: " ")
    let capture = McpSignInCapture()
    let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
        clientMetadata: McpOAuthClientMetadata(clientName: settings.clientName ?? "pi"),
        clientID: settings.clientId, clientSecret: settings.clientSecret,
        clientMetadataDocument: mcpClientMetadataDocumentProvider(
            settings: settings, url: clientMetadataDocumentURL, redirectURL: redirectURL),
        initialState: state, store: store,
        onRedirect: { url in
            let callback = try await presenter.present(authorizationURL: url, state: state)
            await capture.save(callback)
        })
    let options = McpOAuthFlowOptions(serverURL: serverURL,
        scope: scope.isEmpty ? nil : scope,
        resourceMetadataURL: challenge?.resourceMetadataURL,
        authorizationServerMetadataURL: settings.authServerMetadataUrl.flatMap(URL.init(string:)),
        skipRefresh: stepUp)
    do {
        let result = try await McpOAuthFlow.authorize(provider: provider,
            options: options, http: TimedMcpOAuthHTTPClient(base: http))
        if result == .redirect {
            guard let callback = await capture.url else { throw McpOAuthError.invalidRedirect }
            _ = try await McpOAuthFlow.completeRedirect(provider: provider,
                callbackURL: callback, options: options,
                http: TimedMcpOAuthHTTPClient(base: http))
        }
        await presenter.cancel()
    } catch {
        await presenter.cancel()
        throw error
    }
}

private actor McpSignInCapture {
    var url: URL?
    func save(_ value: URL) { url = value }
}

#if os(macOS)
/// Make a loopback presenter for the callback address in an MCP server config.
/// The callback timeout is in seconds. It must be finite and greater than zero.
public func makeMcpMacOSSignInPresenter(
    settings: McpOAuthConfig,
    callbackTimeoutSeconds: TimeInterval = 300,
    pasteRedirectURL: (@Sendable () async throws -> String)? = nil,
    openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void = { url in
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened { throw McpOAuthError.invalidRedirect }
    }
) throws -> McpMacOSSignInPresenter {
    guard callbackTimeoutSeconds.isFinite, callbackTimeoutSeconds > 0 else {
        throw McpOAuthError.invalidMetadata("callbackTimeoutSeconds")
    }
    let parts = URLComponents(string: settings.callbackUrl ?? "http://127.0.0.1/callback")
    let port = settings.callbackPort ?? parts?.port ?? 0
    guard let redirectHost = parts?.host, (0...65535).contains(port) else {
        throw McpOAuthError.invalidRedirect
    }
    let cleanHost = redirectHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let listenHost = cleanHost == "localhost" ? "127.0.0.1" : cleanHost
    let path = parts?.path.isEmpty == false ? parts!.path : "/callback"
    return McpMacOSSignInPresenter(callbackHost: listenHost,
        callbackPort: UInt16(port), callbackPath: path, redirectHost: cleanHost,
        callbackTimeoutSeconds: callbackTimeoutSeconds,
        pasteRedirectURL: pasteRedirectURL, openAuthorizationURL: openAuthorizationURL)
}
#endif
