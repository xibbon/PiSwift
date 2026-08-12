import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func defaultModelPerProviderVercelGateway() {
    let entry = defaultModelPerProvider.first { $0.0 == .vercelAiGateway }
    #expect(entry?.1 == "anthropic/claude-opus-4.5")
}

@Test func defaultModelsIncludeBasetenAndQwenTokenPlans() {
    let defaults = Dictionary(uniqueKeysWithValues: defaultModelPerProvider)
    #expect(defaults[.baseten] == "zai-org/GLM-5.2")
    #expect(defaults[.qwenTokenPlan] == "qwen3.7-max")
    #expect(defaults[.qwenTokenPlanCn] == "qwen3.7-max")
    #expect(defaults[.qwenTokenPlanIndividual] == "qwen3.8-max")
}

@Test func selectDefaultModelPrefersVercelGateway() async {
    let model = Model(
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

    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey("vercel-ai-gateway", "test-key")
    let registry = ModelRegistry(authStorage)

    let selected = await selectDefaultModel(available: [model], registry: registry)
    #expect(selected?.provider == "vercel-ai-gateway")
    #expect(selected?.id == "anthropic/claude-opus-4.5")
}

@Test func selectDefaultModelAcceptsHeaderOnlyConfiguredModels() async {
    let model = Model(
        id: "anthropic/claude-opus-4.5",
        name: "Claude Opus 4.5",
        api: .anthropicMessages,
        provider: "vercel-ai-gateway",
        baseUrl: "https://ai-gateway.vercel.sh",
        reasoning: true,
        input: [.text, .image],
        cost: ModelCost(input: 5, output: 15, cacheRead: 0.5, cacheWrite: 5),
        contextWindow: 200000,
        maxTokens: 8192,
        headers: ["Authorization": "Bearer local-token"]
    )

    let registry = ModelRegistry(AuthStorage(":memory:"))
    let selected = await selectDefaultModel(available: [model], registry: registry)
    #expect(selected?.provider == "vercel-ai-gateway")
}
