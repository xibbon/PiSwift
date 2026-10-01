import Foundation
import CryptoKit
import PiSwiftMCP
#if os(macOS)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct StoredMcpOAuthState: Codable, Sendable {
    var serverUrl: String
    var clientInformation: McpOAuthClientInformation?
    var tokens: McpOAuthTokens?
    var tokensExpireAt: Date?
    var codeVerifier: String?
    var oauthState: String?
    var discovery: McpOAuthDiscoveryState?

    init(_ state: McpOAuthState) {
        serverUrl = state.serverURL
        clientInformation = state.clientInformation
        tokens = state.tokens
        tokensExpireAt = state.tokensExpireAt
        codeVerifier = state.codeVerifier
        oauthState = state.oauthState
        discovery = state.discovery
    }

    var state: McpOAuthState {
        McpOAuthState(serverURL: serverUrl, clientInformation: clientInformation,
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

    public func forServer(_ serverURL: URL) -> any McpOAuthStateStore {
        ServerStore(owner: self, key: Self.key(serverURL))
    }

    public func state(for serverURL: URL) throws -> McpOAuthState? {
        let key = Self.key(serverURL)
        return try backend.withLock { current in
            let states = try Self.parse(current)
            return AuthStorageLockResult(result: states[key]?.state)
        }
    }

    public func tokens(for serverURL: URL) throws -> McpOAuthTokens? {
        try state(for: serverURL)?.tokens
    }

    @discardableResult
    public func remove(_ serverURL: URL) throws -> Bool {
        let key = Self.key(serverURL)
        return try backend.withLock { current in
            var states = try Self.parse(current)
            let removed = states.removeValue(forKey: key) != nil
            return AuthStorageLockResult(result: removed, next: removed ? try Self.encode(states) : nil)
        }
    }

    public func withRefreshLock<Result: Sendable>(
        for serverURL: URL, _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let key = Self.key(serverURL)
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

        func load() async throws -> McpOAuthState? {
            try owner.backend.withLock { current in
                let states = try McpOAuthCredentialStore.parse(current)
                return AuthStorageLockResult(result: states[key]?.state)
            }
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

/// Sends stored tokens and refreshes them before expiry or after HTTP 401.
public actor McpServerAuthProvider: McpAuthProvider {
    private let serverURL: URL
    private let credentials: McpOAuthCredentialStore
    private let settingsResolver: @Sendable () throws -> McpOAuthConfig
    private let http: any McpOAuthHTTPClient
    private var refreshTask: Task<Void, Error>?
    public private(set) var challenge: McpOAuthChallenge?

    public init(serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: McpOAuthConfig = .init(),
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.settingsResolver = { settings }
        self.http = TimedMcpOAuthHTTPClient(base: http)
    }

    public init(serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: @escaping @Sendable () throws -> McpOAuthConfig,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.settingsResolver = settings
        self.http = TimedMcpOAuthHTTPClient(base: http)
    }

    public func token() async throws -> String? {
        _ = try? await refreshTask?.value
        let state = try credentials.state(for: serverURL)
        let token = state?.tokens?.accessToken
        if let expiry = state?.tokensExpireAt,
           expiry.timeIntervalSinceNow <= 30,
           state?.tokens?.refreshToken != nil {
            try? await refresh(staleToken: token, challenge: nil)
            return try credentials.tokens(for: serverURL)?.accessToken
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
            let settingsResolver = self.settingsResolver
            let http = self.http
            refreshTask = Task {
                try await credentials.withRefreshLock(for: serverURL) {
                    let stored = try credentials.state(for: serverURL)
                    if stored?.tokens?.accessToken != staleToken { return }
                    guard stored?.tokens?.refreshToken != nil else { throw McpOAuthError.authorizationRequired }
                    let settings = try settingsResolver()
                    let registered = stored?.clientInformation?.metadata?.redirectURIs.first
                    let redirect = settings.callbackUrl ?? registered ?? "http://127.0.0.1/callback"
                    guard let redirectURL = URL(string: redirect) else { throw McpOAuthError.invalidRedirect }
                    let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
                        clientMetadata: McpOAuthClientMetadata(clientName: "pi"),
                        clientID: settings.clientId, clientSecret: settings.clientSecret,
                        store: credentials.forServer(serverURL), onRedirect: { _ in })
                    let result = try await McpOAuthFlow.authorize(provider: provider,
                        options: McpOAuthFlowOptions(serverURL: serverURL,
                            scope: challenge?.scope, resourceMetadataURL: challenge?.resourceMetadataURL),
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
    serverURL: URL, credentials: McpOAuthCredentialStore, settings: McpOAuthConfig = .init(),
    challenge: McpOAuthChallenge? = nil, presenter: any McpSignInPresenter,
    http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
) async throws {
    let store = credentials.forServer(serverURL)
    if var stored = try await store.load() {
        stored.oauthState = nil
        if challenge?.error == "insufficient_scope" {
            stored.tokens = nil
            stored.tokensExpireAt = nil
        }
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
    if var stored = try await store.load(), settings.clientId == nil,
       !(stored.clientInformation?.metadata?.redirectURIs.contains(redirectURL.absoluteString) ?? false) {
        stored.clientInformation = nil
        stored.tokens = nil
        stored.tokensExpireAt = nil
        try await store.save(stored)
    }
    let combinedScope = [settings.scope, challenge?.scope].compactMap { $0 }
        .flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    var seen: Set<String> = []
    let scope = combinedScope.filter { seen.insert($0).inserted }.joined(separator: " ")
    let capture = McpSignInCapture()
    let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
        clientMetadata: McpOAuthClientMetadata(clientName: "pi"),
        clientID: settings.clientId, clientSecret: settings.clientSecret,
        initialState: state, store: store,
        onRedirect: { url in
            let callback = try await presenter.present(authorizationURL: url, state: state)
            await capture.save(callback)
        })
    do {
        let result = try await McpOAuthFlow.authorize(provider: provider,
            options: McpOAuthFlowOptions(serverURL: serverURL,
                scope: scope.isEmpty ? nil : scope,
                resourceMetadataURL: challenge?.resourceMetadataURL,
                skipRefresh: challenge?.error == "insufficient_scope"),
            http: TimedMcpOAuthHTTPClient(base: http))
        if result == .redirect {
            guard let callback = await capture.url else { throw McpOAuthError.invalidRedirect }
            _ = try await McpOAuthFlow.completeRedirect(provider: provider,
                callbackURL: callback, serverURL: serverURL,
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
