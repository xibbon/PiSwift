import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurableTesting
import Testing

private struct ModelsFixture: Sendable {
    let directory: URL
    let auth: AuthStorage
    let registry: ModelRegistry

    init(api: Api = .openAICompletions, provider: String = "i2-models", authHeader: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("i2-models-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config: [String: Any] = ["providers": [provider: [
            "baseUrl": "https://i2.invalid/v1", "api": api.rawValue, "apiKey": "configured-key", "authHeader": authHeader,
            "headers": ["X-Shared": "provider", "X-Provider": "provider", "X-Env": "${ACCOUNT}"],
            "models": [["id": "ExactID", "name": "I2 Model", "contextWindow": 12000, "maxTokens": 500,
                        "headers": ["x-shared": "model", "X-Model": "model"]]]
        ]]]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("models.json"))
        auth = AuthStorage.inMemory([provider: .apiKey(ApiKeyCredential(key: "stored-key", env: ["ACCOUNT": "stored", "STORED": "yes"]))])
        registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func modelAnswer(_ model: Model) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "answer"))], api: model.api, provider: model.provider,
                     model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
}

private func recordStreams(_ fixture: ModelsFixture, into observed: LockedState<[SimpleStreamOptions]>, started: HarnessChatSignal? = nil) {
    fixture.registry.registerProvider(HookProviderConfig(provider: "i2-models", api: .openAICompletions,
        baseUrl: "https://i2.invalid/v1", streamSimple: { model, _, options in
            observed.withLock { $0.append(options ?? .init()) }
            started?.signal()
            let stream = AssistantMessageEventStream()
            stream.end(modelAnswer(model))
            return stream
        }, models: [HookProviderModel(id: "ExactID", contextWindow: 12000, maxTokens: 500)]), sourceId: "i2-stream")
}

@Test func registryModelsCreationSnapshotAndExactLookup() async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
    #expect(model.name == "I2 Model")
    #expect(models.getModel(provider: "I2-MODELS", modelId: "ExactID") == nil)
    #expect(models.getModel(provider: "i2-models", modelId: "exactid") == nil)
    #expect(models.getAvailableSnapshot().contains { $0.provider == model.provider && $0.id == model.id && $0.contextWindow == 12000 })
    fixture.auth.setRuntimeApiKey("late-i2", "late-key")
    fixture.registry.registerProvider(HookProviderConfig(provider: "late-i2", api: .openAICompletions,
        baseUrl: "https://late.invalid", models: [HookProviderModel(id: "late")]), sourceId: "i2-late")
    #expect(!models.getAvailableSnapshot().contains { $0.provider == "late-i2" })
    _ = await models.refresh(ModelsRefreshOptions(allowNetwork: false))
    #expect(models.getAvailableSnapshot().contains { $0.provider == "late-i2" })
}

@Test(.timeLimit(.minutes(1))) func registryModelsStreamStartsBeforeObservationAndResolvesAuthAtEachUse() async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    let observed = LockedState<[SimpleStreamOptions]>([])
    let started = HarnessChatSignal()
    recordStreams(fixture, into: observed, started: started)
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
    let stream = models.streamSimple(model: model, context: Context(messages: []), options: .init(
        env: ["ACCOUNT": "request", "REQUEST": "yes"], headers: ["X-SHARED": "request", "X-Request": "request"]))
    await started.wait()
    #expect(observed.withLock { $0.count } == 1)
    #expect(await stream.result().stopReason == .stop)
    let first = try #require(observed.withLock { $0.first })
    #expect(first.apiKey == "stored-key")
    #expect(first.headers == ["X-Provider": "provider", "X-Model": "model", "X-SHARED": "request", "X-Request": "request", "X-Env": "request"])
    #expect(first.env == ["ACCOUNT": "request", "STORED": "yes", "REQUEST": "yes"])
    fixture.auth.set("i2-models", credential: .apiKey(ApiKeyCredential(key: "new-key", env: ["ACCOUNT": "new"])))
    _ = await models.completeSimple(model: model, context: Context(messages: []), options: .init())
    #expect(observed.withLock { $0.last?.apiKey } == "new-key")
    _ = await models.completeSimple(model: model, context: Context(messages: []), options: .init(apiKey: "explicit-key"))
    #expect(observed.withLock { $0.last?.apiKey } == "explicit-key")
}

@Test func registryModelsPreCancelledSetupIsError() async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    let observed = LockedState<[SimpleStreamOptions]>([])
    recordStreams(fixture, into: observed)
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
    let token = CancellationToken()
    token.cancel()
    let stream = models.streamSimple(model: model, context: Context(messages: []), options: .init(signal: token))
    var terminal: StopReason?
    for await event in stream {
        if case .error(let reason, let error) = event { terminal = reason; #expect(error.stopReason == .error) }
    }
    #expect(terminal == .error)
    #expect(await stream.result().stopReason == .error)
    #expect(observed.withLock { $0.isEmpty })
}

@Test(arguments: [StopReason.error, .aborted]) func registryModelsCancelledProviderResultPassesThrough(reason: StopReason) async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    fixture.registry.registerProvider(HookProviderConfig(provider: "i2-models", api: .openAICompletions,
        baseUrl: "https://i2.invalid/v1", streamSimple: { model, _, options in
            let stream = AssistantMessageEventStream()
            options?.signal?.cancel()
            var failed = modelAnswer(model)
            failed.stopReason = reason
            failed.errorMessage = "provider cancellation"
            failed.timestamp = 123
            failed.durationMs = 7
            failed.usage = Usage(input: 2, output: 3, cacheRead: 4, cacheWrite: 5, totalTokens: 14)
            stream.push(.error(reason: reason, error: failed))
            return stream
        }, models: [HookProviderModel(id: "ExactID")]), sourceId: "i2-cancel")
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
    let result = await models.completeSimple(model: model, context: Context(messages: []), options: .init(signal: CancellationToken()))
    #expect(result.stopReason == reason)
    #expect(result.errorMessage == "provider cancellation")
    #expect(result.timestamp == 123 && result.durationMs == 7)
    #expect(result.usage.totalTokens == 14)
    #expect(result.content.count == 1)
}

private enum ModelsSetupFailure: Error, LocalizedError {
    case failed
    var errorDescription: String? { "setup failed" }
}

private func expectSetupError(_ message: AssistantMessage, model: Model, error: String,
                              earliest: Int64, latest: Int64) {
    #expect(message.role == "assistant")
    #expect(message.content.isEmpty)
    #expect(message.api == model.api && message.provider == model.provider && message.model == model.id)
    #expect(message.stopReason == .error && message.errorMessage == error)
    #expect(message.timestamp >= earliest && message.timestamp <= latest)
    #expect(message.usage.input == 0 && message.usage.output == 0 && message.usage.cacheRead == 0
            && message.usage.cacheWrite == 0 && message.usage.totalTokens == 0)
    #expect(message.usage.cost.input == 0 && message.usage.cost.output == 0 && message.usage.cost.cacheRead == 0
            && message.usage.cost.cacheWrite == 0 && message.usage.cost.total == 0)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func registryModelsSetupFailureHasUpstreamShape(cancelled: Bool) async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    let reached = HarnessChatSignal(), release = HarnessChatSignal()
    try fixture.registry.registerVirtualModel(VirtualModelDefinition(provider: "i2-setup", id: "auto", name: "Setup", route: { request in
        reached.signal()
        await release.wait()
        if cancelled { request.signal?.cancel() }
        throw ModelsSetupFailure.failed
    }), sourceId: "i2-setup")
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-setup", modelId: "auto"))
    let before = Int64(Date().timeIntervalSince1970 * 1000)
    let output = models.streamSimple(model: model, context: Context(messages: []), options: .init(signal: CancellationToken()))
    let after = Int64(Date().timeIntervalSince1970 * 1000)
    await reached.wait()
    try await Task.sleep(for: .milliseconds(20))
    release.signal()
    var events = 0
    for await event in output {
        if case .error(let reason, let message) = event {
            #expect(reason == .error)
            expectSetupError(message, model: model, error: "setup failed", earliest: before, latest: after)
            events += 1
        } else { Issue.record("Setup failure must emit only an error event") }
    }
    #expect(events == 1)
    expectSetupError(await output.result(), model: model, error: "setup failed", earliest: before, latest: after)
}

@Test func registryModelsAuthenticationFailureHasUpstreamShape() async throws {
    let fixture = try ModelsFixture(authHeader: true)
    defer { fixture.remove() }
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
    fixture.auth.set("i2-models", credential: .apiKey(ApiKeyCredential(key: nil, env: ["ACCOUNT": "stored"])))
    let auth = await fixture.registry.resolveModelRequest(model)
    #expect(!auth.auth.ok)
    let before = Int64(Date().timeIntervalSince1970 * 1000)
    let output = models.streamSimple(model: model, context: Context(messages: []), options: .init())
    let after = Int64(Date().timeIntervalSince1970 * 1000)
    expectSetupError(await output.result(), model: model, error: auth.auth.error ?? "Provider is not configured: \(model.provider)",
                     earliest: before, latest: after)
}

@Test func registryModelsVirtualRouteDropsCrossProviderCredentials() async throws {
    let fixture = try ModelsFixture()
    defer { fixture.remove() }
    let observed = LockedState<[SimpleStreamOptions]>([])
    recordStreams(fixture, into: observed)
    let physical = try #require(fixture.registry.find("i2-models", "ExactID"))
    try fixture.registry.registerVirtualModel(VirtualModelDefinition(provider: "i2-router", id: "auto", name: "Auto", route: { _ in
        ModelRoute(model: physical, thinkingLevel: .off)
    }), sourceId: "i2-route")
    let models = await RegistryDurableModels.create(registry: fixture.registry)
    let virtual = try #require(models.getModel(provider: "i2-router", modelId: "auto"))
    _ = await models.completeSimple(model: virtual, context: Context(messages: []), options: .init(
        env: ["SECRET": "caller"], maxTokens: 2000, apiKey: "caller", headers: ["X-Secret": "caller"]))
    let options = try #require(observed.withLock { $0.first })
    #expect(options.apiKey == "stored-key")
    #expect(options.headers?["X-Secret"] == nil)
    #expect(options.env?["SECRET"] == nil)
    #expect(options.maxTokens == 500)
    #expect(options.reasoning == nil)
}

@Suite(.serialized) struct RegistryDeferredModelsTests {
    @Test func deferredRequestsReceiveMergedOptions() async throws {
        let fixture = try ModelsFixture(api: .piVirtual, provider: "i2-deferred")
        defer { fixture.remove() }
        let faux = registerFauxProvider(FauxRegistrationOptions(api: Api.piVirtual.rawValue, provider: "i2-deferred",
            models: [FauxModelDefinition(id: "ExactID")], deferred: FauxDeferredOptions()))
        defer { faux.unregister() }
        let original = try #require(getApiProvider(.piVirtual))
        let fetches = LockedState<[DeferredFetchOptions]>([])
        let cancels = LockedState<[DeferredCancelOptions]>([])
        let requestModels = LockedState<[Model]>([])
        registerApiProvider(ApiProvider(api: .piVirtual, stream: original.stream, streamSimple: original.streamSimple,
            fetchDeferred: { model, handle, options in
                fetches.withLock { $0.append(options ?? .init()) }
                requestModels.withLock { $0.append(model) }
                if options?.wait == 99 || options?.wait == 98 {
                    options?.signal?.cancel()
                    var message = modelAnswer(model)
                    message.stopReason = options?.wait == 99 ? .error : .aborted
                    message.errorMessage = "provider poll cancellation"
                    message.timestamp = 456
                    message.durationMs = 8
                    let output = AssistantMessageEventStream()
                    output.push(.error(reason: message.stopReason, error: message))
                    return output
                }
                return original.fetchDeferred!(model, handle, options)
            }, cancelDeferred: { model, handle, options in
                cancels.withLock { $0.append(options ?? .init()) }
                requestModels.withLock { $0.append(model) }
                try await original.cancelDeferred!(model, handle, options)
            }), sourceId: faux.sourceId)
        let models = await RegistryDurableModels.create(registry: fixture.registry)
        let model = try #require(models.getModel(provider: "i2-deferred", modelId: "ExactID"))
        // Obtain a real faux deferred handle. pi-virtual is a marker in the registry,
        // so the submission uses the faux API directly; polling uses the adapter.
        faux.setResponses([.message(modelAnswer(model))])
        let pending = try await PiSwiftAI.completeSimple(model: model, context: Context(messages: []), options: .init(deferred: .init()))
        let handle = try #require(pending.deferred)
        let answer = await models.fetchDeferred(model: model, handle: handle, options: .init(
            headers: ["X-SHARED": "request"], env: ["ACCOUNT": "fetch"], timeoutMs: 123, wait: 7))
        #expect(answer.stopReason == .stop)
        let fetched = try #require(fetches.withLock { $0.first })
        #expect(fetched.apiKey == "stored-key")
        #expect(fetched.headers == ["X-Provider": "provider", "X-Model": "model", "X-SHARED": "request", "X-Env": "fetch"])
        #expect(fetched.env == ["ACCOUNT": "fetch", "STORED": "yes"])
        #expect(fetched.timeoutMs == 123 && fetched.wait == 7)
        fixture.auth.set("i2-deferred", credential: .apiKey(ApiKeyCredential(key: "changed-key", env: ["ACCOUNT": "stored", "STORED": "yes"])))
        let secondFetch = await models.fetchDeferred(model: model, handle: handle, options: .init())
        #expect(secondFetch.stopReason == .stop)
        #expect(fetches.withLock { $0.last?.apiKey } == "changed-key")
        try await models.cancelDeferred(model: model, handle: handle, options: .init(
            apiKey: "explicit", headers: ["X-SHARED": "cancel"], env: ["ACCOUNT": "cancel"], timeoutMs: 456))
        let cancelled = try #require(cancels.withLock { $0.first })
        #expect(cancelled.apiKey == "explicit")
        #expect(cancelled.headers == ["X-Provider": "provider", "X-Model": "model", "X-SHARED": "cancel", "X-Env": "cancel"])
        #expect(cancelled.env == ["ACCOUNT": "cancel", "STORED": "yes"])
        #expect(cancelled.timeoutMs == 456)
        #expect(faux.state().deferredFetchCount == 2)
        #expect(faux.state().cancelledDeferred == [handle])
        #expect(requestModels.withLock { $0.allSatisfy { $0.baseUrl == "https://i2.invalid/v1" } })
        for (wait, reason) in [(99, StopReason.error), (98, .aborted)] {
            let cancelledPoll = await models.fetchDeferred(model: model, handle: handle, options: .init(signal: CancellationToken(), wait: wait))
            #expect(cancelledPoll.stopReason == reason)
            #expect(cancelledPoll.errorMessage == "provider poll cancellation")
            #expect(cancelledPoll.timestamp == 456 && cancelledPoll.durationMs == 8)
            #expect(cancelledPoll.content.count == 1)
        }
    }

    @Test func deferredPreparationFailureReturnsErrorAndCancellationThrows() async throws {
        let fixture = try ModelsFixture()
        defer { fixture.remove() }
        let models = await RegistryDurableModels.create(registry: fixture.registry)
        let model = try #require(models.getModel(provider: "i2-models", modelId: "ExactID"))
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "unused")
        let token = CancellationToken()
        token.cancel()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let failure = await models.fetchDeferred(model: model, handle: handle, options: .init(signal: token))
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        expectSetupError(failure, model: model, error: "Request was aborted", earliest: before, latest: after)
        await #expect(throws: (any Error).self) {
            try await models.cancelDeferred(model: model, handle: handle, options: .init(signal: token))
        }
    }
}
