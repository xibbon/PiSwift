import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func modelRegistryRegistersDynamicHookProvider() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let config = HookProviderConfig(
        provider: "swift-extension-provider",
        api: .openAIResponses,
        baseUrl: "https://example.invalid/v1",
        apiKey: "ext-token",
        headers: ["X-Provider": "provider"],
        models: [
            HookProviderModel(
                id: "swift-extension-model",
                name: "Swift Extension Model",
                input: [.text, .image],
                contextWindow: 8192,
                maxTokens: 4096,
                headers: ["X-Model": "model"]
            )
        ]
    )

    registry.registerProvider(config, sourceId: "/extensions/provider.swift")

    let model = try #require(registry.find("swift-extension-provider", "swift-extension-model"))
    #expect(model.name == "Swift Extension Model")
    #expect(model.api == .openAIResponses)
    #expect(model.baseUrl == "https://example.invalid/v1")
    #expect(model.input == [.text, .image])
    #expect(model.contextWindow == 8192)
    #expect(model.maxTokens == 4096)
    #expect(model.headers?["X-Provider"] == "provider")
    #expect(model.headers?["X-Model"] == "model")
    #expect(await registry.getApiKeyForProvider("swift-extension-provider") == "ext-token")

    registry.unregisterProvider("swift-extension-provider", sourceId: "/extensions/provider.swift")

    #expect(registry.find("swift-extension-provider", "swift-extension-model") == nil)
    #expect(await registry.getApiKeyForProvider("swift-extension-provider") == nil)
}

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

@Test func modelRegistryAppliesProviderCompatOverrideWithoutReplacingBuiltIns() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-provider-compat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let baselineRegistry = ModelRegistry(AuthStorage(":memory:"))
    let baselineOpenAIModels = baselineRegistry.getAll().filter { $0.provider == "openai" }
    let baselineModel = try #require(baselineOpenAIModels.first)

    let json = """
    {
      "providers": {
        "openai": {
          "compat": {
            "supportsLongCacheRetention": false,
            "sendSessionIdHeader": false,
            "cacheControlFormat": "anthropic"
          }
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let openAIModels = registry.getAll().filter { $0.provider == "openai" }
    #expect(openAIModels.count == baselineOpenAIModels.count)

    let model = try #require(registry.find("openai", baselineModel.id))
    #expect(model.baseUrl == baselineModel.baseUrl)
    #expect(model.api == baselineModel.api)
    #expect(model.compat?.supportsLongCacheRetention == false)
    #expect(model.compat?.sendSessionIdHeader == false)
    #expect(model.compat?.cacheControlFormat == .anthropic)
}

@Test func modelRegistryBuiltInCustomModelsInheritApiBaseUrlAndMergeCompat() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-models-built-in-inherit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let modelsPath = tempDir.appendingPathComponent("models.json")

    let baselineModel = try #require(getModels(provider: .openai).first)
    let json = """
    {
      "providers": {
        "openai": {
          "compat": {
            "supportsLongCacheRetention": false
          },
          "models": [
            {
              "id": "custom-inherited",
              "compat": {
                "sendSessionIdHeader": false
              }
            }
          ]
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: modelsPath)

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let model = try #require(registry.find("openai", "custom-inherited"))
    #expect(model.api == baselineModel.api)
    #expect(model.baseUrl == baselineModel.baseUrl)
    #expect(model.compat?.supportsLongCacheRetention == false)
    #expect(model.compat?.sendSessionIdHeader == false)
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

@Test func modelRegistryAppliesGitHubCopilotCompatWithoutChangingGPTEndpoint() throws {
    let authStorage = AuthStorage(":memory:")
    let registry = ModelRegistry(authStorage)
    guard let model = registry.find("github-copilot", "gpt-5.4") else {
        #expect(Bool(false), "Expected GitHub Copilot gpt-5.4 model to be available")
        return
    }

    #expect(model.api == .openAIResponses)
    #expect(model.compat?.supportsStore == false)
    #expect(model.compat?.supportsDeveloperRole == false)
    #expect(model.compat?.supportsReasoningEffort == false)
    #expect(model.compat?.supportsUsageInStreaming == false)
    #expect(model.compat?.supportsStrictMode == false)
    #expect(model.compat?.sendSessionIdHeader == false)
}

@Test func modelRegistryRoutesGitHubCopilotClaudeThroughOpenAICompletions() throws {
    let authStorage = AuthStorage(":memory:")
    let registry = ModelRegistry(authStorage)
    guard let model = registry.find("github-copilot", "claude-sonnet-4.5") else {
        #expect(Bool(false), "Expected GitHub Copilot Claude model to be available")
        return
    }

    #expect(model.api == .openAICompletions)
    #expect(model.compat?.supportsStore == false)
    #expect(model.compat?.supportsDeveloperRole == false)
    #expect(model.compat?.supportsReasoningEffort == false)
    #expect(model.compat?.supportsUsageInStreaming == false)
    #expect(model.compat?.supportsStrictMode == false)
    #expect(model.compat?.sendSessionIdHeader == false)
}
