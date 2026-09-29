import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func defaultModelPerProviderVercelGateway() {
    let entry = defaultModelPerProvider.first { $0.0 == .vercelAiGateway }
    #expect(entry?.1 == "zai/glm-5.1")
}

@Test func defaultModelsIncludeBasetenAndQwenTokenPlans() {
    let defaults = Dictionary(uniqueKeysWithValues: defaultModelPerProvider)
    #expect(defaults[.baseten] == "zai-org/GLM-5.2")
    #expect(defaults[.qwenTokenPlan] == "qwen3.7-max")
    #expect(defaults[.qwenTokenPlanCn] == "qwen3.7-max")
    #expect(defaults[.qwenTokenPlanIndividual] == "qwen3.8-max")
}

@Test func everyDefaultModelExistsInBuiltinChatCatalog() {
    for (provider, modelId) in defaultModelPerProvider {
        #expect(getModel(provider: provider.rawValue, modelId: modelId) != nil,
                "Missing default model \(provider.rawValue)/\(modelId)")
    }
}

@Test func selectDefaultModelPrefersVercelGateway() async {
    let model = Model(
        id: "zai/glm-5.1",
        name: "GLM 5.1",
        api: .anthropicMessages,
        provider: "vercel-ai-gateway",
        baseUrl: "https://ai-gateway.vercel.sh",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0),
        contextWindow: 202800,
        maxTokens: 64000
    )

    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey("vercel-ai-gateway", "test-key")
    let registry = ModelRegistry(authStorage)

    let selected = await selectDefaultModel(available: [model], registry: registry)
    #expect(selected?.provider == "vercel-ai-gateway")
    #expect(selected?.id == "zai/glm-5.1")
}

@Test func selectDefaultModelAcceptsHeaderOnlyConfiguredModels() async {
    let model = Model(
        id: "zai/glm-5.1",
        name: "GLM 5.1",
        api: .anthropicMessages,
        provider: "vercel-ai-gateway",
        baseUrl: "https://ai-gateway.vercel.sh",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 0),
        contextWindow: 202800,
        maxTokens: 64000,
        headers: ["Authorization": "Bearer local-token"]
    )

    let registry = ModelRegistry(AuthStorage(":memory:"))
    let selected = await selectDefaultModel(available: [model], registry: registry)
    #expect(selected?.provider == "vercel-ai-gateway")
}
