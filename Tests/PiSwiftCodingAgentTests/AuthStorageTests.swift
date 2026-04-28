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
