import Foundation
import Testing
import TestEnvironmentSupport
import PiSwiftAI
import PiSwiftCodingAgent

private func withEnvValue(_ key: String, value: String?, _ work: () throws -> Void) rethrows {
    let previous = ProcessInfo.processInfo.environment[key]
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
    defer {
        if let previous {
            setenv(key, previous, 1)
        } else {
            unsetenv(key)
        }
    }
    try work()
}

@Test(.processEnvironment, .timeLimit(.minutes(1))) func modelRegistryResolvesProviderHeadersFromEnvAndCommand() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let json = """
    {
      "providers": {
        "openai": {
          "baseUrl": "https://api.openai.com/v1",
          "headers": {
            "X-Env": "$PI_TEST_HEADER_ENV",
            "X-Command": "!printf cmd-value"
          }
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    // Upstream provider-composer resolves configured headers at request time,
    // uncached. Bare environment names are literals; references require `$`.
    let authStorage = AuthStorage(":memory:")
    authStorage.set("openai", credential: .apiKey(ApiKeyCredential(key: "test-key", env: ["PI_TEST_HEADER_ENV": "env-value"])))
    let registry = ModelRegistry(authStorage, tempDir.path)
    let model = try #require(registry.find("openai", "gpt-4o-mini"))
    let auth = await registry.getApiKeyAndHeaders(model)
    #expect(auth.ok)
    #expect(auth.headers?["X-Env"] == "env-value")
    #expect(auth.headers?["X-Command"] == "cmd-value")
}
