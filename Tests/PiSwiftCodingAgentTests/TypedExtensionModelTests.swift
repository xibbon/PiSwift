import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func extensionCatalogReplacesEveryOperationType() throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let provider = "typed-extension"
    registry.registerProvider(HookProviderConfig(
        provider: provider, api: .openAICompletions, baseUrl: "https://example.invalid",
        apiKey: "key", models: [
            .chat(HookProviderModel(id: "chat")),
            .image(HookProviderImageModel(id: "shared", api: .openrouterImages)),
            .classifier(HookProviderClassifierModel(id: "shared", api: .typesafeSystemOne, contextWindow: 512))
        ]
    ), sourceId: "extension")

    #expect(registry.getAll().filter { $0.provider == provider }.map(\.id) == ["chat"])
    #expect(registry.getModelsOfType(.image, provider: provider).map(\.id) == ["shared"])
    #expect(registry.getModelsOfType(.classifier, provider: provider).map(\.id) == ["shared"])

    registry.registerProvider(HookProviderConfig(
        provider: provider, api: .openAICompletions, baseUrl: "https://example.invalid",
        apiKey: "key", models: [HookProviderModel(id: "replacement")]
    ), sourceId: "extension")

    #expect(registry.getAllModels(provider: provider).map(\.id) == ["replacement"])
    #expect(registry.getModelsOfType(.image, provider: provider).isEmpty)
    #expect(registry.getModelsOfType(.classifier, provider: provider).isEmpty)
}

@Test func extensionImageAndClassifierImplementationsReceiveResolvedAuth() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let observed = LockedState<[String]>([])
    registry.registerProvider(HookProviderConfig(
        provider: "typed-operations", api: .openAICompletions,
        baseUrl: "https://example.invalid", apiKey: "extension-key",
        headers: ["X-Provider": "provider"],
        images: [.openrouterImages: { model, _, options in
            observed.withLock { $0 += [options?.apiKey ?? "", providerHeaderValue(options?.headers, name: "X-Operation") ?? ""] }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
        }],
        classifiers: [.typesafeSystemOne: { model, _, options in
            observed.withLock { $0 += [options?.apiKey ?? "", providerHeaderValue(options?.headers, name: "X-Operation") ?? ""] }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
        }],
        models: [
            .image(HookProviderImageModel(id: "shared", api: .openrouterImages,
                                          headers: ["X-Operation": "image"])),
            .classifier(HookProviderClassifierModel(id: "shared", api: .typesafeSystemOne,
                                                    contextWindow: 512,
                                                    headers: ["X-Operation": "classifier"]))
        ]
    ), sourceId: "extension")

    guard case .image(let image)? = registry.getModelOfType(.image, provider: "typed-operations", modelId: "shared"),
          case .classifier(let classifier)? = registry.getModelOfType(.classifier, provider: "typed-operations", modelId: "shared") else {
        Issue.record("Expected typed extension models")
        return
    }
    #expect((await registry.generateImages(image, context: ImagesContext(input: []))).stopReason == .stop)
    #expect((await registry.classify(classifier, context: ClassifierContext(state: [:], questions: [:]))).stopReason == .stop)
    #expect(observed.withLock { $0 } == ["extension-key", "image", "extension-key", "classifier"])
}

@Test func extensionListReplacesBuiltInProviderCatalog() {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    #expect(!registry.getAllModels(provider: "openrouter").isEmpty)
    registry.registerProvider(HookProviderConfig(
        provider: "openrouter", api: .openAICompletions,
        baseUrl: "https://example.invalid", apiKey: "key",
        models: [.image(HookProviderImageModel(id: "only-image", api: .openrouterImages))]
    ), sourceId: "extension")
    #expect(registry.getAll().filter { $0.provider == "openrouter" }.isEmpty)
    #expect(registry.getAllModels(provider: "openrouter").map(\.id) == ["only-image"])
    registry.unregisterProvider("openrouter", sourceId: "extension")
    #expect(registry.getAllModels(provider: "openrouter").count > 1)
}

@Test func pendingVirtualRegistrationReceivesRuntimeContext() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(
        provider: "physical-provider", api: .openAICompletions,
        baseUrl: "https://example.invalid", apiKey: "key",
        models: [HookProviderModel(id: "physical")]
    ), sourceId: "physical-extension")
    let physical = try #require(registry.find("physical-provider", "physical"))
    let observedCwd = LockedState<String?>(nil)
    let apiBox = LockedState<HookAPI?>(nil)
    let loaded = ExtensionLoader.load(
        InlineExtension(name: "router") { api in
            apiBox.withLock { $0 = api }
            try api.registerVirtualModel(HookVirtualModelDefinition(
                provider: "virtual-provider", id: "route", name: "Route"
            ) { _, context in
                observedCwd.withLock { $0 = context.cwd }
                return ModelRoute(model: physical, thinkingLevel: .off)
            })
        },
        cwd: "/tmp/typed-route", eventBus: createEventBus()
    )
    let hook = try #require(loaded.hook)
    #expect(registry.find("virtual-provider", "route") == nil)
    let runner = HookRunner([hook], "/tmp/typed-route", SessionManager.inMemory(), registry)
    let virtual = try #require(registry.find("virtual-provider", "route"))
    let route = try await registry.resolveVirtualModel(
        virtual, messages: [], reason: .direct, thinkingLevel: .off
    )
    #expect(route.model.id == "physical")
    #expect(observedCwd.withLock { $0 } == "/tmp/typed-route")
    let api = try #require(apiBox.withLock { $0 })
    #expect(throws: VirtualModelRegistrationError.self) {
        try api.registerVirtualModel(HookVirtualModelDefinition(
            provider: "physical-provider", id: "physical", name: "Conflict"
        ) { _, _ in ModelRoute(model: physical, thinkingLevel: .off) })
    }
    #expect(api.virtualModelRegistrations["physical-provider"]?["physical"] == nil)
    api.unregisterVirtualModel(provider: "virtual-provider", id: "route")
    #expect(registry.find("virtual-provider", "route") == nil)
    withExtendedLifetime(runner) {}
}
