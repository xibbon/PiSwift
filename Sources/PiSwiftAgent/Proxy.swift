import Foundation
import PiSwiftAI

public struct ProxyStreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoning: ReasoningEffort?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var authToken: String
    public var proxyUrl: String

    // v0.68.1: preserve the proxy-safe serializable subset of stream options when forwarding
    // to the remote streamSimple. These reach the remote unchanged so cache affinity, transport
    // choice, retry behavior, header overrides, metadata tagging, and thinking budgets all
    // continue to work end-to-end through the proxy.
    public var sessionId: String?
    public var transport: Transport?
    public var cacheRetention: CacheRetention?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    public var headers: ProviderHeaders?
    public var metadata: [String: AnyCodable]?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoning: ReasoningEffort? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        authToken: String,
        proxyUrl: String,
        sessionId: String? = nil,
        transport: Transport? = nil,
        cacheRetention: CacheRetention? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        headers: ProviderHeaders? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.signal = signal
        self.apiKey = apiKey
        self.authToken = authToken
        self.proxyUrl = proxyUrl
        self.sessionId = sessionId
        self.transport = transport
        self.cacheRetention = cacheRetention
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.headers = headers
        self.metadata = metadata
    }
}

public func streamProxy(model: Model, context: Context, options: ProxyStreamOptions, session: URLSession = .shared) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()

    Task {
        var partial = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )

        var toolCallPartials: [Int: String] = [:]

        do {
            let url = URL(string: "\(options.proxyUrl)/api/stream")
            guard let url else {
                throw ProxyStreamError.invalidUrl
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("Bearer \(options.authToken)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")

            request.httpBody = try encodeProxyRequestPayload(model: model, context: context, options: options)

            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProxyStreamError.invalidResponse
            }
            guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
                throw ProxyStreamError.httpError(httpResponse.statusCode)
            }

            var sawTerminalEvent = false
            for try await line in bytes.lines {
                if options.signal?.isCancelled == true {
                    throw ProxyStreamError.aborted
                }
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty else { continue }
                let eventData = Data(payload.utf8)
                let event = try JSONDecoder().decode(ProxyAssistantMessageEvent.self, from: eventData)
                let fields = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] ?? [:]
                if let level = fields["providerThinkingLevel"] as? String { partial.providerThinkingLevel = level }
                if let endTurn = fields["endTurn"] as? Bool { partial.endTurn = endTurn }
                if let messageEvent = try processProxyEvent(event, partial: &partial, toolCallPartials: &toolCallPartials) {
                    switch messageEvent {
                    case .done, .error: sawTerminalEvent = true
                    default: break
                    }
                    stream.push(messageEvent)
                }
            }

            if options.signal?.isCancelled == true {
                throw ProxyStreamError.aborted
            }

            if !sawTerminalEvent {
                throw ProxyStreamError.invalidEventPayload("Connection closed by proxy server before the response completed")
            }
            stream.end()
        } catch {
            let reason: StopReason
            if options.signal?.isCancelled == true {
                reason = .aborted
            } else if case ProxyStreamError.aborted = error {
                reason = .aborted
            } else {
                reason = .error
            }
            partial.stopReason = reason
            partial.errorMessage = error.localizedDescription
            stream.push(.error(reason: reason, error: partial))
            stream.end()
        }
    }

    return stream
}

func encodeProxyRequestPayload(model: Model, context: Context, options: ProxyStreamOptions) throws -> Data {
    let body = ProxyRequestPayload(
        model: ProxyModelPayload(model),
        context: ProxyContextPayload(context),
        options: ProxyRequestOptions(
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            reasoning: options.reasoning,
            sessionId: options.sessionId,
            transport: options.transport,
            cacheRetention: options.cacheRetention,
            thinkingBudgets: options.thinkingBudgets,
            maxRetryDelayMs: options.maxRetryDelayMs,
            headers: options.headers,
            metadata: options.metadata
        )
    )
    return try JSONEncoder().encode(body)
}

private func processProxyEvent(
    _ proxyEvent: ProxyAssistantMessageEvent,
    partial: inout AssistantMessage,
    toolCallPartials: inout [Int: String]
) throws -> AssistantMessageEvent? {
    switch proxyEvent {
    case .start:
        return .start(partial: partial)

    case .textStart(let index):
        setContentBlock(&partial.content, index: index, block: .text(TextContent(text: "")))
        return .textStart(contentIndex: index, partial: partial)

    case .textDelta(let index, let delta):
        guard case .text(var textContent) = contentBlock(partial.content, index: index) else {
            throw ProxyStreamError.invalidEventPayload("Received text_delta for non-text content")
        }
        textContent.text += delta
        setContentBlock(&partial.content, index: index, block: .text(textContent))
        return .textDelta(contentIndex: index, delta: delta, partial: partial)

    case .textEnd(let index, let signature):
        guard case .text(var textContent) = contentBlock(partial.content, index: index) else {
            throw ProxyStreamError.invalidEventPayload("Received text_end for non-text content")
        }
        textContent.textSignature = signature
        setContentBlock(&partial.content, index: index, block: .text(textContent))
        return .textEnd(contentIndex: index, content: textContent.text, partial: partial)

    case .thinkingStart(let index):
        setContentBlock(&partial.content, index: index, block: .thinking(ThinkingContent(thinking: "")))
        return .thinkingStart(contentIndex: index, partial: partial)

    case .thinkingDelta(let index, let delta):
        guard case .thinking(var thinkingContent) = contentBlock(partial.content, index: index) else {
            throw ProxyStreamError.invalidEventPayload("Received thinking_delta for non-thinking content")
        }
        thinkingContent.thinking += delta
        setContentBlock(&partial.content, index: index, block: .thinking(thinkingContent))
        return .thinkingDelta(contentIndex: index, delta: delta, partial: partial)

    case .thinkingEnd(let index, let signature):
        guard case .thinking(var thinkingContent) = contentBlock(partial.content, index: index) else {
            throw ProxyStreamError.invalidEventPayload("Received thinking_end for non-thinking content")
        }
        thinkingContent.thinkingSignature = signature
        setContentBlock(&partial.content, index: index, block: .thinking(thinkingContent))
        return .thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: partial)

    case .toolCallStart(let index, let id, let toolName, let namespace):
        toolCallPartials[index] = ""
        let toolCall = ToolCall(id: id, name: toolName, arguments: [:], namespace: namespace)
        setContentBlock(&partial.content, index: index, block: .toolCall(toolCall))
        return .toolCallStart(contentIndex: index, partial: partial)

    case .toolCallDelta(let index, let delta):
        guard case .toolCall(var toolCall) = contentBlock(partial.content, index: index) else {
            throw ProxyStreamError.invalidEventPayload("Received toolcall_delta for non-toolCall content")
        }
        let existing = toolCallPartials[index] ?? ""
        let updated = existing + delta
        toolCallPartials[index] = updated
        toolCall.arguments = parseStreamingJSON(updated)
        setContentBlock(&partial.content, index: index, block: .toolCall(toolCall))
        return .toolCallDelta(contentIndex: index, delta: delta, partial: partial)

    case .toolCallEnd(let index, let finalToolCall):
        toolCallPartials.removeValue(forKey: index)
        guard case .toolCall(let existing) = contentBlock(partial.content, index: index) else {
            return nil
        }
        var toolCall = finalToolCall ?? existing
        toolCall.namespace = toolCall.namespace ?? existing.namespace
        toolCall.thoughtSignature = toolCall.thoughtSignature ?? existing.thoughtSignature
        setContentBlock(&partial.content, index: index, block: .toolCall(toolCall))
        return .toolCallEnd(contentIndex: index, toolCall: toolCall, partial: partial)

    case .done(let reason, let usage):
        partial.stopReason = reason
        partial.usage = usage
        return .done(reason: reason, message: partial)

    case .error(let reason, let errorMessage, let usage):
        partial.stopReason = reason
        partial.errorMessage = errorMessage
        partial.usage = usage
        return .error(reason: reason, error: partial)
    }
}

private func contentBlock(_ content: [ContentBlock], index: Int) -> ContentBlock? {
    guard index >= 0, index < content.count else { return nil }
    return content[index]
}

private func setContentBlock(_ content: inout [ContentBlock], index: Int, block: ContentBlock) {
    if index < content.count {
        content[index] = block
        return
    }
    if index > content.count {
        let paddingCount = index - content.count
        for _ in 0..<paddingCount {
            content.append(.text(TextContent(text: "")))
        }
    }
    content.append(block)
}

private struct ProxyRequestPayload: Encodable {
    let model: ProxyModelPayload
    let context: ProxyContextPayload
    let options: ProxyRequestOptions
}

private struct ProxyRequestOptions: Encodable {
    let temperature: Double?
    let maxTokens: Int?
    let reasoning: ReasoningEffort?
    let sessionId: String?
    let transport: Transport?
    let cacheRetention: CacheRetention?
    let thinkingBudgets: ThinkingBudgets?
    let maxRetryDelayMs: Int?
    let headers: ProviderHeaders?
    let metadata: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case temperature
        case maxTokens
        case reasoning
        case sessionId
        case transport
        case cacheRetention
        case thinkingBudgets
        case maxRetryDelayMs
        case headers
        case metadata
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        if let reasoning {
            try container.encode(reasoning.rawValue, forKey: .reasoning)
        }
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        if let transport {
            try container.encode(transport.rawValue, forKey: .transport)
        }
        if let cacheRetention {
            try container.encode(cacheRetention.rawValue, forKey: .cacheRetention)
        }
        if let thinkingBudgets {
            // Serialize as { "off": 0, "low": ..., ... } so the remote can rehydrate.
            let serialized = Dictionary(uniqueKeysWithValues: thinkingBudgets.map { ($0.key.rawValue, $0.value) })
            try container.encode(serialized, forKey: .thinkingBudgets)
        }
        try container.encodeIfPresent(maxRetryDelayMs, forKey: .maxRetryDelayMs)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

private struct ProxyModelPayload: Encodable {
    let id: String
    let name: String
    let api: String
    let provider: String
    let baseUrl: String
    let reasoning: Bool
    let input: [String]
    let cost: ProxyModelCost
    let contextWindow: Int
    let maxTokens: Int
    let headers: ProviderHeaders?

    init(_ model: Model) {
        self.id = model.id
        self.name = model.name
        self.api = model.api.rawValue
        self.provider = model.provider
        self.baseUrl = model.baseUrl
        self.reasoning = model.reasoning
        self.input = model.input.map { $0.rawValue }
        self.cost = ProxyModelCost(model.cost)
        self.contextWindow = model.contextWindow
        self.maxTokens = model.maxTokens
        self.headers = model.headers
    }
}

private struct ProxyModelCost: Encodable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    init(_ cost: ModelCost) {
        self.input = cost.input
        self.output = cost.output
        self.cacheRead = cost.cacheRead
        self.cacheWrite = cost.cacheWrite
    }
}

private struct ProxyContextPayload: Encodable {
    let systemPrompt: String?
    let messages: [ProxyMessagePayload]
    let tools: [ProxyToolPayload]?

    init(_ context: Context) {
        self.systemPrompt = context.systemPrompt
        self.messages = context.messages.map(ProxyMessagePayload.init)
        self.tools = context.tools?.map(ProxyToolPayload.init)
    }
}

private struct ProxyToolPayload: Encodable {
    let name: String
    let description: String
    let parameters: [String: AnyCodable]

    init(_ tool: AITool) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
    }
}

private struct ProxyMessagePayload: Encodable {
    let message: Message

    init(_ message: Message) {
        self.message = message
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch message {
        case .user(let user):
            try container.encode("user", forKey: .role)
            try container.encode(user.timestamp, forKey: .timestamp)
            try encodeUserContent(user.content, into: &container)
        case .assistant(let assistant):
            try AnyCodable(assistantMessageToJSONObject(assistant)).encode(to: encoder)
        case .toolResult(let toolResult):
            try container.encode("toolResult", forKey: .role)
            try container.encode(toolResult.timestamp, forKey: .timestamp)
            try container.encode(toolResult.toolCallId, forKey: .toolCallId)
            try container.encode(toolResult.toolName, forKey: .toolName)
            try container.encode(toolResult.isError, forKey: .isError)
            try container.encode(toolResult.content.map(ProxyContentBlockPayload.init), forKey: .content)
            try container.encodeIfPresent(toolResult.details, forKey: .details)
        }
    }

    private func encodeUserContent(_ content: UserContent, into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch content {
        case .text(let text):
            try container.encode(text, forKey: .content)
        case .blocks(let blocks):
            try container.encode(blocks.map(ProxyContentBlockPayload.init), forKey: .content)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
        case api
        case provider
        case model
        case usage
        case stopReason
        case errorMessage
        case toolCallId
        case toolName
        case isError
        case details
    }
}

private struct ProxyContentBlockPayload: Encodable {
    let block: ContentBlock

    init(_ block: ContentBlock) {
        self.block = block
    }

    // Delegate to the canonical content-block codec so the proxy wire format can't drift from
    // session persistence. `AnyCodable` re-encodes the JSON object identically.
    func encode(to encoder: Encoder) throws {
        try AnyCodable(contentBlockToJSONObject(block)).encode(to: encoder)
    }
}

private struct ProxyUsagePayload: Encodable {
    let usage: Usage

    init(_ usage: Usage) {
        self.usage = usage
    }

    // Delegate to the canonical usage codec (single source of truth in PiSwiftAI).
    func encode(to encoder: Encoder) throws {
        try AnyCodable(usageToJSONObject(usage)).encode(to: encoder)
    }
}

private enum ProxyAssistantMessageEvent: Decodable {
    case start
    case textStart(contentIndex: Int)
    case textDelta(contentIndex: Int, delta: String)
    case textEnd(contentIndex: Int, contentSignature: String?)
    case thinkingStart(contentIndex: Int)
    case thinkingDelta(contentIndex: Int, delta: String)
    case thinkingEnd(contentIndex: Int, contentSignature: String?)
    case toolCallStart(contentIndex: Int, id: String, toolName: String, namespace: String?)
    case toolCallDelta(contentIndex: Int, delta: String)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall?)
    case done(reason: StopReason, usage: Usage)
    case error(reason: StopReason, errorMessage: String?, usage: Usage)

    private enum CodingKeys: String, CodingKey {
        case type
        case contentIndex
        case delta
        case contentSignature
        case namespace
        case id
        case toolName
        case toolCall
        case reason
        case usage
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "start":
            self = .start
        case "text_start":
            self = .textStart(contentIndex: try container.decode(Int.self, forKey: .contentIndex))
        case "text_delta":
            self = .textDelta(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case "text_end":
            self = .textEnd(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                contentSignature: try container.decodeIfPresent(String.self, forKey: .contentSignature)
            )
        case "thinking_start":
            self = .thinkingStart(contentIndex: try container.decode(Int.self, forKey: .contentIndex))
        case "thinking_delta":
            self = .thinkingDelta(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case "thinking_end":
            self = .thinkingEnd(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                contentSignature: try container.decodeIfPresent(String.self, forKey: .contentSignature)
            )
        case "toolcall_start":
            self = .toolCallStart(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                id: try container.decode(String.self, forKey: .id),
                toolName: try container.decode(String.self, forKey: .toolName),
                namespace: try container.decodeIfPresent(String.self, forKey: .namespace)
            )
        case "toolcall_delta":
            self = .toolCallDelta(
                contentIndex: try container.decode(Int.self, forKey: .contentIndex),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case "toolcall_end":
            self = .toolCallEnd(contentIndex: try container.decode(Int.self, forKey: .contentIndex), toolCall: try container.decodeIfPresent(ProxyFinalToolCall.self, forKey: .toolCall)?.value)
        case "done":
            self = .done(
                reason: try Self.decodeStopReason(from: container),
                usage: try Self.decodeUsage(from: container)
            )
        case "error":
            self = .error(
                reason: try Self.decodeStopReason(from: container),
                errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
                usage: try Self.decodeUsage(from: container)
            )
        default:
            throw ProxyStreamError.invalidEventType(type)
        }
    }

    private static func decodeStopReason(from container: KeyedDecodingContainer<CodingKeys>) throws -> StopReason {
        let reason = try container.decode(String.self, forKey: .reason)
        return StopReason(rawValue: reason) ?? .stop
    }

    private static func decodeUsage(from container: KeyedDecodingContainer<CodingKeys>) throws -> Usage {
        let payload = try container.decode(ProxyUsage.self, forKey: .usage)
        return payload.toUsage()
    }
}

private struct ProxyFinalToolCall: Decodable {
    let value: ToolCall
    init(from decoder: Decoder) throws {
        let payload = try AnyCodable(from: decoder)
        guard let dict = payload.value as? [String: Any],
              case .toolCall(let call) = contentBlockFromJSONObject(dict) else {
            throw ProxyStreamError.invalidEventPayload("Invalid final tool call")
        }
        value = call
    }
}

private struct ProxyUsageCost: Decodable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
    let total: Double
}

private struct ProxyUsage: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let cost: ProxyUsageCost

    func toUsage() -> Usage {
        Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: totalTokens,
            cost: UsageCost(
                input: cost.input,
                output: cost.output,
                cacheRead: cost.cacheRead,
                cacheWrite: cost.cacheWrite,
                total: cost.total
            )
        )
    }
}

private enum ProxyStreamError: Error, LocalizedError, Equatable {
    case invalidUrl
    case invalidResponse
    case httpError(Int)
    case invalidEventType(String)
    case invalidEventPayload(String)
    case aborted

    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return "Invalid proxy URL"
        case .invalidResponse:
            return "Invalid proxy response"
        case .httpError(let status):
            return "Proxy error: HTTP \(status)"
        case .invalidEventType(let type):
            return "Invalid proxy event type: \(type)"
        case .invalidEventPayload(let message):
            return message
        case .aborted:
            return "Request aborted"
        }
    }
}
