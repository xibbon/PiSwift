import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func makeTempDir(_ prefix: String) -> String {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    return tempDir
}

private func writeAuthJson(_ path: String, data: [String: Any]) {
    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload = (try? JSONSerialization.data(withJSONObject: data, options: [])) ?? Data()
    try? payload.write(to: url)
}

/// Represents an app-owned secure store, such as a Keychain wrapper. The test
/// intentionally only implements the public backend protocol.
private final class SecureStoreTestBackend: AuthStorageBackend {
    private let storage = InMemoryAuthStorageBackend()

    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        try storage.withLock(body)
    }

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        try await storage.withLockAsync(body)
    }
}

private actor AsyncTransactionBarrier {
    private var firstStarted = false
    private var isReleased = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func signalFirstStarted() {
        firstStarted = true
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitForFirstStart() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func releaseFirst() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class OutOfOrderReturnBackend: AuthStorageBackend {
    private struct State: Sendable {
        var value: String?
        var writeCount = 0
        var firstWriteIsWaiting = false
    }

    private let state = LockedState(State())
    private let allowFirstWriteToReturn = DispatchSemaphore(value: 0)

    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        let (result, writeCount) = try state.withLock { state in
            let transaction = try body(state.value)
            if let next = transaction.next {
                state.value = next
                state.writeCount += 1
            }
            transaction.onCommit()
            if state.writeCount == 1, transaction.next != nil {
                state.firstWriteIsWaiting = true
            }
            return (transaction.result, transaction.next == nil ? 0 : state.writeCount)
        }

        if writeCount == 1 {
            allowFirstWriteToReturn.wait()
        } else if writeCount == 2 {
            allowFirstWriteToReturn.signal()
        }
        return result
    }

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        fatalError("This test backend only exercises synchronous transactions")
    }

    func isFirstWriteWaiting() -> Bool {
        state.withLock { $0.firstWriteIsWaiting }
    }
}

@Test func authStorageUsesConsumerProvidedBackend() async {
    let backend = SecureStoreTestBackend()
    let storage = AuthStorage(storage: backend)

    storage.set("anthropic", credential: .apiKey(ApiKeyCredential(key: "secure-key")))
    #expect(await storage.getApiKey("anthropic") == "secure-key")

    let reloaded = AuthStorage.fromStorage(backend)
    #expect(await reloaded.getApiKey("anthropic") == "secure-key")
}

@Test func inMemoryBackendSerializesAsyncTransactions() async throws {
    let backend = InMemoryAuthStorageBackend()
    let barrier = AsyncTransactionBarrier()

    let first = Task {
        try await backend.withLockAsync { _ in
            await barrier.signalFirstStarted()
            await barrier.waitForRelease()
            return AuthStorageLockResult(result: (), next: "first")
        }
    }
    await barrier.waitForFirstStart()

    let second = Task {
        try await backend.withLockAsync { current in
            AuthStorageLockResult(result: current)
        }
    }

    for _ in 0..<10 {
        await Task.yield()
    }
    await barrier.releaseFirst()

    _ = try await first.value
    #expect(try await second.value == "first")
}

@Test func authStorageInMemoryRefreshesExpiredOAuthOnlyOnce() async {
    let now = Date().timeIntervalSince1970 * 1000
    let storage = AuthStorage.inMemory([
        "anthropic": .oauth(OAuthCredential(
            access: "expired-access",
            refresh: "refresh-token",
            expires: now - 1
        )),
    ])
    let refreshCount = LockedState(0)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { _, _ in
            refreshCount.withLock { $0 += 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            let credentials = OAuthCredentials(
                refresh: "refresh-token",
                access: "fresh-access",
                expires: now + 10 * 60_000
            )
            return (newCredentials: credentials, apiKey: "fresh-access")
        },
        oauthApiKey: { _, access, _ in "Bearer \(access)" }
    ))

    async let first = storage.getApiKey("anthropic")
    async let second = storage.getApiKey("anthropic")
    let firstKey = await first
    let secondKey = await second
    #expect(firstKey == "fresh-access")
    #expect(secondKey == "fresh-access")
    #expect(refreshCount.withLock { $0 } == 1)
}

@Test func authStorageRefreshesWithinMinimumValidityWindow() async {
    let now = Date().timeIntervalSince1970 * 1000

    func makeStorage(expires: Double, refreshCount: LockedState<Int>) -> AuthStorage {
        let storage = AuthStorage.inMemory([
            "anthropic": .oauth(OAuthCredential(
                access: "current-access",
                refresh: "refresh-token",
                expires: expires
            )),
        ])
        storage.setOAuthOverridesForTesting(OAuthOverrides(
            getOAuthApiKey: { _, _ in
                refreshCount.withLock { $0 += 1 }
                let credentials = OAuthCredentials(
                    refresh: "refresh-token",
                    access: "refreshed-access",
                    expires: now + 60 * 60_000
                )
                return (newCredentials: credentials, apiKey: "refreshed-access")
            },
            oauthApiKey: nil
        ))
        return storage
    }

    let soonCount = LockedState(0)
    let soonStorage = makeStorage(expires: now + 2 * 60_000, refreshCount: soonCount)
    #expect(await soonStorage.getApiKey("anthropic") == "refreshed-access")
    #expect(soonCount.withLock { $0 } == 1)

    let laterCount = LockedState(0)
    let laterStorage = makeStorage(expires: now + 30 * 60_000, refreshCount: laterCount)
    #expect(await laterStorage.getApiKey("anthropic") == "current-access")
    #expect(laterCount.withLock { $0 } == 0)

    let forcedCount = LockedState(0)
    let forcedStorage = makeStorage(expires: now + 30 * 60_000, refreshCount: forcedCount)
    #expect(await forcedStorage.getApiKey(
        "anthropic",
        minimumOAuthValidityMs: 45 * 60_000
    ) == "refreshed-access")
    #expect(forcedCount.withLock { $0 } == 1)
}

@Test func authStorageCancelledRefreshDoesNotCommit() async {
    let now = Date().timeIntervalSince1970 * 1000
    let storage = AuthStorage.inMemory([
        "xai": .oauth(OAuthCredential(
            access: "old-access",
            refresh: "refresh-token",
            expires: now - 1
        )),
    ])
    let refreshStarted = LockedState(false)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { _, _ in
            refreshStarted.withLock { $0 = true }
            try await Task.sleep(nanoseconds: 50_000_000)
            let credentials = OAuthCredentials(
                refresh: "refresh-token",
                access: "new-access",
                expires: now + 60 * 60_000
            )
            return (newCredentials: credentials, apiKey: "new-access")
        },
        oauthApiKey: nil
    ))

    let signal = CancellationToken()
    let request = Task { await storage.getApiKey("xai", signal: signal) }
    while !refreshStarted.withLock({ $0 }) {
        await Task.yield()
    }
    signal.cancel()
    #expect(await request.value == nil)
    guard case .oauth(let stored) = storage.get("xai") else {
        Issue.record("Missing stored OAuth credential")
        return
    }
    #expect(stored.access == "old-access")
}

@Test func authStorageCacheFollowsTransactionCommitOrder() async {
    let backend = OutOfOrderReturnBackend()
    let storage = AuthStorage(storage: backend)

    let first = Task.detached {
        storage.set("anthropic", credential: .apiKey(ApiKeyCredential(key: "anthropic-key")))
    }
    while !backend.isFirstWriteWaiting() {
        await Task.yield()
    }

    let second = Task.detached {
        storage.set("openai", credential: .apiKey(ApiKeyCredential(key: "openai-key")))
    }
    await second.value
    await first.value

    #expect(storage.has("anthropic"))
    #expect(storage.has("openai"))
}

@Test func authStorageLiteralApiKeyReturned() async {
    let tempDir = makeTempDir("auth-storage-literal")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "sk-ant-literal-key"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "sk-ant-literal-key")
}

@Test func authStorageCommandApiKeyUsesStdout() async {
    let tempDir = makeTempDir("auth-storage-command")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo test-api-key-from-command"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "test-api-key-from-command")
}

@Test func authStorageCommandApiKeyTrimsWhitespace() async {
    let tempDir = makeTempDir("auth-storage-trim")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo '  spaced-key  '"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "spaced-key")
}

@Test func authStorageCommandApiKeyHandlesMultilineOutput() async {
    let tempDir = makeTempDir("auth-storage-multiline")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!printf 'line1\\nline2'"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "line1\nline2")
}

@Test func authStorageCommandApiKeyFailureReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-fail")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!exit 1"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageCommandApiKeyNonexistentCommandReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-missing")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!nonexistent-command-12345"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageCommandApiKeyEmptyOutputReturnsNil() async {
    let tempDir = makeTempDir("auth-storage-empty")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!printf ''"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == nil)
}

@Test func authStorageEnvVarNameResolves() async {
    let tempDir = makeTempDir("auth-storage-env")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let envName = "TEST_AUTH_API_KEY_12345"
    let previous = ProcessInfo.processInfo.environment[envName]
    setenv(envName, "env-api-key-value", 1)
    defer {
        if let previous {
            setenv(envName, previous, 1)
        } else {
            unsetenv(envName)
        }
    }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": envName]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "env-api-key-value")
}

@Test func authStorageLiteralValueUsedWhenNotEnv() async {
    let tempDir = makeTempDir("auth-storage-literal-env")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    unsetenv("literal_api_key_value")

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "literal_api_key_value"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "literal_api_key_value")
}

@Test func authStorageCommandApiKeySupportsPipes() async {
    let tempDir = makeTempDir("auth-storage-pipes")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo 'hello world' | tr ' ' '-'"]])

    let storage = AuthStorage(authPath)
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "hello-world")
}

/// v0.63.0: shell-command auth resolves at request time. The previous in-process cache
/// was removed because it caused expiring tokens (OAuth, AWS STS) to be returned stale.
/// Each call to `getApiKey` re-executes the underlying command. Caching policy is the
/// responsibility of the user-provided wrapper command.
@Test func authStorageCommandExecutesEveryCall() async {
    let tempDir = makeTempDir("auth-storage-cache")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); echo key-value'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage = AuthStorage(authPath)
    _ = await storage.getApiKey("anthropic")
    _ = await storage.getApiKey("anthropic")
    _ = await storage.getApiKey("anthropic")

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    // v0.63.0: 3 calls → 3 executions (no caching).
    #expect(count == 3)
}

@Test func authStorageCommandExecutesPerInstance() async {
    let tempDir = makeTempDir("auth-storage-cache-instances")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); echo key-value'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage1 = AuthStorage(authPath)
    _ = await storage1.getApiKey("anthropic")

    let storage2 = AuthStorage(authPath)
    _ = await storage2.getApiKey("anthropic")

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    // v0.63.0: each call re-executes (no persistent cache across calls or instances).
    #expect(count == 2)
}

@Test func authStorageCachesDifferentCommandsSeparately() async {
    let tempDir = makeTempDir("auth-storage-cache-separate")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "!echo key-anthropic"],
        "openai": ["type": "api_key", "key": "!echo key-openai"],
    ])

    let storage = AuthStorage(authPath)
    let keyA = await storage.getApiKey("anthropic")
    let keyB = await storage.getApiKey("openai")

    #expect(keyA == "key-anthropic")
    #expect(keyB == "key-openai")
}

/// v0.63.0: failures are no longer cached either — each call re-executes, giving the
/// wrapper command a fresh chance to recover.
@Test func authStorageFailedCommandsRetry() async {
    let tempDir = makeTempDir("auth-storage-cache-fail")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let counterFile = URL(fileURLWithPath: tempDir).appendingPathComponent("counter").path
    try? "0".write(toFile: counterFile, atomically: true, encoding: .utf8)

    let command = "!sh -c 'count=$(cat \(counterFile)); echo $((count + 1)) > \(counterFile); exit 1'"
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": command]])

    let storage = AuthStorage(authPath)
    let key1 = await storage.getApiKey("anthropic")
    let key2 = await storage.getApiKey("anthropic")

    #expect(key1 == nil)
    #expect(key2 == nil)

    let count = Int((try? String(contentsOfFile: counterFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0") ?? 0
    // Each call re-executes; both attempts ran the failing command.
    #expect(count == 2)
}

@Test func authStorageEnvVarsNotCached() async {
    let tempDir = makeTempDir("auth-storage-env-cache")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let envVarName = "TEST_AUTH_KEY_CACHE_TEST_98765"
    let previous = ProcessInfo.processInfo.environment[envVarName]
    defer {
        if let previous {
            setenv(envVarName, previous, 1)
        } else {
            unsetenv(envVarName)
        }
    }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": envVarName]])

    setenv(envVarName, "first-value", 1)
    let storage = AuthStorage(authPath)
    let key1 = await storage.getApiKey("anthropic")
    #expect(key1 == "first-value")

    setenv(envVarName, "second-value", 1)
    let key2 = await storage.getApiKey("anthropic")
    #expect(key2 == "second-value")
}

@Test func authStorageOAuthLockFailureAllowsLaterRetry() async {
    let tempDir = makeTempDir("auth-storage-oauth-lock")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": [
            "type": "oauth",
            "refresh": "refresh-token",
            "access": "expired-access-token",
            "expires": Double(now - 10_000),
        ],
    ])

    let storage = AuthStorage(authPath)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { _, _ in
            let creds = OAuthCredentials(
                refresh: "refresh-token",
                access: "refreshed-access-token",
                expires: Double(now + 60_000)
            )
            return (newCredentials: creds, apiKey: "Bearer refreshed-access-token")
        },
        oauthApiKey: nil
    ))

    storage.setAuthLockOptionsForTesting(AuthLockOptions(maxAttempts: 0, initialDelayMs: 1, maxDelayMs: 1))
    let firstTry = await storage.getApiKey("anthropic")
    #expect(firstTry == nil)

    storage.setAuthLockOptionsForTesting(nil)
    let secondTry = await storage.getApiKey("anthropic")
    #expect(secondTry == "Bearer refreshed-access-token")
}

@Test func authStorageRuntimeOverrideTakesPriority() async {
    let tempDir = makeTempDir("auth-storage-runtime")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo stored-key"]])

    let storage = AuthStorage(authPath)
    storage.setRuntimeApiKey("anthropic", "runtime-key")
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "runtime-key")
}

@Test func authStorageRuntimeOverrideRemovalFallsBack() async {
    let tempDir = makeTempDir("auth-storage-runtime-fallback")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "!echo stored-key"]])

    let storage = AuthStorage(authPath)
    storage.setRuntimeApiKey("anthropic", "runtime-key")
    storage.removeRuntimeApiKey("anthropic")
    let apiKey = await storage.getApiKey("anthropic")
    #expect(apiKey == "stored-key")
}

@Test func authStorageSetPreservesUnrelatedExternalEdits() async {
    let tempDir = makeTempDir("auth-storage-preserve-set")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "old-anthropic"],
        "openai": ["type": "api_key", "key": "openai-key"],
    ])

    let storage = AuthStorage.create(authPath)
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "old-anthropic"],
        "openai": ["type": "api_key", "key": "openai-key"],
        "google": ["type": "api_key", "key": "google-key"],
    ])

    storage.set("anthropic", credential: .apiKey(ApiKeyCredential(key: "new-anthropic")))
    let data = try? Data(contentsOf: URL(fileURLWithPath: authPath))
    let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
    let anth = json?["anthropic"] as? [String: Any]
    let openai = json?["openai"] as? [String: Any]
    let google = json?["google"] as? [String: Any]
    #expect(anth?["key"] as? String == "new-anthropic")
    #expect(openai?["key"] as? String == "openai-key")
    #expect(google?["key"] as? String == "google-key")
}

@Test func authStorageRemovePreservesUnrelatedExternalEdits() async {
    let tempDir = makeTempDir("auth-storage-preserve-remove")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "anthropic-key"],
        "openai": ["type": "api_key", "key": "openai-key"],
    ])

    let storage = AuthStorage.create(authPath)
    writeAuthJson(authPath, data: [
        "anthropic": ["type": "api_key", "key": "anthropic-key"],
        "openai": ["type": "api_key", "key": "openai-key"],
        "google": ["type": "api_key", "key": "google-key"],
    ])

    storage.remove("anthropic")
    let data = try? Data(contentsOf: URL(fileURLWithPath: authPath))
    let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
    #expect((json?["anthropic"] as? [String: Any]) == nil)
    #expect((json?["openai"] as? [String: Any])?["key"] as? String == "openai-key")
    #expect((json?["google"] as? [String: Any])?["key"] as? String == "google-key")
}

@Test func authStorageDoesNotOverwriteMalformedFileAfterReloadError() async throws {
    let tempDir = makeTempDir("auth-storage-malformed")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "anthropic-key"]])
    let storage = AuthStorage.create(authPath)

    try "{invalid-json".write(toFile: authPath, atomically: true, encoding: .utf8)
    storage.reload()
    storage.set("openai", credential: .apiKey(ApiKeyCredential(key: "openai-key")))

    let raw = try String(contentsOfFile: authPath, encoding: .utf8)
    #expect(raw == "{invalid-json")
}

@Test func authStorageDrainErrorsClearsAfterRead() async throws {
    let tempDir = makeTempDir("auth-storage-errors")
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authPath = URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path
    writeAuthJson(authPath, data: ["anthropic": ["type": "api_key", "key": "anthropic-key"]])
    let storage = AuthStorage.create(authPath)

    try "{invalid-json".write(toFile: authPath, atomically: true, encoding: .utf8)
    storage.reload()
    let first = storage.drainErrors()
    #expect(!first.isEmpty)
    let second = storage.drainErrors()
    #expect(second.isEmpty)
}
