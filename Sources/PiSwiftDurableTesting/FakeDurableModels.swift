import Foundation
import Synchronization
import PiSwiftAI
import PiSwiftDurable

/// Counts each protocol method. `FakeDurableModelsState.callCount` counts generation attempts.
public struct FakeDurableModelCalls: Sendable, Equatable {
    public var getModel = 0
    public var streamSimple = 0
    public var completeSimple = 0
    public var fetchDeferred = 0
    public var cancelDeferred = 0
    public init() {}
}

/// State passed to scripted factories and returned by `state()`.
public struct FakeDurableModelsState: Sendable {
    public var callCount = 0
    public var deferredFetchCount = 0
    public var cancelledDeferred: [DeferredHandle] = []
    public init() {}
}

public typealias FakeDurableResponseFactory = @Sendable (
    TranscriptContext, SimpleStreamOptions?, FakeDurableModelsState, Model
) async throws -> AssistantMessage

public enum FakeDurableResponseStep: Sendable {
    case message(AssistantMessage)
    case factory(FakeDurableResponseFactory)
}

/// A per-instance faux model runtime. It does not modify PiSwiftAI's global API registry.
/// Factories receive the normalized transcript, request options, and the current faux state.
public final class FakeDurableModels: DurableModels {
    public let models: [Model]
    private let options: FauxRegistrationOptions

    private struct DeferredEntry: Sendable {
        let handle: DeferredHandle
        let step: FakeDurableResponseStep
        let context: TranscriptContext
        let options: SimpleStreamOptions
        let model: Model
        var pendingFetches: Int
        var cancelled = false
        var final: AssistantMessage?
        var resolving = false
        var waiters: [CheckedContinuation<AssistantMessage, Never>] = []
    }

    private struct State: Sendable {
        var responses: [FakeDurableResponseStep] = []
        var usage = FakeDurableModelsState()
        var calls = FakeDurableModelCalls()
        var deferred: [String: DeferredEntry] = [:]
        var promptCache: [String: String] = [:]
    }

    private enum Fetch: Sendable {
        case failure(String)
        case pending(DeferredHandle)
        case final(AssistantMessage)
        case resolve(DeferredEntry)
        case wait
    }

    private let storage = Mutex(State())

    public init(options: FauxRegistrationOptions = FauxRegistrationOptions(), responses: [FakeDurableResponseStep] = []) {
        self.options = options
        let provider = options.provider ?? "faux"
        let api = options.api.flatMap(Api.init(rawValue:)) ?? .openAICompletions
        let definitions = options.models.isEmpty ? [FauxModelDefinition(id: "faux-1", name: "Faux Model")] : options.models
        models = definitions.map {
            Model(id: $0.id, name: $0.name ?? $0.id, api: api, provider: provider,
                  baseUrl: "http://localhost:0", reasoning: $0.reasoning, input: $0.input,
                  cost: $0.cost, contextWindow: $0.contextWindow, maxTokens: $0.maxTokens)
        }
        storage.withLock { $0.responses = responses }
    }

    public func getModel(provider: String, modelId: String) -> Model? {
        storage.withLock { $0.calls.getModel += 1 }
        return models.first { $0.provider.utf16.elementsEqual(provider.utf16) && $0.id.utf16.elementsEqual(modelId.utf16) }
    }

    public func setResponses(_ responses: [FakeDurableResponseStep]) {
        storage.withLock { $0.responses = responses }
    }

    public func appendResponses(_ responses: [FakeDurableResponseStep]) {
        storage.withLock { $0.responses.append(contentsOf: responses) }
    }

    public func pendingResponseCount() -> Int { storage.withLock { $0.responses.count } }
    public func state() -> FakeDurableModelsState { storage.withLock { $0.usage } }
    public func calls() -> FakeDurableModelCalls { storage.withLock { $0.calls } }

    public func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        storage.withLock { $0.calls.streamSimple += 1 }
        return makeStream(model: model, context: context, options: options)
    }

    public func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        storage.withLock { $0.calls.completeSimple += 1 }
        return await makeStream(model: model, context: context, options: options).result()
    }

    private func makeStream(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        let stream = AssistantMessageEventStream()
        let transcript = normalizeContext(context)
        // Upstream removes the step and counts the request before its microtask runs.
        let step = storage.withLock { state -> FakeDurableResponseStep? in
            state.usage.callCount += 1
            return state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        Task {
            options.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
            guard let step else {
                let failure = estimate(error("No more faux responses queued", model: model), context: transcript, options: options)
                stream.push(.error(reason: .error, error: failure))
                return
            }
            if options.deferred != nil {
                let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue,
                    id: "deferred-\(UUID().uuidString)", pollAfterMs: self.options.deferred?.pollAfterMs)
                storage.withLock {
                    $0.deferred[handle.id] = DeferredEntry(handle: handle, step: step, context: transcript,
                        options: options, model: model, pendingFetches: max(0, self.options.deferred?.pendingFetches ?? 0))
                }
                await emit(stream, message: deferred(model: model, handle: handle), signal: options.signal)
                return
            }
            do {
                let message = try await resolve(step, context: transcript, options: options, model: model)
                await emit(stream, message: message, signal: options.signal)
            } catch {
                let failure = self.error(errorDescription(error), model: model)
                stream.push(.error(reason: .error, error: failure))
            }
        }
        return stream
    }

    public func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        let action = storage.withLock { state -> Fetch in
            state.calls.fetchDeferred += 1
            state.usage.deferredFetchCount += 1
            guard var entry = state.deferred[handle.id], entry.handle.provider.utf16.elementsEqual(handle.provider.utf16),
                  entry.handle.modelId.utf16.elementsEqual(handle.modelId.utf16),
                  entry.handle.api.utf16.elementsEqual(handle.api.utf16) else {
                return .failure("Unknown faux deferred response: \(handle.id)")
            }
            if entry.cancelled { return .failure("Faux deferred response was cancelled: \(handle.id)") }
            if entry.pendingFetches > 0 {
                entry.pendingFetches -= 1
                state.deferred[handle.id] = entry
                return .pending(entry.handle)
            }
            if let final = entry.final { return .final(final) }
            if entry.resolving { return .wait }
            entry.resolving = true
            state.deferred[handle.id] = entry
            return .resolve(entry)
        }
        options.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
        let message: AssistantMessage
        switch action {
        case .failure(let description): return error(description, model: model)
        case .pending(let handle): message = deferred(model: model, handle: handle)
        case .final(let final): message = final
        case .wait:
            message = await withCheckedContinuation { continuation in
                let final = storage.withLock { state -> AssistantMessage? in
                    if let final = state.deferred[handle.id]?.final { return final }
                    state.deferred[handle.id]?.waiters.append(continuation)
                    return nil
                }
                if let final { continuation.resume(returning: final) }
            }
        case .resolve(let entry):
            var request = entry.options
            request.deferred = nil
            request.signal = nil
            request.onResponse = nil
            do {
                message = try await resolve(entry.step, context: entry.context, options: request, model: entry.model)
            } catch {
                message = self.error(errorDescription(error), model: entry.model)
            }
            let waiters = storage.withLock { state in
                let waiters = state.deferred[handle.id]?.waiters ?? []
                state.deferred[handle.id]?.final = message
                state.deferred[handle.id]?.waiters = []
                return waiters
            }
            for waiter in waiters { waiter.resume(returning: message) }
        }
        let stream = AssistantMessageEventStream()
        await emit(stream, message: message, signal: options.signal)
        var result = await stream.result()
        if result.stopReason != .deferred && result.stopReason != .aborted {
            result = storage.withLock { state in
                guard let final = state.deferred[handle.id]?.final else { return result }
                if let duration = final.durationMs { result.durationMs = duration }
                var cached = final
                cached.durationMs = result.durationMs
                state.deferred[handle.id]?.final = cached
                return result
            }
        }
        return result
    }

    public func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        storage.withLock { state in
            state.calls.cancelDeferred += 1
            state.usage.cancelledDeferred.append(handle)
            state.deferred[handle.id]?.cancelled = true
        }
        options.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
    }

    private func resolve(_ step: FakeDurableResponseStep, context: TranscriptContext, options: SimpleStreamOptions,
                         model: Model) async throws -> AssistantMessage {
        var message: AssistantMessage
        switch step {
        case .message(let response): message = response
        case .factory(let factory): message = try await factory(context, options, state(), model)
        }
        message.api = model.api
        message.provider = model.provider
        message.model = model.id
        return estimate(message, context: context, options: options)
    }

    private func errorDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func error(_ description: String, model: Model) -> AssistantMessage {
        AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error, errorMessage: description)
    }

    private func deferred(model: Model, handle: DeferredHandle) -> AssistantMessage {
        var message = error("", model: model)
        message.errorMessage = nil
        message.stopReason = .deferred
        message.deferred = handle
        return message
    }

    private func estimate(_ message: AssistantMessage, context: TranscriptContext,
                          options: SimpleStreamOptions) -> AssistantMessage {
        let prompt = context.messages.map(promptText).joined(separator: "\n\n")
        let promptTokens = tokens(prompt)
        let output = tokens(blockText(message.content))
        var input = promptTokens
        var cacheRead = 0
        var cacheWrite = 0
        // Upstream keeps caching on when cacheRetention is absent.
        if let session = options.sessionId, !session.isEmpty, options.cacheRetention != CacheRetention.none {
            let previous = storage.withLock { $0.promptCache.updateValue(prompt, forKey: session) }
            if let previous {
                let common = zip(previous.utf16, prompt.utf16).prefix { $0 == $1 }.count
                cacheRead = (common + 3) / 4
                cacheWrite = (prompt.utf16.count - common + 3) / 4
                input = max(0, promptTokens - cacheRead)
            } else { cacheWrite = promptTokens }
        }
        var result = message
        result.usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                             totalTokens: input + output + cacheRead + cacheWrite)
        return result
    }

    private func tokens(_ text: String) -> Int { (text.utf16.count + 3) / 4 }

    private func promptText(_ message: Message) -> String {
        let text: String
        switch message {
        case .system(let system):
            var lines = [getSystemMessageText(system)].filter { !$0.isEmpty }
            for removed in system.toolsRemoved ?? [] {
                lines.append("tool-:\(OrderedJSON.object([("name", .string(removed.name))]).serialized(escapeSlashes: false))")
            }
            if case .array(let declarations)? = systemMessageToOrderedJSON(system)["toolsAdded"] {
                lines.append(contentsOf: declarations.map { "tool+:\($0.serialized(escapeSlashes: false))" })
            }
            text = lines.joined(separator: "\n")
        case .user(let user):
            switch user.content {
            case .text(let value): text = value
            case .blocks(let blocks): text = blockText(blocks)
            }
        case .assistant(let assistant): text = blockText(assistant.content)
        case .toolResult(let result): text = ([result.toolName] + result.content.map { blockText([$0]) }).joined(separator: "\n")
        }
        return "\(message.role):\(text)"
    }

    private func blockText(_ blocks: [ContentBlock]) -> String {
        blocks.map { block in
            switch block {
            case .text(let text): text.text
            case .thinking(let thinking): thinking.thinking
            case .image(let image): "[image:\(image.mimeType):\(image.data.utf16.count)]"
            case .toolCall(let call): "\(call.name):\(argumentsJSON(call))"
            }
        }.joined(separator: "\n")
    }

    private func argumentsJSON(_ call: ToolCall) -> String {
        if let value = call.argumentsJSON { return value.serialized(escapeSlashes: false) }
        return contentBlockToOrderedJSON(.toolCall(call))["arguments"]?.serialized(escapeSlashes: false) ?? "{}"
    }

    private func emit(_ stream: AssistantMessageEventStream, message: AssistantMessage,
                      signal: CancellationToken?) async {
        var partial = message
        partial.content = []
        partial.stopReason = .pending
        func abort() -> Bool {
            guard signal?.isCancelled == true else { return false }
            partial.stopReason = .aborted
            partial.errorMessage = "Request was aborted"
            stream.push(.error(reason: .aborted, error: partial))
            return true
        }
        if abort() { return }
        stream.push(.start(partial: partial))
        for (index, block) in message.content.enumerated() {
            if abort() { return }
            switch block {
            case .text(let text):
                var part = text
                part.text = ""
                partial.content.append(.text(part))
                stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in chunks(text.text) {
                    await pace(chunk)
                    if abort() { return }
                    part.text += chunk
                    partial.content[index] = .text(part)
                    stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.textEnd(contentIndex: index, content: text.text, partial: partial))
            case .thinking(let thinking):
                var part = thinking
                part.thinking = ""
                partial.content.append(.thinking(part))
                stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in chunks(thinking.thinking) {
                    await pace(chunk)
                    if abort() { return }
                    part.thinking += chunk
                    partial.content[index] = .thinking(part)
                    stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: partial))
            case .toolCall(let call):
                var part = call
                part.arguments = [:]
                part.argumentsJSON = nil
                partial.content.append(.toolCall(part))
                stream.push(.toolCallStart(contentIndex: index, partial: partial))
                for chunk in chunks(argumentsJSON(call)) {
                    await pace(chunk)
                    if abort() { return }
                    stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
            case .image:
                partial.content.append(block)
            }
        }
        if message.stopReason == .pending {
            let failure = AssistantMessage(content: [], api: message.api, provider: message.provider, model: message.model,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .error,
                errorMessage: "Faux response ended without a stop reason")
            stream.push(.error(reason: .error, error: failure))
        } else if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
        } else { stream.push(.done(reason: message.stopReason, message: message)) }
    }

    private func chunks(_ text: String) -> [String] {
        // Use scalar boundaries so a chunk cannot introduce a lone surrogate.
        let scalars = Array(text.unicodeScalars)
        let minimum = max(1, min(options.minTokenSize, options.maxTokenSize))
        let maximum = max(minimum, options.maxTokenSize)
        var result: [String] = []
        var index = 0
        while index < scalars.count {
            let end = min(scalars.count, index + Int.random(in: minimum...maximum) * 4)
            result.append(String(String.UnicodeScalarView(scalars[index..<end])))
            index = end
        }
        return result.isEmpty ? [""] : result
    }

    private func pace(_ chunk: String) async {
        guard let rate = options.tokensPerSecond, rate > 0 else { await Task.yield(); return }
        let seconds = Double(tokens(chunk)) / rate
        try? await Task.sleep(for: .seconds(seconds))
    }
}
