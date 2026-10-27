import Testing
@testable import PiSwiftAI

private let registryBaseIdentity = ClientIdentity(
    userAgent: .detailed,
    attribution: .value(ClientAttribution(name: "base", url: "https://base.example")),
    version: "1.2.3"
)
private let registryWrapperIdentity = ClientIdentity(
    userAgent: .short,
    attribution: .value(ClientAttribution(name: "wrapper", url: "https://wrapper.example"))
)
private let registryMergedIdentity = ClientIdentity(
    userAgent: .short,
    attribution: registryWrapperIdentity.attribution,
    version: "1.2.3"
)
private let registryRequestIdentity = ClientIdentity(userAgent: .custom("request"), attribution: .disabled)
private let registryFinalIdentity = ClientIdentity(userAgent: .custom("request"), attribution: .disabled, version: "1.2.3")

private func identityRegistryModel() -> Model {
    Model(id: "identity-registry", name: "Identity registry", api: .openAICompletions,
          provider: "identity-registry", baseUrl: "https://example.invalid", reasoning: false,
          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 4096)
}

private func identityRegistryStream(_ model: Model) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

extension ApiRegistryTests {
    @Test(.timeLimit(.minutes(1)))
    func providerIdentityDefaultsApplyAcrossAllChatOperations() async throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let observed = LockedState<[ClientIdentity?]>([])
        let nilOptions = LockedState<[Bool]>([])
        let model = identityRegistryModel()
        let context = normalizeContext(Context(messages: []))
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "identity")
        func provider(identity: ClientIdentity? = nil) -> ApiProvider {
            ApiProvider(api: model.api, stream: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                nilOptions.withLock { $0.append(options == nil) }
                return identityRegistryStream(model)
            }, streamSimple: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                nilOptions.withLock { $0.append(options == nil) }
                return identityRegistryStream(model)
            }, fetchDeferred: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                nilOptions.withLock { $0.append(options == nil) }
                return identityRegistryStream(model)
            }, cancelDeferred: { _, _, options in
                observed.withLock { $0.append(options?.identity) }
                nilOptions.withLock { $0.append(options == nil) }
            }, identity: identity)
        }
        func send(_ provider: ApiProvider, identity: ClientIdentity? = nil) async throws {
            let fetch = try #require(provider.fetchDeferred)
            let cancel = try #require(provider.cancelDeferred)
            _ = await provider.stream(model, context, identity.map { StreamOptions(identity: $0) }).result()
            _ = await provider.streamSimple(model, context, identity.map { SimpleStreamOptions(identity: $0) }).result()
            _ = await fetch(model, handle, identity.map { DeferredFetchOptions(identity: $0) }).result()
            try await cancel(model, handle, identity.map { DeferredCancelOptions(identity: $0) })
        }

        try await send(provider())
        #expect(nilOptions.withLock { $0 } == [true, true, true, true])
        let base = provider(identity: registryBaseIdentity)
        try await send(base)
        let wrapped = withClientIdentity(base, registryWrapperIdentity)
        #expect(wrapped.api == base.api)
        try await send(wrapped)
        try await send(wrapped, identity: registryRequestIdentity)
        let expected: [ClientIdentity?] =
            Array(repeating: nil, count: 4) +
            Array(repeating: registryBaseIdentity, count: 4) +
            Array(repeating: registryMergedIdentity, count: 4) +
            Array(repeating: registryFinalIdentity, count: 4)
        #expect(observed.withLock { $0 } == expected)

        let noDeferred = ApiProvider(api: model.api, stream: base.stream, streamSimple: base.streamSimple)
        let noDeferredWrapper = withClientIdentity(noDeferred, registryWrapperIdentity)
        #expect(noDeferredWrapper.fetchDeferred == nil)
        #expect(noDeferredWrapper.cancelDeferred == nil)
        registerApiProvider(wrapped, sourceId: "identity-registry")
        let registered = try #require(getApiProvider(model.api))
        try await send(registered, identity: registryRequestIdentity)
        #expect(observed.withLock { Array($0.suffix(4)) } == Array(repeating: registryFinalIdentity, count: 4))
        unregisterApiProviders(sourceId: "identity-registry")
        #expect(getApiProvider(model.api) == nil)
        registerApiProvider(base, sourceId: "identity-registry-restored")
        #expect(getApiProvider(model.api) != nil)
        unregisterApiProviders(sourceId: "identity-registry-restored")
    }

    @Test(.timeLimit(.minutes(1)))
    func imageProviderIdentityDefaultsKeepRegistrationMutable() async throws {
        let model = ImageModel(id: "identity-image", name: "Identity image", api: .openrouterImages,
            provider: "identity-test", baseUrl: "https://example.invalid", input: [.text], output: [.image],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        let previous = getImageApiProvider(model.api)
        defer {
            unregisterImageApiProviders(sourceId: "identity-image")
            if let previous { registerImageApiProvider(previous, sourceId: "built-in") }
        }
        let observed = LockedState<[ClientIdentity?]>([])
        let nilOptions = LockedState<[Bool]>([])
        let generate: ImageApiFunction = { model, _, options in
            observed.withLock { $0.append(options?.identity) }
            nilOptions.withLock { $0.append(options == nil) }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
        }
        let context = ImagesContext(input: [.text(TextContent(text: "circle"))])
        let plain = ImageApiProvider(api: model.api, generateImages: generate)
        _ = await plain.generateImages(model, context, nil)
        #expect(nilOptions.withLock { $0 } == [true])
        let base = ImageApiProvider(api: model.api, generateImages: generate, identity: registryBaseIdentity)
        _ = await base.generateImages(model, context, nil)
        let wrapped = withClientIdentity(base, registryWrapperIdentity)
        #expect(wrapped.api == base.api)
        _ = await wrapped.generateImages(model, context, nil)
        registerImageApiProvider(wrapped, sourceId: "identity-image")
        let registered = try #require(getImageApiProvider(model.api))
        _ = await registered.generateImages(model, context, ImagesOptions(identity: registryRequestIdentity))
        #expect(observed.withLock { $0 } == [nil, registryBaseIdentity, registryMergedIdentity, registryFinalIdentity])
        unregisterImageApiProviders(sourceId: "identity-image")
        #expect(getImageApiProvider(model.api) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func classifierProviderIdentityDefaultsKeepRegistrationMutable() async throws {
        let model = ClassifierModel(id: "identity-classifier", name: "Identity classifier", api: .typesafeSystemOne,
            provider: "identity-test", baseUrl: "https://example.invalid", input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000)
        let previous = getClassifierApiProvider(model.api)
        defer {
            unregisterClassifierApiProviders(sourceId: "identity-classifier")
            if let previous { registerClassifierApiProvider(previous, sourceId: "built-in") }
        }
        let observed = LockedState<[ClientIdentity?]>([])
        let nilOptions = LockedState<[Bool]>([])
        let classify: ClassifierFunction = { model, _, options in
            observed.withLock { $0.append(options?.identity) }
            nilOptions.withLock { $0.append(options == nil) }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
        }
        let context = ClassifierContext(state: [:], questions: [:])
        let plain = ClassifierApiProvider(api: model.api, classify: classify)
        _ = await plain.classify(model, context, nil)
        #expect(nilOptions.withLock { $0 } == [true])
        let base = ClassifierApiProvider(api: model.api, classify: classify, identity: registryBaseIdentity)
        _ = await base.classify(model, context, nil)
        let wrapped = withClientIdentity(base, registryWrapperIdentity)
        #expect(wrapped.api == base.api)
        _ = await wrapped.classify(model, context, nil)
        registerClassifierApiProvider(wrapped, sourceId: "identity-classifier")
        let registered = try #require(getClassifierApiProvider(model.api))
        _ = await registered.classify(model, context, ClassifierOptions(identity: registryRequestIdentity))
        #expect(observed.withLock { $0 } == [nil, registryBaseIdentity, registryMergedIdentity, registryFinalIdentity])
        unregisterClassifierApiProviders(sourceId: "identity-classifier")
        #expect(getClassifierApiProvider(model.api) == nil)
    }
}
