import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct A3SystemOneHTTPClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await handler(request)
    }
}

private struct A3SystemOneRegistryFixture {
    let directory: URL
    let auth = AuthStorage(":memory:")

    init(_ models: String = #"{"providers":{}}"#) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("a3-system-one-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(models.utf8).write(to: directory.appendingPathComponent("models.json"))
    }

    func registry(store: any ModelsStore = InMemoryModelsStore(),
                  client: any ProviderHTTPClient = DefaultProviderHTTPClient(),
                  networkEnabled: Bool = false) -> ModelRegistry {
        ModelRegistry(auth, directory.path, modelsStore: store, remoteHTTPClient: client,
                      networkEnabled: networkEnabled)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// Use a provider with a remote catalog source. TypeSafe has no source in this Swift tree.
private func a3SystemOneModel(provider: String = "vercel-ai-gateway", compat: SystemOneCompat? = nil) -> ClassifierModel {
    ClassifierModel(id: "jev-a3", name: "Jev A3", api: .typesafeSystemOne, provider: provider,
        baseUrl: "https://api.typesafe.ai/v1", input: [.text, .image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 32_000,
        compat: compat)
}

private func a3SystemOneStore(_ model: ClassifierModel) -> InMemoryModelsStore {
    InMemoryModelsStore(entries: [model.provider: ModelsStoreEntry(
        models: [.classifier(model)], lastModified: 2_200_000_000_000
    )])
}

private func a3SystemOneContext() -> ClassifierContext {
    ClassifierContext(state: ["text": AnyCodable("Looks good")], questions: [
        "approved": .bool(instructions: "Does this express approval?",
                          trueCriterion: "Approval", falseCriterion: "No approval")
    ], images: [ImageContent(data: "cG5n", mimeType: "image/png")])
}

private func a3SystemOneClassifier(_ registry: ModelRegistry, provider: String) throws -> ClassifierModel {
    guard case .classifier(let model)? = registry.getModelOfType(.classifier, provider: provider, modelId: "jev-a3") else {
        throw A3SystemOneTestError.missingClassifier
    }
    return model
}

private enum A3SystemOneTestError: Error {
    case missingClassifier
}

private func a3SystemOneImageRequest(_ registry: ModelRegistry, model: ClassifierModel) async throws -> URLRequest {
    let requests = LockedState<[URLRequest]>([])
    let result = await registry.classify(model, context: a3SystemOneContext(), options: ClassifierOptions(
        httpClient: A3SystemOneHTTPClient { request in
            requests.withLock { $0.append(request) }
            return ProviderHTTPResponse(statusCode: 200,
                body: Data(#"{"answers":{"approved":{"type":"noul","noul":0.8}}}"#.utf8))
        }
    ))
    #expect(result.stopReason == .stop)
    #expect(result.errorMessage == nil)
    #expect(requests.withLock { $0.count } == 1)
    return try #require(requests.withLock { $0.first })
}

private func a3ExpectStateImageURLs(_ request: URLRequest) throws {
    #expect(request.url?.absoluteString == "https://proxy.example.com/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let state = try #require(body["state"] as? [[String: Any]])
    #expect(state.count == 2)
    #expect(state.first?["type"] as? String == "image_url")
    #expect((state.first?["image_url"] as? [String: String])?["url"] == "data:image/png;base64,cG5n")
    #expect(state.last?["text"] as? String == "Looks good")
    #expect(body["assets"] == nil)
    #expect(body["images"] == nil)
}

@Suite(.timeLimit(.minutes(1))) struct A3SystemOneRegistryTests {
    // Upstream model-runtime-classifiers.test.ts:87. Use a hand-built catalog entry until K1.
    @Test func openRouterProxyKeepsCatalogImageForm() async throws {
        let fixture = try A3SystemOneRegistryFixture(#"{"providers":{"openrouter":{"baseUrl":"https://proxy.example.com/v1"}}}"#)
        defer { fixture.remove() }
        fixture.auth.set("openrouter", credential: .apiKey(ApiKeyCredential(key: "secret")))
        let compat = SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false)
        let registry = fixture.registry(store: a3SystemOneStore(a3SystemOneModel(provider: "openrouter", compat: compat)))
        let refresh = await registry.refresh(ModelsRefreshOptions(allowNetwork: false))
        #expect(refresh.errors.isEmpty)
        let model = try a3SystemOneClassifier(registry, provider: "openrouter")
        #expect(model.compat == compat)
        try a3ExpectStateImageURLs(await a3SystemOneImageRequest(registry, model: model))
    }

    // Upstream model-runtime-classifiers.test.ts:102.
    @Test func providerCompatReachesClassifierRequest() async throws {
        let fixture = try A3SystemOneRegistryFixture(#"{"providers":{"vercel-ai-gateway":{"baseUrl":"https://proxy.example.com/v1","compat":{"imageInput":"state-image-urls","sendImageOptInHeader":false,"supportsStore":false,"customField":"retained"}}}}"#)
        defer { fixture.remove() }
        fixture.auth.set("vercel-ai-gateway", credential: .apiKey(ApiKeyCredential(key: "secret")))
        let registry = fixture.registry(store: a3SystemOneStore(a3SystemOneModel(
            compat: SystemOneCompat(imageInput: .assets, sendImageOptInHeader: true))))
        _ = await registry.refresh(ModelsRefreshOptions(allowNetwork: false))
        #expect(registry.getError() == nil)
        let model = try a3SystemOneClassifier(registry, provider: "vercel-ai-gateway")
        #expect(model.compat == SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false))
        let configured = try #require(registry.getConfiguredCompatibility(provider: "vercel-ai-gateway"))
        #expect(configured["imageInput"]?.value as? String == "state-image-urls")
        #expect(configured["sendImageOptInHeader"]?.value as? Bool == false)
        #expect(configured["customField"]?.value as? String == "retained")
        try a3ExpectStateImageURLs(await a3SystemOneImageRequest(registry, model: model))
    }

    @Test(arguments: [true, false])
    func providerCompatMergesEachFieldIndependently(changeImageInput: Bool) async throws {
        let value = changeImageInput ? #""imageInput":"images""# : #""sendImageOptInHeader":false"#
        let fixture = try A3SystemOneRegistryFixture("{\"providers\":{\"vercel-ai-gateway\":{\"compat\":{\(value)}}}}")
        defer { fixture.remove() }
        let registry = fixture.registry(store: a3SystemOneStore(a3SystemOneModel(
            compat: SystemOneCompat(imageInput: .assets, sendImageOptInHeader: true))))
        _ = await registry.refresh(ModelsRefreshOptions(allowNetwork: false))
        let model = try a3SystemOneClassifier(registry, provider: "vercel-ai-gateway")
        #expect(model.compat?.imageInput == (changeImageInput ? .images : .assets))
        #expect(model.compat?.sendImageOptInHeader == changeImageInput)
    }

    @Test func modelsAndModelOverridesStayChatOnly() async throws {
        let fixture = try A3SystemOneRegistryFixture(#"{"providers":{"vercel-ai-gateway":{"baseUrl":"https://provider.example/v1","models":[{"id":"jev-a3","api":"openai-completions","contextWindow":100,"maxTokens":10,"compat":{"imageInput":"images"}}],"modelOverrides":{"jev-a3":{"contextWindow":200,"compat":{"sendImageOptInHeader":true}}}}}}"#)
        defer { fixture.remove() }
        let compat = SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false)
        let registry = fixture.registry(store: a3SystemOneStore(a3SystemOneModel(compat: compat)))
        _ = await registry.refresh(ModelsRefreshOptions(allowNetwork: false))
        #expect(registry.getError() == nil)
        #expect(registry.find("vercel-ai-gateway", "jev-a3") != nil)
        let model = try a3SystemOneClassifier(registry, provider: "vercel-ai-gateway")
        #expect(model.compat == compat)
        #expect(model.contextWindow == 32_000)
    }

    @Test func extensionClassifierDefinitionCodableRoundTrip() throws {
        let definition = HookProviderClassifierModel(id: "jev-a3", name: "Extension Jev", api: .typesafeSystemOne,
            baseUrl: "https://classifier.example/v1", input: [.text, .image],
            inputLimits: ModelInputLimits(images: ModelImageInputLimits(maxPerRequest: 4)),
            contextWindow: 32_000, headers: ["X-Extension": "classifier"],
            compat: SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false))
        let encoded = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(HookProviderClassifierModel.self, from: encoded)
        #expect(decoded.id == definition.id)
        #expect(decoded.name == definition.name)
        #expect(decoded.api == definition.api)
        #expect(decoded.baseUrl == definition.baseUrl)
        #expect(decoded.input == definition.input)
        #expect(decoded.contextWindow == definition.contextWindow)
        #expect(decoded.inputLimits?.images?.maxPerRequest == 4)
        #expect(providerHeaderValue(decoded.headers, name: "X-Extension") == "classifier")
        #expect(decoded.compat == definition.compat)
    }

    @Test func extensionClassifierCompatSurvivesRegistrationAuthAndReplacesProviderOverride() async throws {
        let fixture = try A3SystemOneRegistryFixture(#"{"providers":{"extension-a3":{"baseUrl":"https://proxy.example.com/v1","headers":{"X-Provider":"models-json","X-Model":"models-json"},"compat":{"imageInput":"state-image-urls","sendImageOptInHeader":false}}}}"#)
        defer { fixture.remove() }
        let registry = fixture.registry()
        let observed = LockedState<[(ClassifierModel, ClassifierOptions?)]>([])
        registry.registerProvider(HookProviderConfig(provider: "extension-a3", api: .openAICompletions,
            baseUrl: "https://original.example/v1", apiKey: "extension-key",
            headers: ["X-Provider": "extension-provider"], classifiers: [
                .typesafeSystemOne: { model, _, options in
                    observed.withLock { $0.append((model, options)) }
                    return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
                }
            ], models: [.classifier(HookProviderClassifierModel(id: "jev-a3", api: .typesafeSystemOne,
                input: [.text, .image], contextWindow: 32_000, headers: ["X-Model": "extension-model"],
                compat: SystemOneCompat(imageInput: .assets, sendImageOptInHeader: true)))]
        ), sourceId: "a3-extension")
        let model = try a3SystemOneClassifier(registry, provider: "extension-a3")
        let result = await registry.classify(model, context: a3SystemOneContext())
        #expect(result.stopReason == .stop)
        let call = try #require(observed.withLock { $0.first })
        #expect(call.0.baseUrl == "https://original.example/v1")
        #expect(call.0.compat == SystemOneCompat(imageInput: .assets, sendImageOptInHeader: true))
        #expect(providerHeaderValue(call.0.headers, name: "X-Provider") == "extension-provider")
        #expect(providerHeaderValue(call.0.headers, name: "X-Model") == "extension-model")
        #expect(call.1?.apiKey == "extension-key")
        #expect(providerHeaderValue(call.1?.headers, name: "X-Provider") == "extension-provider")
        #expect(providerHeaderValue(call.1?.headers, name: "X-Model") == "extension-model")
    }

    @Test func extensionClassifierKeepsPartialOrAbsentCompat() throws {
        let fixture = try A3SystemOneRegistryFixture(#"{"providers":{"extension-a3":{"compat":{"imageInput":"assets","sendImageOptInHeader":true}}}}"#)
        defer { fixture.remove() }
        let registry = fixture.registry()
        let definitions: [SystemOneCompat?] = [nil, SystemOneCompat(imageInput: .images)]
        for compat in definitions {
            registry.registerProvider(HookProviderConfig(provider: "extension-a3", api: .openAICompletions,
                baseUrl: "https://original.example/v1", models: [
                    .classifier(HookProviderClassifierModel(id: "jev-a3", api: .typesafeSystemOne,
                        contextWindow: 32_000, compat: compat))
                ]
            ), sourceId: "a3-extension")
            let model = try a3SystemOneClassifier(registry, provider: "extension-a3")
            #expect(model.compat == compat)
        }
    }

    @Test func remoteCatalogCompatSurvivesFileStoreAndOfflineRestore() async throws {
        let fixture = try A3SystemOneRegistryFixture()
        defer { fixture.remove() }
        fixture.auth.set("vercel-ai-gateway", credential: .apiKey(ApiKeyCredential(key: "secret")))
        let path = fixture.directory.appendingPathComponent("models-store.json").path
        let store = FileModelsStore(path)
        let requests = LockedState(0)
        let body = Data(#"[{"type":"classifier","id":"jev-a3","name":"Remote Jev","api":"typesafe-system-one","provider":"vercel-ai-gateway","baseUrl":"https://regional.example/v1","input":["text","image"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":32000,"compat":{"imageInput":"state-image-urls","sendImageOptInHeader":false}}]"#.utf8)
        let registry = fixture.registry(store: store, client: A3SystemOneHTTPClient { _ in
            requests.withLock { $0 += 1 }
            return ProviderHTTPResponse(statusCode: 200,
                headers: ["Last-Modified": "Wed, 12 Aug 2037 12:00:00 GMT", "ETag": "\"a3\""], body: body)
        }, networkEnabled: true)
        let refresh = await registry.refresh(ModelsRefreshOptions(providers: ["vercel-ai-gateway"], force: true))
        #expect(refresh.errors.isEmpty)
        #expect(requests.withLock { $0 } == 1)
        let expected = SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false)
        #expect(try a3SystemOneClassifier(registry, provider: "vercel-ai-gateway").compat == expected)
        let saved = try #require(try await FileModelsStore(path).read(providerId: "vercel-ai-gateway"))
        guard case .classifier(let model) = try #require(saved.models.first) else {
            Issue.record("Expected a saved classifier")
            return
        }
        #expect(model.compat == expected)
        #expect(saved.etag == "\"a3\"")
        let restored = fixture.registry(store: FileModelsStore(path))
        _ = await restored.refresh(ModelsRefreshOptions(allowNetwork: false))
        #expect(try a3SystemOneClassifier(restored, provider: "vercel-ai-gateway").compat == expected)
    }

    @Test(arguments: [#""imageInput":"unknown""#, #""imageInput":true"#,
                      #""sendImageOptInHeader":"false""#, #""sendImageOptInHeader":1"#])
    func rejectsInvalidProviderClassifierCompat(field: String) throws {
        let fixture = try A3SystemOneRegistryFixture("{\"providers\":{\"vercel-ai-gateway\":{\"compat\":{\(field)}}}}")
        defer { fixture.remove() }
        let registry = fixture.registry()
        #expect(registry.getError()?.contains("providers.vercel-ai-gateway.compat.") == true)
    }
}
