import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func modelRegistryParsesCostTiersForCustomModelsAndMergesOverrides() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-model-tiers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let modelsPath = tempDir.appendingPathComponent("models.json")
    let json = """
    {
      "providers": {
        "local": {
          "baseUrl": "http://localhost:1234/v1",
          "api": "openai-completions",
          "models": [{
            "id": "tiered-local",
            "cost": {
              "input": 1,
              "output": 2,
              "cacheRead": 0.1,
              "cacheWrite": 0.2,
              "tiers": [{
                "inputTokensAbove": 100000,
                "input": 3,
                "output": 4,
                "cacheRead": 0.3,
                "cacheWrite": 0.4
              }]
            }
          }]
        },
        "openai": {
          "modelOverrides": {
            "gpt-4o-mini": {
              "cost": {
                "input": 9,
                "tiers": [{
                  "inputTokensAbove": 200000,
                  "input": 10,
                  "output": 11,
                  "cacheRead": 1,
                  "cacheWrite": 2
                }]
              }
            }
          }
        }
      }
    }
    """
    try json.write(to: modelsPath, atomically: true, encoding: .utf8)

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let custom = try #require(registry.find("local", "tiered-local"))
    #expect(custom.cost.tiers?.count == 1)
    #expect(custom.cost.tiers?.first?.inputTokensAbove == 100000)
    #expect(custom.cost.tiers?.first?.output == 4)

    let overridden = try #require(registry.find("openai", "gpt-4o-mini"))
    #expect(overridden.cost.input == 9)
    #expect(overridden.cost.output > 0)
    #expect(overridden.cost.tiers?.first?.inputTokensAbove == 200000)
    #expect(overridden.cost.tiers?.first?.cacheWrite == 2)
}

@Test func modelRegistryAppliesConfiguredOverridesToExtensionProviders() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-extension-model-override-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let json = """
    {
      "providers": {
        "swift-extension-provider": {
          "modelOverrides": {
            "swift-extension-model": {
              "name": "Configured extension model",
              "cost": {
                "output": 7,
                "tiers": [{
                  "inputTokensAbove": 50000,
                  "input": 2,
                  "output": 8,
                  "cacheRead": 0.2,
                  "cacheWrite": 0.3
                }]
              }
            }
          }
        }
      }
    }
    """
    try json.write(to: tempDir.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    registry.registerProvider(HookProviderConfig(
        provider: "swift-extension-provider",
        api: .openAIResponses,
        baseUrl: "https://example.invalid/v1",
        models: [HookProviderModel(
            id: "swift-extension-model",
            input: [.text],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8192,
            maxTokens: 4096
        )]
    ), sourceId: "test-extension")

    let model = try #require(registry.find("swift-extension-provider", "swift-extension-model"))
    #expect(model.name == "Configured extension model")
    #expect(model.cost.input == 1)
    #expect(model.cost.output == 7)
    #expect(model.cost.tiers?.first?.inputTokensAbove == 50000)
}

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
