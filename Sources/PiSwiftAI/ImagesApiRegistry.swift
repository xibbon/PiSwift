import Foundation

public typealias ImagesApiFunction = @Sendable (ImagesModel, ImagesContext, ImagesOptions?) async -> AssistantImages

public struct ImagesApiProvider: Sendable {
    public let api: ImagesApi
    public let generateImages: ImagesApiFunction

    public init(api: ImagesApi, generateImages: @escaping ImagesApiFunction) {
        self.api = api
        self.generateImages = generateImages
    }
}

private struct RegisteredImagesApiProvider: Sendable {
    let provider: ImagesApiProvider
    let sourceId: String?
}

public final class ImagesApiProviderRegistry: @unchecked Sendable {
    public static let shared = ImagesApiProviderRegistry()

    private let lock = NSLock()
    private var providers: [ImagesApi: RegisteredImagesApiProvider] = [:]

    private init() {}

    public func register(_ provider: ImagesApiProvider, sourceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.api] = RegisteredImagesApiProvider(provider: provider, sourceId: sourceId)
    }

    public func get(_ api: ImagesApi) -> ImagesApiProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[api]?.provider
    }

    public func all() -> [ImagesApiProvider] {
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

    public func has(_ api: ImagesApi) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers[api] != nil
    }
}

public func registerImagesApiProvider(_ provider: ImagesApiProvider, sourceId: String? = nil) {
    ImagesApiProviderRegistry.shared.register(provider, sourceId: sourceId)
}

public func getImagesApiProvider(_ api: ImagesApi) -> ImagesApiProvider? {
    ImagesApiProviderRegistry.shared.get(api)
}

public func getImagesApiProviders() -> [ImagesApiProvider] {
    ImagesApiProviderRegistry.shared.all()
}

public func unregisterImagesApiProviders(sourceId: String) {
    ImagesApiProviderRegistry.shared.unregister(sourceId: sourceId)
}

public func clearImagesApiProviders() {
    ImagesApiProviderRegistry.shared.clear()
}

public func registerBuiltInImagesApiProviders() {
    registerImagesApiProvider(ImagesApiProvider(
        api: .openrouterImages,
        generateImages: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            var providerOptions = options ?? ImagesOptions()
            providerOptions.apiKey = apiKey
            return await generateImagesOpenRouter(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")
}

private let builtInImagesProvidersRegistered: Bool = {
    registerBuiltInImagesApiProviders()
    return true
}()

func ensureBuiltInImagesProviders() {
    _ = builtInImagesProvidersRegistered
}

public func generateImages(model: ImagesModel, context: ImagesContext, options: ImagesOptions? = nil) async -> AssistantImages {
    ensureBuiltInImagesProviders()
    guard let provider = getImagesApiProvider(model.api) else {
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

