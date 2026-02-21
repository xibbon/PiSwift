import Foundation
import Darwin
import PiSwiftAI

public struct ApiKeyCredential: Sendable {
    public var type: String = "api_key"
    public var key: String
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

public final class AuthStorage: Sendable {
    private struct State: Sendable {
        var data: [String: AuthCredential] = [:]
        var runtimeOverrides: [String: String] = [:]
        var fallbackResolver: (@Sendable (String) -> String?)?
        var lockOptionsOverride: AuthLockOptions?
        var oauthOverrides: OAuthOverrides?
        var loadError: String?
        var errors: [String] = []
    }

    private let state = LockedState(State())
    private let authPath: String

    public init(_ authPath: String) {
        self.authPath = authPath
        reload()
    }

    public static func create(_ authPath: String? = nil) -> AuthStorage {
        AuthStorage(authPath ?? getAuthPath())
    }

    public static func inMemory(_ data: [String: AuthCredential] = [:]) -> AuthStorage {
        let storage = AuthStorage(":memory:")
        storage.state.withLock { state in
            state.data = data
            state.loadError = nil
            state.errors = []
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
        state.withLock { $0.lockOptionsOverride = options }
    }

    func setOAuthOverridesForTesting(_ overrides: OAuthOverrides?) {
        state.withLock { $0.oauthOverrides = overrides }
    }

    public func reload() {
        guard authPath != ":memory:" else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)) else {
            state.withLock {
                $0.data = [:]
                $0.loadError = nil
            }
            return
        }
        do {
            let loaded = try parseAuthData(data)
            state.withLock {
                $0.data = loaded
                $0.loadError = nil
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
        state.withLock { $0.data[provider] = credential }
        persistProviderChange(provider: provider, credential: credential)
    }

    public func remove(_ provider: String) {
        state.withLock { $0.data.removeValue(forKey: provider) }
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
        case .githubCopilot, .googleGeminiCli, .googleAntigravity:
            throw OAuthError.notImplemented(provider.rawValue)
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

    private func save() {
        if authPath == ":memory:" { return }
        var json: [String: Any] = [:]
        let credentials = state.withLock { $0.data }
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

        let dir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: authPath))
            chmod(authPath, 0o600)
        }
    }

    private func persistProviderChange(provider: String, credential: AuthCredential?) {
        if authPath == ":memory:" { return }
        let blockedByLoadError = state.withLock { $0.loadError != nil }
        if blockedByLoadError {
            return
        }

        do {
            try withAuthLockSync {
                let url = URL(fileURLWithPath: authPath)
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                var merged: [String: AuthCredential] = [:]
                if let data = try? Data(contentsOf: url) {
                    merged = try parseAuthData(data)
                }
                if let credential {
                    merged[provider] = credential
                } else {
                    merged.removeValue(forKey: provider)
                }

                var json: [String: Any] = [:]
                for (providerName, value) in merged {
                    switch value {
                    case .apiKey(let apiKey):
                        json[providerName] = ["type": "api_key", "key": apiKey.key]
                    case .oauth(let oauth):
                        var entry: [String: Any] = ["type": "oauth", "access": oauth.access]
                        if let refresh = oauth.refresh { entry["refresh"] = refresh }
                        if let expires = oauth.expires { entry["expires"] = expires }
                        if let enterpriseUrl = oauth.enterpriseUrl { entry["enterpriseUrl"] = enterpriseUrl }
                        if let projectId = oauth.projectId { entry["projectId"] = projectId }
                        if let email = oauth.email { entry["email"] = email }
                        if let accountId = oauth.accountId { entry["accountId"] = accountId }
                        json[providerName] = entry
                    }
                }

                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                    try? data.write(to: url)
                    chmod(authPath, 0o600)
                }
            }
        } catch {
            state.withLock { state in
                state.errors.append(error.localizedDescription)
            }
        }
    }

    private func parseAuthData(_ data: Data) throws -> [String: AuthCredential] {
        let raw = try JSONSerialization.jsonObject(with: data)
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

    private func refreshOAuthTokenWithLock(_ provider: OAuthProvider) async throws -> (apiKey: String, newCredentials: OAuthCredentials)? {
        try await withAuthLock {
            self.reload()

            let credential = self.state.withLock { $0.data[provider.rawValue] }
            guard case .oauth(let oauth) = credential else {
                return nil
            }

            let now = Date().timeIntervalSince1970 * 1000
            if let expires = oauth.expires, now < expires {
                let apiKey = try oauthApiKey(provider: provider, accessToken: oauth.access, projectId: oauth.projectId)
                if let creds = oauth.toOAuthCredentials() {
                    return (apiKey: apiKey, newCredentials: creds)
                }
                return (apiKey: apiKey, newCredentials: OAuthCredentials(
                    refresh: oauth.refresh ?? "",
                    access: oauth.access,
                    expires: expires,
                    enterpriseUrl: oauth.enterpriseUrl,
                    projectId: oauth.projectId,
                    email: oauth.email,
                    accountId: oauth.accountId
                ))
            }

            let oauthCreds = self.oauthCredentialsMap()
            let override = self.state.withLock { $0.oauthOverrides }
            let result: (newCredentials: OAuthCredentials, apiKey: String)?
            if let overrideFn = override?.getOAuthApiKey {
                result = try await overrideFn(provider, oauthCreds)
            } else {
                result = try await getOAuthApiKey(provider: provider, credentials: oauthCreds)
            }
            if let result {
                self.state.withLock { state in
                    state.data[provider.rawValue] = .oauth(OAuthCredential(result.newCredentials))
                }
                self.save()
                return (apiKey: result.apiKey, newCredentials: result.newCredentials)
            }

            return nil
        }
    }

    private func oauthCredentialsMap() -> [String: OAuthCredentials] {
        var creds: [String: OAuthCredentials] = [:]
        let credentials = state.withLock { $0.data }
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

    private func withAuthLock<T>(_ body: @escaping () async throws -> T) async throws -> T {
        ensureAuthFileExists()

        let fd = open(authPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OAuthError.refreshFailed("failed to open auth.json")
        }
        defer { close(fd) }

        let override = state.withLock { $0.lockOptionsOverride }
        let maxAttempts = override?.maxAttempts ?? 10
        let maxDelayMs = override?.maxDelayMs ?? 10_000
        var delayMs = override?.initialDelayMs ?? 100
        var locked = false
        if maxAttempts <= 0 {
            throw OAuthError.refreshFailed("failed to acquire auth.json lock")
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
            throw OAuthError.refreshFailed("failed to acquire auth.json lock")
        }

        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private func withAuthLockSync<T>(_ body: () throws -> T) throws -> T {
        ensureAuthFileExists()

        let fd = open(authPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw OAuthError.refreshFailed("failed to open auth.json")
        }
        defer { close(fd) }

        let override = state.withLock { $0.lockOptionsOverride }
        let maxAttempts = override?.maxAttempts ?? 10
        let maxDelayMs = override?.maxDelayMs ?? 10_000
        var delayMs = override?.initialDelayMs ?? 100
        var locked = false
        if maxAttempts <= 0 {
            throw OAuthError.refreshFailed("failed to acquire auth.json lock")
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
            throw OAuthError.refreshFailed("failed to acquire auth.json lock")
        }

        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func ensureAuthFileExists() {
        let dir = URL(fileURLWithPath: authPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if !FileManager.default.fileExists(atPath: authPath) {
            let empty = Data("{}".utf8)
            FileManager.default.createFile(atPath: authPath, contents: empty, attributes: [.posixPermissions: 0o600])
        }
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
