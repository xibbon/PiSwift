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
}

public typealias FauxResponseFactory = @Sendable (Context, SimpleStreamOptions?, FauxState, Model) async -> AssistantMessage

public enum FauxResponseStep: Sendable {
    case message(AssistantMessage)
    case factory(FauxResponseFactory)
}

public struct FauxRegistrationOptions: Sendable {
    public var api: String?
    public var provider: String?
    public var models: [FauxModelDefinition]
    public var tokensPerSecond: Double?
    public var minTokenSize: Int
    public var maxTokenSize: Int

    public init(
        api: String? = nil,
        provider: String? = nil,
        models: [FauxModelDefinition] = [],
        tokensPerSecond: Double? = nil,
        minTokenSize: Int = 3,
        maxTokenSize: Int = 5
    ) {
        self.api = api
        self.provider = provider
        self.models = models
        self.tokensPerSecond = tokensPerSecond
        self.minTokenSize = minTokenSize
        self.maxTokenSize = maxTokenSize
    }
}

/// SAFETY: mutable scripted-response and usage state is serialized by `lock`;
/// immutable registration metadata is value typed.
public final class FauxProviderRegistration: @unchecked Sendable {
    public let api: Api
    public let models: [Model]
    public let sourceId: String

    private let lock = NSLock()
    private var pendingResponses: [FauxResponseStep] = []
    private var stateBox: FauxState = FauxState()
    private var promptCache: [String: String] = [:]
    private let minTokenSize: Int
    private let maxTokenSize: Int
    private let tokensPerSecond: Double?
    private let provider: String

    init(api: Api, provider: String, models: [Model], sourceId: String, minTokenSize: Int, maxTokenSize: Int, tokensPerSecond: Double?) {
        self.api = api
        self.provider = provider
        self.models = models
        self.sourceId = sourceId
        self.minTokenSize = minTokenSize
        self.maxTokenSize = maxTokenSize
        self.tokensPerSecond = tokensPerSecond
    }

    public func setResponses(_ responses: [FauxResponseStep]) {
        lock.lock(); defer { lock.unlock() }
        pendingResponses = responses
    }

    public func appendResponses(_ responses: [FauxResponseStep]) {
        lock.lock(); defer { lock.unlock() }
        pendingResponses.append(contentsOf: responses)
    }

    public func pendingResponseCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingResponses.count
    }

    public func state() -> FauxState {
        lock.lock(); defer { lock.unlock() }
        return stateBox
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
        lock.lock(); defer { lock.unlock() }
        guard !pendingResponses.isEmpty else { return nil }
        stateBox.callCount += 1
        return pendingResponses.removeFirst()
    }

    fileprivate func currentState() -> FauxState {
        lock.lock(); defer { lock.unlock() }
        return stateBox
    }

    fileprivate func cachedPrompt(forSession session: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return promptCache[session]
    }

    fileprivate func storePrompt(_ prompt: String, forSession session: String) {
        lock.lock(); defer { lock.unlock() }
        promptCache[session] = prompt
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
        tokensPerSecond: options.tokensPerSecond
    )

    registerApiProvider(ApiProvider(
        api: api,
        stream: { model, context, options in
            fauxStream(model: model, context: context, registration: registration, simpleOptions: options.flatMap(toSimpleOptions))
        },
        streamSimple: { model, context, options in
            fauxStream(model: model, context: context, registration: registration, simpleOptions: options)
        }
    ), sourceId: sourceId)

    return registration
}

private func toSimpleOptions(_ options: StreamOptions) -> SimpleStreamOptions {
    SimpleStreamOptions(
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

private func fauxStream(
    model: Model,
    context: Context,
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
            let state = registration.currentState()
            let resolved: AssistantMessage
            switch step {
            case .message(let message): resolved = message
            case .factory(let factory): resolved = await factory(context, simpleOptions, state, model)
            }
            var message = cloneFauxMessage(resolved, api: registration.api, provider: registration.providerName, modelId: model.id)
            message = withFauxUsageEstimate(message: message, context: context, options: simpleOptions, registration: registration)
            await streamFauxWithDeltas(stream: outer, message: message, registration: registration, signal: simpleOptions?.signal)
        }
    }
    return outer
}

private func cloneFauxMessage(_ message: AssistantMessage, api: Api, provider: String, modelId: String) -> AssistantMessage {
    AssistantMessage(
        content: message.content,
        api: api,
        provider: provider,
        model: modelId,
        responseId: message.responseId,
        usage: message.usage,
        stopReason: message.stopReason,
        errorMessage: message.errorMessage,
        timestamp: message.timestamp,
        deferred: message.deferred,
        rawStopReason: message.rawStopReason
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
    context: Context,
    options: SimpleStreamOptions?,
    registration: FauxProviderRegistration
) -> AssistantMessage {
    let promptText = serializeFauxContext(context)
    let promptTokens = estimateFauxTokens(promptText)
    let outputTokens = estimateFauxTokens(assistantContentToText(message.content))
    var input = promptTokens
    var cacheRead = 0
    var cacheWrite = 0
    let sessionId = options?.sessionId
    let cacheEnabled = (options?.cacheRetention ?? .none) != .none
    if let sessionId, cacheEnabled {
        if let previous = registration.cachedPrompt(forSession: sessionId) {
            let cachedChars = commonPrefixLength(previous, promptText)
            let head = String(previous.prefix(cachedChars))
            let tail = String(promptText.dropFirst(cachedChars))
            cacheRead = estimateFauxTokens(head)
            cacheWrite = estimateFauxTokens(tail)
            input = max(0, promptTokens - cacheRead)
        } else {
            cacheWrite = promptTokens
        }
        registration.storePrompt(promptText, forSession: sessionId)
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

private func serializeFauxContext(_ context: Context) -> String {
    var parts: [String] = []
    if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
        parts.append("system:\(systemPrompt)")
    }
    for message in context.messages {
        parts.append("\(message.role):\(messageToFauxText(message))")
    }
    if let tools = context.tools, !tools.isEmpty {
        if let data = try? JSONSerialization.data(withJSONObject: tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters.mapValues { $0.value },
            ] as [String: Any]
        }, options: []), let str = String(data: data, encoding: .utf8) {
            parts.append("tools:\(str)")
        }
    }
    return parts.joined(separator: "\n\n")
}

private func messageToFauxText(_ message: Message) -> String {
    switch message {
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
    signal: CancellationToken?
) async {
    let (minTokenSize, maxTokenSize) = registration.tokenSizes()
    let tokensPerSecond = registration.tokensPerSecondValue

    var partial = AssistantMessage(
        content: [],
        api: message.api,
        provider: message.provider,
        model: message.model,
        responseId: message.responseId,
        usage: message.usage,
        stopReason: message.stopReason,
        errorMessage: message.errorMessage,
        timestamp: message.timestamp,
        deferred: message.deferred,
        rawStopReason: message.rawStopReason
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
            let argsJSON: String = {
                if let data = try? JSONSerialization.data(withJSONObject: toolCall.arguments.mapValues { $0.value }, options: []), let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return "{}"
            }()
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
                partial.content[index] = .toolCall(existing)
            }
            stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: partial))
        case .image:
            continue
        }
    }

    if message.stopReason == .pending {
        var error = message
        error.stopReason = .error
        error.errorMessage = error.errorMessage ?? "Faux stream ended without a stop reason"
        stream.push(.error(reason: .error, error: error))
        stream.end()
        return
    }
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
    responseId: String? = nil
) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAICompletions,
        provider: "faux",
        model: "faux-1",
        responseId: responseId,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason,
        errorMessage: errorMessage
    )
}
