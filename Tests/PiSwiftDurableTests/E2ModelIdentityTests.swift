import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftTelemetry
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("Harness model identity")
struct E2ModelIdentityTests {
    @Test func identityFieldsUseDefaultInnerHostThenRequest() async {
        let inner = E2IdentityModels(identity: .init(userAgent: .short, version: "inner"))
        let host = ClientIdentity(userAgent: .custom("host"))
        let wrapped = harnessModels(inner, identity: host)
        #expect(wrapped.clientIdentity == ClientIdentity(userAgent: .custom("host"), attribution: .value(PI_ATTRIBUTION), version: "inner"))
        let request = ClientIdentity(attribution: .disabled, version: "request")
        _ = await wrapped.completeSimple(model: inner.model, context: .init(messages: []), options: .init(identity: request))
        #expect(inner.calls.withLock { $0.last?.identity } == ClientIdentity(userAgent: .custom("host"), attribution: .disabled, version: "request"))
        #expect(DEFAULT_HARNESS_IDENTITY == ClientIdentity(attribution: .value(PI_ATTRIBUTION)))
    }

    @Test func disabledAttributionAndEmptyIdentitiesInheritByField() async {
        let inner = E2IdentityModels(identity: .init(attribution: .disabled, version: "inner"))
        let wrapped = harnessModels(inner, identity: ClientIdentity())
        _ = await wrapped.completeSimple(model: inner.model, context: .init(messages: []), options: .init(identity: ClientIdentity()))
        #expect(inner.calls.withLock { $0.last?.identity } == ClientIdentity(attribution: .disabled, version: "inner"))
        let attribution = ClientAttribution(name: "host", url: "https://example.invalid")
        let host = harnessModels(inner, identity: .init(attribution: .value(attribution)))
        _ = await host.completeSimple(model: inner.model, context: .init(messages: []), options: .init())
        #expect(inner.calls.withLock { $0.last?.identity?.attribution } == .value(attribution))
        let plain = FakeDurableModels()
        #expect(plain.clientIdentity == nil)
        #expect(harnessModels(plain, identity: nil).clientIdentity == DEFAULT_HARNESS_IDENTITY)
    }

    @Test func chatAndDeferredOperationsKeepOptionsAndResults() async throws {
        let inner = E2IdentityModels(identity: .init(version: "inner"))
        let wrapped = harnessModels(inner, identity: .init(userAgent: .short))
        let request = ClientIdentity(attribution: .disabled)
        let span = E2IdentitySpan(), signal = CancellationToken()
        let context = PiSwiftAI.Context(messages: [])
        #expect(wrapped.getModel(provider: inner.model.provider, modelId: inner.model.id)?.id == inner.model.id)
        let stream = await wrapped.streamSimple(model: inner.model, context: context,
            options: .init(signal: signal, telemetry: span, identity: request, apiKey: "key", timeoutMs: 123)).result()
        let complete = await wrapped.completeSimple(model: inner.model, context: context,
            options: .init(signal: signal, telemetry: span, identity: request, apiKey: "key", timeoutMs: 123))
        let handle = DeferredHandle(provider: inner.model.provider, modelId: inner.model.id, api: inner.model.api.rawValue, id: "saved")
        let fetched = await wrapped.fetchDeferred(model: inner.model, handle: handle,
            options: .init(apiKey: "key", signal: signal, telemetry: span, identity: request, timeoutMs: 123, wait: 77))
        try await wrapped.cancelDeferred(model: inner.model, handle: handle,
            options: .init(apiKey: "key", signal: signal, telemetry: span, identity: request, timeoutMs: 123))
        #expect([stream.model, complete.model, fetched.model] == [inner.model.id, inner.model.id, inner.model.id])
        let calls = inner.calls.withLock { $0 }
        #expect(calls.map(\.name) == ["stream", "complete", "fetch", "cancel"])
        for call in calls {
            #expect(call.identity == ClientIdentity(userAgent: .short, attribution: .disabled, version: "inner"))
            #expect(call.span === span)
            #expect(call.signal === signal)
            #expect(call.key == "key")
            #expect(call.timeout == 123)
        }
        #expect(calls[2].handle == handle)
        #expect(calls[3].handle == handle)
        #expect(calls[2].wait == 77)
    }

    @Test func oneTaskHookReadsEachDynamicModelAndKeepsCapabilities() async throws {
        let first = E2IdentityModels(identity: .init(version: "first"))
        let second = E2IdentityModels(identity: .init(version: "second"))
        let current = Mutex(first), reads = Mutex(0)
        let registry = Registry()
        let span = E2IdentitySpan()
        let definition = harnessOneStep("test.dynamic-model-identity") { _, runtime, context in
            let api = HookApi(taskId: runtime.taskId, conversationId: runtime.conversationId, models: runtime.models)
            for inner in [first, second] {
                current.withLock { $0 = inner }
                let before = reads.withLock { $0 }
                let catalog = try #require(api.models as? any CodemodeModels)
                #expect(catalog.getModelsOfType(.classifier, provider: "test").first?.id == inner.classifier.id)
                let available = try #require(api.models as? any CodemodeModels)
                #expect(try await available.getAvailableOfType(.image, provider: "test", context: context).first?.id == inner.painter.id)
                let lookup = try #require(api.models as? any CodemodeModels)
                #expect(lookup.getModelOfType(.chat, provider: inner.model.provider, id: inner.model.id)?.id == inner.model.id)
                let classifier = try #require(api.models as? any CodemodeModels)
                _ = try await classifier.classify(model: inner.classifier, context: .init(state: [:], questions: [:]),
                    options: .init(telemetry: span, identity: .init(attribution: .disabled)), operation: context)
                let images = try #require(api.models as? any CodemodeModels)
                _ = try await images.generateImages(model: inner.painter, context: .init(input: []),
                    options: .init(telemetry: span, identity: .init(attribution: .disabled)), operation: context)
                let handle = DeferredHandle(provider: inner.model.provider, modelId: inner.model.id, api: inner.model.api.rawValue, id: inner.clientIdentity?.version ?? "")
                _ = await api.models.fetchDeferred(model: inner.model, handle: handle,
                    options: .init(telemetry: span, identity: .init(attribution: .disabled)))
                try await api.models.cancelDeferred(model: inner.model, handle: handle,
                    options: .init(telemetry: span, identity: .init(attribution: .disabled)))
                #expect(reads.withLock { $0 } == before + 7)
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        try registry.install(Extension(name: "dynamic-model-identity", tasks: [AnyTaskDefinition(definition)]))
        let provider: HarnessModelsProvider = {
            reads.withLock { $0 += 1 }
            return current.withLock { $0 }
        }
        let harness = try await Harness.open(storage: MemoryStorage(),
            options: .init(models: provider, registry: registry, identity: .init(userAgent: .short)), context: .background)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: .null))
        try await harness.close(context: .background)
        for inner in [first, second] {
            #expect(inner.catalog.withLock { $0 } == ["list", "available", "one"])
            let calls = inner.calls.withLock { $0 }
            #expect(calls.map(\.name) == ["classify", "images", "fetch", "cancel"])
            for call in calls {
                #expect(call.identity == ClientIdentity(userAgent: .short, attribution: .disabled, version: inner.clientIdentity?.version))
                #expect(call.span === span)
            }
            #expect(calls.last?.handle?.id == inner.clientIdentity?.version)
        }
    }

    @Test func codemodeKeepsCatalogCapabilitiesAndRequestOptions() async throws {
        let inner = E2IdentityModels(identity: .init(version: "inner"))
        let wrapped = try #require(harnessModels(inner, identity: .init(userAgent: .short)) as? any CodemodeModels)
        #expect(wrapped.getModelsOfType(.classifier, provider: "test").first?.id == inner.classifier.id)
        #expect(try await wrapped.getAvailableOfType(.image, provider: "test", context: .background).first?.id == inner.painter.id)
        #expect(wrapped.getModelOfType(.chat, provider: inner.model.provider, id: inner.model.id)?.id == inner.model.id)
        #expect(inner.catalog.withLock { $0 } == ["list", "available", "one"])
        let span = E2IdentitySpan(), signal = CancellationToken()
        let identity = ClientIdentity(attribution: .disabled, version: "request")
        let classified = try await wrapped.classify(model: inner.classifier, context: .init(state: [:], questions: [:]),
            options: .init(signal: signal, telemetry: span, identity: identity, apiKey: "key", timeoutMs: 123), operation: .background)
        let images = try await wrapped.generateImages(model: inner.painter, context: .init(input: [.text(.init(text: "paint"))]),
            options: .init(signal: signal, telemetry: span, identity: identity, apiKey: "key", timeoutMs: 123), operation: .background)
        #expect(classified.model == inner.classifier.id)
        #expect(images.model == inner.painter.id)
        let calls = inner.calls.withLock { $0 }
        #expect(calls.map(\.name) == ["classify", "images"])
        for call in calls {
            #expect(call.identity == ClientIdentity(userAgent: .short, attribution: .disabled, version: "request"))
            #expect(call.span === span)
            #expect(call.signal === signal)
            #expect(call.key == "key")
            #expect(call.timeout == 123)
        }
        _ = try await wrapped.classify(model: inner.classifier, context: .init(state: [:], questions: [:]), operation: .background)
        _ = try await wrapped.generateImages(model: inner.painter, context: .init(input: []), operation: .background)
        #expect(inner.calls.withLock { Array($0.suffix(2)).map(\.identity) } == [wrapped.clientIdentity, wrapped.clientIdentity])
    }
}

private final class E2IdentityModels: CodemodeModels {
    struct Call: Sendable {
        let name: String
        let identity: ClientIdentity?
        let span: (any TelemetrySpan)?
        let signal: CancellationToken?
        let key: String?
        let timeout: Int?
        var handle: DeferredHandle? = nil
        var wait: Int? = nil
    }
    let clientIdentity: ClientIdentity?
    let model = FakeDurableModels().models[0]
    let classifier = ClassifierModel(id: "judge", name: "Judge", api: .typesafeSystemOne, provider: "test", baseUrl: "https://example.invalid", input: [.text], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000)
    let painter = ImageModel(id: "paint", name: "Paint", api: .openrouterImages, provider: "test", baseUrl: "https://example.invalid", input: [.text], output: [.image], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    let calls = Mutex<[Call]>([])
    let catalog = Mutex<[String]>([])
    init(identity: ClientIdentity?) { clientIdentity = identity }
    func getModel(provider: String, modelId: String) -> Model? { provider == model.provider && modelId == model.id ? model : nil }
    private func response() -> AssistantMessage { fauxAssistantMessage(content: [], timestamp: 1) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        record("stream", options)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: response()))
        return stream
    }
    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        record("complete", options); return response()
    }
    private func record(_ name: String, _ options: SimpleStreamOptions) {
        calls.withLock { $0.append(.init(name: name, identity: options.identity, span: options.telemetry, signal: options.signal, key: options.apiKey, timeout: options.timeoutMs)) }
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        calls.withLock { $0.append(.init(name: "fetch", identity: options.identity, span: options.telemetry, signal: options.signal, key: options.apiKey, timeout: options.timeoutMs, handle: handle, wait: options.wait)) }
        return response()
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        calls.withLock { $0.append(.init(name: "cancel", identity: options.identity, span: options.telemetry, signal: options.signal, key: options.apiKey, timeout: options.timeoutMs, handle: handle)) }
    }
    private func values(_ type: ModelType, _ provider: String?) -> [AnyModel] {
        [AnyModel.chat(model), .classifier(classifier), .image(painter)].filter { $0.type == type && (provider == nil || $0.provider == provider) }
    }
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        catalog.withLock { $0.append("list") }; return values(type, provider)
    }
    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel] {
        catalog.withLock { $0.append("available") }; return values(type, provider)
    }
    func getModelOfType(_ type: ModelType, provider: String, id: String) -> AnyModel? {
        catalog.withLock { $0.append("one") }; return values(type, provider).first { $0.id == id }
    }
    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult {
        Issue.record("The wrapper must use the options overload")
        return .init(api: model.api, provider: model.provider, model: model.id)
    }
    func classify(model: ClassifierModel, context: ClassifierContext, options: ClassifierOptions, operation: ChordContext) async throws -> ClassifierResult {
        calls.withLock { $0.append(.init(name: "classify", identity: options.identity, span: options.telemetry, signal: options.signal, key: options.apiKey, timeout: options.timeoutMs)) }
        return .init(api: model.api, provider: model.provider, model: model.id)
    }
    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages {
        Issue.record("The wrapper must use the options overload")
        return .init(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
    }
    func generateImages(model: ImageModel, context: ImagesContext, options: ImagesOptions, operation: ChordContext) async throws -> AssistantImages {
        calls.withLock { $0.append(.init(name: "images", identity: options.identity, span: options.telemetry, signal: options.signal, key: options.apiKey, timeout: options.timeoutMs)) }
        return .init(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
    }
}

private final class E2IdentitySpan: TelemetrySpan {
    func startSpan<Result>(_ options: SpanOptions, body: (any TelemetrySpan) throws -> Result) rethrows -> Result { try body(self) }
    func startSpan<Result: Sendable>(_ options: SpanOptions, body: @Sendable (any TelemetrySpan) async throws -> Result) async rethrows -> Result { try await body(self) }
    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}
