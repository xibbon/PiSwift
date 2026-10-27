// v1.4.0 order A1: identity on ModelRegistry-resolved requests (upstream identity.test.ts:235).
import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private struct IdentityModelRegistryFixture {
    let directory: URL
    let provider = "identity-registry-\(UUID().uuidString)"
    let registry: ModelRegistry
    let requests = LockedState<[(Model, SimpleStreamOptions?)]>([])

    init(headers: ProviderHeaders? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(provider)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auth = AuthStorage(directory.appendingPathComponent("auth.json").path)
        auth.set(provider, credential: .apiKey(ApiKeyCredential(key: "identity-key")))
        registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryCodingAgentModelsStore(), networkEnabled: false)
        let requests = requests
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions, baseUrl: "https://opencode.ai/zen/v1",
            headers: headers,
            streamSimple: { model, _, options in
                requests.withLock { $0.append((model, options)) }
                let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
                let stream = AssistantMessageEventStream()
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
                return stream
            }, models: [HookProviderModel(id: "chat")]
        ), sourceId: provider)
    }

    func remove() {
        registry.unregisterProviders(sourceId: provider)
        try? FileManager.default.removeItem(at: directory)
    }

    func model() throws -> Model {
        try #require(registry.find(provider, "chat"))
    }
}

@Suite("Client identity ModelRegistry", .serialized, .timeLimit(.minutes(1)))
struct ClientIdentityModelRegistryTests {
    // Upstream v1.4.0 identity.test.ts:235: inspect the resolved request, not the catalog endpoint.
    @Test func customOpenCodeRoutesFullAndSimpleRequestsAfterResolution() async throws {
        let fixture = try IdentityModelRegistryFixture()
        defer { fixture.remove() }
        let identity = ClientIdentity(userAgent: .short, attribution: .disabled)
        let context = PiSwiftAI.Context(messages: [])
        _ = await fixture.registry.stream(model: try fixture.model(), context: context,
            options: StreamOptions(identity: identity, sessionId: "session-1")).result()
        _ = await fixture.registry.streamSimple(model: try fixture.model(), context: context,
            options: SimpleStreamOptions(identity: identity, sessionId: "session-2")).result()
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.map { $0.0.baseUrl } == ["https://opencode.ai/zen/v1", "https://opencode.ai/zen/v1"])
        #expect(requests.map { providerHeaderValue($0.1?.headers, name: "x-opencode-session") } == ["session-1", "session-2"])
        #expect(requests.allSatisfy { $0.1?.identity == identity })
    }

    @Test func customOpenCodeKeepsAuthAndRequestOverridesAndDeletion() async throws {
        let fixture = try IdentityModelRegistryFixture(headers: ["X-OpenCode-Session": "configured"])
        defer { fixture.remove() }
        let context = PiSwiftAI.Context(messages: [])
        for headers: ProviderHeaders? in [nil, ["X-OPENCODE-SESSION": "request"], ["x-OpenCode-session": nil]] {
            _ = await fixture.registry.streamSimple(model: try fixture.model(), context: context,
                options: SimpleStreamOptions(sessionId: "session-1", headers: headers)).result()
        }
        let requests = fixture.requests.withLock { $0 }
        #expect(requests.count == 3)
        #expect(requests.map { providerHeaderValue($0.1?.headers, name: "x-opencode-session") } == ["configured", "request", nil])
        #expect(providerHeadersContain(requests.last?.1?.headers, name: "x-opencode-session"))
    }

    @Test func openCodeSessionRequiresNonemptySessionAndExactTarget() {
        func model(provider: String = "custom", baseUrl: String = "https://opencode.ai/zen/v1") -> Model {
            Model(id: "chat", name: "Test", api: .openAICompletions, provider: provider,
                baseUrl: baseUrl, reasoning: false, input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 8192, maxTokens: 1024)
        }
        #expect(openCodeSessionHeaders(model: model(), sessionId: "", headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(), sessionId: nil, headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(baseUrl: "https://opencode.ai.example/v1"), sessionId: "session", headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(baseUrl: "https://gateway.example/opencode.ai"), sessionId: "session", headers: nil) == nil)
        #expect(providerHeaderValue(openCodeSessionHeaders(model: model(provider: "opencode-go", baseUrl: "https://gateway.example"), sessionId: "session", headers: nil), name: "x-opencode-session") == "session")
    }
}

