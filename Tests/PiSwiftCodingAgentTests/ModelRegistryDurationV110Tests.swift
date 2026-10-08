import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Suite(.timeLimit(.minutes(1))) struct ModelRegistryDurationV110Tests {
    @Test(arguments: [false, true]) func forwardingKeepsProviderDuration(simple: Bool) async throws {
        let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let provider = "duration-v110-\(UUID().uuidString)"
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: "https://example.invalid", streamSimple: { model, _, _ in
                let stream = AssistantMessageEventStream()
                let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: .stop, durationMs: 1234)
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }, models: [HookProviderModel(id: "demo")]), sourceId: provider)
        defer { registry.unregisterProvider(provider, sourceId: provider) }
        let model = try #require(registry.find(provider, "demo"))
        let stream = simple
            ? registry.streamSimple(model: model, context: Context(messages: []))
            : registry.stream(model: model, context: Context(messages: []))
        var iterator = stream.makeAsyncIterator()
        guard case .done(_, let delivered) = await iterator.next() else {
            Issue.record("Expected a forwarded done event")
            return
        }
        #expect(delivered.durationMs == 1234)
        #expect(await stream.result().durationMs == delivered.durationMs)
        #expect(await iterator.next() == nil)
    }

    @Test(arguments: [false, true]) func setupErrorKeepsRequestStartTimestamp(simple: Bool) async throws {
        let registry = ModelRegistry(AuthStorage(":memory:"), nil, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let provider = "setup-duration-v110-\(UUID().uuidString)"
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: "https://example.invalid", apiKey: "!sleep 0.05; exit 1",
            models: [HookProviderModel(id: "demo")]), sourceId: provider)
        defer { registry.unregisterProvider(provider, sourceId: provider) }
        let model = try #require(registry.find(provider, "demo"))
        let beforeCall = Int64(Date().timeIntervalSince1970 * 1000)
        let stream = simple
            ? registry.streamSimple(model: model, context: Context(messages: []))
            : registry.stream(model: model, context: Context(messages: []))
        let afterCall = Int64(Date().timeIntervalSince1970 * 1000)
        let result = await stream.result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Failed to resolve API key") == true)
        #expect(result.timestamp >= beforeCall)
        #expect(result.timestamp <= afterCall)
    }
}
