import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import PiSwiftTelemetry
import Testing

private final class E2ForwardingSpan: TelemetrySpan {
    func startSpan<Result>(_ options: SpanOptions, body: (any TelemetrySpan) throws -> Result) rethrows -> Result {
        try body(self)
    }

    func startSpan<Result: Sendable>(_ options: SpanOptions,
        body: @Sendable (any TelemetrySpan) async throws -> Result) async rethrows -> Result {
        try await body(self)
    }

    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

private struct E2ForwardingFixture: Sendable {
    let directory: URL
    let provider: String
    let registry: ModelRegistry
    let identities = LockedState<ClientIdentity>(ClientIdentity(userAgent: .short,
        attribution: .value(.init(name: "registry", url: "https://registry.invalid")), version: "registry-version"))
    let chats = LockedState<[SimpleStreamOptions]>([])
    let classifiers = LockedState<[ClassifierOptions]>([])
    let images = LockedState<[ImagesOptions]>([])

    init(api: Api = .openAICompletions) throws {
        provider = "e2-forwarding-\(UUID())"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(provider)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auth = AuthStorage.inMemory([provider: .apiKey(.init(key: "host-key"))])
        let defaults = identities
        registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryCodingAgentModelsStore(),
            networkEnabled: false, clientIdentityProvider: { defaults.withLock { $0 } })
        let chats = chats, classifiers = classifiers, images = images
        registry.registerProvider(HookProviderConfig(provider: provider, api: api, baseUrl: "https://e2.invalid",
            streamSimple: { model, _, options in
                chats.withLock { $0.append(options ?? .init()) }
                return e2ForwardingStream(model)
            }, images: [.openrouterImages: { model, _, options in
                images.withLock { $0.append(options ?? .init()) }
                return AssistantImages(api: model.api, provider: model.provider, model: model.id, stopReason: .stop)
            }], classifiers: [.typesafeSystemOne: { model, _, options in
                classifiers.withLock { $0.append(options ?? .init()) }
                return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                    answers: [:], stopReason: .stop)
            }], models: [.chat(.init(id: "chat")), .image(.init(id: "image", api: .openrouterImages)),
                .classifier(.init(id: "classifier", api: .typesafeSystemOne, contextWindow: 512))]), sourceId: provider)
    }

    func remove() {
        registry.unregisterProviders(sourceId: provider)
        try? FileManager.default.removeItem(at: directory)
    }
}

private func e2ForwardingStream(_ model: Model) -> AssistantMessageEventStream {
    let message = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Suite("E2 host model forwarding", .serialized, .timeLimit(.minutes(1)))
struct E2ModelForwardingTests {
    @Test(arguments: [true, false])
    func e2OpenDurableUsesSDKIdentityFromInstallTelemetrySettings(enabled: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e2-runtime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cwd = directory.appendingPathComponent("project")
        let agent = directory.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let settings = """
        {"enableInstallTelemetry":\(enabled),"retry":{"enabled":false},"compaction":{"enabled":false}}
        """
        try Data(settings.utf8).write(to: agent.appendingPathComponent("settings.json"))
        let requests = LockedState<[SimpleStreamOptions]>([])
        let models = FakeDurableModels(responses: [.factory { _, options, _, model in
            requests.withLock { $0.append(options ?? .init()) }
            return AssistantMessage(content: [.text(.init(text: "SDK identity response"))], api: model.api,
                provider: model.provider, model: model.id,
                usage: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        }])
        let result = try await openDurable(.init(cwd: cwd.path), dependencies: OpenDurableDependencies(
            agentDirectory: agent.path, makeModels: { _ in
                DurableRuntimeModels(models: models, available: models.models, initial: { _ in
                    .init(model: .init(provider: "faux", modelId: "faux-1"))
                })
            }))
        do {
            #expect(result.settings.getInstallTelemetryEnabled() == enabled)
            await result.controller.submit("Check SDK identity", whenBusy: .followUp)
            try await eventually { requests.withLock { !$0.isEmpty } }
            let sent = try #require(requests.withLock { $0.first })
            #expect(sent.identity == getCodingAgentClientIdentity(result.settings))
            #expect(sent.identity?.userAgent == .detailed)
            #expect(sent.identity?.version == VERSION)
            #expect(sent.identity?.attribution == (enabled ? .value(PI_ATTRIBUTION) : .disabled))
        } catch {
            await result.close()
            throw error
        }
        await result.close()
    }

    @Test func e2RegistryClassifierAndImagesForwardIdentityTelemetryAndSignal() async throws {
        let fixture = try E2ForwardingFixture()
        defer { fixture.remove() }
        let models = await RegistryCodemodeModels.create(registry: fixture.registry)
        let classifierValue = try #require(models.getModelOfType(.classifier, provider: fixture.provider, id: "classifier"))
        let imageValue = try #require(models.getModelOfType(.image, provider: fixture.provider, id: "image"))
        guard case .classifier(let classifier) = classifierValue, case .image(let image) = imageValue else {
            Issue.record("Expected classifier and image models")
            return
        }
        let operationSpan = E2ForwardingSpan(), requestSpan = E2ForwardingSpan()
        let operation = ChordContext.background.withTelemetry(operationSpan).withCancel()
        let classifierContext = ClassifierContext(state: [:], questions: [:])
        // The original signatures must forward operation telemetry and registry identity.
        _ = try await models.classify(model: classifier, context: classifierContext, operation: operation.context)
        _ = try await models.generateImages(model: image, context: .init(input: []), operation: operation.context)
        let defaultClassifier = try #require(fixture.classifiers.withLock { $0.last })
        let defaultImage = try #require(fixture.images.withLock { $0.last })
        #expect(defaultClassifier.identity == models.clientIdentity && defaultImage.identity == models.clientIdentity)
        #expect(defaultClassifier.telemetry === operationSpan && defaultImage.telemetry === operationSpan)

        let request = ClientIdentity(userAgent: .custom("codemode-agent"), attribution: .disabled)
        let token = CancellationToken()
        _ = try await models.classify(model: classifier, context: classifierContext,
            options: .init(signal: token, telemetry: requestSpan, identity: request), operation: operation.context)
        _ = try await models.generateImages(model: image, context: .init(input: []),
            options: .init(signal: token, telemetry: requestSpan, identity: request), operation: operation.context)
        let sentClassifier = try #require(fixture.classifiers.withLock { $0.last })
        let sentImage = try #require(fixture.images.withLock { $0.last })
        let expected = mergeClientIdentity(models.clientIdentity, request)
        #expect(sentClassifier.identity == expected && sentImage.identity == expected)
        #expect(sentClassifier.telemetry === requestSpan && sentImage.telemetry === requestSpan)
        #expect(sentClassifier.signal === token && sentImage.signal === token)
        #expect(sentClassifier.apiKey == "host-key" && sentImage.apiKey == "host-key")
        // Completion removes both listeners; later context cancellation must not cancel the caller token.
        operation.cancel()
        #expect(!token.isCancelled)
        fixture.identities.withLock { $0.version = "changed-version" }
        #expect(models.clientIdentity?.version == "changed-version")
        let cancelled = ChordContext.background.withCancel()
        cancelled.cancel()
        let cancelledToken = CancellationToken()
        let classified = try await models.classify(model: classifier, context: classifierContext,
            options: .init(signal: cancelledToken), operation: cancelled.context)
        let generated = try await models.generateImages(model: image, context: .init(input: []),
            options: .init(signal: cancelledToken), operation: cancelled.context)
        #expect(cancelledToken.isCancelled)
        #expect(classified.stopReason == .aborted && generated.stopReason == .aborted)
    }

    @Test func e2RegistryChatForwardsRequestIdentityAndTelemetry() async throws {
        let fixture = try E2ForwardingFixture()
        defer { fixture.remove() }
        let models = await RegistryCodemodeModels.create(registry: fixture.registry)
        let model = try #require(models.getModel(provider: fixture.provider, modelId: "chat"))
        let span = E2ForwardingSpan()
        for request: ClientIdentity? in [nil, .init(userAgent: .custom("request-agent"), attribution: .disabled)] {
            let result = await models.completeSimple(model: model, context: .init(messages: []),
                options: .init(telemetry: span, identity: request))
            #expect(result.stopReason == .stop)
            let sent = try #require(fixture.chats.withLock { $0.last })
            #expect(sent.identity == mergeClientIdentity(fixture.identities.withLock { $0 }, request))
            #expect(sent.telemetry === span)
            #expect(sent.apiKey == "host-key")
        }
        fixture.identities.withLock { $0.version = "changed-version" }
        _ = await models.streamSimple(model: model, context: .init(messages: []), options: .init(telemetry: span)).result()
        #expect(fixture.chats.withLock { $0.last?.identity?.version } == "changed-version")
        #expect(fixture.chats.withLock { $0.last?.telemetry } === span)
    }

    @Test func e2RegistryDeferredForwardsRequestIdentityAndTelemetry() async throws {
        let fixture = try E2ForwardingFixture(api: .azureOpenAIResponses)
        defer { fixture.remove() }
        let models = await RegistryCodemodeModels.create(registry: fixture.registry)
        let model = try #require(models.getModel(provider: fixture.provider, modelId: "chat"))
        // Keep normal Azure dispatch intact. Only this test's provider uses the deferred callbacks.
        // Azure has no built-in deferred handler. This initializes the built-ins without a request.
        _ = try? PiSwiftAI.streamDeferred(model: model, handle: DeferredHandle(provider: model.provider,
            modelId: model.id, api: model.api.rawValue, id: "initialize"))
        let original = try #require(getApiProvider(.azureOpenAIResponses))
        let fetches = LockedState<[DeferredFetchOptions]>([])
        let cancels = LockedState<[DeferredCancelOptions]>([])
        registerApiProvider(ApiProvider(api: .azureOpenAIResponses, stream: original.stream,
            streamSimple: original.streamSimple, fetchDeferred: { requestModel, handle, options in
                guard requestModel.provider == model.provider else {
                    return original.fetchDeferred?(requestModel, handle, options) ?? e2ForwardingStream(requestModel)
                }
                fetches.withLock { $0.append(options ?? .init()) }
                return e2ForwardingStream(requestModel)
            }, cancelDeferred: { requestModel, handle, options in
                guard requestModel.provider == model.provider else {
                    try await original.cancelDeferred?(requestModel, handle, options)
                    return
                }
                cancels.withLock { $0.append(options ?? .init()) }
            }))
        defer { registerApiProvider(original) }
        let span = E2ForwardingSpan()
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "response")
        for request: ClientIdentity? in [nil, .init(userAgent: .custom("deferred-agent"), attribution: .disabled)] {
            let result = await models.fetchDeferred(model: model, handle: handle,
                options: .init(telemetry: span, identity: request))
            #expect(result.stopReason == .stop)
            try await models.cancelDeferred(model: model, handle: handle,
                options: .init(telemetry: span, identity: request))
            let fetched = try #require(fetches.withLock { $0.last })
            let cancelled = try #require(cancels.withLock { $0.last })
            let expected = mergeClientIdentity(fixture.identities.withLock { $0 }, request)
            #expect(fetched.identity == expected && cancelled.identity == expected)
            #expect(fetched.telemetry === span && cancelled.telemetry === span)
            #expect(fetched.apiKey == "host-key" && cancelled.apiKey == "host-key")
        }
    }
}
