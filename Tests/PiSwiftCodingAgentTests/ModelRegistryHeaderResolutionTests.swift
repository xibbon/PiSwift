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

@Test(.processEnvironment, .timeLimit(.minutes(1))) func modelRegistryResolvesProviderHeadersFromEnvAndCommand() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let json = """
    {
      "providers": {
        "openai": {
          "baseUrl": "https://api.openai.com/v1",
          "headers": {
            "X-Env": "PI_TEST_HEADER_ENV",
            "X-Command": "!printf cmd-value"
          }
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    withEnvValue("PI_TEST_HEADER_ENV", value: "env-value") {
        let authStorage = AuthStorage(":memory:")
        let registry = ModelRegistry(authStorage, tempDir.path)
        guard let model = registry.find("openai", "gpt-4o-mini") else {
            #expect(Bool(false), "Expected openai model to be available")
            return
        }
        #expect(model.headers?["X-Env"] == "env-value")
        #expect(model.headers?["X-Command"] == "cmd-value")
    }
}
