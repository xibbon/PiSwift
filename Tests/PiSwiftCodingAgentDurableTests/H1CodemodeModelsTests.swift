import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurableTesting
import Testing

private struct H1ModelsFixture: Sendable {
    let directory: URL
    let auth: AuthStorage
    let registry: ModelRegistry
    let provider = "h1-models-é"
    let modelID = "Exact-é"
    let classifiers = LockedState<[ClassifierOptions]>([])
    let images = LockedState<[ImagesOptions]>([])
    let chats = LockedState<[SimpleStreamOptions]>([])
    let started = HarnessChatSignal()

    init(configured: Bool = true, hold: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("h1-models-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        auth = AuthStorage.inMemory()
        registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        if configured {
            auth.set(provider, credential: .apiKey(ApiKeyCredential(key: "host-key", env: ["ACCOUNT": "host-account"])))
        }
        let classifierRequests = classifiers, imageRequests = images, chatRequests = chats, reached = started
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions, baseUrl: "https://h1.invalid",
            authHeader: true, headers: configured ? ["X-Provider": "host", "X-Account": "${ACCOUNT}"] : nil,
            streamSimple: { model, _, options in
                chatRequests.withLock { $0.append(options ?? .init()) }
                let stream = AssistantMessageEventStream()
                stream.end(AssistantMessage(content: [.text(.init(text: "chat result"))], api: model.api,
                    provider: model.provider, model: model.id,
                    usage: Usage(input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3), stopReason: .stop))
                return stream
            }, images: [.openrouterImages: { model, _, options in
                imageRequests.withLock { $0.append(options ?? .init()) }
                if hold { await h1WaitForCancellation(options?.signal, started: reached) }
                return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                    responseId: "image-response", output: [.image(.init(data: "aW1hZ2U=", mimeType: "image/png"))],
                    usage: Usage(input: 2, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 5),
                    stopReason: options?.signal?.isCancelled == true ? .aborted : .stop,
                    errorMessage: options?.signal?.isCancelled == true ? "image cancelled" : nil, timestamp: 42)
            }], classifiers: [.typesafeSystemOne: { model, _, options in
                classifierRequests.withLock { $0.append(options ?? .init()) }
                if hold { await h1WaitForCancellation(options?.signal, started: reached) }
                return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                    answers: ["ok": .bool(probability: 0.75)],
                    usage: Usage(input: 3, output: 4, cacheRead: 0, cacheWrite: 0, totalTokens: 7),
                    stopReason: options?.signal?.isCancelled == true ? .aborted : .stop,
                    errorMessage: options?.signal?.isCancelled == true ? "classifier cancelled" : nil, timestamp: 43)
            }], models: [
                .chat(HookProviderModel(id: modelID)),
                .image(HookProviderImageModel(id: modelID, api: .openrouterImages,
                    headers: configured ? ["X-Operation": "image"] : nil)),
                .classifier(HookProviderClassifierModel(id: modelID, api: .typesafeSystemOne,
                    contextWindow: 512, headers: configured ? ["X-Operation": "classifier"] : nil))
            ]), sourceId: "h1-models")
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func classifier() throws -> ClassifierModel {
        let value = try #require(registry.getModelOfType(.classifier, provider: provider, modelId: modelID))
        guard case .classifier(let model) = value else { throw H1ModelsError.wrongType }
        return model
    }

    func image() throws -> ImageModel {
        let value = try #require(registry.getModelOfType(.image, provider: provider, modelId: modelID))
        guard case .image(let model) = value else { throw H1ModelsError.wrongType }
        return model
    }
}

private enum H1ModelsError: Error { case wrongType }

private func h1WaitForCancellation(_ token: CancellationToken?, started: HarnessChatSignal) async {
    guard let token else { Issue.record("Expected a model cancellation token"); return }
    let cancelled = HarnessChatSignal()
    let remove = token.onCancel { cancelled.signal() }
    defer { remove() }
    started.signal()
    await cancelled.wait()
}

private let h1ClassifierContext = ClassifierContext(state: [:], questions: [
    "ok": .bool(instructions: "Check the input", trueCriterion: "Accept", falseCriterion: "Reject")
])

@Test func h1CodemodeModelsCatalogUsesExactIdentityAndCurrentAvailability() async throws {
    let fixture = try H1ModelsFixture(configured: false)
    defer { fixture.remove() }
    let models = await RegistryCodemodeModels.create(registry: fixture.registry)
    for type in ModelType.allCases {
        #expect(models.getModelsOfType(type, provider: fixture.provider).map(\.id) == [fixture.modelID])
        #expect(models.getModelOfType(type, provider: fixture.provider, id: fixture.modelID)?.type == type)
        #expect(models.getModelOfType(type, provider: fixture.provider.uppercased(), id: fixture.modelID) == nil)
        #expect(models.getModelOfType(type, provider: fixture.provider, id: "Exact-e\u{301}") == nil)
        #expect(models.getModelsOfType(type, provider: "h1-models-e\u{301}").isEmpty)
        #expect(try await models.getAvailableOfType(type, provider: fixture.provider, context: .background).isEmpty)
    }
    #expect(!models.getAvailableSnapshot().contains { $0.provider == fixture.provider })
    fixture.auth.set(fixture.provider, credential: .apiKey(ApiKeyCredential(key: "late-key")))
    for type in ModelType.allCases {
        #expect(try await models.getAvailableOfType(type, provider: fixture.provider, context: .background).map(\.id) == [fixture.modelID])
        #expect(try await models.getAvailableOfType(type, provider: "h1-models-e\u{301}", context: .background).isEmpty)
    }
    _ = await models.refresh(ModelsRefreshOptions(allowNetwork: false))
    #expect(models.getAvailableSnapshot().contains { $0.provider == fixture.provider && $0.id == fixture.modelID })
    let cancelled = ChordContext.background.withCancel()
    cancelled.cancel()
    await #expect(throws: AbortError.self) {
        try await models.getAvailableOfType(.classifier, provider: fixture.provider, context: cancelled.context)
    }
}

@Test func h1CodemodeModelsUseHostCredentialsAndPreserveResults() async throws {
    let fixture = try H1ModelsFixture()
    defer { fixture.remove() }
    let models = await RegistryCodemodeModels.create(registry: fixture.registry)
    let classifier = try fixture.classifier(), image = try fixture.image()
    for key in ["host-key", "changed-key"] {
        fixture.auth.set(fixture.provider, credential: .apiKey(ApiKeyCredential(key: key, env: ["ACCOUNT": key])))
        let classification = try await models.classify(model: classifier, context: h1ClassifierContext, operation: .background)
        #expect(classification.stopReason == .stop && classification.timestamp == 43)
        #expect(classification.usage?.totalTokens == 7)
        guard case .bool(let probability)? = classification.answers["ok"] else {
            Issue.record("Expected the classifier answer"); return
        }
        #expect(probability == 0.75)
        let generated = try await models.generateImages(model: image, context: .init(input: [.text(.init(text: "Draw"))]), operation: .background)
        #expect(generated.stopReason == .stop && generated.timestamp == 42 && generated.responseId == "image-response")
        #expect(generated.output.count == 1 && generated.usage?.totalTokens == 5)
        let classified = try #require(fixture.classifiers.withLock { $0.last })
        let imaged = try #require(fixture.images.withLock { $0.last })
        #expect(classified.apiKey == key && imaged.apiKey == key)
        #expect(classified.env?["ACCOUNT"] == key && imaged.env?["ACCOUNT"] == key)
        #expect(providerHeaderValue(classified.headers, name: "X-Account") == key)
        #expect(providerHeaderValue(imaged.headers, name: "X-Account") == key)
        #expect(providerHeaderValue(classified.headers, name: "X-Operation") == "classifier")
        #expect(providerHeaderValue(imaged.headers, name: "X-Operation") == "image")
        #expect(providerHeaderValue(classified.headers, name: "X-Provider") == "host")
        #expect(providerHeaderValue(imaged.headers, name: "X-Provider") == "host")
    }
    // The bridge must remove its listener when a completed request returns.
    let operation = ChordContext.background.withCancel()
    _ = try await models.classify(model: classifier, context: h1ClassifierContext, operation: operation.context)
    _ = try await models.generateImages(model: image, context: .init(input: []), operation: operation.context)
    operation.cancel()
    #expect(fixture.classifiers.withLock { $0.last?.signal?.isCancelled } == false)
    #expect(fixture.images.withLock { $0.last?.signal?.isCancelled } == false)
}

@Test func h1CodemodeModelsMissingAuthReturnsRegistryErrorText() async throws {
    let fixture = try H1ModelsFixture(configured: false)
    defer { fixture.remove() }
    let models = await RegistryCodemodeModels.create(registry: fixture.registry)
    let classifier = try fixture.classifier(), image = try fixture.image()
    let classifierAuth = await fixture.registry.resolveModelRequest(classifier)
    let imageAuth = await fixture.registry.resolveModelRequest(image)
    #expect(!classifierAuth.auth.ok && !imageAuth.auth.ok)
    #expect(classifierAuth.auth.error?.isEmpty == false && imageAuth.auth.error?.isEmpty == false)
    let classified = try await models.classify(model: classifier, context: h1ClassifierContext, operation: .background)
    let generated = try await models.generateImages(model: image, context: .init(input: []), operation: .background)
    #expect(classified.stopReason == .error && classified.errorMessage == classifierAuth.auth.error)
    #expect(generated.stopReason == .error && generated.errorMessage == imageAuth.auth.error)
    #expect(fixture.classifiers.withLock { $0.isEmpty } && fixture.images.withLock { $0.isEmpty })
}

@Test(.timeLimit(.minutes(1)), arguments: [ModelType.classifier, .image], [false, true])
func h1CodemodeModelsBridgeOperationCancellation(type: ModelType, preCancelled: Bool) async throws {
    let fixture = try H1ModelsFixture(hold: true)
    defer { fixture.remove() }
    let models = await RegistryCodemodeModels.create(registry: fixture.registry)
    let operation = ChordContext.background.withCancel()
    if preCancelled {
        operation.cancel()
        if type == .classifier {
            let result = try await models.classify(model: fixture.classifier(), context: h1ClassifierContext, operation: operation.context)
            #expect(result.stopReason == .aborted && result.errorMessage == "Authentication cancelled")
        } else {
            let result = try await models.generateImages(model: fixture.image(), context: .init(input: []), operation: operation.context)
            #expect(result.stopReason == .aborted && result.errorMessage == "Authentication cancelled")
        }
        #expect(fixture.classifiers.withLock { $0.isEmpty } && fixture.images.withLock { $0.isEmpty })
        return
    }
    let request = Task { () throws -> String? in
        if type == .classifier {
            let result = try await models.classify(model: fixture.classifier(), context: h1ClassifierContext, operation: operation.context)
            #expect(result.stopReason == .aborted && result.timestamp == 43)
            return result.errorMessage
        }
        let result = try await models.generateImages(model: fixture.image(), context: .init(input: []), operation: operation.context)
        #expect(result.stopReason == .aborted && result.timestamp == 42)
        return result.errorMessage
    }
    await fixture.started.wait()
    operation.cancel()
    #expect(try await request.value == (type == .classifier ? "classifier cancelled" : "image cancelled"))
}

@Test func h1CodemodeModelsForwardDurableChatAndDeferredSetup() async throws {
    let fixture = try H1ModelsFixture()
    defer { fixture.remove() }
    let models = await RegistryCodemodeModels.create(registry: fixture.registry)
    let model = try #require(models.getModel(provider: fixture.provider, modelId: fixture.modelID))
    #expect(models.getModel(provider: "h1-models-e\u{301}", modelId: fixture.modelID) == nil)
    let stream = models.streamSimple(model: model, context: .init(messages: []), options: .init())
    #expect(await stream.result().stopReason == .stop)
    #expect(await models.completeSimple(model: model, context: .init(messages: []), options: .init()).stopReason == .stop)
    #expect(fixture.chats.withLock { $0.count == 2 && $0.allSatisfy { $0.apiKey == "host-key" } })
    let token = CancellationToken()
    token.cancel()
    let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue, id: "unused")
    let failed = await models.fetchDeferred(model: model, handle: handle, options: .init(signal: token))
    #expect(failed.stopReason == .error && failed.errorMessage == "Request was aborted")
    await #expect(throws: (any Error).self) {
        try await models.cancelDeferred(model: model, handle: handle, options: .init(signal: token))
    }
}
