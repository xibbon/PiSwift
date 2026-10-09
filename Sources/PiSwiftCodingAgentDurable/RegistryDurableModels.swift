import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftDurable
import Synchronization

/// Uses coding-agent authentication and model routing for durable requests.
public final class RegistryDurableModels: DurableModels {
    public let registry: ModelRegistry
    private struct Snapshot: Sendable {
        var models: [Model] = []
        var generation: UInt64 = 0
    }
    private let snapshot = Mutex(Snapshot())

    private init(registry: ModelRegistry) {
        self.registry = registry
    }

    /// Restores cached catalogs without a network catalog refresh, then records availability.
    public static func create(registry: ModelRegistry) async -> RegistryDurableModels {
        let models = RegistryDurableModels(registry: registry)
        _ = await models.refresh(ModelsRefreshOptions(allowNetwork: false))
        return models
    }

    /// Refreshes the registry and replaces the synchronous availability snapshot.
    @discardableResult
    public func refresh(_ options: ModelsRefreshOptions = .init()) async -> ModelsRefreshResult {
        let generation = snapshot.withLock { value in
            value.generation += 1
            return value.generation
        }
        let result = await registry.refresh(options)
        let available = await registry.getAvailable()
        snapshot.withLock { value in
            if value.generation == generation { value.models = available }
        }
        return result
    }

    /// Returns the last availability snapshot. Refresh after registry or credential changes.
    public func getAvailableSnapshot() -> [Model] {
        snapshot.withLock { $0.models }
    }

    public func getModel(provider: String, modelId: String) -> Model? {
        registry.getAll().first {
            $0.provider.utf16.elementsEqual(provider.utf16) && $0.id.utf16.elementsEqual(modelId.utf16)
        }
    }

    /// Starts asynchronous authentication and routing at once, before stream observation.
    public func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let output = AssistantMessageEventStream()
        Task {
            do {
                var requestModel = model
                var requestOptions = options
                if isVirtualModel(model) {
                    let route = try await registry.resolveVirtualModel(
                        model, messages: normalizeContext(context).messages, reason: .direct,
                        thinkingLevel: options.reasoning.flatMap { ModelThinkingLevel(rawValue: $0.rawValue) } ?? .off,
                        signal: options.signal
                    )
                    requestModel = route.model
                    if let budget = options.maxTokens, route.model.maxTokens > 0 {
                        requestOptions.maxTokens = min(budget, route.model.maxTokens)
                    }
                    requestOptions.reasoning = route.thinkingLevel == .off ? nil : PiSwiftAI.ThinkingLevel(rawValue: route.thinkingLevel.rawValue)
                    if route.model.provider != model.provider {
                        requestOptions.apiKey = nil
                        requestOptions.headers = nil
                        requestOptions.env = nil
                    }
                }
                let resolved = try await prepareRequest(model: requestModel, apiKey: requestOptions.apiKey,
                    headers: requestOptions.headers, env: requestOptions.env, signal: requestOptions.signal)
                requestOptions.apiKey = requestOptions.apiKey ?? resolved.auth.apiKey
                requestOptions.headers = mergeProviderHeaders(resolved.auth.headers, requestOptions.headers)
                requestOptions.env = mergeEnvironment(resolved.auth.env, requestOptions.env)
                let input = try registry.streamSimplePrepared(model: resolved.model, context: context, options: requestOptions)
                for await event in input { output.push(event) }
                output.end(await input.result())
            } catch {
                let failed = modelFailure(model: model, error: error, startedAt: startedAt)
                output.push(.error(reason: .error, error: failed))
                output.end(failed)
            }
        }
        return output
    }

    public func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let resolved = try await prepareRequest(model: model, apiKey: options.apiKey, headers: options.headers,
                                                    env: options.env, signal: options.signal)
            var prepared = options
            prepared.apiKey = options.apiKey ?? resolved.auth.apiKey
            prepared.headers = mergeProviderHeaders(resolved.auth.headers, options.headers)
            prepared.env = mergeEnvironment(resolved.auth.env, options.env)
            return try await PiSwiftAI.fetchDeferred(model: resolved.model, handle: handle, options: prepared)
        } catch {
            return modelFailure(model: model, error: error, startedAt: startedAt)
        }
    }

    public func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        let resolved = try await prepareRequest(model: model, apiKey: options.apiKey, headers: options.headers,
                                                env: options.env, signal: options.signal)
        var prepared = options
        prepared.apiKey = options.apiKey ?? resolved.auth.apiKey
        prepared.headers = mergeProviderHeaders(resolved.auth.headers, options.headers)
        prepared.env = mergeEnvironment(resolved.auth.env, options.env)
        try await PiSwiftAI.cancelDeferred(model: resolved.model, handle: handle, options: prepared)
    }

    private func prepareRequest(model: Model, apiKey: String?, headers: ProviderHeaders?,
                                env: [String: String]?, signal: CancellationToken?) async throws -> ResolvedModelRequest {
        let resolved = await registry.resolveModelRequest(model, signal: signal, env: env)
        guard signal?.isCancelled != true else { throw RegistryDurableModelsError.aborted }
        guard resolved.auth.ok || apiKey != nil || headers?.isEmpty == false else {
            throw RegistryDurableModelsError.authentication(resolved.auth.error ?? "Provider is not configured: \(model.provider)")
        }
        return resolved
    }
}

private enum RegistryDurableModelsError: Error, LocalizedError {
    case aborted
    case authentication(String)
    var errorDescription: String? {
        switch self {
        case .aborted: "Request was aborted"
        case .authentication(let message): message
        }
    }
}

private func mergeEnvironment(_ base: [String: String]?, _ override: [String: String]?) -> [String: String]? {
    guard base != nil || override != nil else { return nil }
    return (base ?? [:]).merging(override ?? [:]) { _, value in value }
}

private func modelFailure(model: Model, error: any Error, startedAt: Int64) -> AssistantMessage {
    AssistantMessage(
        content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: (error as? any LocalizedError)?.errorDescription ?? String(describing: error),
        timestamp: startedAt
    )
}
