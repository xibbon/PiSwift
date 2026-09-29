import Foundation

public typealias ClassifierFunction = @Sendable (ClassifierModel, ClassifierContext, ClassifierOptions?) async -> ClassifierResult

public struct ClassifierApiProvider: Sendable {
    public let api: ClassifierApi
    public let classify: ClassifierFunction

    public init(api: ClassifierApi, classify: @escaping ClassifierFunction) {
        self.api = api
        self.classify = classify
    }
}

private struct RegisteredClassifierProvider: Sendable {
    let provider: ClassifierApiProvider
    let sourceId: String?
}

public final class ClassifierApiProviderRegistry: Sendable {
    public static let shared = ClassifierApiProviderRegistry()
    private let providers = LockedState<[ClassifierApi: RegisteredClassifierProvider]>([:])

    private init() {}

    public func register(_ provider: ClassifierApiProvider, sourceId: String? = nil) {
        providers.withLock { $0[provider.api] = RegisteredClassifierProvider(provider: provider, sourceId: sourceId) }
    }
    public func get(_ api: ClassifierApi) -> ClassifierApiProvider? {
        providers.withLock { $0[api]?.provider }
    }
    public func all() -> [ClassifierApiProvider] {
        providers.withLock { $0.values.map(\.provider) }
    }
    public func unregister(sourceId: String) {
        providers.withLock { $0 = $0.filter { $0.value.sourceId != sourceId } }
    }
    public func clear() { providers.withLock { $0.removeAll() } }
    public func has(_ api: ClassifierApi) -> Bool { get(api) != nil }
}

public func registerClassifierApiProvider(_ provider: ClassifierApiProvider, sourceId: String? = nil) {
    ClassifierApiProviderRegistry.shared.register(provider, sourceId: sourceId)
}
public func getClassifierApiProvider(_ api: ClassifierApi) -> ClassifierApiProvider? {
    ClassifierApiProviderRegistry.shared.get(api)
}
public func getClassifierApiProviders() -> [ClassifierApiProvider] {
    ClassifierApiProviderRegistry.shared.all()
}
public func unregisterClassifierApiProviders(sourceId: String) {
    ClassifierApiProviderRegistry.shared.unregister(sourceId: sourceId)
}
public func clearClassifierApiProviders() { ClassifierApiProviderRegistry.shared.clear() }

public func registerBuiltInClassifierApiProviders() {
    registerClassifierApiProvider(ClassifierApiProvider(api: .typesafeSystemOne, classify: { model, context, options in
        var requestOptions = options ?? ClassifierOptions()
        requestOptions.apiKey = requestOptions.apiKey ?? getEnvApiKey(provider: model.provider)
        return await classifyTypeSafeSystemOne(model: model, context: context, options: requestOptions)
    }), sourceId: "built-in")
    registerClassifierApiProvider(ClassifierApiProvider(api: .cloudflareWorkersAISystemOne, classify: { model, context, options in
        var requestOptions = options ?? ClassifierOptions()
        requestOptions.apiKey = requestOptions.apiKey ?? getEnvApiKey(provider: model.provider)
        return await classifyCloudflareWorkersAISystemOne(model: model, context: context, options: requestOptions)
    }), sourceId: "built-in")
}

private let builtInClassifierProvidersRegistered: Bool = {
    registerBuiltInClassifierApiProviders()
    return true
}()

public func classify(model: ClassifierModel, context: ClassifierContext,
                     options: ClassifierOptions? = nil) async -> ClassifierResult {
    _ = builtInClassifierProvidersRegistered
    guard let provider = getClassifierApiProvider(model.api) else {
        return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                                stopReason: .error,
                                errorMessage: "No classifier API provider registered for api: \(model.api.rawValue)")
    }
    return await provider.classify(model, context, options)
}
