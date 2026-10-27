import Testing
@testable import PiSwiftAI

private func identityOptionsModel() -> Model {
    Model(id: "identity-model", name: "Identity model", api: .openAICompletions,
          provider: "identity-test", baseUrl: "https://example.invalid", reasoning: true,
          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 16_384)
}

private func identityOptionsStream(_ model: Model) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop, timestamp: 0)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Suite("Client identity request options")
struct ClientIdentityOptionsTests {
    @Test func requestSurfacesKeepIdentityAndDefaultToNil() {
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let identities: [ClientIdentity?] = [
            StreamOptions(identity: identity).identity,
            SimpleStreamOptions(identity: identity).identity,
            DeferredFetchOptions(identity: identity).identity,
            DeferredCancelOptions(identity: identity).identity,
            ImagesOptions(identity: identity).identity,
            ClassifierOptions(identity: identity).identity,
            OpenAIOptions(identity: identity).identity,
        ]
        #expect(identities.allSatisfy { $0 == identity })
        let defaults: [ClientIdentity?] = [
            StreamOptions().identity, SimpleStreamOptions().identity,
            DeferredFetchOptions().identity, DeferredCancelOptions().identity,
            ImagesOptions().identity, ClassifierOptions().identity, OpenAIOptions().identity,
        ]
        #expect(defaults.allSatisfy { $0 == nil })
    }

    // Swift has one conversion for each provider in place of buildBaseOptions().
    @Test(arguments: [nil, ThinkingLevel.high])
    func simpleConversionsKeepIdentity(reasoning: ThinkingLevel?) throws {
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let model = identityOptionsModel()
        let context = normalizeContext(Context(messages: []))
        let options = SimpleStreamOptions(identity: identity, reasoning: reasoning)
        let identities: [ClientIdentity?] = [
            mapAnthropicSimpleOptions(model: model, context: context, options: options, apiKey: "test").identity,
            mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test").identity,
            mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").identity,
            mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "test").identity,
            mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").identity,
            mapGoogleSimpleOptions(model: model, options: options, apiKey: "test").identity,
            try mapGoogleSimpleOptionsValidated(model: model, options: options, apiKey: "test").identity,
            mapGoogleVertexSimpleOptions(model: model, options: options, apiKey: "test").identity,
            try mapGoogleVertexSimpleOptionsValidated(model: model, options: options, apiKey: "test").identity,
            mapBedrockSimpleOptions(model: model, options: options).identity,
            mapMistralSimpleOptions(model: model, options: options, apiKey: "test").identity,
        ]
        #expect(identities.count == 11)
        #expect(identities.allSatisfy { $0 == identity })
    }
}

// Use the existing serial suite for the shared API registry.
extension ApiRegistryTests {
    @Test(.timeLimit(.minutes(1)))
    func clientIdentitySurvivesEightDirectAndRegistryCalls() async throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let observed = LockedState<[ClientIdentity?]>([])
        let model = identityOptionsModel()
        let context = Context(messages: [])
        let transcript = normalizeContext(context)
        let handle = DeferredHandle(provider: model.provider, modelId: model.id,
                                    api: model.api.rawValue, id: "response")
        let provider = ApiProvider(api: model.api,
            stream: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                return identityOptionsStream(model)
            }, streamSimple: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                return identityOptionsStream(model)
            }, fetchDeferred: { model, _, options in
                observed.withLock { $0.append(options?.identity) }
                return identityOptionsStream(model)
            }, cancelDeferred: { _, _, options in
                observed.withLock { $0.append(options?.identity) }
            })
        let fetch = try #require(provider.fetchDeferred)
        let cancel = try #require(provider.cancelDeferred)
        _ = await provider.stream(model, transcript, StreamOptions(identity: identity)).result()
        _ = await provider.streamSimple(model, transcript, SimpleStreamOptions(identity: identity)).result()
        _ = await fetch(model, handle, DeferredFetchOptions(identity: identity)).result()
        try await cancel(model, handle, DeferredCancelOptions(identity: identity))

        registerApiProvider(provider, sourceId: "identity-options")
        _ = try await stream(model: model, context: context, options: StreamOptions(identity: identity)).result()
        _ = try await streamSimple(model: model, context: context, options: SimpleStreamOptions(identity: identity)).result()
        _ = try await fetchDeferred(model: model, handle: handle, options: DeferredFetchOptions(identity: identity))
        try await cancelDeferred(model: model, handle: handle, options: DeferredCancelOptions(identity: identity))
        let identities = observed.withLock { $0 }
        #expect(identities.count == 8)
        #expect(identities.allSatisfy { $0 == identity })
    }

    @Test(.timeLimit(.minutes(1)))
    func clientIdentitySurvivesFauxFullToSimpleConversion() async throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let observed = LockedState<ClientIdentity?>(nil)
        let registration = registerFauxProvider()
        let model = try #require(registration.getModel())
        registration.setResponses([.factory { _, options, _, _ in
            observed.withLock { $0 = options?.identity }
            return fauxAssistantMessage(content: [fauxText("done")])
        }])
        _ = try await stream(model: model, context: Context(messages: []),
                             options: StreamOptions(identity: identity)).result()
        #expect(observed.withLock { $0 } == identity)
    }

    @Test(.timeLimit(.minutes(1)))
    func clientIdentitySurvivesDirectAndRegistryImageCalls() async throws {
        ensureBuiltInImageProviders()
        let previous = try #require(getImageApiProvider(.openrouterImages))
        defer { registerImageApiProvider(previous, sourceId: "built-in") }
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let observed = LockedState<[ClientIdentity?]>([])
        let model = ImageModel(id: "telemetry-image", name: "Telemetry image", api: .openrouterImages,
            provider: "identity-test", baseUrl: "https://example.invalid", input: [.text], output: [.image],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        let context = ImagesContext(input: [.text(TextContent(text: "circle"))])
        let provider = ImageApiProvider(api: model.api) { model, _, options in
            observed.withLock { $0.append(options?.identity) }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                                   stopReason: .stop, timestamp: 0)
        }
        _ = await provider.generateImages(model, context, ImagesOptions(identity: identity))
        registerImageApiProvider(provider, sourceId: "identity-options")
        _ = await generateImages(model: model, context: context, options: ImagesOptions(identity: identity))
        let identities = observed.withLock { $0 }
        #expect(identities.count == 2)
        #expect(identities.allSatisfy { $0 == identity })
    }
}

extension ApiRegistryTests {
    @Test(.timeLimit(.minutes(1)))
    func clientIdentitySurvivesLegacyOpenAIConversion() async {
        resetApiProviders()
        defer { resetApiProviders() }
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let observed = LockedState<ClientIdentity?>(nil)
        let model = identityOptionsModel()
        registerApiProvider(ApiProvider(api: model.api, stream: { model, _, options in
            observed.withLock { $0 = options?.identity }
            return identityOptionsStream(model)
        }, streamSimple: { model, _, _ in identityOptionsStream(model) }), sourceId: "identity-legacy")

        _ = await streamOpenAI(model: model, context: Context(messages: []), options: OpenAIOptions(identity: identity)).result()

        #expect(observed.withLock { $0 } == identity)
    }

    @Test(.timeLimit(.minutes(1)))
    func clientIdentitySurvivesDirectAndRegistryClassifierCalls() async throws {
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled, version: "9.9.9")
        let observed = LockedState<[ClientIdentity?]>([])
        let model = ClassifierModel(id: "identity-classifier", name: "Identity classifier", api: .typesafeSystemOne,
            provider: "identity-test", baseUrl: "https://example.invalid", input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000)
        let context = ClassifierContext(state: [:], questions: [:])
        _ = await classify(model: model, context: context, options: ClassifierOptions(env: [:]))
        let previous = try #require(getClassifierApiProvider(.typesafeSystemOne))
        defer { registerClassifierApiProvider(previous, sourceId: "built-in") }
        let provider = ClassifierApiProvider(api: model.api) { model, _, options in
            observed.withLock { $0.append(options?.identity) }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
        }
        _ = await provider.classify(model, context, ClassifierOptions(identity: identity))
        registerClassifierApiProvider(provider, sourceId: "identity-options")
        _ = await classify(model: model, context: context, options: ClassifierOptions(identity: identity))

        #expect(observed.withLock { $0 } == [identity, identity])
    }
}

extension ClientIdentityOptionsTests {
    @Test func requestOptionDefaultsMergeFieldByField() {
        func check<Options: ClientIdentityOptions>(_ options: Options) {
            let base = ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION), version: "base")
            let inherited = withClientIdentity(options, base)
            #expect(inherited.identity == base)
            var request = inherited
            request.identity = ClientIdentity(attribution: .disabled)
            let merged = withClientIdentity(request, base)
            #expect(merged.identity == ClientIdentity(userAgent: .short, attribution: .disabled, version: "base"))
            #expect(options.identity == nil)
        }
        check(StreamOptions())
        check(SimpleStreamOptions())
        check(DeferredFetchOptions())
        check(DeferredCancelOptions())
        check(ImagesOptions())
        check(ClassifierOptions())
        check(OpenAIOptions())
        check(OpenAICompletionsOptions())
        check(OpenAIResponsesOptions())
        check(AzureOpenAIResponsesOptions())
        check(OpenAICodexResponsesOptions())
        check(GoogleOptions())
        check(GoogleGeminiCliOptions())
        check(GoogleVertexOptions())
        check(AnthropicOptions())
        check(BedrockOptions())
        check(MistralOptions())
    }
}
