import Foundation
import Darwin
import PiSwiftAI

public struct ApiKeyCredential: Sendable {
    public var type: String = "api_key"
    public var key: String?
    public var env: [String: String]?

    public init(key: String? = nil, env: [String: String]? = nil) {
        self.env = env
        self.key = key
    }
}

public struct OAuthCredential: Sendable {
    public var type: String = "oauth"
    public var access: String
    public var refresh: String?
    public var expires: Double?
    public var enterpriseUrl: String?
    public var projectId: String?
    public var email: String?
    public var accountId: String?
    public var availableModelIds: [String]?
    public var clientId: String?
    public var scopes: [String]?
    public var env: [String: String]?

    public init(
        access: String,
        refresh: String?,
        expires: Double?,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil,
        availableModelIds: [String]? = nil,
        clientId: String? = nil,
        scopes: [String]? = nil,
        env: [String: String]? = nil
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
        self.availableModelIds = availableModelIds
        self.clientId = clientId
        self.scopes = scopes
        self.env = env
    }
}

public enum AuthCredential: Sendable {
    case apiKey(ApiKeyCredential)
    case oauth(OAuthCredential)
}

/// A stored credential type. This value does not contain credential secrets.
public struct CredentialInfo: Sendable, Equatable {
    public enum CredentialType: String, Sendable { case apiKey = "api_key", oauth }
    public let providerId: String
    public let type: CredentialType

    public init(providerId: String, type: CredentialType) {
        self.providerId = providerId
        self.type = type
    }
}

struct AuthLockOptions: Sendable {
    var maxAttempts: Int
    var initialDelayMs: Int
    var maxDelayMs: Int
}

private func cancellableAuthStorageSleep(_ milliseconds: Int, signal: CancellationToken?) async throws {
    var remaining = max(0, milliseconds)
    while remaining > 0 {
        if signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
        let slice = min(remaining, 25)
        try await Task.sleep(nanoseconds: UInt64(slice) * 1_000_000)
        remaining -= slice
    }
    if signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
}

private let oauthRefreshTimeoutMs = 15_000

private struct AuthFileReadSnapshot: Sendable {
    var data: [String: AuthCredential]
    var revision: String
}

private let sharedAuthFileReadSnapshots = LockedState<[String: AuthFileReadSnapshot]>([:])

private func authFileRevision(_ path: String) -> String? {
    var info = stat()
    let status = path.withCString { Darwin.lstat($0, &info) }
    guard status == 0 else { return nil }
    return "\(info.st_dev):\(info.st_ino):\(info.st_size):" +
        "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):" +
        "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
}

private enum AuthStorageDataError: Error, LocalizedError, Sendable {
    case invalidFormat
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid auth storage format"
        case .encodingFailed:
            return "Unable to encode auth storage"
        }
    }
}

private func boundedOAuthRefreshSignal() -> (CancellationToken, Task<Void, Never>) {
    let signal = CancellationToken()
    let monitor = Task {
        do {
            try await Task.sleep(for: .milliseconds(oauthRefreshTimeoutMs))
            if !Task.isCancelled { signal.cancel() }
        } catch {
            // The transaction cancels this timer when the refresh ends.
        }
    }
    return (signal, monitor)
}

// The caller can stop waiting while the detached transaction keeps the lock.
private final class OAuthRefreshWaiter<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var outcome: Result<Value, any Error>?
        var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
    }
    private let state = LockedState(State())

    func finish(_ outcome: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Result<Value, any Error>, Never>? = state.withLock { state in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }

    func wait() async throws -> Value {
        let outcome: Result<Value, any Error> = await withCheckedContinuation { continuation in
            let outcome: Result<Value, any Error>? = state.withLock { state in
                if let outcome = state.outcome { return outcome }
                state.continuation = continuation
                return nil
            }
            if let outcome { continuation.resume(returning: outcome) }
        }
        return try outcome.get()
    }
}

// Serializes cancellation with callback entry. A late cancellation handler must
// not cancel the backend token after the protected transaction has started.
private final class OAuthRefreshBoundary: Sendable {
    private struct State: Sendable {
        var started = false
        var cancelled = false
    }
    private let state = LockedState(State())
    let lockWait = CancellationToken()

    func cancelWait() {
        let cancelLockWait = state.withLock { state in
            state.cancelled = true
            return !state.started
        }
        if cancelLockWait { lockWait.cancel() }
    }

    func start() throws {
        try state.withLock { state in
            if state.cancelled { throw OAuthError.cancelled }
            state.started = true
        }
    }
}

struct OAuthOverrides: Sendable {
    var getOAuthApiKey: (@Sendable (OAuthProvider, [String: OAuthCredentials]) async throws -> (newCredentials: OAuthCredentials, apiKey: String)?)?
    var oauthApiKey: (@Sendable (OAuthProvider, String, String?) throws -> String)?
    var getOAuthApiKeyWithSignal: (@Sendable (OAuthProvider, [String: OAuthCredentials], CancellationToken) async throws -> (newCredentials: OAuthCredentials, apiKey: String)?)? = nil
}

/// The result of an atomic auth-storage transaction.
///
/// Set `next` to persist a replacement value, or leave it `nil` to make the
/// transaction read-only. A backend invokes `onCommit` exactly once after it
/// has persisted `next` (if any), and before it releases the transaction.
public struct AuthStorageLockResult<Result: Sendable>: Sendable {
    public let result: Result
    public let next: String?
    public let onCommit: @Sendable () -> Void

    public init(
        result: Result,
        next: String? = nil,
        onCommit: @escaping @Sendable () -> Void = {}
    ) {
        self.result = result
        self.next = next
        self.onCommit = onCommit
    }
}

/// Persistent storage for `AuthStorage` credential data.
///
/// Implement this protocol to keep the serialized auth data in a secure store,
/// such as the Keychain or an encrypted database, instead of `auth.json`.
/// Implementations must run each closure atomically: it receives the current
/// value and may replace it by returning a non-`nil` `next` value. Invoke the
/// returned transaction's `onCommit` callback only after a replacement has
/// been persisted successfully, before releasing the transaction.
/// OAuth refresh passes a separate signal for the lock wait. After callback
/// entry, caller cancellation does not cancel that signal or the transaction task.
public protocol AuthStorageBackend: Sendable {
    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result

    func withLockAsync<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result
}

public extension AuthStorageBackend {
    func withLockAsync<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        if signal?.isCancelled == true { throw OAuthError.cancelled }
        let result = try await withLockAsync { current in
            if signal?.isCancelled == true { throw OAuthError.cancelled }
            let transaction = try await body(current)
            if signal?.isCancelled == true { throw OAuthError.cancelled }
            return transaction
        }
        if signal?.isCancelled == true { throw OAuthError.cancelled }
        return result
    }
}

/// The default `AuthStorageBackend`, which stores credentials in an auth JSON file.
public final class FileAuthStorageBackend: AuthStorageBackend {
    private let authPath: String
    private let decodesInvalidUTF8: Bool
    private let lockOptionsOverride = LockedState<AuthLockOptions?>(nil)
    private let asyncTransactionGate = AsyncTransactionGate()

    public init(_ authPath: String = getAuthPath()) {
        self.authPath = authPath
        self.decodesInvalidUTF8 = false
    }

    /// For caches: a file cut off mid-character reads with replacement characters
    /// instead of failing every transaction until someone deletes it.
    init(_ path: String, decodesInvalidUTF8: Bool) {
        self.authPath = path
        self.decodesInvalidUTF8 = decodesInvalidUTF8
    }

    public func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        try withFileLockSync {
            let current = try readCurrent()
            let transaction = try body(current)
            if let next = transaction.next {
                try write(next)
            }
            transaction.onCommit()
            return transaction.result
        }
    }

    public func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await withLockAsync(signal: nil, body)
    }

    public func withLockAsync<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await asyncTransactionGate.acquire(signal: signal)
        do {
            let result = try await withFileLock(signal: signal) {
                let current = try self.readCurrent()
                let transaction = try await body(current)
                if signal?.isCancelled == true { throw OAuthError.cancelled }
                if let next = transaction.next {
                    try self.write(next)
                }
                transaction.onCommit()
                return transaction.result
            }
            await asyncTransactionGate.release()
            return result
        } catch {
            await asyncTransactionGate.release()
            throw error
        }
    }

    func setLockOptionsForTesting(_ options: AuthLockOptions?) {
        lockOptionsOverride.withLock { $0 = options }
    }

    private func write(_ value: String) throws {
        try value.write(toFile: authPath, atomically: false, encoding: .utf8)
    }

    private func readCurrent() throws -> String {
        guard decodesInvalidUTF8 else {
            return try String(contentsOfFile: authPath, encoding: .utf8)
        }
        return String(decoding: try Data(contentsOf: URL(fileURLWithPath: authPath)), as: UTF8.self)
    }

    private func withFileLock<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try ensureAuthFileExists()

        let fd = open(authPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OAuthError.refreshFailed("failed to open auth storage")
        }
        defer { close(fd) }

        let override = lockOptionsOverride.withLock { $0 }
        let maxAttempts = override?.maxAttempts ?? 10
        let maxDelayMs = override?.maxDelayMs ?? 10_000
        var delayMs = override?.initialDelayMs ?? 100
        var locked = false
        guard maxAttempts > 0 else {
            throw OAuthError.refreshFailed("failed to acquire auth storage lock")
        }
        for _ in 0..<maxAttempts {
            if signal?.isCancelled == true { throw OAuthError.cancelled }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            try await cancellableAuthStorageSleep(delayMs, signal: signal)
            delayMs = min(delayMs * 2, maxDelayMs)
        }

        guard locked else {
            throw OAuthError.refreshFailed("failed to acquire auth storage lock")
        }

        defer { flock(fd, LOCK_UN) }
        if signal?.isCancelled == true { throw OAuthError.cancelled }
        return try await body()
    }

    private func withFileLockSync<Result: Sendable>(_ body: () throws -> Result) throws -> Result {
        try ensureAuthFileExists()

        let fd = open(authPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OAuthError.refreshFailed("failed to open auth storage")
        }
        defer { close(fd) }

        let override = lockOptionsOverride.withLock { $0 }
        let maxAttempts = override?.maxAttempts ?? 10
        let maxDelayMs = override?.maxDelayMs ?? 10_000
        var delayMs = override?.initialDelayMs ?? 100
        var locked = false
        guard maxAttempts > 0 else {
            throw OAuthError.refreshFailed("failed to acquire auth storage lock")
        }
        for _ in 0..<maxAttempts {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            usleep(useconds_t(delayMs) * 1_000)
            delayMs = min(delayMs * 2, maxDelayMs)
        }

        guard locked else {
            throw OAuthError.refreshFailed("failed to acquire auth storage lock")
        }

        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func ensureAuthFileExists() throws {
        let url = URL(fileURLWithPath: authPath)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if !FileManager.default.fileExists(atPath: authPath) {
            guard FileManager.default.createFile(
                atPath: authPath,
                contents: Data("{}".utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw OAuthError.refreshFailed("failed to create auth storage")
            }
        }
    }
}

private actor AsyncTransactionGate {
    private var isLocked = false

    func acquire(signal: CancellationToken? = nil) async throws {
        while isLocked {
            if signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
        isLocked = true
    }

    func release() {
        isLocked = false
    }
}

/// Coordinates synchronous and asynchronous in-memory transactions without
/// holding a thread mutex across an `await`.
private final class InMemoryTransactionState: Sendable {
    private struct TransactionFlags: Sendable {
        var synchronousTransactionInProgress = false
        var asynchronousTransactionInProgress = false
    }

    // The flags ensure no transaction can observe or update `value` while an
    // asynchronous transaction is suspended in its closure.
    private let value: LockedState<String?>
    private let asyncGate = AsyncTransactionGate()
    private let flags = LockedState(TransactionFlags())

    init(_ initialValue: String?) {
        value = LockedState(initialValue)
    }

    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        beginSynchronousTransaction()
        defer { endSynchronousTransaction() }

        return try value.withLock { current in
            let transaction = try body(current)
            if let next = transaction.next {
                current = next
            }
            transaction.onCommit()
            return transaction.result
        }
    }

    func withLockAsync<Result: Sendable>(
        signal: CancellationToken? = nil,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await asyncGate.acquire(signal: signal)
        do {
            try await beginAsynchronousTransaction(signal: signal)
        } catch {
            await asyncGate.release()
            throw error
        }

        do {
            let current = value.withLock { $0 }
            let transaction = try await body(current)
            if signal?.isCancelled == true || Task.isCancelled { throw OAuthError.cancelled }
            if let next = transaction.next {
                value.withLock { $0 = next }
            }
            transaction.onCommit()
            endAsynchronousTransaction()
            await asyncGate.release()
            return transaction.result
        } catch {
            endAsynchronousTransaction()
            await asyncGate.release()
            throw error
        }
    }

    private func beginSynchronousTransaction() {
        while true {
            let acquired = flags.withLock { flags in
                guard !flags.synchronousTransactionInProgress,
                      !flags.asynchronousTransactionInProgress else { return false }
                flags.synchronousTransactionInProgress = true
                return true
            }
            if acquired { return }
            usleep(1_000)
        }
    }

    private func endSynchronousTransaction() {
        flags.withLock { $0.synchronousTransactionInProgress = false }
    }

    private func beginAsynchronousTransaction(signal: CancellationToken?) async throws {
        while true {
            if tryBeginAsynchronousTransaction() { return }
            try await cancellableAuthStorageSleep(25, signal: signal)
        }
    }

    private func tryBeginAsynchronousTransaction() -> Bool {
        flags.withLock { flags in
            guard !flags.synchronousTransactionInProgress,
                  !flags.asynchronousTransactionInProgress else { return false }
            flags.asynchronousTransactionInProgress = true
            return true
        }
    }

    private func endAsynchronousTransaction() {
        flags.withLock { $0.asynchronousTransactionInProgress = false }
    }
}

/// An `AuthStorageBackend` that keeps credential data only in memory.
public final class InMemoryAuthStorageBackend: AuthStorageBackend {
    private let state: InMemoryTransactionState

    public init(_ initialValue: String? = nil) {
        state = InMemoryTransactionState(initialValue)
    }

    public func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        try state.withLock(body)
    }

    public func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await state.withLockAsync(signal: nil, body)
    }

    public func withLockAsync<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await state.withLockAsync(signal: signal, body)
    }
}

public final class AuthStorage: Sendable {
    private struct State: Sendable {
        var data: [String: AuthCredential] = [:]
        var fileRevision: String?
        var runtimeOverrides: [String: String] = [:]
        var fallbackResolver: (@Sendable (String) -> String?)?
        var fallbackConfigured: (@Sendable (String) -> Bool)?
        var oauthOverrides: OAuthOverrides?
        var loadError: String?
        var errors: [String] = []
    }

    private let state = LockedState(State())
    private let storage: any AuthStorageBackend
    private let authPath: String?

    public init(_ authPath: String) {
        if authPath == ":memory:" {
            storage = InMemoryAuthStorageBackend()
            self.authPath = nil
        } else {
            let normalizedPath = URL(fileURLWithPath: authPath).standardized.path
            storage = FileAuthStorageBackend(normalizedPath)
            self.authPath = normalizedPath
            if let revision = authFileRevision(normalizedPath),
               let snapshot = sharedAuthFileReadSnapshots.withLock({ $0[normalizedPath] }),
               snapshot.revision == revision {
                state.withLock {
                    $0.data = snapshot.data
                    $0.fileRevision = snapshot.revision
                }
                return
            }
        }
        reload()
    }

    /// Creates auth storage backed by a caller-provided persistence implementation.
    public init(storage: any AuthStorageBackend) {
        self.storage = storage
        self.authPath = nil
        reload()
    }

    public static func create(_ authPath: String? = nil) -> AuthStorage {
        AuthStorage(authPath ?? getAuthPath())
    }

    /// Creates auth storage backed by a caller-provided persistence implementation.
    public static func fromStorage(_ storage: any AuthStorageBackend) -> AuthStorage {
        AuthStorage(storage: storage)
    }

    public static func inMemory(_ data: [String: AuthCredential] = [:]) -> AuthStorage {
        let storage = AuthStorage(":memory:")
        for (provider, credential) in data {
            storage.set(provider, credential: credential)
        }
        return storage
    }

    public func setRuntimeApiKey(_ provider: String, _ apiKey: String) {
        state.withLock { $0.runtimeOverrides[provider] = apiKey }
    }

    public func removeRuntimeApiKey(_ provider: String) {
        state.withLock { $0.runtimeOverrides.removeValue(forKey: provider) }
    }

    public func setFallbackResolver(_ resolver: @escaping @Sendable (String) -> String?, configured: (@Sendable (String) -> Bool)? = nil) {
        state.withLock { $0.fallbackResolver = resolver; $0.fallbackConfigured = configured }
    }

    func setAuthLockOptionsForTesting(_ options: AuthLockOptions?) {
        (storage as? FileAuthStorageBackend)?.setLockOptionsForTesting(options)
    }

    func setOAuthOverridesForTesting(_ overrides: OAuthOverrides?) {
        state.withLock { $0.oauthOverrides = overrides }
    }

    public func reload() {
        do {
            try storage.withLock { current in
                let loaded = try self.parseAuthData(current)
                return AuthStorageLockResult(result: (), onCommit: self.cacheCommit(loaded))
            }
        } catch {
            state.withLock { state in
                state.errors.append(error.localizedDescription)
                state.loadError = error.localizedDescription
            }
        }
    }

    public func get(_ provider: String) -> AuthCredential? {
        state.withLock { $0.data[provider] }
    }

    public func set(_ provider: String, credential: AuthCredential) {
        persistProviderChange(provider: provider, credential: credential)
    }

    public func remove(_ provider: String) {
        persistProviderChange(provider: provider, credential: nil)
    }

    public func list() -> [String] {
        state.withLock { Array($0.data.keys) }
    }

    /// Return stored credential types in provider id order, without secrets.
    public func listCredentials() -> [CredentialInfo] {
        state.withLock { state in
            state.data.keys.sorted().map { provider in
                let type: CredentialInfo.CredentialType
                if case .oauth = state.data[provider] { type = .oauth } else { type = .apiKey }
                return CredentialInfo(providerId: provider, type: type)
            }
        }
    }

    public func has(_ provider: String) -> Bool {
        state.withLock { $0.data[provider] != nil }
    }

    public func hasAuth(_ provider: String, env: [String: String]? = nil) -> Bool {
        let snapshot = state.withLock { state in
            let runtime = state.runtimeOverrides[provider]
            let credential = state.data[provider]
            return (runtime: runtime, credential: credential, fallback: state.fallbackResolver, configured: state.fallbackConfigured)
        }
        if snapshot.runtime != nil {
            return true
        }
        if let credential = snapshot.credential {
            switch credential {
            case .apiKey(let key):
                if let value = key.key, provider != "anthropic" || !value.isEmpty {
                    return isConfigValueConfigured(value, env: key.env)
                }
                let scopedEnv = mergeConfigEnvironment(key.env, env)
                return getEnvApiKey(provider: provider, env: scopedEnv) != nil ||
                    (provider == "anthropic" && anthropicFederationEnv(env: providerEnvironment(scopedEnv)) != nil)
            case .oauth: return true
            }
        }
        if getEnvApiKey(provider: provider, env: env) != nil ||
            (provider == "anthropic" && anthropicFederationEnv(env: providerEnvironment(env)) != nil) {
            return true
        }
        if let configured = snapshot.configured { return configured(provider) }
        if snapshot.fallback?(provider) != nil {
            return true
        }
        return false
    }

    func getRuntimeApiKey(_ provider: String) -> String? {
        state.withLock { $0.runtimeOverrides[provider] }
    }

    public func getProviderEnv(_ provider: String) -> [String: String]? {
        switch get(provider) {
        case .apiKey(let key): return key.env
        case .oauth(let oauth): return oauth.env
        case nil: return nil
        }
    }

    public func getAll() -> [String: AuthCredential] {
        state.withLock { $0.data }
    }

    public func drainErrors() -> [String] {
        state.withLock { state in
            let drained = state.errors
            state.errors = []
            return drained
        }
    }

    public func login(_ provider: OAuthProvider, callbacks: OAuthLoginCallbacks) async throws {
        let credentials: OAuthCredentials
        switch provider {
        case .anthropic:
            credentials = try await loginAnthropicOAuth(callbacks)
        case .openAICodex:
            credentials = try await loginOpenAICodex(callbacks)
        case .openAI:
            credentials = try await loginOpenAIChatGPT(callbacks)
        case .githubCopilot:
            credentials = try await loginGitHubCopilot(callbacks)
        case .googleGeminiCli:
            credentials = try await loginGoogleGeminiCli(callbacks)
        case .googleAntigravity:
            credentials = try await loginAntigravity(callbacks)
        case .openRouter:
            credentials = try await loginOpenRouter(callbacks)
            set(provider.rawValue, credential: .apiKey(ApiKeyCredential(key: credentials.access)))
            return
        case .kimiCoding:
            credentials = try await loginKimiCoding(callbacks)
        case .xai:
            credentials = try await loginXai(callbacks)
        case .meta:
            credentials = try await loginMeta(callbacks)
        }
        set(provider.rawValue, credential: .oauth(OAuthCredential(credentials)))
    }

    public func logout(_ provider: OAuthProvider) {
        remove(provider.rawValue)
    }

    public func getApiKey(
        _ provider: String,
        minimumOAuthValidityMs: Double? = nil,
        signal: CancellationToken? = nil,
        includeFallback: Bool = true,
        env: [String: String]? = nil
    ) async -> String? {
        if signal?.isCancelled == true || Task.isCancelled { return nil }
        let runtime = state.withLock { $0.runtimeOverrides[provider] }
        if let runtime {
            return runtime
        }

        await reloadLatestData(signal: signal)
        if signal?.isCancelled == true || Task.isCancelled { return nil }
        let snapshot = state.withLock { state in
            let credential = state.data[provider]
            return (credential: credential, fallback: state.fallbackResolver)
        }

        if let credential = snapshot.credential {
            switch credential {
            case .apiKey(let apiKey):
                if let key = apiKey.key { return resolveConfigValue(key, env: apiKey.env) }
                return getEnvApiKey(provider: provider, env: mergeConfigEnvironment(apiKey.env, env))
            case .oauth(let oauth):
                let oauthProviderId = OAuthProvider(rawValue: provider)
                let now = Date().timeIntervalSince1970 * 1000
                let minimumValidity = max(defaultOAuthMinimumValidityMs, minimumOAuthValidityMs ?? 0)
                let needsRefresh = oauth.expires == nil || now + minimumValidity >= (oauth.expires ?? 0)
                if needsRefresh,
                   let providerId = oauthProviderId,
                   oauth.refresh != nil {
                    do {
                        if let result = try await refreshOAuthTokenWithLock(
                            providerId,
                            minimumOAuthValidityMs: minimumValidity,
                            signal: signal
                        ) {
                            if signal?.isCancelled == true || Task.isCancelled { return nil }
                            return result.apiKey
                        }
                        if signal?.isCancelled == true || Task.isCancelled { return nil }
                    } catch {
                        if signal?.isCancelled == true || Task.isCancelled { return nil }
                        let message = error.localizedDescription
                        fputs("OAuth token refresh failed for \(provider): \(message)\n", stderr)
                        if let expires = oauth.expires, now >= expires {
                            return nil
                        }
                    }
                }

                if let providerId = oauthProviderId {
                    let override = state.withLock { $0.oauthOverrides }
                    if let overrideApiKey = override?.oauthApiKey {
                        if let apiKey = try? overrideApiKey(providerId, oauth.access, oauth.projectId) {
                            return apiKey
                        }
                    } else if let apiKey = try? oauthApiKey(provider: providerId, accessToken: oauth.access, projectId: oauth.projectId) {
                        return apiKey
                    }
                }
                return oauth.access
            }
        }

        if let envKey = getEnvApiKey(provider: provider, env: env) {
            return envKey
        }

        if let envName = envKeyName(for: provider),
           let value = getProviderEnvValue(envName, env: env),
           !value.isEmpty {
            return value
        }

        return includeFallback ? snapshot.fallback?(provider) : nil
    }

    private func reloadLatestData(signal: CancellationToken?) async {
        guard let authPath else { return }
        if let revision = authFileRevision(authPath),
           state.withLock({ $0.fileRevision }) == revision {
            return
        }

        do {
            try await storage.withLockAsync(signal: signal) { current in
                let loaded = try self.parseAuthData(current)
                return AuthStorageLockResult(result: (), onCommit: self.cacheCommit(loaded))
            }
        } catch {
            // Preserve the last valid snapshot. Request-time reads must not make a
            // transient lock or parse failure erase usable credentials.
        }
    }

    private func persistProviderChange(provider: String, credential: AuthCredential?) {
        let blockedByLoadError = state.withLock { $0.loadError != nil }
        if blockedByLoadError {
            return
        }

        do {
            try storage.withLock { current in
                var merged = try self.parseAuthData(current)
                if let credential {
                    merged[provider] = credential
                } else {
                    merged.removeValue(forKey: provider)
                }
                return AuthStorageLockResult(
                    result: (),
                    next: try self.serializeAuthData(merged),
                    onCommit: self.cacheCommit(merged)
                )
            }
        } catch {
            state.withLock { state in
                state.errors.append(error.localizedDescription)
            }
        }
    }

    private func parseAuthData(_ content: String?) throws -> [String: AuthCredential] {
        guard let content, !content.isEmpty else { return [:] }
        let raw = try JSONSerialization.jsonObject(with: Data(content.utf8))
        guard let json = raw as? [String: Any] else {
            throw AuthStorageDataError.invalidFormat
        }

        var loaded: [String: AuthCredential] = [:]
        for (provider, value) in json {
            guard let dict = value as? [String: Any],
                  let type = dict["type"] as? String else { continue }
            if type == "api_key" {
                loaded[provider] = .apiKey(ApiKeyCredential(key: dict["key"] as? String, env: dict["env"] as? [String: String]))
            } else if type == "oauth" {
                let access = (dict["access"] as? String) ?? (dict["accessToken"] as? String)
                guard let access else { continue }
                let refresh = (dict["refresh"] as? String) ?? (dict["refreshToken"] as? String)
                let expires = (dict["expires"] as? Double) ?? (dict["expiresAt"] as? Double)
                let enterpriseUrl = dict["enterpriseUrl"] as? String
                let projectId = dict["projectId"] as? String
                let email = dict["email"] as? String
                let accountId = dict["accountId"] as? String
                let availableModelIds = dict["availableModelIds"] as? [String]
                let clientId = dict["clientId"] as? String
                let scopes = dict["scopes"] as? [String]
                loaded[provider] = .oauth(OAuthCredential(
                    access: access,
                    refresh: refresh,
                    expires: expires,
                    enterpriseUrl: enterpriseUrl,
                    projectId: projectId,
                    email: email,
                    accountId: accountId,
                    availableModelIds: availableModelIds,
                    clientId: clientId,
                    scopes: scopes,
                    env: dict["env"] as? [String: String]
                ))
            }
        }
        return loaded
    }

    private func serializeAuthData(_ credentials: [String: AuthCredential]) throws -> String {
        var json: [String: Any] = [:]
        for (provider, credential) in credentials {
            switch credential {
            case .apiKey(let apiKey):
                var entry: [String: Any] = ["type": "api_key"]
                if let key = apiKey.key { entry["key"] = key }
                if let env = apiKey.env { entry["env"] = env }
                json[provider] = entry
            case .oauth(let oauth):
                var entry: [String: Any] = ["type": "oauth", "access": oauth.access]
                if let refresh = oauth.refresh { entry["refresh"] = refresh }
                if let expires = oauth.expires { entry["expires"] = expires }
                if let enterpriseUrl = oauth.enterpriseUrl { entry["enterpriseUrl"] = enterpriseUrl }
                if let projectId = oauth.projectId { entry["projectId"] = projectId }
                if let email = oauth.email { entry["email"] = email }
                if let accountId = oauth.accountId { entry["accountId"] = accountId }
                if let availableModelIds = oauth.availableModelIds { entry["availableModelIds"] = availableModelIds }
                if let clientId = oauth.clientId { entry["clientId"] = clientId }
                if let scopes = oauth.scopes { entry["scopes"] = scopes }
                if let env = oauth.env { entry["env"] = env }
                json[provider] = entry
            }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        guard let content = String(data: data, encoding: .utf8) else {
            throw AuthStorageDataError.encodingFailed
        }
        return content
    }

    private func cacheCommit(_ data: [String: AuthCredential]) -> @Sendable () -> Void {
        { [self] in
            let revision = authPath.flatMap(authFileRevision)
            state.withLock { state in
                state.data = data
                state.fileRevision = revision
                state.loadError = nil
            }
            if let authPath, let revision {
                sharedAuthFileReadSnapshots.withLock {
                    $0[authPath] = AuthFileReadSnapshot(data: data, revision: revision)
                }
            }
        }
    }

    private struct OAuthRefreshLockedResult: Sendable {
        var value: (apiKey: String, newCredentials: OAuthCredentials)?
    }

    private func refreshOAuthTokenWithLock(
        _ provider: OAuthProvider,
        minimumOAuthValidityMs: Double,
        signal: CancellationToken?
    ) async throws -> (apiKey: String, newCredentials: OAuthCredentials)? {
        let boundary = OAuthRefreshBoundary()
        let waiter = OAuthRefreshWaiter<OAuthRefreshLockedResult>()
        let callerCancellation = CancellationToken()
        let removeCaller = signal?.onCancel { callerCancellation.cancel() }
        defer { removeCaller?() }
        let removeWaitCancellation = callerCancellation.onCancel {
            boundary.cancelWait()
            waiter.finish(.failure(OAuthError.cancelled))
        }
        defer { removeWaitCancellation() }
        return try await withTaskCancellationHandler {
            Task.detached {
                do {
                    let result = try await self.refreshOAuthTransaction(
                        provider, minimumOAuthValidityMs: minimumOAuthValidityMs, boundary: boundary
                    )
                    waiter.finish(.success(result))
                } catch {
                    waiter.finish(.failure(error))
                }
            }
            return try await waiter.wait().value
        } onCancel: {
            callerCancellation.cancel()
        }
    }

    private func refreshOAuthTransaction(
        _ provider: OAuthProvider,
        minimumOAuthValidityMs: Double,
        boundary: OAuthRefreshBoundary
    ) async throws -> OAuthRefreshLockedResult {
        try await storage.withLockAsync(signal: boundary.lockWait) { current in
            // Upstream bde882c74: caller cancellation ends at callback entry.
            try boundary.start()
            let currentData = try self.parseAuthData(current)
            let credential = currentData[provider.rawValue]
            guard case .oauth(let oauth) = credential else {
                return AuthStorageLockResult(
                    result: OAuthRefreshLockedResult(value: nil),
                    onCommit: self.cacheCommit(currentData)
                )
            }

            let now = Date().timeIntervalSince1970 * 1000
            if let expires = oauth.expires, now + minimumOAuthValidityMs < expires {
                let apiKey = try oauthApiKey(provider: provider, accessToken: oauth.access, projectId: oauth.projectId)
                if let creds = oauth.toOAuthCredentials() {
                    return AuthStorageLockResult(result: OAuthRefreshLockedResult(
                        value: (apiKey: apiKey, newCredentials: creds)
                    ), onCommit: self.cacheCommit(currentData))
                }
                return AuthStorageLockResult(result: OAuthRefreshLockedResult(
                    value: (apiKey: apiKey, newCredentials: OAuthCredentials(
                        refresh: oauth.refresh ?? "",
                        access: oauth.access,
                        expires: expires,
                        enterpriseUrl: oauth.enterpriseUrl,
                        projectId: oauth.projectId,
                        email: oauth.email,
                        accountId: oauth.accountId,
                        availableModelIds: oauth.availableModelIds,
                        clientId: oauth.clientId,
                        scopes: oauth.scopes,
                        env: oauth.env
                    ))
                ), onCommit: self.cacheCommit(currentData))
            }

            let oauthCreds = self.oauthCredentialsMap(from: currentData)
            let override = self.state.withLock { $0.oauthOverrides }
            let result: (newCredentials: OAuthCredentials, apiKey: String)?
            let (refreshSignal, refreshMonitor) = boundedOAuthRefreshSignal()
            defer { refreshMonitor.cancel() }
            if let overrideFn = override?.getOAuthApiKeyWithSignal {
                result = try await overrideFn(provider, oauthCreds, refreshSignal)
            } else if let overrideFn = override?.getOAuthApiKey {
                result = try await overrideFn(provider, oauthCreds)
            } else {
                result = try await getOAuthApiKey(
                    provider: provider,
                    credentials: oauthCreds,
                    minimumValidityMs: minimumOAuthValidityMs,
                    signal: refreshSignal
                )
            }
            if let result {
                var updatedData = currentData
                var refreshed = result.newCredentials
                refreshed.env = refreshed.env ?? oauth.env
                updatedData[provider.rawValue] = .oauth(OAuthCredential(refreshed))
                return AuthStorageLockResult(
                    result: OAuthRefreshLockedResult(
                        value: (apiKey: result.apiKey, newCredentials: refreshed)
                    ),
                    next: try self.serializeAuthData(updatedData),
                    onCommit: self.cacheCommit(updatedData)
                )
            }

            return AuthStorageLockResult(
                result: OAuthRefreshLockedResult(value: nil),
                onCommit: self.cacheCommit(currentData)
            )
        }
    }

    private func oauthCredentialsMap(from credentials: [String: AuthCredential]) -> [String: OAuthCredentials] {
        var creds: [String: OAuthCredentials] = [:]
        for (provider, credential) in credentials {
            guard case .oauth(let oauth) = credential,
                  let refresh = oauth.refresh else { continue }
            let expires = oauth.expires ?? 0
            creds[provider] = OAuthCredentials(
                refresh: refresh,
                access: oauth.access,
                expires: expires,
                enterpriseUrl: oauth.enterpriseUrl,
                projectId: oauth.projectId,
                email: oauth.email,
                accountId: oauth.accountId,
                availableModelIds: oauth.availableModelIds,
                clientId: oauth.clientId,
                scopes: oauth.scopes,
                env: oauth.env
            )
        }
        return creds
    }

    private func envKeyName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "anthropic":
            return "ANTHROPIC_API_KEY"
        case "openai":
            return "OPENAI_API_KEY"
        case "google", "google-gemini-cli", "google-antigravity":
            return "GEMINI_API_KEY"
        case "openrouter":
            return "OPENROUTER_API_KEY"
        case "opencode":
            return "OPENCODE_API_KEY"
        case "groq":
            return "GROQ_API_KEY"
        case "cerebras":
            return "CEREBRAS_API_KEY"
        case "baseten":
            return "BASETEN_API_KEY"
        case "qwen-token-plan", "qwen-token-plan-individual":
            return "QWEN_TOKEN_PLAN_API_KEY"
        case "qwen-token-plan-cn":
            return "QWEN_TOKEN_PLAN_CN_API_KEY"
        case "xai":
            return "XAI_API_KEY"
        case "meta":
            return "META_API_KEY"
        case "zai":
            return "ZAI_API_KEY"
        default:
            return nil
        }
    }
}

private extension OAuthCredential {
    init(_ credentials: OAuthCredentials) {
        self.init(
            access: credentials.access,
            refresh: credentials.refresh,
            expires: credentials.expires,
            enterpriseUrl: credentials.enterpriseUrl,
            projectId: credentials.projectId,
            email: credentials.email,
            accountId: credentials.accountId,
            availableModelIds: credentials.availableModelIds,
            clientId: credentials.clientId,
            scopes: credentials.scopes,
            env: credentials.env
        )
    }

    func toOAuthCredentials() -> OAuthCredentials? {
        guard let refresh else { return nil }
        let expiry = expires ?? 0
        return OAuthCredentials(
            refresh: refresh,
            access: access,
            expires: expiry,
            enterpriseUrl: enterpriseUrl,
            projectId: projectId,
            email: email,
            accountId: accountId,
            availableModelIds: availableModelIds,
            clientId: clientId,
            scopes: scopes,
            env: env
        )
    }
}
