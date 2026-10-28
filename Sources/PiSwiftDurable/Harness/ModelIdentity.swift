import PiSwiftAI
import PiSwiftChord

/// The default provider attribution for Harness model requests.
public let DEFAULT_HARNESS_IDENTITY = ClientIdentity(attribution: .value(PI_ATTRIBUTION))

/// Returns the current model service. The Harness reports a thrown host error.
public typealias HarnessModelsProvider = @Sendable () throws -> any DurableModels

/// Adds the Harness identity and retains the model service's capabilities.
internal func harnessModels(_ models: any DurableModels, identity: ClientIdentity?) -> any DurableModels {
    if let models = models as? any CodemodeModels {
        return IdentityCodemodeModels(models: models, identity: identity)
    }
    return IdentityDurableModels(models: models, identity: identity)
}

internal final class IdentityDurableModels: DurableModels {
    let models: any DurableModels
    let identity: ClientIdentity?

    init(models: any DurableModels, identity: ClientIdentity?) {
        self.models = models; self.identity = identity
    }

    var clientIdentity: ClientIdentity? {
        mergeClientIdentity(DEFAULT_HARNESS_IDENTITY, models.clientIdentity, identity)
    }

    func getModel(provider: String, modelId: String) -> Model? {
        models.getModel(provider: provider, modelId: modelId)
    }

    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        models.streamSimple(model: model, context: context, options: withClientIdentity(options, clientIdentity))
    }

    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await models.completeSimple(model: model, context: context, options: withClientIdentity(options, clientIdentity))
    }

    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await models.fetchDeferred(model: model, handle: handle, options: withClientIdentity(options, clientIdentity))
    }

    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await models.cancelDeferred(model: model, handle: handle, options: withClientIdentity(options, clientIdentity))
    }
}

private final class IdentityCodemodeModels: CodemodeModels {
    private let durable: IdentityDurableModels
    private let codemode: any CodemodeModels

    init(models: any CodemodeModels, identity: ClientIdentity?) {
        codemode = models
        durable = IdentityDurableModels(models: models, identity: identity)
    }

    var clientIdentity: ClientIdentity? { durable.clientIdentity }

    func getModel(provider: String, modelId: String) -> Model? {
        durable.getModel(provider: provider, modelId: modelId)
    }

    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        durable.streamSimple(model: model, context: context, options: options)
    }

    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await durable.completeSimple(model: model, context: context, options: options)
    }

    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await durable.fetchDeferred(model: model, handle: handle, options: options)
    }

    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await durable.cancelDeferred(model: model, handle: handle, options: options)
    }

    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        codemode.getModelsOfType(type, provider: provider)
    }

    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel] {
        try await codemode.getAvailableOfType(type, provider: provider, context: context)
    }

    func getModelOfType(_ type: ModelType, provider: String, id: String) -> AnyModel? {
        codemode.getModelOfType(type, provider: provider, id: id)
    }

    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult {
        try await classify(model: model, context: context, options: .init(), operation: operation)
    }

    func classify(model: ClassifierModel, context: ClassifierContext, options: ClassifierOptions, operation: ChordContext) async throws -> ClassifierResult {
        try await codemode.classify(model: model, context: context, options: withClientIdentity(options, clientIdentity), operation: operation)
    }

    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages {
        try await generateImages(model: model, context: context, options: .init(), operation: operation)
    }

    func generateImages(model: ImageModel, context: ImagesContext, options: ImagesOptions, operation: ChordContext) async throws -> AssistantImages {
        try await codemode.generateImages(model: model, context: context, options: withClientIdentity(options, clientIdentity), operation: operation)
    }
}

/// A failed provider access cannot start an AI request.
internal struct UnavailableDurableModels: CodemodeModels {
    let error: any Error

    func getModel(provider: String, modelId: String) -> Model? { nil }
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] { [] }
    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel] { throw error }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let stream = AssistantMessageEventStream()
        stream.push(.error(reason: .error, error: failure(model)))
        return stream
    }
    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage { failure(model) }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage { failure(model) }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws { throw error }
    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult { throw error }
    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages { throw error }
    private func failure(_ model: Model) -> AssistantMessage {
        AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error, errorMessage: String(describing: error))
    }
}
