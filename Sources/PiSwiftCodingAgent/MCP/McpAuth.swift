import Foundation
import CryptoKit
import Darwin
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
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while held.contains(key) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw McpRefreshLockBusyError() }
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

    public func forServer(name: String, url: URL) -> any McpOAuthServerStore {
        ServerStore(owner: self, name: name, url: url, key: Self.key(name: name, url: url), legacyKey: Self.key(url))
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
                let path = lockDirectory.appendingPathComponent("mcp-auth-refresh-\(hash)").path
                try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
                let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { close(descriptor) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                    let code = errno
                    guard code == EWOULDBLOCK || code == EAGAIN else {
                        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    }
                    guard ContinuousClock.now < deadline else { throw McpRefreshLockBusyError() }
                    try await Task.sleep(for: .milliseconds(25))
                }
                defer { flock(descriptor, LOCK_UN) }
                value = try await operation()
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

    private struct ServerStore: McpOAuthServerStore {
        let owner: McpOAuthCredentialStore
        let name: String
        let url: URL
        let key: String
        let legacyKey: String

        func withRefreshLock<Result: Sendable>(
            _ operation: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            try await owner.withRefreshLock(name: name, url: url, operation)
        }

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
    private let provider: McpStoredAuthProvider
    public private(set) var challenge: McpOAuthChallenge?

    public init(name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: McpOAuthConfig = .init(),
                clientMetadataDocumentURL: URL? = nil, redirectURL: URL? = nil,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.provider = Self.makeProvider(name: name, serverURL: serverURL, credentials: credentials,
            settings: { settings }, clientMetadataDocumentURL: clientMetadataDocumentURL,
            redirectURL: redirectURL, http: http)
    }

    public init(name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore,
                settings: @escaping @Sendable () throws -> McpOAuthConfig,
                clientMetadataDocumentURL: URL? = nil, redirectURL: URL? = nil,
                http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()) {
        self.provider = Self.makeProvider(name: name, serverURL: serverURL, credentials: credentials,
            settings: settings, clientMetadataDocumentURL: clientMetadataDocumentURL,
            redirectURL: redirectURL, http: http)
    }

    private static func makeProvider(
        name: String, serverURL: URL, credentials: McpOAuthCredentialStore,
        settings: @escaping @Sendable () throws -> McpOAuthConfig,
        clientMetadataDocumentURL: URL?, redirectURL: URL?, http: any McpOAuthHTTPClient
    ) -> McpStoredAuthProvider {
        let store = credentials.forServer(name: name, url: serverURL)
        return McpStoredAuthProvider(store: store) { state, challenge in
            let settings = try settings()
            let registered = state.clientInformation?.metadata?.redirectURIs.first
            let redirect = redirectURL?.absoluteString ?? settings.callbackUrl ?? registered ?? "http://127.0.0.1/callback"
            guard let redirectURL = URL(string: redirect) else { throw McpOAuthError.invalidRedirect }
            let provider = McpOAuthProvider(serverURL: serverURL, redirectURL: redirectURL,
                clientMetadata: McpOAuthClientMetadata(clientName: settings.clientName ?? "pi"),
                clientID: settings.clientId, clientSecret: settings.clientSecret,
                clientMetadataDocument: mcpClientMetadataDocumentProvider(
                    settings: settings, url: clientMetadataDocumentURL, redirectURL: redirectURL),
                store: store, onRedirect: { _ in })
            return try await McpOAuthFlow.authorize(provider: provider,
                options: McpOAuthFlowOptions(serverURL: serverURL,
                    scope: challenge?.scope, resourceMetadataURL: challenge?.resourceMetadataURL,
                    authorizationServerMetadataURL: settings.authServerMetadataUrl.flatMap(URL.init(string:)),
                    refreshOnly: true),
                http: TimedMcpOAuthHTTPClient(base: http))
        }
    }

    public func token() async throws -> String? { try await provider.token() }

    public func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        self.challenge = McpOAuthDiscovery.parseWWWAuthenticate(challenge)
        try await provider.onUnauthorized(challenge: challenge, serverURL: serverURL, rejectedToken: rejectedToken)
    }

    public func settled() async { await provider.settled() }
}

/// Run interactive OAuth for one server. The presenter supplies macOS loopback or an iOS host flow.
public func signInMcpServer(
    name: String = "", serverURL: URL, credentials: McpOAuthCredentialStore, settings: McpOAuthConfig = .init(),
    challenge: McpOAuthChallenge? = nil, presenter: any McpSignInPresenter,
    clientMetadataDocumentURL: URL? = nil,
    http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient()
) async throws {
    try Task.checkCancellation()
    do {
        try await performMcpSignIn(name: name, serverURL: serverURL, credentials: credentials,
            settings: settings, challenge: challenge, presenter: presenter,
            clientMetadataDocumentURL: clientMetadataDocumentURL, http: http)
        try Task.checkCancellation()
        await presenter.cancel()
    } catch {
        await presenter.cancel()
        if isMcpSignInCancellation(error) { throw CancellationError() }
        throw error
    }
}

func isMcpSignInCancellation(_ error: any Error) -> Bool {
    Task.isCancelled || error is CancellationError || error is McpSignInCancelledError || (error as? URLError)?.code == .cancelled
}

private func performMcpSignIn(
    name: String, serverURL: URL, credentials: McpOAuthCredentialStore, settings: McpOAuthConfig,
    challenge: McpOAuthChallenge?, presenter: any McpSignInPresenter,
    clientMetadataDocumentURL: URL?, http: any McpOAuthHTTPClient
) async throws {
    if settings.clientRegistration == .cimd, clientMetadataDocumentURL == nil {
        throw McpRuntimeError.invalidConfig(mcpMissingClientMetadataDocument)
    }
    let store = credentials.forServer(name: name, url: serverURL)
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
    let options = McpSignInOptions(serverURL: serverURL, redirectURL: redirectURL, initialState: state,
        replaceRegisteredClientForDocument: settings.clientRegistration == .cimd, store: store,
        clientMetadata: McpOAuthClientMetadata(clientName: settings.clientName ?? "pi"),
        clientID: settings.clientId, clientSecret: settings.clientSecret,
        clientMetadataDocument: mcpClientMetadataDocumentProvider(
            settings: settings, url: clientMetadataDocumentURL, redirectURL: redirectURL),
        challenge: challenge, scope: settings.scope,
        authorizationServerMetadataURL: settings.authServerMetadataUrl.flatMap(URL.init(string:)),
        http: TimedMcpOAuthHTTPClient(base: http))
    switch try await McpOAuthSignIn.startMcpSignIn(options: options) {
    case .authorized:
        return
    case .redirect(let authorization):
        let callback = try await presenter.present(authorizationURL: authorization.authorizationURL,
            state: authorization.state)
        try Task.checkCancellation()
        let expected = authorization.redirectURL
        guard callback.scheme == expected.scheme, callback.host == expected.host,
              callback.port == expected.port, callback.path == expected.path,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw McpOAuthError.invalidRedirect
        }
        let parameter: (String) -> String? = { name in
            components.queryItems?.first { $0.name == name }?.value
        }
        if let error = parameter("error") {
            throw McpOAuthError.authorization(code: error,
                message: parameter("error_description") ?? error, uri: parameter("error_uri"))
        }
        guard let responseState = parameter("state"), responseState == authorization.state else {
            throw McpOAuthError.invalidState
        }
        guard let code = parameter("code"), !code.isEmpty else { throw McpOAuthError.invalidRedirect }
        try await McpOAuthSignIn.completeMcpSignIn(options: options, authorization: authorization,
            response: McpAuthorizationResponse(code: code, state: responseState, iss: parameter("iss")))
    }
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
