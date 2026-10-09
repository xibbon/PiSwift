import Foundation

/// In-memory provider used by tests to script assistant responses without making network calls.
/// Mirrors `pi-mono` `faux.ts`: register a fake provider/api pair, queue `AssistantMessage`
/// responses (or factories that produce them), and consume them via `stream`/`streamSimple`.
public struct FauxModelDefinition: Sendable {
    public var id: String
    public var name: String?
    public var reasoning: Bool
    public var input: [ModelInput]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int

    public init(
        id: String,
        name: String? = nil,
        reasoning: Bool = false,
        input: [ModelInput] = [.text, .image],
        cost: ModelCost = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: Int = 128_000,
        maxTokens: Int = 16_384
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }
}

public struct FauxState: Sendable {
    public var callCount: Int = 0
    public var deferredFetchCount: Int = 0
    public var cancelledDeferred: [DeferredHandle] = []
}

public typealias FauxResponseFactory = @Sendable (TranscriptContext, SimpleStreamOptions?, FauxState, Model) async throws -> AssistantMessage

public enum FauxResponseStep: Sendable {
    case message(AssistantMessage)
    case factory(FauxResponseFactory)
}

public struct FauxDeferredOptions: Sendable {
    /// Fetches that return the original handle before the scripted response becomes ready.
    public var pendingFetches: Int
    public var pollAfterMs: Int?

    public init(pendingFetches: Int = 0, pollAfterMs: Int? = nil) {
        self.pendingFetches = pendingFetches
        self.pollAfterMs = pollAfterMs
    }
}

public struct FauxRegistrationOptions: Sendable {
    public var api: String?
    public var provider: String?
    public var models: [FauxModelDefinition]
    public var tokensPerSecond: Double?
    public var minTokenSize: Int
    public var maxTokenSize: Int
    public var deferred: FauxDeferredOptions?

    public init(
        api: String? = nil,
        provider: String? = nil,
        models: [FauxModelDefinition] = [],
        tokensPerSecond: Double? = nil,
        minTokenSize: Int = 3,
        maxTokenSize: Int = 5,
        deferred: FauxDeferredOptions? = nil
    ) {
        self.api = api
        self.provider = provider
        self.models = models
        self.tokensPerSecond = tokensPerSecond
        self.minTokenSize = minTokenSize
        self.maxTokenSize = maxTokenSize
        self.deferred = deferred
    }
}

/// Mutable scripted-response and usage state is stored in `LockedState`.
public final class FauxProviderRegistration: Sendable {
    public let api: Api
    public let models: [Model]
    public let sourceId: String

    fileprivate struct DeferredEntry: Sendable {
        var handle: DeferredHandle
        var step: FauxResponseStep
        var context: TranscriptContext
        var options: SimpleStreamOptions?
        var model: Model
        var pendingFetches: Int
        var cancelled = false
        var final: AssistantMessage?
        var resolving = false
        var waiters: [CheckedContinuation<AssistantMessage, Never>] = []
    }

    fileprivate enum DeferredFetch: Sendable {
        case failure(String)
        case pending(DeferredHandle)
        case final(AssistantMessage)
        case resolve(DeferredEntry)
        case wait
    }

    private struct State: Sendable {
        var pendingResponses: [FauxResponseStep] = []
        var usage = FauxState()
        var promptCache: [String: [String]] = [:]
        var deferredResponses: [String: DeferredEntry] = [:]
    }

    private let storage = LockedState(State())
    private let minTokenSize: Int
    private let maxTokenSize: Int
    private let tokensPerSecond: Double?
    private let provider: String
    private let deferred: FauxDeferredOptions?

    init(api: Api, provider: String, models: [Model], sourceId: String, minTokenSize: Int, maxTokenSize: Int, tokensPerSecond: Double?, deferred: FauxDeferredOptions? = nil) {
        self.api = api
        self.provider = provider
        self.models = models
        self.sourceId = sourceId
        self.minTokenSize = minTokenSize
        self.maxTokenSize = maxTokenSize
        self.tokensPerSecond = tokensPerSecond
        self.deferred = deferred
    }

    public func setResponses(_ responses: [FauxResponseStep]) {
        storage.withLock { $0.pendingResponses = responses }
    }

    public func appendResponses(_ responses: [FauxResponseStep]) {
        storage.withLock { $0.pendingResponses.append(contentsOf: responses) }
    }

    public func pendingResponseCount() -> Int {
        storage.withLock { $0.pendingResponses.count }
    }

    public func state() -> FauxState {
        storage.withLock { $0.usage }
    }

    public func unregister() {
        unregisterApiProviders(sourceId: sourceId)
    }

    public func getModel() -> Model? {
        models.first
    }

    public func getModel(id: String) -> Model? {
        models.first { $0.id == id }
    }

    fileprivate func popStep() -> FauxResponseStep? {
        storage.withLock { state in
            guard !state.pendingResponses.isEmpty else { return nil }
            state.usage.callCount += 1
            return state.pendingResponses.removeFirst()
        }
    }

    fileprivate func submitDeferred(step: FauxResponseStep, context: TranscriptContext, options: SimpleStreamOptions?, model: Model) -> DeferredHandle {
        let handle = DeferredHandle(provider: model.provider, modelId: model.id, api: model.api.rawValue,
            id: "deferred-\(UUID().uuidString)", pollAfterMs: deferred?.pollAfterMs)
        let entry = DeferredEntry(handle: handle, step: step, context: context, options: options, model: model,
            pendingFetches: max(0, deferred?.pendingFetches ?? 0))
        storage.withLock { $0.deferredResponses[handle.id] = entry }
        return handle
    }

    fileprivate func recordDeferredFetch() {
        storage.withLock { $0.usage.deferredFetchCount += 1 }
    }

    fileprivate func claimDeferred(_ handle: DeferredHandle) -> DeferredFetch {
        storage.withLock { state in
            guard var entry = state.deferredResponses[handle.id],
                  entry.handle.provider == handle.provider, entry.handle.modelId == handle.modelId,
                  entry.handle.api == handle.api else {
                return .failure("Unknown faux deferred response: \(handle.id)")
            }
            if entry.cancelled { return .failure("Faux deferred response was cancelled: \(handle.id)") }
            if entry.pendingFetches > 0 {
                entry.pendingFetches -= 1
                state.deferredResponses[handle.id] = entry
                return .pending(entry.handle)
            }
            if let final = entry.final { return .final(final) }
            if entry.resolving { return .wait }
            entry.resolving = true
            state.deferredResponses[handle.id] = entry
            return .resolve(entry)
        }
    }

    fileprivate func waitForDeferred(_ id: String) async -> AssistantMessage {
        await withCheckedContinuation { continuation in
            let final = storage.withLock { state -> AssistantMessage? in
                if let final = state.deferredResponses[id]?.final { return final }
                state.deferredResponses[id]?.waiters.append(continuation)
                return nil
            }
            if let final { continuation.resume(returning: final) }
        }
    }

    fileprivate func finishDeferred(_ id: String, message: AssistantMessage) {
        let waiters = storage.withLock { state in
            let waiters = state.deferredResponses[id]?.waiters ?? []
            state.deferredResponses[id]?.final = message
            state.deferredResponses[id]?.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: message) }
    }

    fileprivate func cacheDeferredTiming(_ id: String, message: AssistantMessage) -> AssistantMessage {
        storage.withLock { state in
            var message = message
            if let duration = state.deferredResponses[id]?.final?.durationMs {
                message.durationMs = duration
            }
            state.deferredResponses[id]?.final = message
            return message
        }
    }

    func cancelDeferred(_ handle: DeferredHandle) {
        storage.withLock { state in
            state.usage.cancelledDeferred.append(handle)
            state.deferredResponses[handle.id]?.cancelled = true
        }
    }

    fileprivate func currentState() -> FauxState {
        storage.withLock { $0.usage }
    }

    fileprivate func replacePrompt(_ prompt: [String], forSession session: String) -> [String]? {
        storage.withLock { state in
            state.promptCache.updateValue(prompt, forKey: session)
        }
    }

    fileprivate func tokenSizes() -> (Int, Int) {
        return (minTokenSize, maxTokenSize)
    }

    fileprivate var tokensPerSecondValue: Double? { tokensPerSecond }
    fileprivate var providerName: String { provider }
}

@discardableResult
public func registerFauxProvider(_ options: FauxRegistrationOptions = FauxRegistrationOptions()) -> FauxProviderRegistration {
    let api: Api
    if let raw = options.api, let custom = Api(rawValue: raw) {
        api = custom
    } else {
        api = .openAICompletions
    }
    let provider = options.provider ?? "faux"
    let sourceId = "faux-\(UUID().uuidString)"
    let minTokenSize = max(1, min(options.minTokenSize, options.maxTokenSize))
    let maxTokenSize = max(minTokenSize, options.maxTokenSize)

    let definitions: [FauxModelDefinition] = options.models.isEmpty
        ? [FauxModelDefinition(id: "faux-1", name: "Faux Model")]
        : options.models

    let models: [Model] = definitions.map { def in
        Model(
            id: def.id,
            name: def.name ?? def.id,
            api: api,
            provider: provider,
            baseUrl: "http://localhost:0",
            reasoning: def.reasoning,
            input: def.input,
            cost: def.cost,
            contextWindow: def.contextWindow,
            maxTokens: def.maxTokens
        )
    }

    let registration = FauxProviderRegistration(
        api: api,
        provider: provider,
        models: models,
        sourceId: sourceId,
        minTokenSize: minTokenSize,
        maxTokenSize: maxTokenSize,
        tokensPerSecond: options.tokensPerSecond,
        deferred: options.deferred
    )

    registerApiProvider(ApiProvider(
        api: api,
        stream: { model, context, options in
            fauxStream(model: model, context: context, registration: registration, simpleOptions: options.flatMap(toSimpleOptions))
        },
        streamSimple: { model, context, options in
            fauxStream(model: model, context: context, registration: registration, simpleOptions: options)
        },
        fetchDeferred: { model, handle, options in
            fauxFetchDeferred(model: model, handle: handle, registration: registration, options: options)
        },
        cancelDeferred: { _, handle, options in
            registration.cancelDeferred(handle)
            options?.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
        }
    ), sourceId: sourceId)

    return registration
}

private func toSimpleOptions(_ options: StreamOptions) -> SimpleStreamOptions {
    SimpleStreamOptions(
        env: options.env,
        temperature: options.temperature,
        maxTokens: options.maxTokens,
        signal: options.signal,
        apiKey: options.apiKey,
        cacheRetention: options.cacheRetention,
        sessionId: options.sessionId,
        headers: options.headers,
        onPayload: options.onPayload
    )
}

func fauxStream(
    model: Model,
    context: TranscriptContext,
    registration: FauxProviderRegistration,
    simpleOptions: SimpleStreamOptions?
) -> AssistantMessageEventStream {
    let outer = createAssistantMessageEventStream()
    Task {
        do {
            guard let step = registration.popStep() else {
                let message = createFauxErrorMessage("No more faux responses queued", api: registration.api, provider: registration.providerName, modelId: model.id)
                let withUsage = withFauxUsageEstimate(message: message, context: context, options: simpleOptions, registration: registration)
                outer.push(.error(reason: .error, error: withUsage))
                outer.end()
                return
            }
            if simpleOptions?.deferred != nil {
                simpleOptions?.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
                let handle = registration.submitDeferred(step: step, context: context, options: simpleOptions, model: model)
                await streamFauxWithDeltas(stream: outer, message: createFauxDeferredMessage(model: model, handle: handle),
                    registration: registration, signal: simpleOptions?.signal)
                return
            }
            let message = try await resolveFauxResponse(step: step, context: context, options: simpleOptions, model: model, registration: registration)
            await streamFauxWithDeltas(stream: outer, message: message, registration: registration, signal: simpleOptions?.signal)
        } catch {
            let message = createFauxErrorMessage(fauxErrorDescription(error), api: registration.api, provider: registration.providerName, modelId: model.id)
            outer.push(.error(reason: .error, error: message))
            outer.end()
        }
    }
    return outer
}

private func fauxErrorDescription(_ error: any Error) -> String {
    (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
}

private func resolveFauxResponse(step: FauxResponseStep, context: TranscriptContext, options: SimpleStreamOptions?, model: Model, registration: FauxProviderRegistration) async throws -> AssistantMessage {
    let resolved: AssistantMessage
    switch step {
    case .message(let message): resolved = message
    case .factory(let factory): resolved = try await factory(context, options, registration.currentState(), model)
    }
    let message = cloneFauxMessage(resolved, api: registration.api, provider: registration.providerName, modelId: model.id)
    return withFauxUsageEstimate(message: message, context: context, options: options, registration: registration)
}

private func createFauxDeferredMessage(model: Model, handle: DeferredHandle) -> AssistantMessage {
    AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .deferred, deferred: handle)
}

func fauxFetchDeferred(model: Model, handle: DeferredHandle, registration: FauxProviderRegistration, options: DeferredFetchOptions?) -> AssistantMessageEventStream {
    let outer = createAssistantMessageEventStream()
    registration.recordDeferredFetch()
    Task {
        options?.onResponse?(ResponseSnapshot(statusCode: 200, headers: [:]))
        let action = registration.claimDeferred(handle)
        let message: AssistantMessage
        switch action {
        case .failure(let description):
            message = createFauxErrorMessage(description, api: registration.api, provider: registration.providerName, modelId: model.id)
            outer.push(.error(reason: .error, error: message))
            outer.end()
            return
        case .pending(let stored):
            await streamFauxWithDeltas(stream: outer, message: createFauxDeferredMessage(model: model, handle: stored),
                registration: registration, signal: options?.signal)
            return
        case .final(let final): message = final
        case .wait: message = await registration.waitForDeferred(handle.id)
        case .resolve(let entry):
            var submissionOptions = entry.options ?? SimpleStreamOptions()
            submissionOptions.deferred = nil
            submissionOptions.signal = nil
            submissionOptions.onResponse = nil
            do {
                message = try await resolveFauxResponse(step: entry.step, context: entry.context, options: submissionOptions,
                    model: entry.model, registration: registration)
            } catch {
                message = createFauxErrorMessage(fauxErrorDescription(error), api: registration.api,
                    provider: registration.providerName, modelId: entry.model.id)
            }
            registration.finishDeferred(handle.id, message: message)
        }
        await streamFauxWithDeltas(stream: outer, message: message, registration: registration, signal: options?.signal,
            finalize: { message in registration.cacheDeferredTiming(handle.id, message: outer.time(message)) })
    }
    return outer
}

private func cloneFauxMessage(_ message: AssistantMessage, api: Api, provider: String, modelId: String) -> AssistantMessage {
    AssistantMessage(
        content: message.content,
        api: api,
        provider: provider,
        model: modelId,
        responseModel: message.responseModel,
        responseId: message.responseId,
        usage: message.usage,
        stopReason: message.stopReason,
        errorMessage: message.errorMessage,
        timestamp: message.timestamp,
        deferred: message.deferred,
        rawStopReason: message.rawStopReason,
        diagnostics: message.diagnostics,
        durationMs: message.durationMs
    )
}

private func createFauxErrorMessage(_ description: String, api: Api, provider: String, modelId: String) -> AssistantMessage {
    AssistantMessage(
        content: [],
        api: api,
        provider: provider,
        model: modelId,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .error,
        errorMessage: description
    )
}

private func withFauxUsageEstimate(
    message: AssistantMessage,
    context: TranscriptContext,
    options: SimpleStreamOptions?,
    registration: FauxProviderRegistration
) -> AssistantMessage {
    // One text per message; the whole prompt joins them with blank lines.
    let prompt = fauxContextMessages(context)
    let promptLength = joinedFauxLength(prompt)
    let promptTokens = (promptLength + 3) / 4
    let outputTokens = estimateFauxTokens(assistantContentToText(message.content))
    var input = promptTokens
    var cacheRead = 0
    var cacheWrite = 0
    let sessionId = options?.sessionId
    let cacheEnabled = (options?.cacheRetention ?? .none) != .none
    if let sessionId, cacheEnabled {
        if let previous = registration.replacePrompt(prompt, forSession: sessionId) {
            let cachedChars = commonFauxPromptPrefixLength(previous, prompt)
            cacheRead = (cachedChars + 3) / 4
            cacheWrite = (promptLength - cachedChars + 3) / 4
            input = max(0, promptTokens - cacheRead)
        } else {
            cacheWrite = promptTokens
        }
    }
    var copy = message
    copy.usage = Usage(
        input: input,
        output: outputTokens,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        totalTokens: input + outputTokens + cacheRead + cacheWrite
    )
    return copy
}

private func estimateFauxTokens(_ text: String) -> Int {
    Int((Double(text.count) / 4.0).rounded(.up))
}

private func commonPrefixLength(_ a: String, _ b: String) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    let minLen = min(aChars.count, bChars.count)
    var i = 0
    while i < minLen && aChars[i] == bChars[i] { i += 1 }
    return i
}

private func joinedFauxLength(_ messages: [String], count: Int? = nil) -> Int {
    let count = count ?? messages.count
    // Swift counts CRLF as one Character. Keep the previous joined-string count.
    let joinedCRLFCount = messages.prefix(max(0, count - 1)).filter { $0.hasSuffix("\r") }.count
    return max(0, count - 1) * 2 + messages.prefix(count).reduce(0) { $0 + $1.count } - joinedCRLFCount
}

/// Compare equal messages whole, then compare characters from the first difference.
private func commonFauxPromptPrefixLength(_ previous: [String], _ current: [String]) -> Int {
    var index = 0
    while index < previous.count && index < current.count && previous[index] == current[index] {
        index += 1
    }
    // A final CR differs from CRLF when only one prompt has a next message.
    if index > 0, previous[index - 1].hasSuffix("\r"),
       (index == previous.count) != (index == current.count) {
        index -= 1
    }
    func rest(_ messages: [String]) -> String {
        guard index < messages.count else { return "" }
        return (index > 0 ? "\n\n" : "") + messages.dropFirst(index).joined(separator: "\n\n")
    }
    let remainingPrefix = commonPrefixLength(rest(previous), rest(current))
    let joinedCRLFCount = index > 0 && previous[index - 1].hasSuffix("\r") && remainingPrefix > 0 ? 1 : 0
    return joinedFauxLength(previous, count: index) + remainingPrefix - joinedCRLFCount
}

func serializeFauxContext(_ context: TranscriptContext) -> String {
    fauxContextMessages(context).joined(separator: "\n\n")
}

private func fauxContextMessages(_ context: TranscriptContext) -> [String] {
    context.messages.map { message in
        if case .system(let system) = message {
            var lines: [String] = []
            let prompt = getSystemMessageText(system)
            if !prompt.isEmpty { lines.append(prompt) }
            for removed in system.toolsRemoved ?? [] {
                lines.append("tool-:\(OrderedJSON.object([("name", .string(removed.name))]).serialized(escapeSlashes: false))")
            }
            if case .array(let declarations)? = systemMessageToOrderedJSON(system)["toolsAdded"] {
                lines.append(contentsOf: declarations.map { "tool+:\($0.serialized(escapeSlashes: false))" })
            }
            return "system:\(lines.joined(separator: "\n"))"
        }
        return "\(message.role):\(messageToFauxText(message))"
    }
}

private func messageToFauxText(_ message: Message) -> String {
    switch message {
    case .system(let system): return getSystemMessageText(system)
    case .user(let user):
        switch user.content {
        case .text(let text): return text
        case .blocks(let blocks):
            return blocks.map { block in
                switch block {
                case .text(let textBlock): return textBlock.text
                case .image(let imageBlock): return "[image:\(imageBlock.mimeType):\(imageBlock.data.count)]"
                case .thinking(let thinkingBlock): return thinkingBlock.thinking
                case .toolCall(let toolCall): return "\(toolCall.name):\(toolCall.arguments)"
                }
            }.joined(separator: "\n")
        }
    case .assistant(let assistant):
        return assistantContentToText(assistant.content)
    case .toolResult(let result):
        let inner = result.content.map { block -> String in
            switch block {
            case .text(let textBlock): return textBlock.text
            case .image(let imageBlock): return "[image:\(imageBlock.mimeType):\(imageBlock.data.count)]"
            case .thinking(let thinkingBlock): return thinkingBlock.thinking
            case .toolCall(let toolCall): return "\(toolCall.name):\(toolCall.arguments)"
            }
        }.joined(separator: "\n")
        return "\(result.toolName)\n\(inner)"
    }
}

private func assistantContentToText(_ content: [ContentBlock]) -> String {
    content.map { block in
        switch block {
        case .text(let textBlock): return textBlock.text
        case .thinking(let thinkingBlock): return thinkingBlock.thinking
        case .toolCall(let toolCall):
            let argsString: String
            if let data = try? JSONSerialization.data(withJSONObject: toolCall.arguments.mapValues { $0.value }, options: []), let str = String(data: data, encoding: .utf8) {
                argsString = str
            } else {
                argsString = "{}"
            }
            return "\(toolCall.name):\(argsString)"
        case .image: return ""
        }
    }.joined(separator: "\n")
}

private func splitStringByTokenSize(_ text: String, minTokenSize: Int, maxTokenSize: Int) -> [String] {
    var chunks: [String] = []
    var index = text.startIndex
    while index < text.endIndex {
        let tokenSize = Int.random(in: minTokenSize...maxTokenSize)
        let charSize = max(1, tokenSize * 4)
        let end = text.index(index, offsetBy: charSize, limitedBy: text.endIndex) ?? text.endIndex
        chunks.append(String(text[index..<end]))
        index = end
    }
    return chunks.isEmpty ? [""] : chunks
}

private func scheduleFauxChunk(_ chunk: String, tokensPerSecond: Double?) async {
    guard let tps = tokensPerSecond, tps > 0 else { return }
    let delaySec = Double(estimateFauxTokens(chunk)) / tps
    if delaySec > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
    }
}

private func streamFauxWithDeltas(
    stream: AssistantMessageEventStream,
    message: AssistantMessage,
    registration: FauxProviderRegistration,
    signal: CancellationToken?,
    finalize: (@Sendable (AssistantMessage) -> AssistantMessage)? = nil
) async {
    var message = message
    message.content = message.content.map { block in
        guard case .toolCall(var call) = block else { return block }
        if call.argumentsJSON == nil { call.argumentsJSON = toolArgumentsToOrderedJSON(call.arguments) }
        call.arguments = toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON)
        return .toolCall(call)
    }
    let (minTokenSize, maxTokenSize) = registration.tokenSizes()
    let tokensPerSecond = registration.tokensPerSecondValue

    var partial = AssistantMessage(
        content: [],
        api: message.api,
        provider: message.provider,
        model: message.model,
        responseModel: message.responseModel,
        responseId: message.responseId,
        usage: message.usage,
        stopReason: message.stopReason,
        errorMessage: message.errorMessage,
        timestamp: message.timestamp,
        deferred: message.deferred,
        rawStopReason: message.rawStopReason,
        diagnostics: message.diagnostics,
        durationMs: message.durationMs
    )

    if signal?.isCancelled == true {
        partial.stopReason = .aborted
        partial.errorMessage = "Request was aborted"
        stream.push(.error(reason: .aborted, error: partial))
        stream.end()
        return
    }

    stream.push(.start(partial: partial))

    for (index, block) in message.content.enumerated() {
        if signal?.isCancelled == true {
            partial.stopReason = .aborted
            partial.errorMessage = "Request was aborted"
            stream.push(.error(reason: .aborted, error: partial))
            stream.end()
            return
        }
        switch block {
        case .thinking(let thinkingContent):
            partial.content.append(.thinking(ThinkingContent(thinking: "")))
            stream.push(.thinkingStart(contentIndex: index, partial: partial))
            for chunk in splitStringByTokenSize(thinkingContent.thinking, minTokenSize: minTokenSize, maxTokenSize: maxTokenSize) {
                await scheduleFauxChunk(chunk, tokensPerSecond: tokensPerSecond)
                if signal?.isCancelled == true {
                    partial.stopReason = .aborted
                    partial.errorMessage = "Request was aborted"
                    stream.push(.error(reason: .aborted, error: partial))
                    stream.end()
                    return
                }
                if case .thinking(var existing) = partial.content[index] {
                    existing.thinking += chunk
                    partial.content[index] = .thinking(existing)
                }
                stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: partial))
        case .text(let textContent):
            partial.content.append(.text(TextContent(text: "")))
            stream.push(.textStart(contentIndex: index, partial: partial))
            for chunk in splitStringByTokenSize(textContent.text, minTokenSize: minTokenSize, maxTokenSize: maxTokenSize) {
                await scheduleFauxChunk(chunk, tokensPerSecond: tokensPerSecond)
                if signal?.isCancelled == true {
                    partial.stopReason = .aborted
                    partial.errorMessage = "Request was aborted"
                    stream.push(.error(reason: .aborted, error: partial))
                    stream.end()
                    return
                }
                if case .text(var existing) = partial.content[index] {
                    existing.text += chunk
                    partial.content[index] = .text(existing)
                }
                stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: partial))
        case .toolCall(let toolCall):
            partial.content.append(.toolCall(ToolCall(id: toolCall.id, name: toolCall.name, arguments: [:])))
            stream.push(.toolCallStart(contentIndex: index, partial: partial))
            let argsJSON = toolArgumentsToOrderedJSON(toolCall.arguments, argumentsJSON: toolCall.argumentsJSON).serialized()
            for chunk in splitStringByTokenSize(argsJSON, minTokenSize: minTokenSize, maxTokenSize: maxTokenSize) {
                await scheduleFauxChunk(chunk, tokensPerSecond: tokensPerSecond)
                if signal?.isCancelled == true {
                    partial.stopReason = .aborted
                    partial.errorMessage = "Request was aborted"
                    stream.push(.error(reason: .aborted, error: partial))
                    stream.end()
                    return
                }
                stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
            }
            if case .toolCall(var existing) = partial.content[index] {
                existing.arguments = toolCall.arguments
                existing.argumentsJSON = toolCall.argumentsJSON ?? parseToolArgumentsSource(argsJSON)
                partial.content[index] = .toolCall(existing)
            }
            if case .toolCall(let finalCall) = partial.content[index] {
                stream.push(.toolCallEnd(contentIndex: index, toolCall: finalCall, partial: partial))
            }
        case .image:
            continue
        }
    }

    if message.stopReason == .pending {
        var error = message
        error.stopReason = .error
        error.errorMessage = error.errorMessage ?? "Faux stream ended without a stop reason"
        error = finalize?(error) ?? error
        stream.push(.error(reason: .error, error: error))
        stream.end()
        return
    }
    message = finalize?(message) ?? message
    if message.stopReason == .error || message.stopReason == .aborted {
        stream.push(.error(reason: message.stopReason, error: message))
        stream.end()
        return
    }
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end()
}

public func fauxText(_ text: String) -> ContentBlock {
    .text(TextContent(text: text))
}

public func fauxThinking(_ text: String) -> ContentBlock {
    .thinking(ThinkingContent(thinking: text))
}

public func fauxToolCall(name: String, arguments: [String: AnyCodable], id: String? = nil) -> ContentBlock {
    let resolvedId = id ?? "tool:\(Int(Date().timeIntervalSince1970 * 1000)):\(UUID().uuidString.prefix(8))"
    return .toolCall(ToolCall(id: resolvedId, name: name, arguments: arguments))
}

public func fauxAssistantMessage(
    content: [ContentBlock],
    stopReason: StopReason = .stop,
    errorMessage: String? = nil,
    responseId: String? = nil,
    deferred: DeferredHandle? = nil,
    timestamp: Int64? = nil
) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAICompletions,
        provider: "faux",
        model: "faux-1",
        responseId: responseId,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason,
        errorMessage: errorMessage,
        timestamp: timestamp ?? Int64(Date().timeIntervalSince1970 * 1000),
        deferred: deferred
    )
}
