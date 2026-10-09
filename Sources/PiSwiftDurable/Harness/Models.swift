import Foundation
import PiSwiftAI
import PiSwiftChord

/// The five model operations used by the durable harness.
/// Request contexts use `PiSwiftAI.Context`; operation contexts use `PiSwiftChord.Context`.
public protocol DurableModels: Sendable {
    func getModel(provider: String, modelId: String) -> Model?
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream
    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws
}

public enum DurableModelsError: Error, Sendable, Equatable, CustomStringConvertible {
    case deferredUnsupported(provider: String)

    public var description: String {
        switch self {
        case .deferredUnsupported(let provider): "Provider \(provider) does not support deferred responses"
        }
    }
}

extension DurableModels {
    public func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await streamSimple(model: model, context: context, options: options).result()
    }

    public func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        durableModelFailure(model: model, error: DurableModelsError.deferredUnsupported(provider: model.provider), signal: options.signal)
    }

    public func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        throw DurableModelsError.deferredUnsupported(provider: model.provider)
    }
}

/// Resolves the API key at the time of each request. An explicit request key takes priority.
public typealias DurableAPIKeyResolver = @Sendable (Model) async throws -> String?

/// Adapts the PiSwiftAI functions and the built-in model catalog.
/// As in upstream `Models`, setup and fetch failures become assistant error messages.
public struct PiSwiftAIDurableModels: DurableModels {
    private let resolveAPIKey: DurableAPIKeyResolver

    public init(apiKeyResolver: @escaping DurableAPIKeyResolver = { _ in nil }) {
        resolveAPIKey = apiKeyResolver
    }

    public func getModel(provider: String, modelId: String) -> Model? {
        guard let model = PiSwiftAI.getModel(provider: provider, modelId: modelId),
              model.provider.utf16.elementsEqual(provider.utf16),
              model.id.utf16.elementsEqual(modelId.utf16) else { return nil }
        return model
    }

    public func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let outer = AssistantMessageEventStream()
        // Upstream lazyStream starts auth and the provider only when observed.
        outer.setOnStart { [weak outer] in
            guard let outer else { return }
            Task {
                do {
                    var options = options
                    if options.apiKey == nil { options.apiKey = try await resolveAPIKey(model) }
                    let inner = try PiSwiftAI.streamSimple(model: model, context: context, options: options)
                    for await event in inner { outer.push(event) }
                } catch {
                    let message = durableModelFailure(model: model, error: error, signal: options.signal)
                    outer.push(.error(reason: message.stopReason, error: message))
                }
            }
        }
        return outer
    }

    public func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        do {
            var options = options
            if options.apiKey == nil { options.apiKey = try await resolveAPIKey(model) }
            return try await PiSwiftAI.fetchDeferred(model: model, handle: handle, options: options)
        } catch {
            return durableModelFailure(model: model, error: error, signal: options.signal)
        }
    }

    public func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        var options = options
        if options.apiKey == nil { options.apiKey = try await resolveAPIKey(model) }
        try await PiSwiftAI.cancelDeferred(model: model, handle: handle, options: options)
    }
}

private func durableModelFailure(model: Model, error: any Error, signal: CancellationToken? = nil) -> AssistantMessage {
    let aborted = signal?.isCancelled == true
    return AssistantMessage(
        content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: aborted ? .aborted : .error,
        errorMessage: aborted ? "Request was aborted" : ((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
    )
}

/// Retain this bridge for the lifetime of a model call or a model stream.
/// Context abort cancels the token. Token cancellation does not abort the context.
/// The bridge removes its listener when it is released.
public final class ContextCancellationBridge: Sendable {
    public let token: CancellationToken
    private let signal: AbortSignal?
    private let registration: AbortListenerRegistration?

    public init(context: PiSwiftChord.Context, token: CancellationToken = CancellationToken()) {
        self.token = token
        signal = context.abortSignal
        registration = signal?.addAbortListener { _ in token.cancel() }
        // AbortSignal does not invoke listeners added after abort. This also closes
        // the race between reading the signal and adding the listener.
        if signal?.aborted == true { token.cancel() }
    }

    deinit {
        if let signal, let registration { signal.removeAbortListener(registration) }
    }
}

/// Keeps the bridge alive until an asynchronous operation ends.
public func withContextCancellation<Result: Sendable>(
    _ context: PiSwiftChord.Context,
    operation: @Sendable (CancellationToken) async throws -> Result
) async rethrows -> Result {
    let bridge = ContextCancellationBridge(context: context)
    defer { withExtendedLifetime(bridge) {} }
    return try await operation(bridge.token)
}
