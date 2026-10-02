import Foundation

public typealias ImageApiFunction = @Sendable (ImageModel, ImagesContext, ImagesOptions?) async -> AssistantImages

public struct ImageApiProvider: Sendable {
    public let api: ImageApi
    public let generateImages: ImageApiFunction

    public init(api: ImageApi, generateImages: @escaping ImageApiFunction) {
        self.api = api
        self.generateImages = generateImages
    }
}

private struct RegisteredImageApiProvider: Sendable {
    let provider: ImageApiProvider
    let sourceId: String?
}

/// SAFETY: all mutable provider storage is accessed only while holding `lock`;
/// registered providers and source identifiers are value-typed `Sendable`.
public final class ImageApiProviderRegistry: @unchecked Sendable {
    public static let shared = ImageApiProviderRegistry()

    private let lock = NSLock()
    private var providers: [ImageApi: RegisteredImageApiProvider] = [:]

    private init() {}

    public func register(_ provider: ImageApiProvider, sourceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.api] = RegisteredImageApiProvider(provider: provider, sourceId: sourceId)
    }

    public func get(_ api: ImageApi) -> ImageApiProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[api]?.provider
    }

    public func all() -> [ImageApiProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providers.values.map { $0.provider }
    }

    public func unregister(sourceId: String) {
        lock.lock()
        defer { lock.unlock() }
        providers = providers.filter { $0.value.sourceId != sourceId }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        providers.removeAll()
    }

    public func has(_ api: ImageApi) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers[api] != nil
    }
}

public func registerImageApiProvider(_ provider: ImageApiProvider, sourceId: String? = nil) {
    ImageApiProviderRegistry.shared.register(provider, sourceId: sourceId)
}

public func getImageApiProvider(_ api: ImageApi) -> ImageApiProvider? {
    ImageApiProviderRegistry.shared.get(api)
}

public func getImageApiProviders() -> [ImageApiProvider] {
    ImageApiProviderRegistry.shared.all()
}

public func unregisterImageApiProviders(sourceId: String) {
    ImageApiProviderRegistry.shared.unregister(sourceId: sourceId)
}

public func clearImageApiProviders() {
    ImageApiProviderRegistry.shared.clear()
}

public func registerBuiltInImageApiProviders() {
    registerImageApiProvider(ImageApiProvider(
        api: .openrouterImages,
        generateImages: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider, env: options?.env) ?? ""
            var providerOptions = options ?? ImagesOptions()
            providerOptions.apiKey = apiKey
            return await generateImagesOpenRouter(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")
}

private let builtInImageProvidersRegistered: Bool = {
    registerBuiltInImageApiProviders()
    return true
}()

func ensureBuiltInImageProviders() {
    _ = builtInImageProvidersRegistered
}

public func generateImages(model: ImageModel, context: ImagesContext, options: ImagesOptions? = nil) async -> AssistantImages {
    ensureBuiltInImageProviders()
    return await generateImages(model: model, context: context, options: options, provider: getImageApiProvider)
}

/// Dispatch with an explicit provider lookup, so tests need not change the shared registry.
func generateImages(
    model: ImageModel, context: ImagesContext, options: ImagesOptions?,
    provider lookup: (ImageApi) -> ImageApiProvider?
) async -> AssistantImages {
    guard let provider = lookup(model.api) else {
        return AssistantImages(
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .error,
            errorMessage: "No API provider registered for api: \(model.api.rawValue)"
        )
    }
    return await provider.generateImages(model, context, options)
}
