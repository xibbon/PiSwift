import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func withSamplingRegistry(
    configuration: Any,
    body: (ModelRegistry) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-sampling-levels-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try JSONSerialization.data(withJSONObject: configuration)
        .write(to: directory.appendingPathComponent("models.json"))
    let registry = ModelRegistry(AuthStorage(":memory:"), directory.path,
                                 modelsStore: FileModelsStore(directory.appendingPathComponent("models-store.json").path),
                                 networkEnabled: false)
    try body(registry)
}

@Suite struct SamplingByThinkingLevelRegistryTests {
    @Test func customModelsAndModelOverridesCarrySamplingParams() throws {
        try withSamplingRegistry(configuration: ["providers": ["openrouter": [
            "baseUrl": "https://my-proxy.example.com/v1",
            "api": "openai-completions",
            "models": [[
                "id": "custom/sampling-model",
                "samplingParams": ["temperature": 1, "top_p": 0.95, "top_k": 0],
                "samplingParamsByThinkingLevel": [
                    "low": ["temperature": 0.6, "top_p": 0.95],
                    "high": ["temperature": 0.8],
                ],
            ]],
            "modelOverrides": [
                "custom/sampling-model": ["samplingParamsByThinkingLevel": [
                    "low": ["temperature": 0.5, "top_k": 20],
                    "max": ["temperature": 1],
                ]],
                "anthropic/claude-sonnet-4": [
                    "samplingParams": ["top_p": 0.9],
                    "samplingParamsByThinkingLevel": ["high": ["temperature": 0.8]],
                ],
            ],
        ]]]) { registry in
            let custom = try #require(registry.find("openrouter", "custom/sampling-model"))
            #expect(custom.samplingParams == ["temperature": AnyCodable(1), "top_p": AnyCodable(0.95), "top_k": AnyCodable(0)])
            #expect(custom.samplingParamsByThinkingLevel == [
                .low: ["temperature": AnyCodable(0.5), "top_p": AnyCodable(0.95), "top_k": AnyCodable(20)],
                .high: ["temperature": AnyCodable(0.8)],
                .max: ["temperature": AnyCodable(1)],
            ])
            let sonnet = try #require(registry.find("openrouter", "anthropic/claude-sonnet-4"))
            #expect(sonnet.samplingParams == ["top_p": AnyCodable(0.9)])
            #expect(sonnet.samplingParamsByThinkingLevel == [.high: ["temperature": AnyCodable(0.8)]])
            let opus = try #require(registry.find("openrouter", "anthropic/claude-opus-4.1"))
            #expect(opus.samplingParams == nil)
            #expect(opus.samplingParamsByThinkingLevel == nil)
        }
    }

    @Test func extensionModelsKeepSamplingParamsWithoutOverrides() throws {
        try withSamplingRegistry(configuration: ["providers": [:]]) { registry in
            let params: SamplingParamsByThinkingLevel = [.low: ["temperature": AnyCodable(0.6)]]
            registry.registerProvider(HookProviderConfig(
                provider: "extension-sampling", api: .openAICompletions,
                baseUrl: "https://extension.example/v1",
                models: [HookProviderModel(id: "sampling", samplingParamsByThinkingLevel: params)]
            ), sourceId: "<test:extension-sampling>")
            let model = try #require(registry.find("extension-sampling", "sampling"))
            #expect(model.samplingParamsByThinkingLevel == params)
        }
    }

    @Test func extensionOverridesMergeEachLevelAndKeepOtherFields() throws {
        try withSamplingRegistry(configuration: ["providers": ["extension-sampling": [
            "modelOverrides": ["sampling": [
                "name": "Overridden sampling model",
                "baseUrl": "https://override.example/v1",
                "reasoning": true,
                "input": ["text", "image"],
                "contextWindow": 32_000,
                "maxTokens": 4_000,
                "samplingParams": ["top_p": 0.5],
                "samplingParamsByThinkingLevel": [
                    "low": ["temperature": 0.5, "top_k": 20],
                    "max": ["temperature": 1],
                ],
                "thinkingLevelMap": ["low": "provider-low"],
                "cost": ["input": 2],
                "headers": ["X-Sampling": "override"],
                "compat": ["supportsStrictMode": true],
                "inputLimits": [:],
                "promptCache": ["short": 300],
            ]],
        ]]]) { registry in
            registry.registerProvider(HookProviderConfig(
                provider: "extension-sampling", api: .openAICompletions,
                baseUrl: "https://extension.example/v1",
                models: [HookProviderModel(id: "sampling", samplingParamsByThinkingLevel: [
                    .low: ["temperature": AnyCodable(0.6), "top_p": AnyCodable(0.95)],
                    .high: ["temperature": AnyCodable(0.8)],
                ])]
            ), sourceId: "<test:extension-sampling>")
            let model = try #require(registry.find("extension-sampling", "sampling"))
            #expect(model.samplingParamsByThinkingLevel == [
                .low: ["temperature": AnyCodable(0.5), "top_p": AnyCodable(0.95), "top_k": AnyCodable(20)],
                .high: ["temperature": AnyCodable(0.8)],
                .max: ["temperature": AnyCodable(1)],
            ])
            #expect(model.name == "Overridden sampling model")
            #expect(model.baseUrl == "https://override.example/v1")
            #expect(model.reasoning)
            #expect(model.input == [.text, .image])
            #expect(model.contextWindow == 32_000)
            #expect(model.maxTokens == 4_000)
            #expect(model.samplingParams == ["top_p": AnyCodable(0.5)])
            #expect(model.thinkingLevelMap?[.low] == "provider-low")
            #expect(model.cost.input == 2)
            #expect(model.headers?["X-Sampling"] == "override")
            #expect(model.compat?.supportsStrictMode == true)
            #expect(model.inputLimits != nil)
            #expect(model.promptCache?.short == 300)
        }
    }

    @Test func customEntryThatReplacesBuiltInKeepsItsOverride() throws {
        try withSamplingRegistry(configuration: ["providers": ["openrouter": [
            "models": [[
                "id": "anthropic/claude-sonnet-4",
                "name": "Custom Sonnet",
                "samplingParams": ["temperature": 0.9],
                "samplingParamsByThinkingLevel": ["low": ["temperature": 0.6, "top_p": 0.95]],
            ]],
            "modelOverrides": ["anthropic/claude-sonnet-4": [
                "name": "Override wins",
                "samplingParams": ["top_k": 20],
                "samplingParamsByThinkingLevel": ["low": ["temperature": 0.5]],
            ]],
        ]]]) { registry in
            let model = try #require(registry.find("openrouter", "anthropic/claude-sonnet-4"))
            #expect(model.name == "Override wins")
            #expect(model.samplingParams == ["temperature": AnyCodable(0.9), "top_k": AnyCodable(20)])
            #expect(model.samplingParamsByThinkingLevel == [
                .low: ["temperature": AnyCodable(0.5), "top_p": AnyCodable(0.95)],
            ])
        }
    }

    @Test func unknownLevelsAndNonObjectLevelValuesAreIgnored() throws {
        try withSamplingRegistry(configuration: ["providers": ["sampling": [
            "api": "openai-completions", "baseUrl": "https://sampling.example/v1",
            "models": [["id": "model", "samplingParamsByThinkingLevel": [
                "low": ["temperature": 0.6], "unknown": ["temperature": 1], "high": 42,
            ]]],
            "modelOverrides": ["model": ["samplingParamsByThinkingLevel": [
                "low": "invalid", "unknown": ["temperature": 1],
                "medium": ["top_k": 64], "high": NSNull(),
            ]]],
        ]]]) { registry in
            let model = try #require(registry.find("sampling", "model"))
            #expect(model.samplingParamsByThinkingLevel == [
                .low: ["temperature": AnyCodable(0.6)], .medium: ["top_k": AnyCodable(64)],
            ])
        }
    }

    @Test func nonObjectFieldsAreAbsent() throws {
        try withSamplingRegistry(configuration: ["providers": ["sampling": [
            "api": "openai-completions", "baseUrl": "https://sampling.example/v1",
            "models": [
                ["id": "invalid-model", "samplingParamsByThinkingLevel": 42],
                ["id": "invalid-override", "samplingParamsByThinkingLevel": ["low": ["temperature": 0.6]]],
            ],
            "modelOverrides": ["invalid-override": ["samplingParamsByThinkingLevel": "invalid"]],
        ]]]) { registry in
            let model = try #require(registry.find("sampling", "invalid-model"))
            #expect(model.samplingParamsByThinkingLevel == nil)
            let overridden = try #require(registry.find("sampling", "invalid-override"))
            #expect(overridden.samplingParamsByThinkingLevel == [.low: ["temperature": AnyCodable(0.6)]])
        }
    }

    @Test func emptyOverridesKeepExistingLevelsAndRemainPresentWithoutBase() throws {
        try withSamplingRegistry(configuration: ["providers": ["sampling": [
            "api": "openai-completions", "baseUrl": "https://sampling.example/v1",
            "models": [
                ["id": "base", "samplingParamsByThinkingLevel": ["low": ["temperature": 0.6]]],
                ["id": "no-base"],
                ["id": "empty-level", "samplingParamsByThinkingLevel": ["low": ["temperature": 0.6]]],
            ],
            "modelOverrides": [
                "base": ["samplingParamsByThinkingLevel": [:]],
                "no-base": ["samplingParamsByThinkingLevel": [:]],
                "empty-level": ["samplingParamsByThinkingLevel": ["low": [:], "high": [:]]],
            ],
        ]]]) { registry in
            let base = try #require(registry.find("sampling", "base"))
            #expect(base.samplingParamsByThinkingLevel == [.low: ["temperature": AnyCodable(0.6)]])
            let noBase = try #require(registry.find("sampling", "no-base"))
            #expect(noBase.samplingParamsByThinkingLevel == [:])
            let emptyLevel = try #require(registry.find("sampling", "empty-level"))
            #expect(emptyLevel.samplingParamsByThinkingLevel == [.low: ["temperature": AnyCodable(0.6)], .high: [:]])
        }
    }

    @Test func legacyModelsParseSamplingParamsByThinkingLevel() throws {
        let fields: [String: Any] = [
            "provider": "legacy-sampling", "name": "Legacy sampling",
            "api": "openai-completions", "baseUrl": "https://legacy.example/v1",
            "reasoning": true, "input": ["text"], "contextWindow": 32_000,
            "maxTokens": 4_000, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
        ]
        var valid = fields
        valid["id"] = "valid"
        valid["samplingParamsByThinkingLevel"] = [
            "low": ["temperature": 0.6], "unknown": ["temperature": 1], "high": 42,
        ] as [String: Any]
        var invalid = fields
        invalid["id"] = "invalid"
        invalid["samplingParamsByThinkingLevel"] = "invalid"
        try withSamplingRegistry(configuration: [valid, invalid]) { registry in
            let model = try #require(registry.find("legacy-sampling", "valid"))
            #expect(model.samplingParamsByThinkingLevel == [.low: ["temperature": AnyCodable(0.6)]])
            let invalidModel = try #require(registry.find("legacy-sampling", "invalid"))
            #expect(invalidModel.samplingParamsByThinkingLevel == nil)
        }
    }
}
