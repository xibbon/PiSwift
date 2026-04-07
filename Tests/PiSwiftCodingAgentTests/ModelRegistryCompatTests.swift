import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func modelRegistryParsesCompatRouting() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-compat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let json = """
    {
      "providers": {
        "openrouter": {
          "baseUrl": "https://openrouter.ai/api/v1",
          "models": [
            {
              "id": "test-model",
              "name": "Test Model",
              "api": "openai-completions",
              "reasoning": false,
              "input": ["text"],
              "cost": {
                "input": 1,
                "output": 2,
                "cacheRead": 0,
                "cacheWrite": 0
              },
              "contextWindow": 8192,
              "maxTokens": 4096,
              "compat": {
                "openRouterRouting": {
                  "only": ["openai", "anthropic"],
                  "order": ["anthropic"]
                },
                "vercelGatewayRouting": {
                  "only": ["openai"]
                }
              }
            }
          ]
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    let authStorage = AuthStorage(":memory:")
    let registry = ModelRegistry(authStorage, tempDir.path)
    guard let model = registry.find("openrouter", "test-model") else {
        #expect(Bool(false), "Expected test model to be available")
        return
    }

    #expect(model.compat?.openRouterRouting?.only == ["openai", "anthropic"])
    #expect(model.compat?.openRouterRouting?.order == ["anthropic"])
    #expect(model.compat?.vercelGatewayRouting?.only == ["openai"])
}

@Test func modelRegistryPreservesSlashDelimitedCustomModelIdsUnderConfiguredProvider() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-provider-ids-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let json = """
    {
      "providers": {
        "lmstudio": {
          "baseUrl": "http://localhost:1234/v1",
          "apiKey": "lmstudio",
          "api": "openai-completions",
          "models": [
            {
              "id": "qwen/qwen3-coder-next",
              "name": "Qwen 3 Coder Next",
              "reasoning": true,
              "input": ["text"],
              "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0
              },
              "contextWindow": 131072,
              "maxTokens": 8192
            }
          ]
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    let authStorage = AuthStorage(":memory:")
    let registry = ModelRegistry(authStorage, tempDir.path)
    guard let model = registry.find("lmstudio", "qwen/qwen3-coder-next") else {
        #expect(Bool(false), "Expected slash-delimited custom model ID to remain under lmstudio")
        return
    }

    #expect(model.provider == "lmstudio")
    #expect(model.id == "qwen/qwen3-coder-next")
    #expect(model.name == "Qwen 3 Coder Next")

    let available = await registry.getAvailable()
    #expect(available.contains { $0.provider == "lmstudio" && $0.id == "qwen/qwen3-coder-next" })
}
