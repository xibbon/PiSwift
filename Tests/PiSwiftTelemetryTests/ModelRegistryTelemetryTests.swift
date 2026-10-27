import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftTelemetry

private struct TelemetryRegistryFixture {
    let directory: URL
    let provider: String
    let registry: ModelRegistry

    init() throws {
        provider = "telemetry-registry-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(provider)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ["providers": [provider: ["modelOverrides": [
            "chat": ["name": "Configured telemetry model"],
        ]]]]
        try JSONSerialization.data(withJSONObject: configuration)
            .write(to: directory.appendingPathComponent("models.json"))
        let auth = AuthStorage(directory.appendingPathComponent("auth.json").path)
        auth.set(provider, credential: .apiKey(ApiKeyCredential(key: "telemetry-test-key")))
        registry = ModelRegistry(auth, directory.path,
                                 modelsStore: InMemoryCodingAgentModelsStore(), networkEnabled: false)
    }

    func remove() {
        registry.unregisterProviders(sourceId: provider)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func registryTelemetryStream(_ model: Model) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop, timestamp: 0)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Suite("ModelRegistry telemetry options", .serialized, .timeLimit(.minutes(1)))
struct ModelRegistryTelemetryTests {
    @Test func fullAndSimpleStreamKeepSpanThroughAuthAndOptionConversion() async throws {
        let fixture = try TelemetryRegistryFixture()
        defer { fixture.remove() }
        let span = noopTelemetryContext
        let observed = LockedState<[(any TelemetrySpan)?]>([])
        let keys = LockedState<[String?]>([])
        fixture.registry.registerProvider(HookProviderConfig(
            provider: fixture.provider, api: .openAICompletions, baseUrl: "https://example.invalid",
            streamSimple: { model, _, options in
                observed.withLock { $0.append(options?.telemetry) }
                keys.withLock { $0.append(options?.apiKey) }
                #expect(model.name == "Configured telemetry model")
                return registryTelemetryStream(model)
            },
            models: [HookProviderModel(id: "chat")]
        ), sourceId: fixture.provider)
        let model = try #require(fixture.registry.find(fixture.provider, "chat"))
        let context = PiSwiftAI.Context(messages: [])
        let full = await fixture.registry.stream(model: model, context: context,
            options: StreamOptions(telemetry: span)).result()
        let simple = await fixture.registry.streamSimple(model: model, context: context,
            options: SimpleStreamOptions(telemetry: span)).result()
        #expect(full.stopReason == .stop)
        #expect(simple.stopReason == .stop)
        let spans = observed.withLock { $0 }
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0 === span })
        #expect(keys.withLock { $0 } == ["telemetry-test-key", "telemetry-test-key"])
    }

    @Test func imageRequestKeepsSpanThroughAuthAndDispatch() async throws {
        let fixture = try TelemetryRegistryFixture()
        defer { fixture.remove() }
        let span = noopTelemetryContext
        let observed = LockedState<[(any TelemetrySpan)?]>([])
        fixture.registry.registerProvider(HookProviderConfig(
            provider: fixture.provider, api: .openAICompletions, baseUrl: "https://example.invalid",
            images: [.openrouterImages: { model, _, options in
                observed.withLock { $0.append(options?.telemetry) }
                #expect(options?.apiKey == "telemetry-test-key")
                return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                                       stopReason: .stop, timestamp: 0)
            }],
            models: [.image(HookProviderImageModel(id: "image", api: .openrouterImages))]
        ), sourceId: fixture.provider)
        let entry = try #require(fixture.registry.getModelOfType(.image, provider: fixture.provider, modelId: "image"))
        guard case .image(let model) = entry else {
            Issue.record("Expected an image model")
            return
        }
        let result = await fixture.registry.generateImages(model,
            context: ImagesContext(input: [.text(TextContent(text: "circle"))]),
            options: ImagesOptions(telemetry: span))
        #expect(result.stopReason == .stop)
        let spans = observed.withLock { $0 }
        #expect(spans.count == 1)
        #expect(spans.first.flatMap { $0 } === span)
    }
}
