import PiSwiftAgent
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

private func initialModelRegistry() -> ModelRegistry {
    let registry = ModelRegistry(AuthStorage.inMemory(), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    for provider in Set(registry.getAll().map(\.provider)) {
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
                                                    baseUrl: "https://example.invalid", models: [HookProviderModelConfig]()), sourceId: "test")
    }
    return registry
}

private func addInitialModel(_ registry: ModelRegistry, provider: String = "i2-provider", id: String = "i2-model",
                             authenticated: Bool = true, headers: ProviderHeaders? = nil) {
    registry.registerProvider(HookProviderConfig(
        provider: provider, api: .openAICompletions, baseUrl: "https://example.invalid",
        apiKey: authenticated ? "test-key" : nil,
        headers: headers, models: [HookProviderModel(id: id)]
    ), sourceId: "test")
}

@Test(arguments: ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
func initialAgentModelMapsSavedModelAndThinkingLevel(level: String) async {
    let registry = initialModelRegistry()
    addInitialModel(registry)
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("i2-provider", "i2-model")
    settings.setDefaultThinkingLevel(level)
    let result = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(result.model == ModelRef(provider: "i2-provider", modelId: "i2-model"))
    #expect(result.thinkingLevel == ModelThinkingLevel(rawValue: level))
    #expect(result.fallbackMessage == nil)
}

@Test func initialAgentModelUsesResolverThinkingDefaultForInvalidSetting() async {
    let registry = initialModelRegistry()
    addInitialModel(registry)
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("i2-provider", "i2-model")
    settings.setDefaultThinkingLevel("unknown")
    let result = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(result.thinkingLevel?.rawValue == DEFAULT_THINKING_LEVEL.rawValue)
}

@Test func initialAgentModelFallsBackWhenSavedModelIsMissing() async {
    let registry = initialModelRegistry()
    addInitialModel(registry)
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("missing", "missing")
    settings.setDefaultThinkingLevel("max")
    let result = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(result.model == ModelRef(provider: "i2-provider", modelId: "i2-model"))
    #expect(result.thinkingLevel?.rawValue == DEFAULT_THINKING_LEVEL.rawValue)
    #expect(result.fallbackMessage == nil)
}

@Test func initialAgentModelFallsBackWhenSavedProviderHasNoAuthentication() async {
    let registry = initialModelRegistry()
    addInitialModel(registry)
    addInitialModel(registry, provider: "i2-no-auth", id: "unavailable", authenticated: false)
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("i2-no-auth", "unavailable")
    let result = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(result.model == ModelRef(provider: "i2-provider", modelId: "i2-model"))
    #expect(result.fallbackMessage == nil)
}

@Test func initialAgentModelAcceptsSavedHeaderOnlyModel() async {
    let registry = initialModelRegistry()
    addInitialModel(registry, authenticated: false, headers: ["Authorization": "Bearer test-key"])
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("i2-provider", "i2-model")
    settings.setDefaultThinkingLevel("high")
    let result = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(result.model == ModelRef(provider: "i2-provider", modelId: "i2-model"))
    #expect(result.thinkingLevel == .high)
}

@Test func initialAgentModelOmitsModelAndThinkingWhenNoModelIsAvailable() async {
    let registry = initialModelRegistry()
    #expect(registry.getAll().isEmpty)
    let result = await findInitialAgentModel(settingsManager: .inMemory(), registry: registry)
    #expect(result == InitialAgentModel())
}

@Test func initialAgentModelReadsUpdatedSettingsAtEveryCall() async {
    let registry = initialModelRegistry()
    addInitialModel(registry, provider: "i2-first", id: "first")
    addInitialModel(registry, provider: "i2-second", id: "second")
    let settings = SettingsManager.inMemory()
    settings.setDefaultModelAndProvider("i2-first", "first")
    let first = await findInitialAgentModel(settingsManager: settings, registry: registry)
    settings.setDefaultModelAndProvider("i2-second", "second")
    settings.setDefaultThinkingLevel("low")
    let second = await findInitialAgentModel(settingsManager: settings, registry: registry)
    #expect(first.model?.modelId == "first")
    #expect(second.model == ModelRef(provider: "i2-second", modelId: "second"))
    #expect(second.thinkingLevel == .low)
}
