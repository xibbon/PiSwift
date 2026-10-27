import Testing
import PiSwiftTelemetry
@testable import PiSwiftAI

private func telemetryOptionsModel() -> Model {
    Model(id: "telemetry-model", name: "Telemetry model", api: .openAICompletions,
          provider: "telemetry-test", baseUrl: "https://example.invalid", reasoning: true,
          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 128_000, maxTokens: 16_384)
}

private func telemetryOptionsStream(_ model: Model) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop, timestamp: 0)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Suite("Telemetry request options")
struct TelemetryOptionsTests {
    @Test func requestSurfacesKeepSpanIdentityAndDefaultToNil() {
        let span = noopTelemetryContext
        let spans: [(any TelemetrySpan)?] = [
            StreamOptions(telemetry: span).telemetry,
            SimpleStreamOptions(telemetry: span).telemetry,
            DeferredFetchOptions(telemetry: span).telemetry,
            DeferredCancelOptions(telemetry: span).telemetry,
            ImagesOptions(telemetry: span).telemetry,
            ClassifierOptions(telemetry: span).telemetry,
            OpenAIOptions(telemetry: span).telemetry,
        ]
        #expect(spans.allSatisfy { $0 === span })
        let defaults: [(any TelemetrySpan)?] = [
            StreamOptions().telemetry, SimpleStreamOptions().telemetry,
            DeferredFetchOptions().telemetry, DeferredCancelOptions().telemetry,
            ImagesOptions().telemetry, ClassifierOptions().telemetry, OpenAIOptions().telemetry,
        ]
        #expect(defaults.allSatisfy { $0 == nil })
    }

    // Swift has one conversion for each provider in place of buildBaseOptions().
    @Test(arguments: [nil, ThinkingLevel.high])
    func simpleConversionsKeepSpanIdentity(reasoning: ThinkingLevel?) throws {
        let span = noopTelemetryContext
        let model = telemetryOptionsModel()
        let context = normalizeContext(Context(messages: []))
        let options = SimpleStreamOptions(telemetry: span, reasoning: reasoning)
        let spans: [(any TelemetrySpan)?] = [
            mapAnthropicSimpleOptions(model: model, context: context, options: options, apiKey: "test").telemetry,
            mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            mapGoogleSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            try mapGoogleSimpleOptionsValidated(model: model, options: options, apiKey: "test").telemetry,
            mapGoogleVertexSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
            try mapGoogleVertexSimpleOptionsValidated(model: model, options: options, apiKey: "test").telemetry,
            mapBedrockSimpleOptions(model: model, options: options).telemetry,
            mapMistralSimpleOptions(model: model, options: options, apiKey: "test").telemetry,
        ]
        #expect(spans.count == 11)
        #expect(spans.allSatisfy { $0 === span })
    }
}

// Use the existing serial suite for the shared API registry.
extension ApiRegistryTests {
    @Test(.timeLimit(.minutes(1)))
    func telemetrySurvivesEightDirectAndRegistryCalls() async throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let span = noopTelemetryContext
        let observed = LockedState<[(any TelemetrySpan)?]>([])
        let model = telemetryOptionsModel()
        let context = Context(messages: [])
        let transcript = normalizeContext(context)
        let handle = DeferredHandle(provider: model.provider, modelId: model.id,
                                    api: model.api.rawValue, id: "response")
        let provider = ApiProvider(api: model.api,
            stream: { model, _, options in
                observed.withLock { $0.append(options?.telemetry) }
                return telemetryOptionsStream(model)
            }, streamSimple: { model, _, options in
                observed.withLock { $0.append(options?.telemetry) }
                return telemetryOptionsStream(model)
            }, fetchDeferred: { model, _, options in
                observed.withLock { $0.append(options?.telemetry) }
                return telemetryOptionsStream(model)
            }, cancelDeferred: { _, _, options in
                observed.withLock { $0.append(options?.telemetry) }
            })
        let fetch = try #require(provider.fetchDeferred)
        let cancel = try #require(provider.cancelDeferred)
        _ = await provider.stream(model, transcript, StreamOptions(telemetry: span)).result()
        _ = await provider.streamSimple(model, transcript, SimpleStreamOptions(telemetry: span)).result()
        _ = await fetch(model, handle, DeferredFetchOptions(telemetry: span)).result()
        try await cancel(model, handle, DeferredCancelOptions(telemetry: span))

        registerApiProvider(provider, sourceId: "telemetry-options")
        _ = try await stream(model: model, context: context, options: StreamOptions(telemetry: span)).result()
        _ = try await streamSimple(model: model, context: context, options: SimpleStreamOptions(telemetry: span)).result()
        _ = try await fetchDeferred(model: model, handle: handle, options: DeferredFetchOptions(telemetry: span))
        try await cancelDeferred(model: model, handle: handle, options: DeferredCancelOptions(telemetry: span))
        let spans = observed.withLock { $0 }
        #expect(spans.count == 8)
        #expect(spans.allSatisfy { $0 === span })
    }

    @Test(.timeLimit(.minutes(1)))
    func telemetrySurvivesFauxFullToSimpleConversion() async throws {
        resetApiProviders()
        defer { resetApiProviders() }
        let span = noopTelemetryContext
        let observed = LockedState<(any TelemetrySpan)?>(nil)
        let registration = registerFauxProvider()
        let model = try #require(registration.getModel())
        registration.setResponses([.factory { _, options, _, _ in
            observed.withLock { $0 = options?.telemetry }
            return fauxAssistantMessage(content: [fauxText("done")])
        }])
        _ = try await stream(model: model, context: Context(messages: []),
                             options: StreamOptions(telemetry: span)).result()
        #expect(observed.withLock { $0 } === span)
    }

    @Test(.timeLimit(.minutes(1)))
    func telemetrySurvivesDirectAndRegistryImageCalls() async throws {
        ensureBuiltInImageProviders()
        let previous = try #require(getImageApiProvider(.openrouterImages))
        defer { registerImageApiProvider(previous, sourceId: "built-in") }
        let span = noopTelemetryContext
        let observed = LockedState<[(any TelemetrySpan)?]>([])
        let model = ImageModel(id: "telemetry-image", name: "Telemetry image", api: .openrouterImages,
            provider: "telemetry-test", baseUrl: "https://example.invalid", input: [.text], output: [.image],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        let context = ImagesContext(input: [.text(TextContent(text: "circle"))])
        let provider = ImageApiProvider(api: model.api) { model, _, options in
            observed.withLock { $0.append(options?.telemetry) }
            return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                                   stopReason: .stop, timestamp: 0)
        }
        _ = await provider.generateImages(model, context, ImagesOptions(telemetry: span))
        registerImageApiProvider(provider, sourceId: "telemetry-options")
        _ = await generateImages(model: model, context: context, options: ImagesOptions(telemetry: span))
        let spans = observed.withLock { $0 }
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0 === span })
    }
}
