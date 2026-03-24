import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func mockModels() -> [Model] {
    let mockModels: [Model] = [
        Model(
            id: "claude-sonnet-4-5",
            name: "Claude Sonnet 4.5",
            api: .anthropicMessages,
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: true,
            input: [.text, .image],
            cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            contextWindow: 200000,
            maxTokens: 8192
        ),
        Model(
            id: "gpt-4o",
            name: "GPT-4o",
            api: .anthropicMessages,
            provider: "openai",
            baseUrl: "https://api.openai.com",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
            contextWindow: 128000,
            maxTokens: 4096
        ),
        Model(
            id: "qwen/qwen3-coder:exacto",
            name: "Qwen3 Coder Exacto",
            api: .anthropicMessages,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: true,
            input: [.text],
            cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 1),
            contextWindow: 128000,
            maxTokens: 8192
        ),
        Model(
            id: "openai/gpt-4o:extended",
            name: "GPT-4o Extended",
            api: .anthropicMessages,
            provider: "openrouter",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: false,
            input: [.text, .image],
            cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
            contextWindow: 128000,
            maxTokens: 4096
        ),
    ]
    return mockModels
}

@Test func parseModelPatternSimple() {
    let models = mockModels()
    let exact = parseModelPattern("claude-sonnet-4-5", models)
    #expect(exact.model?.id == "claude-sonnet-4-5")
    #expect(exact.thinkingLevel == .off)
    #expect(exact.isThinkingExplicit == false)
    #expect(exact.warning == nil)

    let partial = parseModelPattern("sonnet", models)
    #expect(partial.model?.id == "claude-sonnet-4-5")
    #expect(partial.thinkingLevel == .off)
    #expect(partial.isThinkingExplicit == false)

    let missing = parseModelPattern("nonexistent", models)
    #expect(missing.model == nil)
    #expect(missing.thinkingLevel == .off)
    #expect(missing.isThinkingExplicit == false)
}

@Test func parseModelPatternThinkingLevels() {
    let models = mockModels()
    let high = parseModelPattern("sonnet:high", models)
    #expect(high.model?.id == "claude-sonnet-4-5")
    #expect(high.thinkingLevel == .high)
    #expect(high.isThinkingExplicit == true)
    #expect(high.warning == nil)

    let medium = parseModelPattern("gpt-4o:medium", models)
    #expect(medium.model?.id == "gpt-4o")
    #expect(medium.thinkingLevel == .medium)
    #expect(medium.isThinkingExplicit == true)

    for level in ["off", "minimal", "low", "medium", "high", "xhigh"] {
        let result = parseModelPattern("sonnet:\(level)", models)
        #expect(result.model?.id == "claude-sonnet-4-5")
        #expect(result.thinkingLevel.rawValue == level)
        #expect(result.isThinkingExplicit == true)
        #expect(result.warning == nil)
    }
}

@Test func parseModelPatternInvalidThinking() {
    let models = mockModels()
    let result = parseModelPattern("sonnet:random", models)
    #expect(result.model?.id == "claude-sonnet-4-5")
    #expect(result.thinkingLevel == .off)
    #expect(result.isThinkingExplicit == false)
    #expect(result.warning?.contains("Invalid thinking level") == true)

    let result2 = parseModelPattern("gpt-4o:invalid", models)
    #expect(result2.model?.id == "gpt-4o")
    #expect(result2.isThinkingExplicit == false)
    #expect(result2.warning?.contains("Invalid thinking level") == true)
}

@Test func parseModelPatternOpenRouter() {
    let models = mockModels()
    let qwen = parseModelPattern("qwen/qwen3-coder:exacto", models)
    #expect(qwen.model?.id == "qwen/qwen3-coder:exacto")
    #expect(qwen.thinkingLevel == .off)
    #expect(qwen.isThinkingExplicit == false)

    let qwenProvider = parseModelPattern("openrouter/qwen/qwen3-coder:exacto", models)
    #expect(qwenProvider.model?.id == "qwen/qwen3-coder:exacto")
    #expect(qwenProvider.model?.provider == "openrouter")
    #expect(qwenProvider.isThinkingExplicit == false)

    let qwenHigh = parseModelPattern("qwen/qwen3-coder:exacto:high", models)
    #expect(qwenHigh.thinkingLevel == .high)
    #expect(qwenHigh.isThinkingExplicit == true)

    let qwenProviderHigh = parseModelPattern("openrouter/qwen/qwen3-coder:exacto:high", models)
    #expect(qwenProviderHigh.thinkingLevel == .high)
    #expect(qwenProviderHigh.isThinkingExplicit == true)

    let extended = parseModelPattern("openai/gpt-4o:extended", models)
    #expect(extended.model?.id == "openai/gpt-4o:extended")
    #expect(extended.isThinkingExplicit == false)
}

@Test func parseModelPatternInvalidOpenRouterThinking() {
    let models = mockModels()
    let result = parseModelPattern("qwen/qwen3-coder:exacto:random", models)
    #expect(result.model?.id == "qwen/qwen3-coder:exacto")
    #expect(result.thinkingLevel == .off)
    #expect(result.isThinkingExplicit == false)
    #expect(result.warning?.contains("Invalid thinking level") == true)

    let result2 = parseModelPattern("qwen/qwen3-coder:exacto:high:random", models)
    #expect(result2.model?.id == "qwen/qwen3-coder:exacto")
    #expect(result2.thinkingLevel == .off)
    #expect(result2.isThinkingExplicit == false)
    #expect(result2.warning?.contains("Invalid thinking level") == true)
}

@Test func parseModelPatternEdgeCases() {
    let models = mockModels()
    let empty = parseModelPattern("", models)
    #expect(empty.model != nil)
    #expect(empty.thinkingLevel == .off)
    #expect(empty.isThinkingExplicit == false)

    let trailing = parseModelPattern("sonnet:", models)
    #expect(trailing.model?.id == "claude-sonnet-4-5")
    #expect(trailing.warning?.contains("Invalid thinking level") == true)
    #expect(trailing.isThinkingExplicit == false)
}

@Test func resolveCliModelProviderAndIdWithoutExplicitProviderFlag() {
    let models = mockModels()
    let result = resolveCliModel(cliModel: "openai/gpt-4o", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.provider == "openai")
    #expect(result.model?.id == "gpt-4o")
}

@Test func resolveCliModelFuzzyWithinExplicitProvider() {
    let models = mockModels()
    let result = resolveCliModel(cliProvider: "openai", cliModel: "4o", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.provider == "openai")
    #expect(result.model?.id == "gpt-4o")
}

@Test func resolveCliModelSupportsThinkingSuffixInModelFlag() {
    let models = mockModels()
    let result = resolveCliModel(cliModel: "sonnet:high", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.id == "claude-sonnet-4-5")
    #expect(result.thinkingLevel == .high)
}

@Test func resolveCliModelPrefersExactIdOverProviderInference() {
    let models = mockModels()
    let result = resolveCliModel(cliModel: "openai/gpt-4o:extended", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.provider == "openrouter")
    #expect(result.model?.id == "openai/gpt-4o:extended")
}

@Test func resolveCliModelTreatsInvalidSuffixAsHardFailure() {
    let models = mockModels()
    let result = resolveCliModel(cliProvider: "openai", cliModel: "gpt-4o:extended", availableModels: models)
    #expect(result.model == nil)
    #expect(result.error?.contains("not found") == true)
}

@Test func resolveCliModelReturnsNoModelsError() {
    let result = resolveCliModel(cliProvider: "openai", cliModel: "gpt-4o", availableModels: [])
    #expect(result.model == nil)
    #expect(result.error?.contains("No models available") == true)
}

@Test func resolveCliModelResolvesProviderPrefixedFuzzyPatterns() {
    let models = mockModels()
    let result = resolveCliModel(cliModel: "openrouter/qwen", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.provider == "openrouter")
    #expect(result.model?.id == "qwen/qwen3-coder:exacto")
}

@Test func defaultModelPerProviderVercelAiGateway() {
    // Verify ai-gateway default is opus 4.5
    let aiGatewayDefault = defaultModelPerProvider.first { $0.0 == .vercelAiGateway }
    #expect(aiGatewayDefault?.1 == "anthropic/claude-opus-4.5")
}

@Test func selectDefaultModelWithAiGateway() async {
    let aiGatewayModel = Model(
        id: "anthropic/claude-opus-4.5",
        name: "Claude Opus 4.5",
        api: .anthropicMessages,
        provider: "vercel-ai-gateway",
        baseUrl: "https://ai-gateway.vercel.sh",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
        contextWindow: 200000,
        maxTokens: 8192
    )

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("model-resolver-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let authStorage = AuthStorage(URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path)
    authStorage.setRuntimeApiKey("vercel-ai-gateway", "test-key")

    let registry = ModelRegistry(authStorage, tempDir)

    let result = await selectDefaultModel(available: [aiGatewayModel], registry: registry)
    #expect(result?.provider == "vercel-ai-gateway")
    #expect(result?.id == "anthropic/claude-opus-4.5")
}

@Test func resolveCliModelSlashDelimitedRef() {
    var models = mockModels()
    // Add a model with slash-delimited ID to simulate "openai/gpt-5.4"
    models.append(Model(
        id: "gpt-5.4",
        name: "GPT-5.4",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://api.openai.com",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
        contextWindow: 128000,
        maxTokens: 4096
    ))

    // "openai/gpt-5.4" should resolve via provider/id split
    let result = resolveCliModel(cliModel: "openai/gpt-5.4", availableModels: models)
    #expect(result.error == nil)
    #expect(result.model?.id == "gpt-5.4")
    #expect(result.model?.provider == "openai")
}

@Test func resolveCliModelAmbiguousBareIdReturnsNil() {
    // When the same bare model ID exists in multiple providers, resolution should fail
    let models = [
        Model(
            id: "shared-model",
            name: "Shared Model A",
            api: .openAIResponses,
            provider: "openai",
            baseUrl: "https://api.openai.com",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
            contextWindow: 128000,
            maxTokens: 4096
        ),
        Model(
            id: "shared-model",
            name: "Shared Model B",
            api: .anthropicMessages,
            provider: "anthropic",
            baseUrl: "https://api.anthropic.com",
            reasoning: false,
            input: [.text],
            cost: ModelCost(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            contextWindow: 200000,
            maxTokens: 8192
        ),
    ]

    // Bare ambiguous ID should not resolve
    let result = parseModelPattern("shared-model", models)
    #expect(result.model == nil)
}
