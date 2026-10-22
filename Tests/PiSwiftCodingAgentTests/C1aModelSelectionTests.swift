import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func c1aModel(_ provider: String, _ id: String, reasoning: Bool = true) -> Model {
    Model(id: id, name: id, api: .anthropicMessages, provider: provider,
          baseUrl: "https://example.invalid", reasoning: reasoning, input: [.text],
          cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1),
          contextWindow: 128_000, maxTokens: 8192)
}

private var c1aCatalog: [Model] {
    [c1aModel("anthropic", "claude-sonnet-4-5"), c1aModel("openai", "gpt-4o", reasoning: false),
     c1aModel("openrouter", "qwen/qwen3-coder:exacto"),
     c1aModel("openrouter", "openai/gpt-4o:extended", reasoning: false)]
}

private var c1aGateways: [Model] {
    [c1aModel("anthropic", "claude-sonnet-4-5"),
     c1aModel("openrouter", "anthropic/claude-opus-5.5"),
     c1aModel("vercel-ai-gateway", "anthropic/claude-opus-5.5")]
}

@Suite struct C1aModelSelectionTests {
    @Test func scopeReturnsStructuredDiagnostics() throws {
        let result = resolveModelScopeFromModels(["sonnet:high", "gpt-4o:invalid", "missing"], c1aCatalog)
        #expect(result.scopedModels.map(\.model.id) == ["claude-sonnet-4-5", "gpt-4o"])
        #expect(result.scopedModels.map(\.thinkingLevel) == [.high, nil])
        #expect(result.scopedModels.map(\.isThinkingExplicit) == [true, false])
        #expect(result.diagnostics.count == 2)
        let invalid = try #require(result.diagnostics.first)
        #expect(invalid.type == .warning)
        #expect(invalid.code == .invalidThinkingLevel)
        #expect(invalid.pattern == "gpt-4o:invalid")
        #expect(invalid.message == "Invalid thinking level \"invalid\" in pattern \"gpt-4o:invalid\". Using default instead.")
        let missing = try #require(result.diagnostics.last)
        #expect(missing.type == .warning)
        #expect(missing.code == .noMatch)
        #expect(missing.pattern == "missing")
        #expect(missing.message == "No models match pattern \"missing\"")
    }

    @Test func scopeAddsAllProvidersForAnAmbiguousExactId() throws {
        let models = c1aCatalog + [c1aModel("azure", "gpt-4o"), c1aModel("openai-codex", "gpt-4o-mini")]
        let cases: [(String, PiSwiftAgent.ThinkingLevel?)] = [("gpt-4o:high", .high), ("GPT-4o", nil)]
        for (pattern, thinking) in cases {
            for catalog in [models, Array(models.reversed())] {
                let result = resolveModelScopeFromModels([pattern], catalog)
                #expect(result.scopedModels.map { "\($0.model.provider)/\($0.model.id)" }.sorted()
                        == ["azure/gpt-4o", "openai/gpt-4o"])
                #expect(result.scopedModels.allSatisfy { $0.thinkingLevel == thinking })
                #expect(result.scopedModels.allSatisfy { $0.isThinkingExplicit == (thinking != nil) })
                #expect(result.diagnostics.count == 1)
                let diagnostic = try #require(result.diagnostics.first)
                #expect(diagnostic.type == .warning)
                #expect(diagnostic.code == .ambiguous)
                #expect(diagnostic.pattern == pattern)
                #expect(diagnostic.message == "Pattern \"\(pattern)\" matches several providers: azure, openai. Use provider/id to choose one.")
            }
        }
    }

    @Test func scopeTreatsBracketedIdsAsExactBeforeGlobMatching() {
        let models = c1aCatalog + [c1aModel("custom", "bracketed-model[1m]"), c1aModel("custom", "bracketed-model1")]
        let cases: [(String, PiSwiftAgent.ThinkingLevel?)] = [("custom/bracketed-model[1m]", nil),
                                                ("custom/bracketed-model[1m]:high", .high)]
        for (pattern, thinking) in cases {
            let result = resolveModelScopeFromModels([pattern], models)
            #expect(result.scopedModels.map(\.model.id) == ["bracketed-model[1m]"])
            #expect(result.scopedModels.first?.thinkingLevel == thinking)
            #expect(result.diagnostics.isEmpty)
        }
    }

    @Test func asyncScopeReturnsDiagnosticsAndAllAvailableMatches() async throws {
        let registry = ModelRegistry(AuthStorage(":memory:"), nil,
                                     modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let source = "c1a-scope-\(UUID().uuidString)"
        let providers = ["c1a-scope-a-\(source)", "c1a-scope-b-\(source)"]
        for provider in providers {
            registry.registerProvider(HookProviderConfig(provider: provider, api: .anthropicMessages,
                baseUrl: "https://example.invalid", apiKey: "test-key",
                models: [HookProviderModel(id: "c1a-bracketed[1m]"), HookProviderModel(id: "c1a-shared")]),
                sourceId: source)
        }
        defer { registry.unregisterProviders(sourceId: source) }
        let bracketed = await resolveModelScopeWithDiagnostics(["\(providers[0])/c1a-bracketed[1m]:high"], registry)
        #expect(bracketed.scopedModels.map(\.model.id) == ["c1a-bracketed[1m]"])
        #expect(bracketed.scopedModels.first?.thinkingLevel == .high)
        #expect(bracketed.diagnostics.isEmpty)
        let patterns = ["c1a-shared:high", "c1a-no-such-model"]
        let result = await resolveModelScopeWithDiagnostics(patterns, registry)
        #expect(result.scopedModels.map(\.model.provider).sorted() == providers.sorted())
        #expect(result.scopedModels.allSatisfy { $0.thinkingLevel == .high })
        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics.first?.code == .ambiguous)
        #expect(result.diagnostics.first?.pattern == patterns[0])
        #expect(result.diagnostics.last?.code == .noMatch)
        #expect(result.diagnostics.last?.message == "No models match pattern \"c1a-no-such-model\"")
        let invalid = await resolveModelScopeWithDiagnostics(["\(providers[0])/c1a-shared:invalid"], registry)
        #expect(invalid.scopedModels.first?.thinkingLevel == nil)
        #expect(invalid.diagnostics.first?.code == .invalidThinkingLevel)
    }

    @Test func duplicateRawIdSelectsTheAuthenticatedGateway() {
        let cases: [(String, PiSwiftAgent.ThinkingLevel?)] = [("anthropic/claude-opus-5.5", nil),
                                                ("anthropic/claude-opus-5.5:high", .high)]
        for (reference, thinking) in cases {
            for models in [c1aGateways, Array(c1aGateways.reversed())] {
                let result = resolveCliModel(cliModel: reference, cliThinking: nil, inlineApiKey: false, availableModels: models,
                                             usable: { $0 == "vercel-ai-gateway" })
                #expect(result.error == nil)
                #expect(result.model?.provider == "vercel-ai-gateway")
                #expect(result.model?.id == "anthropic/claude-opus-5.5")
                #expect(result.thinkingLevel == thinking)
            }
        }
    }

    @Test func duplicateRawIdWithoutCredentialsReportsAmbiguity() {
        for models in [c1aGateways, Array(c1aGateways.reversed())] {
            let result = resolveCliModel(cliModel: "anthropic/claude-opus-5.5", cliThinking: nil, inlineApiKey: false, availableModels: models)
            #expect(result.model == nil)
            #expect(result.error?.contains("openrouter/anthropic/claude-opus-5.5, vercel-ai-gateway/anthropic/claude-opus-5.5") == true)
            #expect(result.error?.contains("No matching provider is authenticated. Use --provider or provider/model.") == true)
        }
    }

    @Test func inlineKeyDoesNotSelectAStoredCredentialProvider() {
        let result = resolveCliModel(cliModel: "anthropic/claude-opus-5.5", cliThinking: nil, inlineApiKey: true,
                                     availableModels: c1aGateways, usable: { $0 == "vercel-ai-gateway" })
        #expect(result.model == nil)
        #expect(result.error?.contains("--api-key does not choose a provider.") == true)
    }

    @Test func usableQualifiedZaiMatchWinsOverRawGatewayId() {
        let models = c1aCatalog + [c1aModel("zai", "glm-5"), c1aModel("vercel-ai-gateway", "zai/glm-5")]
        for catalog in [models, Array(models.reversed())] {
            let result = resolveCliModel(cliModel: "zai/glm-5", cliThinking: nil, inlineApiKey: false, availableModels: catalog, usable: { _ in true })
            #expect(result.error == nil)
            #expect(result.model?.provider == "zai")
            #expect(result.model?.id == "glm-5")
        }
    }

    @Test func usableRawXiaomiIdWinsOverUnusableQualifiedMatch() {
        let models = c1aCatalog + [c1aModel("commandcode", "xiaomi/mimo-v2.5-pro", reasoning: false),
                                   c1aModel("xiaomi", "mimo-v2.5-pro", reasoning: false)]
        for catalog in [models, Array(models.reversed())] {
            let result = resolveCliModel(cliModel: "xiaomi/mimo-v2.5-pro", cliThinking: nil, inlineApiKey: false, availableModels: catalog,
                                         usable: { $0 == "commandcode" })
            #expect(result.error == nil)
            #expect(result.model?.provider == "commandcode")
            #expect(result.model?.id == "xiaomi/mimo-v2.5-pro")
        }
    }

    @Test func customFallbackRemovesThinkingSuffix() {
        let models = c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)]
        let result = resolveCliModel(cliModel: "neuralwatt/zai-org/GLM-5.1-FP8:high", cliThinking: nil, inlineApiKey: false, availableModels: models)
        #expect(result.error == nil)
        #expect(result.model?.provider == "neuralwatt")
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8")
        #expect(result.model?.reasoning == true)
        #expect(result.thinkingLevel == .high)
    }

    @Test func customFallbackWithoutThinkingSuffix() {
        let result = resolveCliModel(cliModel: "neuralwatt/zai-org/GLM-5.1-FP8",
            cliThinking: nil, inlineApiKey: false, availableModels: c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)])
        #expect(result.error == nil)
        #expect(result.model?.provider == "neuralwatt")
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8")
        #expect(result.thinkingLevel == nil)
    }

    @Test(arguments: [PiSwiftAgent.ThinkingLevel.off, .minimal, .low, .medium, .high, .xhigh, .max])
    func customFallbackAcceptsEachThinkingLevel(level: PiSwiftAgent.ThinkingLevel) {
        let result = resolveCliModel(cliModel: "neuralwatt/zai-org/GLM-5.1-FP8:\(level.rawValue)",
            cliThinking: nil, inlineApiKey: false, availableModels: c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)])
        #expect(result.error == nil)
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8")
        #expect(result.thinkingLevel == level)
    }

    @Test func customFallbackKeepsInvalidThinkingSuffixInId() {
        let result = resolveCliModel(cliModel: "neuralwatt/zai-org/GLM-5.1-FP8:banana",
            cliThinking: nil, inlineApiKey: false, availableModels: c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)])
        #expect(result.error == nil)
        #expect(result.model?.provider == "neuralwatt")
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8:banana")
        #expect(result.thinkingLevel == nil)
    }

    @Test func customFallbackWithExplicitProviderRemovesThinkingSuffix() {
        let result = resolveCliModel(cliProvider: "neuralwatt", cliModel: "zai-org/GLM-5.1-FP8:high",
            cliThinking: nil, inlineApiKey: false, availableModels: c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)])
        #expect(result.error == nil)
        #expect(result.model?.provider == "neuralwatt")
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8")
        #expect(result.thinkingLevel == .high)
    }

    @Test func explicitThinkingKeepsFallbackSuffixInId() {
        let result = resolveCliModel(cliModel: "neuralwatt/zai-org/GLM-5.1-FP8:high", cliThinking: .medium, inlineApiKey: false,
            availableModels: c1aCatalog + [c1aModel("neuralwatt", "some-base-model", reasoning: false)])
        #expect(result.error == nil)
        #expect(result.model?.provider == "neuralwatt")
        #expect(result.model?.id == "zai-org/GLM-5.1-FP8:high")
        #expect(result.thinkingLevel == nil)
    }

    @Test func fallbackCopiesProviderDefaultBeforeFirstCatalogModel() throws {
        let defaultId = try #require(defaultModelPerProvider.first { $0.0 == .openai }?.1)
        let base = Model(id: defaultId, name: "Default", api: .openAIResponses, provider: "openai",
            baseUrl: "https://default.invalid/v1", reasoning: false, input: [.text, .image],
            cost: ModelCost(input: 7, output: 11, cacheRead: 2, cacheWrite: 3),
            contextWindow: 123_456, maxTokens: 9876, headers: ["X-Test": "default"])
        let models = [c1aModel("openai", "first-catalog-model"), base]
        let result = resolveCliModel(cliProvider: "openai", cliModel: "uncatalogued-model", cliThinking: nil, inlineApiKey: false, availableModels: models)
        let model = try #require(result.model)
        #expect(result.error == nil)
        #expect(model.id == "uncatalogued-model")
        #expect(model.name == "uncatalogued-model")
        #expect(model.api == base.api)
        #expect(model.baseUrl == base.baseUrl)
        #expect(model.reasoning == base.reasoning)
        #expect(model.input == base.input)
        #expect(model.cost.input == base.cost.input)
        #expect(model.cost.output == base.cost.output)
        #expect(model.cost.cacheRead == base.cost.cacheRead)
        #expect(model.cost.cacheWrite == base.cost.cacheWrite)
        #expect(model.contextWindow == base.contextWindow)
        #expect(model.maxTokens == base.maxTokens)
        #expect(model.headers == base.headers)
    }

    @Test func credentialPrintUsesOnlyCatalogModelsOfGivenProviders() {
        let models = [c1aModel("anthropic", "claude-sonnet-4-5"), c1aModel("openai", "gpt-5.5")]
        let matches = resolveCredentialPrintModels("gpt-5.5", providers: ["anthropic", "openai"], availableModels: models)
        #expect(matches.map(\.provider) == ["openai"])
        #expect(matches.map(\.id) == ["gpt-5.5"])
        #expect(resolveCredentialPrintModels("missing-model", providers: ["anthropic", "openai"], availableModels: models).isEmpty)
        #expect(resolveCredentialPrintModels("gpt-5.5", providers: ["anthropic"], availableModels: models).isEmpty)
    }

    @Test func credentialPrintCollectsEachProviderAndUsesStrictFuzzyMatching() {
        let models = [c1aModel("a", "shared-model"), c1aModel("b", "shared-model")]
        let matches = resolveCredentialPrintModels("shared", providers: ["b", "a"], availableModels: models)
        #expect(matches.map(\.provider) == ["b", "a"])
        #expect(matches.map(\.id) == ["shared-model", "shared-model"])
        #expect(resolveCredentialPrintModels("shared:invalid", providers: ["a", "b"], availableModels: models).isEmpty)
    }

    @Test func exactHelperDoesNotUseFuzzyThinkingOrCustomFallback() {
        #expect(findExactModelReferenceMatch("OPENAI/GPT-4O", c1aCatalog)?.id == "gpt-4o")
        #expect(findExactModelReferenceMatch("qwen/qwen3-coder:exacto", c1aCatalog)?.id == "qwen/qwen3-coder:exacto")
        #expect(findExactModelReferenceMatch("sonnet", c1aCatalog) == nil)
        #expect(findExactModelReferenceMatch("gpt-4o:high", c1aCatalog) == nil)
        #expect(findExactModelReferenceMatch("openai/custom-model", c1aCatalog) == nil)
        #expect(findExactModelReferenceMatch("", c1aCatalog) == nil)
        #expect(findExactModelReferenceMatch("shared", [c1aModel("a", "shared"), c1aModel("b", "shared")]) == nil)
    }
}
