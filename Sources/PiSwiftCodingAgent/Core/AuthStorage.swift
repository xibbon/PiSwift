import Foundation
import Darwin
import PiSwiftAI

public struct ApiKeyCredential: Sendable {
    public var type: String = "api_key"
    public var key: String

    public init(key: String) {
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

    public init(
        access: String,
        refresh: String?,
        expires: Double?,
        enterpriseUrl: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        accountId: String? = nil
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.enterpriseUrl = enterpriseUrl
        self.projectId = projectId
        self.email = email
        self.accountId = accountId
    }
}

public enum AuthCredential: Sendable {
    case apiKey(ApiKeyCredential)
    case oauth(OAuthCredential)
}

struct AuthLockOptions: Sendable {
    var maxAttempts: Int
    var initialDelayMs: Int
    var maxDelayMs: Int
}

struct OAuthOverrides: Sendable {
    var getOAuthApiKey: (@Sendable (OAuthProvider, [String: OAuthCredentials]) async throws -> (newCredentials: OAuthCredentials, apiKey: String)?)?
    var oauthApiKey: (@Sendable (OAuthProvider, String, String?) throws -> String)?
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
public protocol AuthStorageBackend: Sendable {
    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result
}

/// The default `AuthStorageBackend`, which stores credentials in an auth JSON file.
public final class FileAuthStorageBackend: AuthStorageBackend {
    private let authPath: String
    private let lockOptionsOverride = LockedState<AuthLockOptions?>(nil)

    public init(_ authPath: String = getAuthPath()) {
        self.authPath = authPath
    }

    public func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        try withFileLockSync {
            let current = try String(contentsOfFile: authPath, encoding: .utf8)
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
        try await withFileLock {
            let current = try String(contentsOfFile: self.authPath, encoding: .utf8)
            let transaction = try await body(current)
            if let next = transaction.next {
                try self.write(next)
            }
            transaction.onCommit()
            return transaction.result
        }
    }

    func setLockOptionsForTesting(_ options: AuthLockOptions?) {
        lockOptionsOverride.withLock { $0 = options }
    }

    private func write(_ value: String) throws {
        try value.write(toFile: authPath, atomically: false, encoding: .utf8)
        chmod(authPath, 0o600)
    }

    private func withFileLock<Result: Sendable>(
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
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            delayMs = min(delayMs * 2, maxDelayMs)
        }

        guard locked else {
            throw OAuthError.refreshFailed("failed to acquire auth storage lock")
        }

        defer { flock(fd, LOCK_UN) }
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Coordinates synchronous and asynchronous in-memory transactions without
/// holding a thread mutex across an `await`.
private final class InMemoryTransactionState: @unchecked Sendable {
    // `condition` protects both transaction flags; `value` has its own mutex.
    // The flags ensure no transaction can observe or update `value` while an
    // asynchronous transaction is suspended in its closure.
    private let value: LockedState<String?>
    private let asyncGate = AsyncTransactionGate()
    private let condition = NSCondition()
    private var synchronousTransactionInProgress = false
    private var asynchronousTransactionInProgress = false

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
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        await asyncGate.acquire()
        beginAsynchronousTransaction()

        do {
            let current = value.withLock { $0 }
            let transaction = try await body(current)
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
        condition.lock()
        while synchronousTransactionInProgress || asynchronousTransactionInProgress {
            condition.wait()
        }
        synchronousTransactionInProgress = true
        condition.unlock()
    }

    private func endSynchronousTransaction() {
        condition.lock()
        synchronousTransactionInProgress = false
        condition.broadcast()
        condition.unlock()
    }

    private func beginAsynchronousTransaction() {
        condition.lock()
        while synchronousTransactionInProgress || asynchronousTransactionInProgress {
            condition.wait()
        }
        asynchronousTransactionInProgress = true
        condition.unlock()
    }

    private func endAsynchronousTransaction() {
        condition.lock()
        asynchronousTransactionInProgress = false
        condition.broadcast()
        condition.unlock()
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
        try await state.withLockAsync(body)
    }
}

public final class AuthStorage: Sendable {
    private struct State: Sendable {
        var data: [String: AuthCredential] = [:]
        var runtimeOverrides: [String: String] = [:]
        var fallbackResolver: (@Sendable (String) -> String?)?
        var oauthOverrides: OAuthOverrides?
        var loadError: String?
        var errors: [String] = []
    }

    private let state = LockedState(State())
    private let storage: any AuthStorageBackend

    public init(_ authPath: String) {
        if authPath == ":memory:" {
            storage = InMemoryAuthStorageBackend()
        } else {
            storage = FileAuthStorageBackend(authPath)
        }
        reload()
    }

    /// Creates auth storage backed by a caller-provided persistence implementation.
    public init(storage: any AuthStorageBackend) {
        self.storage = storage
        reload()
    }

    public static func create(_ authPath: String? = nil) -> AuthStorage {
        AuthStorage(storage: FileAuthStorageBackend(authPath ?? getAuthPath()))
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

    public func setFallbackResolver(_ resolver: @escaping @Sendable (String) -> String?) {
        state.withLock { $0.fallbackResolver = resolver }
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

    public func has(_ provider: String) -> Bool {
        state.withLock { $0.data[provider] != nil }
    }

    public func hasAuth(_ provider: String) -> Bool {
        let snapshot = state.withLock { state in
            let runtime = state.runtimeOverrides[provider]
            let credential = state.data[provider]
            return (runtime: runtime, credential: credential, fallback: state.fallbackResolver)
        }
        if snapshot.runtime != nil {
            return true
        }
        if snapshot.credential != nil {
            return true
        }
        if getEnvApiKey(provider: provider) != nil {
            return true
        }
        if snapshot.fallback?(provider) != nil {
            return true
        }
        return false
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
            credentials = try await loginAnthropic(callbacks)
        case .openAICodex:
            credentials = try await loginOpenAICodex(callbacks)
        case .githubCopilot:
            credentials = try await loginGitHubCopilot(callbacks)
        case .googleGeminiCli:
            credentials = try await loginGoogleGeminiCli(callbacks)
        case .googleAntigravity:
            credentials = try await loginAntigravity(callbacks)
        case .xai:
            credentials = try await loginXai(callbacks)
        }
        set(provider.rawValue, credential: .oauth(OAuthCredential(credentials)))
    }

    public func logout(_ provider: OAuthProvider) {
        remove(provider.rawValue)
    }

    public func getApiKey(_ provider: String) async -> String? {
        let snapshot = state.withLock { state in
            let runtime = state.runtimeOverrides[provider]
            let credential = state.data[provider]
            return (runtime: runtime, credential: credential, fallback: state.fallbackResolver)
        }

        if let runtime = snapshot.runtime {
            return runtime
        }
        if let credential = snapshot.credential {
            switch credential {
            case .apiKey(let apiKey):
                return resolveConfigValue(apiKey.key)
            case .oauth(let oauth):
                let oauthProviderId = OAuthProvider(rawValue: provider)
                let now = Date().timeIntervalSince1970 * 1000
                let needsRefresh = oauth.expires == nil || now >= (oauth.expires ?? 0)
                if needsRefresh,
                   let providerId = oauthProviderId,
                   oauth.refresh != nil {
                    do {
                        if let result = try await refreshOAuthTokenWithLock(providerId) {
                            return result.apiKey
                        }
                    } catch {
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

        if let envKey = getEnvApiKey(provider: provider) {
            return envKey
        }

        if let envName = envKeyName(for: provider),
           let value = ProcessInfo.processInfo.environment[envName],
           !value.isEmpty {
            return value
        }

        return snapshot.fallback?(provider)
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
            throw NSError(domain: "AuthStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid auth storage format"])
        }

        var loaded: [String: AuthCredential] = [:]
        for (provider, value) in json {
            guard let dict = value as? [String: Any],
                  let type = dict["type"] as? String else { continue }
            if type == "api_key", let key = dict["key"] as? String {
                loaded[provider] = .apiKey(ApiKeyCredential(key: key))
            } else if type == "oauth" {
                let access = (dict["access"] as? String) ?? (dict["accessToken"] as? String)
                guard let access else { continue }
                let refresh = (dict["refresh"] as? String) ?? (dict["refreshToken"] as? String)
                let expires = (dict["expires"] as? Double) ?? (dict["expiresAt"] as? Double)
                let enterpriseUrl = dict["enterpriseUrl"] as? String
                let projectId = dict["projectId"] as? String
                let email = dict["email"] as? String
                let accountId = dict["accountId"] as? String
                loaded[provider] = .oauth(OAuthCredential(
                    access: access,
                    refresh: refresh,
                    expires: expires,
                    enterpriseUrl: enterpriseUrl,
                    projectId: projectId,
                    email: email,
                    accountId: accountId
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
                json[provider] = ["type": "api_key", "key": apiKey.key]
            case .oauth(let oauth):
                var entry: [String: Any] = ["type": "oauth", "access": oauth.access]
                if let refresh = oauth.refresh { entry["refresh"] = refresh }
                if let expires = oauth.expires { entry["expires"] = expires }
                if let enterpriseUrl = oauth.enterpriseUrl { entry["enterpriseUrl"] = enterpriseUrl }
                if let projectId = oauth.projectId { entry["projectId"] = projectId }
                if let email = oauth.email { entry["email"] = email }
                if let accountId = oauth.accountId { entry["accountId"] = accountId }
                json[provider] = entry
            }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        guard let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AuthStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode auth storage"])
        }
        return content
    }

    private func cacheCommit(_ data: [String: AuthCredential]) -> @Sendable () -> Void {
        { [self] in
            state.withLock { state in
                state.data = data
                state.loadError = nil
            }
        }
    }

    private struct OAuthRefreshLockedResult: Sendable {
        var value: (apiKey: String, newCredentials: OAuthCredentials)?
    }

    private func refreshOAuthTokenWithLock(_ provider: OAuthProvider) async throws -> (apiKey: String, newCredentials: OAuthCredentials)? {
        let lockedResult = try await storage.withLockAsync { current in
            let currentData = try self.parseAuthData(current)
            let credential = currentData[provider.rawValue]
            guard case .oauth(let oauth) = credential else {
                return AuthStorageLockResult(
                    result: OAuthRefreshLockedResult(value: nil),
                    onCommit: self.cacheCommit(currentData)
                )
            }

            let now = Date().timeIntervalSince1970 * 1000
            if let expires = oauth.expires, now < expires {
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
                        accountId: oauth.accountId
                    ))
                ), onCommit: self.cacheCommit(currentData))
            }

            let oauthCreds = self.oauthCredentialsMap(from: currentData)
            let override = self.state.withLock { $0.oauthOverrides }
            let result: (newCredentials: OAuthCredentials, apiKey: String)?
            if let overrideFn = override?.getOAuthApiKey {
                result = try await overrideFn(provider, oauthCreds)
            } else {
                result = try await getOAuthApiKey(provider: provider, credentials: oauthCreds)
            }
            if let result {
                var updatedData = currentData
                updatedData[provider.rawValue] = .oauth(OAuthCredential(result.newCredentials))
                return AuthStorageLockResult(
                    result: OAuthRefreshLockedResult(
                        value: (apiKey: result.apiKey, newCredentials: result.newCredentials)
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
        return lockedResult.value
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
                accountId: oauth.accountId
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
        case "xai":
            return "XAI_API_KEY"
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
            accountId: credentials.accountId
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
            accountId: accountId
        )
    }
}
