import Foundation
import PiSwiftAI

/// Stream function used by the agent loop.
///
/// Contract: must not throw or return a rejected promise for request/model/runtime failures.
/// Must return an `AssistantMessageEventStream`. Failures must be encoded in the returned stream
/// via protocol events and a final `AssistantMessage` with `stopReason` `.error` or `.aborted`.
public typealias StreamFn = @Sendable (Model, Context, SimpleStreamOptions) async throws -> AssistantMessageEventStream

/// Callback for emitting agent events. Supports both sync and async handlers.
public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void

/// Configuration for how tool calls from a single assistant message are executed.
///
/// - `sequential`: each tool call is prepared, executed, and finalized before the next one starts.
/// - `parallel`: tool calls are prepared sequentially, then allowed tools execute concurrently.
///   Final tool results are still emitted in assistant source order.
public enum ToolExecutionMode: String, Sendable {
    case sequential
    case parallel
}

/// A single tool call content block emitted by an assistant message.
public typealias AgentToolCall = ToolCall

/// Result returned from `beforeToolCall`.
///
/// Returning `BeforeToolCallResult(block: true)` prevents the tool from executing.
/// The loop emits an error tool result instead. `reason` becomes the text shown in that error result.
public struct BeforeToolCallResult: Sendable {
    public var block: Bool?
    public var reason: String?

    public init(block: Bool? = nil, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

/// Partial override returned from `afterToolCall`.
///
/// Merge semantics are field-by-field:
/// - `content`: if provided, replaces the tool result content array in full
/// - `details`: if provided, replaces the tool result details value in full
/// - `isError`: if provided, replaces the tool result error flag
///
/// Omitted fields keep the original executed tool result values.
public struct AfterToolCallResult: Sendable {
    public var content: [ContentBlock]?
    public var details: AnyCodable?
    public var isError: Bool?

    public init(content: [ContentBlock]? = nil, details: AnyCodable? = nil, isError: Bool? = nil) {
        self.content = content
        self.details = details
        self.isError = isError
    }
}

/// Context passed to `beforeToolCall`.
public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: AgentToolCall
    public var args: [String: AnyCodable]
    public var context: AgentContext

    public init(assistantMessage: AssistantMessage, toolCall: AgentToolCall, args: [String: AnyCodable], context: AgentContext) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.args = args
        self.context = context
    }
}

/// Context passed to `afterToolCall`.
public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: AgentToolCall
    public var args: [String: AnyCodable]
    public var result: AgentToolResult
    public var isError: Bool
    public var context: AgentContext

    public init(assistantMessage: AssistantMessage, toolCall: AgentToolCall, args: [String: AnyCodable], result: AgentToolResult, isError: Bool, context: AgentContext) {
        self.assistantMessage = assistantMessage
        self.toolCall = toolCall
        self.args = args
        self.result = result
        self.isError = isError
        self.context = context
    }
}

public typealias BeforeToolCallFn = @Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?
public typealias AfterToolCallFn = @Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?
public typealias OnPayloadFn = PayloadHandler

public enum ThinkingLevel: String, Sendable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public struct AgentCustomMessage: Sendable {
    public var role: String
    public var payload: AnyCodable?
    public var timestamp: Int64

    public init(role: String, payload: AnyCodable? = nil, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.role = role
        self.payload = payload
        self.timestamp = timestamp
    }
}

public enum AgentMessage: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(AgentCustomMessage)

    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        case .custom(let custom):
            return custom.role
        }
    }

    public var timestamp: Int64 {
        switch self {
        case .user(let message):
            return message.timestamp
        case .assistant(let message):
            return message.timestamp
        case .toolResult(let message):
            return message.timestamp
        case .custom(let message):
            return message.timestamp
        }
    }

    public var asMessage: Message? {
        switch self {
        case .user(let message):
            return .user(message)
        case .assistant(let message):
            return .assistant(message)
        case .toolResult(let message):
            return .toolResult(message)
        case .custom:
            return nil
        }
    }

    public init(_ message: Message) {
        switch message {
        case .user(let msg):
            self = .user(msg)
        case .assistant(let msg):
            self = .assistant(msg)
        case .toolResult(let msg):
            self = .toolResult(msg)
        }
    }
}

public struct AgentToolResult: Sendable {
    public var content: [ContentBlock]
    public var details: AnyCodable?

    public init(content: [ContentBlock], details: AnyCodable? = nil) {
        self.content = content
        self.details = details
    }
}

public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void
public typealias AgentToolExecute = @Sendable (
    _ toolCallId: String,
    _ params: [String: AnyCodable],
    _ signal: CancellationToken?,
    _ onUpdate: AgentToolUpdateCallback?
) async throws -> AgentToolResult

public struct AgentTool: Sendable {
    public var label: String
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var execute: AgentToolExecute

    public init(
        label: String,
        name: String,
        description: String,
        parameters: [String: AnyCodable],
        execute: @escaping AgentToolExecute
    ) {
        self.label = label
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    public var aiTool: AITool {
        AITool(name: name, description: description, parameters: parameters)
    }
}

public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [AgentMessage]
    public var tools: [AgentTool]?

    public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentTool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [AgentMessage])
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    case messageStart(message: AgentMessage)
    case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: AgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: [String: AnyCodable])
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: [String: AnyCodable], partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}

public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoning: ReasoningEffort?
    public var transport: Transport?
    public var apiKey: String?
    public var sessionId: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    public var onPayload: OnPayloadFn?

    /// Tool execution mode. Default: `.parallel`
    public var toolExecution: ToolExecutionMode?

    /// Called before a tool is executed, after arguments have been validated.
    /// Return `BeforeToolCallResult(block: true)` to prevent execution.
    public var beforeToolCall: BeforeToolCallFn?

    /// Called after a tool finishes executing, before final tool events are emitted.
    /// Return an `AfterToolCallResult` to override parts of the executed tool result.
    public var afterToolCall: AfterToolCallFn?

    /// Converts `[AgentMessage]` to LLM-compatible `[Message]` before each LLM call.
    ///
    /// Contract: must not throw or reject. Return a safe fallback value instead.
    public var convertToLlm: @Sendable ([AgentMessage]) async throws -> [Message]

    /// Optional transform applied to the context before `convertToLlm`.
    ///
    /// Contract: must not throw or reject. Return the original messages or a safe fallback.
    public var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?

    /// Resolves an API key dynamically for each LLM call.
    ///
    /// Contract: must not throw or reject. Return nil when no key is available.
    public var getApiKey: (@Sendable (String) async -> String?)?

    /// Returns steering messages to inject into the conversation mid-run.
    ///
    /// Called after the current assistant turn finishes executing its tool calls.
    /// Tool calls from the current assistant message are not skipped.
    ///
    /// Contract: must not throw or reject. Return `[]` when no steering messages are available.
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?

    /// Returns follow-up messages to process after the agent would otherwise stop.
    ///
    /// Contract: must not throw or reject. Return `[]` when no follow-up messages are available.
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?

    public init(
        model: Model,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoning: ReasoningEffort? = nil,
        transport: Transport? = nil,
        apiKey: String? = nil,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        onPayload: OnPayloadFn? = nil,
        toolExecution: ToolExecutionMode? = nil,
        beforeToolCall: BeforeToolCallFn? = nil,
        afterToolCall: AfterToolCallFn? = nil,
        convertToLlm: @escaping @Sendable ([AgentMessage]) async throws -> [Message],
        transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.transport = transport
        self.apiKey = apiKey
        self.sessionId = sessionId
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.onPayload = onPayload
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.getApiKey = getApiKey
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
    }
}

public enum AgentSteeringMode: String, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

public enum AgentFollowUpMode: String, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [AgentMessage]
    public var isStreaming: Bool
    public var streamMessage: AgentMessage?
    public var pendingToolCalls: Set<String>
    public var error: String?

    public init(
        systemPrompt: String = "",
        model: Model = getModel(provider: .openai, modelId: "gpt-4o-mini"),
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [AgentMessage] = [],
        isStreaming: Bool = false,
        streamMessage: AgentMessage? = nil,
        pendingToolCalls: Set<String> = [],
        error: String? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamMessage = streamMessage
        self.pendingToolCalls = pendingToolCalls
        self.error = error
    }
}
