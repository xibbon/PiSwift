import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable

/// Uses the host registry for durable chat and codemode model requests.
public final class RegistryCodemodeModels: CodemodeModels {
    private let registry: ModelRegistry
    private let durable: RegistryDurableModels

    private init(registry: ModelRegistry, durable: RegistryDurableModels) {
        self.registry = registry
        self.durable = durable
    }

    /// Restores cached catalogs without a network refresh and records available chat models.
    public static func create(registry: ModelRegistry) async -> RegistryCodemodeModels {
        let durable = await RegistryDurableModels.create(registry: registry)
        return RegistryCodemodeModels(registry: registry, durable: durable)
    }

    /// Refreshes the registry and the available chat model snapshot.
    @discardableResult
    public func refresh(_ options: ModelsRefreshOptions = .init()) async -> ModelsRefreshResult {
        await durable.refresh(options)
    }

    /// Returns the last available chat model snapshot.
    public func getAvailableSnapshot() -> [Model] {
        durable.getAvailableSnapshot()
    }

    /// Finds a chat model by its exact provider and model ID.
    public func getModel(provider: String, modelId: String) -> Model? {
        durable.getModel(provider: provider, modelId: modelId)
    }

    /// Starts a chat request with credentials from the host registry.
    public func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        durable.streamSimple(model: model, context: context, options: options)
    }

    /// Returns a complete chat response with credentials from the host registry.
    public func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await durable.completeSimple(model: model, context: context, options: options)
    }

    /// Polls a deferred response with current host credentials.
    public func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await durable.fetchDeferred(model: model, handle: handle, options: options)
    }

    /// Cancels a deferred response with current host credentials.
    public func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await durable.cancelDeferred(model: model, handle: handle, options: options)
    }

    /// Returns catalog models with an exact provider match, when supplied.
    public func getModelsOfType(_ type: ModelType, provider: String? = nil) -> [AnyModel] {
        registry.getModelsOfType(type).filter { model in
            provider.map { model.provider.utf16.elementsEqual($0.utf16) } ?? true
        }
    }

    /// Returns models with configured host authentication.
    public func getAvailableOfType(_ type: ModelType, provider: String? = nil, context: ChordContext) async throws -> [AnyModel] {
        try Task.checkCancellation()
        try context.abortSignal?.throwIfAborted()
        let models = await registry.getAvailableOfType(type)
        try Task.checkCancellation()
        try context.abortSignal?.throwIfAborted()
        return models.filter { model in
            provider.map { model.provider.utf16.elementsEqual($0.utf16) } ?? true
        }
    }

    /// Finds a catalog model by its exact type, provider, and ID.
    public func getModelOfType(_ type: ModelType, provider: String, id: String) -> AnyModel? {
        getModelsOfType(type, provider: provider).first { $0.id.utf16.elementsEqual(id.utf16) }
    }

    /// Runs a classifier with host credentials and operation cancellation.
    public func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult {
        await withContextCancellation(operation) { token in
            await registry.classify(model, context: context, options: ClassifierOptions(signal: token))
        }
    }

    /// Generates images with host credentials and operation cancellation.
    public func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages {
        await withContextCancellation(operation) { token in
            await registry.generateImages(model, context: context, options: ImagesOptions(signal: token))
        }
    }
}
