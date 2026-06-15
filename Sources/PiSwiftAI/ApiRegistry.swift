import Foundation

/// Function type for streaming with full options.
public typealias ApiStreamFunction = @Sendable (Model, Context, StreamOptions?) -> AssistantMessageEventStream

/// Function type for streaming with simple options.
public typealias ApiStreamSimpleFunction = @Sendable (Model, Context, SimpleStreamOptions?) -> AssistantMessageEventStream

/// A registered API provider with stream functions.
public struct ApiProvider: Sendable {
    public let api: Api
    public let stream: ApiStreamFunction
    public let streamSimple: ApiStreamSimpleFunction

    public init(
        api: Api,
        stream: @escaping ApiStreamFunction,
        streamSimple: @escaping ApiStreamSimpleFunction
    ) {
        self.api = api
        self.stream = stream
        self.streamSimple = streamSimple
    }
}

/// Internal registration entry with optional source ID for grouping.
private struct RegisteredApiProvider: Sendable {
    let provider: ApiProvider
    let sourceId: String?
}

/// Thread-safe registry for API providers.
public final class ApiProviderRegistry: @unchecked Sendable {
    public static let shared = ApiProviderRegistry()

    private let lock = NSLock()
    private var providers: [Api: RegisteredApiProvider] = [:]

    private init() {}

    /// Register an API provider.
    /// - Parameters:
    ///   - provider: The provider to register
    ///   - sourceId: Optional identifier for grouping (used for unregistration)
    public func register(_ provider: ApiProvider, sourceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.api] = RegisteredApiProvider(provider: provider, sourceId: sourceId)
    }

    /// Get a provider by API type.
    public func get(_ api: Api) -> ApiProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[api]?.provider
    }

    /// Get all registered providers.
    public func all() -> [ApiProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providers.values.map { $0.provider }
    }

    /// Unregister all providers with the given source ID.
    public func unregister(sourceId: String) {
        lock.lock()
        defer { lock.unlock() }
        providers = providers.filter { $0.value.sourceId != sourceId }
    }

    /// Clear all registered providers.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        providers.removeAll()
    }

    /// Check if a provider is registered for the given API.
    public func has(_ api: Api) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return providers[api] != nil
    }
}

/// Register an API provider globally.
public func registerApiProvider(_ provider: ApiProvider, sourceId: String? = nil) {
    ApiProviderRegistry.shared.register(provider, sourceId: sourceId)
}

/// Get a provider by API type.
public func getApiProvider(_ api: Api) -> ApiProvider? {
    ApiProviderRegistry.shared.get(api)
}

/// Get all registered providers.
public func getApiProviders() -> [ApiProvider] {
    ApiProviderRegistry.shared.all()
}

/// Unregister all providers with the given source ID.
public func unregisterApiProviders(sourceId: String) {
    ApiProviderRegistry.shared.unregister(sourceId: sourceId)
}

/// Clear all registered providers.
public func clearApiProviders() {
    ApiProviderRegistry.shared.clear()
}

/// Register all built-in providers.
public func registerBuiltInProviders() {
    registerApiProvider(ApiProvider(
        api: .anthropicMessages,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = AnthropicOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                metadata: options?.metadata,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamAnthropic(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapAnthropicSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamAnthropic(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .openAICompletions,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = OpenAICompletionsOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamOpenAICompletions(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapOpenAICompletionsSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamOpenAICompletions(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .openAIResponses,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = OpenAIResponsesOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                cacheRetention: options?.cacheRetention,
                sessionId: options?.sessionId,
                transport: options?.transport,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamOpenAIResponses(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamOpenAIResponses(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .openAICodexResponses,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = OpenAICodexResponsesOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                sessionId: options?.sessionId,
                transport: options?.transport,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamOpenAICodexResponses(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapOpenAICodexResponsesSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamOpenAICodexResponses(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .azureOpenAIResponses,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = AzureOpenAIResponsesOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                sessionId: options?.sessionId,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamAzureOpenAIResponses(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapAzureOpenAIResponsesSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamAzureOpenAIResponses(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .googleGenerativeAI,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = GoogleOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamGoogle(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapGoogleSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamGoogle(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .googleVertex,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = GoogleVertexOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamGoogleVertex(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapGoogleVertexSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamGoogleVertex(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .mistralConversations,
        stream: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = MistralOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                apiKey: apiKey,
                sessionId: options?.sessionId,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamMistral(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider) ?? ""
            let providerOptions = mapMistralSimpleOptions(model: model, options: options, apiKey: apiKey)
            return streamMistral(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")

    registerApiProvider(ApiProvider(
        api: .bedrockConverseStream,
        stream: { model, context, options in
            let providerOptions = BedrockOptions(
                temperature: options?.temperature,
                maxTokens: options?.maxTokens,
                signal: options?.signal,
                cacheRetention: options?.cacheRetention,
                headers: options?.headers,
                onPayload: options?.onPayload
            )
            return streamBedrock(model: model, context: context, options: providerOptions)
        },
        streamSimple: { model, context, options in
            let providerOptions = mapBedrockSimpleOptions(model: model, options: options)
            return streamBedrock(model: model, context: context, options: providerOptions)
        }
    ), sourceId: "built-in")
}

/// Ensure built-in providers are registered (idempotent).
private let builtInProvidersRegistered: Bool = {
    registerBuiltInProviders()
    return true
}()

/// Ensure built-in providers are registered before using the registry.
func ensureBuiltInProviders() {
    _ = builtInProvidersRegistered
}
