import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func payloadHookRunner(_ hooks: [LoadedHook]) -> HookRunner {
    let runner = HookRunner(hooks, "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    return runner
}

@Suite("Provider payload hooks", .timeLimit(.minutes(1)))
struct ProviderPayloadHookTests {
    @Test func replacementsRunInHandlerAndHookOrder() async {
        let seen = LockedState<[String]>([])
        let handler: HookHandler = { event, _ in
            let event = try #require(event as? BeforeProviderRequestEvent)
            seen.withLock { $0.append(event.payload) }
            await Task.yield()
            return BeforeProviderRequestEventResult(payload: event.payload + "x")
        }
        let runner = payloadHookRunner([
            LoadedHook(path: "first", resolvedPath: "first", handlers: ["before_provider_request": [handler, handler]]),
            LoadedHook(path: "second", resolvedPath: "second", handlers: ["before_provider_request": [handler]])
        ])
        defer { runner.dispose() }
        let result = await runner.emitBeforeProviderRequest("start")
        #expect(result == "startxxx")
        #expect(seen.withLock { $0 } == ["start", "startx", "startxx"])
    }

    @Test func nilResultKeepsCurrentPayload() async {
        let seen = LockedState<[String]>([])
        let noChange: HookHandler = { event, _ in
            let event = try #require(event as? BeforeProviderRequestEvent)
            seen.withLock { $0.append(event.payload) }
            return nil
        }
        let runner = payloadHookRunner([
            LoadedHook(path: "observer", resolvedPath: "observer", handlers: ["before_provider_request": [noChange]])
        ])
        defer { runner.dispose() }
        #expect(await runner.emitBeforeProviderRequest("original") == nil)
        #expect(seen.withLock { $0 } == ["original"])
        let empty = payloadHookRunner([])
        defer { empty.dispose() }
        #expect(await empty.emitBeforeProviderRequest("original") == nil)
    }

    @Test func errorsAreReportedAndLaterHandlersContinue() async {
        enum Failure: Error { case expected }
        let errors = LockedState<[HookError]>([])
        let replacement: HookHandler = { _, _ in BeforeProviderRequestEventResult(payload: "changed") }
        let failure: HookHandler = { _, _ in throw Failure.expected }
        let final: HookHandler = { event, _ in
            let event = try #require(event as? BeforeProviderRequestEvent)
            #expect(event.payload == "changed")
            return BeforeProviderRequestEventResult(payload: "final")
        }
        let runner = payloadHookRunner([
            LoadedHook(path: "replacement", resolvedPath: "replacement", handlers: ["before_provider_request": [replacement]]),
            LoadedHook(path: "failure", resolvedPath: "failure", handlers: ["before_provider_request": [failure]]),
            LoadedHook(path: "final", resolvedPath: "final", handlers: ["before_provider_request": [final]])
        ])
        defer { runner.dispose() }
        let unsubscribe = runner.onError { error in errors.withLock { $0.append(error) } }
        defer { unsubscribe() }
        #expect(await runner.emitBeforeProviderRequest("original") == "final")
        #expect(errors.withLock { $0.count } == 1)
        #expect(errors.withLock { $0.first?.hookPath } == "failure")
        #expect(errors.withLock { $0.first?.event } == "before_provider_request")
    }

    @Test func sdkAwaitsReplacementBeforeSendingRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("payload-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = "payload-hook-\(UUID().uuidString)"
        let auth = AuthStorage.inMemory([provider: .apiKey(ApiKeyCredential(key: "test-key"))])
        let registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryCodingAgentModelsStore(), networkEnabled: false)
        let requests = LockedState<[URLRequest]>([])
        let completed = LockedState(false)
        let client = PayloadHookHTTPClient(requests: requests, completed: completed)
        registry.registerProvider(HookProviderConfig(provider: provider, api: .openAICompletions,
            baseUrl: "https://provider.example/v1", streamSimple: { model, context, options in
                var options = options ?? SimpleStreamOptions()
                options.httpClient = client
                do {
                    return try PiSwiftAI.streamSimple(model: model, context: context, options: options)
                } catch {
                    Issue.record(error)
                    let message = AssistantMessage(content: [], api: model.api, provider: model.provider,
                        model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                        stopReason: .error, errorMessage: error.localizedDescription)
                    let stream = AssistantMessageEventStream()
                    stream.push(.error(reason: .error, error: message))
                    stream.end(message)
                    return stream
                }
            }, models: [HookProviderModel(id: "chat")]), sourceId: provider)
        let model = try #require(registry.find(provider, "chat"))
        var settings = Settings()
        settings.cacheWarming = .off
        let session = try await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path, authStorage: auth, modelRegistry: registry,
            model: model, offline: true, noTools: .all, resourceLoader: TestResourceLoader(),
            hooks: [HookDefinition { api in
                api.on("before_provider_request") { (event: BeforeProviderRequestEvent, _: HookContext) in
                    await Task.yield()
                    let data = try #require(event.payload.data(using: .utf8))
                    var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    payload["model"] = "replacement-model"
                    let replacement = try JSONSerialization.data(withJSONObject: payload)
                    completed.withLock { $0 = true }
                    return BeforeProviderRequestEventResult(payload: String(decoding: replacement, as: UTF8.self))
                }
            }], noExtensions: true, sessionManager: .inMemory(), settingsManager: .inMemory(settings))).session
        defer { session.dispose() }
        try await session.prompt("hello")
        let request = try #require(requests.withLock { $0.first })
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["model"] as? String == "replacement-model")
        #expect(requests.withLock { $0.count } == 1)
    }
}

private struct PayloadHookHTTPClient: ProviderHTTPClient {
    let requests: LockedState<[URLRequest]>
    let completed: LockedState<Bool>

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        #expect(completed.withLock { $0 })
        requests.withLock { $0.append(request) }
        let body = """
        data: {"id":"payload","object":"chat.completion.chunk","created":0,"model":"chat","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(body.utf8))
    }
}
