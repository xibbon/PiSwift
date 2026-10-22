import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func c1aIntegrationModel(_ provider: String, _ id: String, reasoning: Bool = false) -> Model {
    Model(id: id, name: id, api: .openAICompletions, provider: provider,
          baseUrl: "https://example.invalid", reasoning: reasoning, input: [.text],
          cost: ModelCost(input: 1, output: 2, cacheRead: 0, cacheWrite: 0),
          contextWindow: 1000, maxTokens: 100)
}

@Suite struct C1aResolverIntegrationTests {
    @Test func inlineKeySupportsFirstTimeAvailabilityAfterProviderSelection() async throws {
        let auth = AuthStorage(":memory:")
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let provider = "c1a-first-time-\(UUID().uuidString)"
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: "https://example.invalid", models: [HookProviderModel(id: "first-time-model")]), sourceId: provider)
        defer { registry.unregisterProviders(sourceId: provider) }
        let result = resolveCliModel(cliProvider: provider, cliModel: "first-time-model",
                                     cliThinking: nil, inlineApiKey: true, modelRegistry: registry)
        let model = try #require(result.model)
        #expect(result.error == nil)
        #expect(await registry.isAvailable(model) == false)
        #expect(await registry.isAvailable(model, inlineApiKey: false) == false)
        #expect(await registry.isAvailable(model, inlineApiKey: true))
        #expect(registry.hasConfiguredAuth(model) == false)
        auth.setRuntimeApiKey(provider, "test-key")
        #expect(await registry.isAvailable(model))
    }

    @Test func registryCredentialsDoNotChooseAProviderForAnInlineKey() {
        let auth = AuthStorage(":memory:")
        let registry = ModelRegistry(auth, nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let source = "c1a-inline-\(UUID().uuidString)"
        let providers = ["\(source)-a", "\(source)-b"]
        for provider in providers {
            registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
                baseUrl: "https://example.invalid", models: [HookProviderModel(id: source)]), sourceId: source)
        }
        defer { registry.unregisterProviders(sourceId: source) }
        auth.setRuntimeApiKey(providers[1], "test-key")
        let stored = resolveCliModel(cliModel: source, cliThinking: nil, inlineApiKey: false, modelRegistry: registry)
        #expect(stored.model?.provider == providers[1])
        let inline = resolveCliModel(cliModel: source, cliThinking: nil, inlineApiKey: true, modelRegistry: registry)
        #expect(inline.model == nil)
        #expect(inline.error == "Model \"\(source)\" is ambiguous across providers: \(providers[0])/\(source), \(providers[1])/\(source). --api-key does not choose a provider. Use --provider or provider/model.")
    }

    @Test func subagentRequiresAProviderForAnAmbiguousAvailableModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c1a-subagent-\(UUID().uuidString)")
        let agentsDir = dir.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sharedId = "c1a-shared-\(UUID().uuidString)"
        try "---\nname: worker\ndescription: test\nmodel: \(sharedId)\n---\nTest agent.\n".write(
            to: agentsDir.appendingPathComponent("worker.md"), atomically: true, encoding: .utf8)
        let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let providers = ["c1a-subagent-a", "c1a-subagent-b"]
        for provider in providers {
            registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
                baseUrl: "https://example.invalid", apiKey: "test-key",
                models: [HookProviderModel(id: sharedId)]), sourceId: sharedId)
        }
        defer { registry.unregisterProviders(sourceId: sharedId) }
        let context = SubagentToolContext()
        context.update(SubagentToolDependencies(cwd: dir.path, agentDir: dir.path, modelRegistry: registry,
            settingsManager: SettingsManager.inMemory(), defaultModel: c1aIntegrationModel("fallback", "default"),
            defaultThinkingLevel: .off))
        let tool = createSubagentTool(context)
        let result = try await tool.execute("call", ["agent": AnyCodable("worker"), "task": AnyCodable("test")], nil, nil)
        let output = result.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        #expect(output.contains("Model \"\(sharedId)\" is ambiguous across providers: c1a-subagent-a/\(sharedId), c1a-subagent-b/\(sharedId). Use provider/model."))
    }

    @Test func scopeDeduplicatesProviderAndIdAndKeepsFirstThinking() {
        let models = [c1aIntegrationModel("a", "shared"), c1aIntegrationModel("b", "shared")]
        let result = resolveModelScopeFromModels(["shared:high", "a/shared:low", "*:medium"], models)
        #expect(result.scopedModels.map(\.model.provider) == ["a", "b"])
        #expect(result.scopedModels.allSatisfy { $0.thinkingLevel == .high })
        #expect(result.diagnostics.map(\.code) == [.ambiguous])
    }

    @Test func scopeAddsAllAmbiguousBracketedLiteralsAndFuzzyTies() {
        for id in ["bracketed[1m]", "shared-latest"] {
            let models = [c1aIntegrationModel("a", id), c1aIntegrationModel("b", id)]
            let pattern = id.contains("[") ? "\(id):high" : "shared:high"
            let result = resolveModelScopeFromModels([pattern], models)
            #expect(result.scopedModels.map(\.model.provider) == ["a", "b"])
            #expect(result.scopedModels.allSatisfy { $0.thinkingLevel == .high })
            #expect(result.diagnostics.map(\.code) == [.ambiguous])
            #expect(result.diagnostics.first?.message == "Pattern \"\(pattern)\" matches several providers: a, b. Use provider/id to choose one.")
        }
    }

    @Test func fallbackUsesProviderDefaultsAndPreservesReasoningForOff() {
        for (provider, defaultId) in [("github-copilot", "gpt-6.1-sol"), ("xiaomi", "mimo-v2.6-pro"), ("anthropic", "claude-opus-4-8")] {
            let models = [c1aIntegrationModel(provider, "first"), c1aIntegrationModel(provider, defaultId, reasoning: true)]
            let result = resolveCliModel(cliProvider: provider, cliModel: "future:off", cliThinking: nil,
                                         inlineApiKey: false, availableModels: models)
            #expect(result.model?.reasoning == true)
            #expect(result.thinkingLevel == .off)
            #expect(result.model?.name == "future")
            #expect(result.warning == "Model \"future\" not found for provider \"\(provider)\". Using custom model id.")
        }
    }

    @Test func onlyASCIIDateSuffixesAreDatedModels() {
        let models = [c1aIntegrationModel("p", "series-20260101"), c1aIntegrationModel("p", "series-٢٠٢٦٠١٠١")]
        let result = resolveModelReference(ModelReferenceRequest(text: "series"), models, usable: { _ in true })
        #expect(result.model?.id == "series-٢٠٢٦٠١٠١")
    }
    @Test func scopeGlobsUseCaseInsensitivePathAndBracketRules() {
        let models = [c1aIntegrationModel("openai", "gpt-a"), c1aIntegrationModel("openai", "gpt-b"),
                      c1aIntegrationModel("openrouter", "vendor/gpt-c"), c1aIntegrationModel("custom", "gpt-.hidden"),
                      c1aIntegrationModel("custom", ".hidden")]
        let cases: [(String, [String])] = [
            ("OPENAI/GPT-*:low", ["gpt-a", "gpt-b"]),
            ("gpt-[ab]", ["gpt-a", "gpt-b"]),
            ("gpt-[!b]", ["gpt-a"]),
            ("gpt-?", ["gpt-a", "gpt-b"]),
            ("**/gpt-?", ["gpt-a", "gpt-b", "vendor/gpt-c"]),
            ("gpt-{a,b}*", ["gpt-a", "gpt-b"]),
            ("*", ["gpt-.hidden", "gpt-a", "gpt-b"]),
        ]
        for (pattern, expected) in cases {
            let result = resolveModelScopeFromModels([pattern], models)
            #expect(result.scopedModels.map(\.model.id).sorted() == expected)
            #expect(result.diagnostics.isEmpty)
        }
    }

    @Test func cliAmbiguityUsesExactAuthenticationHints() {
        let models = [c1aIntegrationModel("b", "shared"), c1aIntegrationModel("a", "shared")]
        for (authenticated, hint) in [
            (false, "No matching provider is authenticated."),
            (true, "More than one matching provider is authenticated."),
        ] {
            let result = resolveCliModel(cliModel: "shared", cliThinking: nil, inlineApiKey: false,
                                         availableModels: models, usable: { _ in authenticated })
            #expect(result.model == nil)
            #expect(result.error == "Model \"shared\" is ambiguous across providers: a/shared, b/shared. \(hint) Use --provider or provider/model.")
        }
    }

    @Test func explicitThinkingControlsOnlyFallbackReasoning() {
        let models = [c1aIntegrationModel("custom", "base")]
        for (level, reasoning) in [(PiSwiftCodingAgent.ThinkingLevel.off, false), (.medium, true)] {
            let result = resolveCliModel(cliModel: "custom/future:high", cliThinking: level,
                                         inlineApiKey: false, availableModels: models)
            #expect(result.model?.id == "future:high")
            #expect(result.model?.reasoning == reasoning)
            #expect(result.thinkingLevel == nil)
        }
    }

}
