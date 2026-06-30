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
/// - `terminate`: if every finalized tool result in the current batch sets `terminate == true`,
///   the loop skips the automatic follow-up LLM turn after this batch (v0.69.0).
///
/// Omitted fields keep the original executed tool result values.
public struct AfterToolCallResult: Sendable {
    public var content: [ContentBlock]?
    public var details: AnyCodable?
    public var isError: Bool?
    public var terminate: Bool?

    public init(
        content: [ContentBlock]? = nil,
        details: AnyCodable? = nil,
        isError: Bool? = nil,
        terminate: Bool? = nil
    ) {
        self.content = content
        self.details = details
        self.isError = isError
        self.terminate = terminate
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
public typealias AfterToolCallFn = @Sendable (AfterToolCallContext, CancellationToken?) async throws -> AfterToolCallResult?
public typealias OnPayloadFn = PayloadHandler
public typealias ShouldStopAfterTurnFn = @Sendable () async -> Bool

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
    public var terminate: Bool?

    public init(content: [ContentBlock], details: AnyCodable? = nil, terminate: Bool? = nil) {
        self.content = content
        self.details = details
        self.terminate = terminate
    }
}

public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void
public typealias AgentToolExecute = @Sendable (
    _ toolCallId: String,
    _ params: [String: AnyCodable],
    _ signal: CancellationToken?,
    _ onUpdate: AgentToolUpdateCallback?
) async throws -> AgentToolResult

/// Optional preprocessor invoked before schema validation on raw tool-call arguments.
///
/// Use this for compatibility shims when tool argument shapes change across versions:
/// the hook can rewrite legacy payloads into the current shape before validation runs.
/// Throwing produces a tool-result error with the thrown error's localized description;
/// returning `nil` keeps the raw arguments unchanged.
public typealias AgentToolPrepareArguments = @Sendable (_ args: [String: AnyCodable]) async throws -> [String: AnyCodable]?

public struct AgentTool: Sendable {
    public var label: String
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var execute: AgentToolExecute
    public var prepareArguments: AgentToolPrepareArguments?

    public init(
        label: String,
        name: String,
        description: String,
        parameters: [String: AnyCodable],
        execute: @escaping AgentToolExecute,
        prepareArguments: AgentToolPrepareArguments? = nil
    ) {
        self.label = label
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
        self.prepareArguments = prepareArguments
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

    /// v0.67.6: invoked after the provider HTTP response is received and before the stream
    /// begins consuming. Forwarded as `SimpleStreamOptions.onResponse`. Use for header /
    /// status inspection (telemetry, after_provider_response extension hook, etc.).
    public var onResponse: ResponseHandler?

    /// v0.68.0: prompt cache retention preference. Forwarded to providers that support it
    /// (OpenAI Chat Completions / OpenAI Responses with `prompt_cache_retention: "24h"` for
    /// long retention; Anthropic Messages with `cache_control.ttl`).
    public var cacheRetention: CacheRetention?

    /// HTTP headers to include on every provider request (auth tokens, custom routing,
    /// instrumentation correlation IDs, etc.). Forwarded as `SimpleStreamOptions.headers`.
    public var headers: [String: String]?

    /// Provider-specific request metadata. Forwarded as `SimpleStreamOptions.metadata`.
    /// Anthropic uses this for `metadata.user_id`; Bedrock for cost-allocation tags; etc.
    public var metadata: [String: AnyCodable]?

    /// v0.70.1: provider SDK request timeout (ms). Forwarded as `SimpleStreamOptions.timeoutMs`
    /// so long-running local-LLM SSE streams don't hit the SDK default cap.
    public var timeoutMs: Int?

    /// WebSocket connect/open handshake timeout (ms). Forwarded as
    /// `SimpleStreamOptions.websocketConnectTimeoutMs`.
    public var websocketConnectTimeoutMs: Int?

    /// v0.70.1: provider SDK max retries. Forwarded as `SimpleStreamOptions.maxRetries`.
    public var maxRetries: Int?

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

    /// Resolves model-aware auth dynamically for each LLM call.
    ///
    /// Use this when a provider needs more than a provider-level token, such as
    /// per-model headers or token-derived base URLs.
    public var getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)?

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

    /// Returns whether the loop should stop after the current complete turn.
    ///
    /// Called after tool-call follow-up handling completes and before queued follow-up messages
    /// are fetched. Return `false` to continue normal steering/follow-up processing.
    public var shouldStopAfterTurn: ShouldStopAfterTurnFn?

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
        onResponse: ResponseHandler? = nil,
        cacheRetention: CacheRetention? = nil,
        headers: [String: String]? = nil,
        metadata: [String: AnyCodable]? = nil,
        timeoutMs: Int? = nil,
        websocketConnectTimeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        toolExecution: ToolExecutionMode? = nil,
        beforeToolCall: BeforeToolCallFn? = nil,
        afterToolCall: AfterToolCallFn? = nil,
        convertToLlm: @escaping @Sendable ([AgentMessage]) async throws -> [Message],
        transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
        shouldStopAfterTurn: ShouldStopAfterTurnFn? = nil
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
        self.onResponse = onResponse
        self.cacheRetention = cacheRetention
        self.headers = headers
        self.metadata = metadata
        self.timeoutMs = timeoutMs
        self.websocketConnectTimeoutMs = websocketConnectTimeoutMs
        self.maxRetries = maxRetries
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.getApiKey = getApiKey
        self.getModelAuth = getModelAuth
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.shouldStopAfterTurn = shouldStopAfterTurn
    }
}

public struct AgentModelAuth: Sendable {
    public var apiKey: String?
    public var headers: [String: String]?
    public var baseUrl: String?

    public init(apiKey: String? = nil, headers: [String: String]? = nil, baseUrl: String? = nil) {
        self.apiKey = apiKey
        self.headers = headers
        self.baseUrl = baseUrl
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

/// Public agent state snapshot.
///
/// Reshape (v0.65.0):
/// - `streamMessage` was renamed to `streamingMessage`.
/// - `error` was renamed to `errorMessage`.
/// - `isStreaming`, `streamingMessage`, `pendingToolCalls`, and `errorMessage` are runtime-owned
///   and readonly to external callers (`private(set)`). The agent loop is the only writer.
/// - `tools` and `messages` are mutable from outside; assigning copies the input array (Swift
///   value semantics already guarantee no shared identity).
///
/// Construct an initial state via the public initializer, which accepts only the writable fields
/// (no runtime-owned values are accepted at construction time).
public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [AgentMessage]
    public private(set) var isStreaming: Bool
    public private(set) var streamingMessage: AgentMessage?
    public private(set) var pendingToolCalls: Set<String>
    public private(set) var errorMessage: String?

    /// Public initializer for caller-provided initial state.
    /// Runtime-owned fields (`isStreaming`, `streamingMessage`, `pendingToolCalls`, `errorMessage`)
    /// always start at their default values and cannot be set by callers.
    public init(
        systemPrompt: String = "",
        model: Model = getModel(provider: .openai, modelId: "gpt-4o-mini"),
        thinkingLevel: ThinkingLevel = .off,
        tools: [AgentTool] = [],
        messages: [AgentMessage] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = false
        self.streamingMessage = nil
        self.pendingToolCalls = []
        self.errorMessage = nil
    }

    // MARK: - Internal mutators (loop-owned)

    /// Internal initializer for full state construction (used by the agent loop and tests within the module).
    internal init(
        systemPrompt: String,
        model: Model,
        thinkingLevel: ThinkingLevel,
        tools: [AgentTool],
        messages: [AgentMessage],
        isStreaming: Bool,
        streamingMessage: AgentMessage?,
        pendingToolCalls: Set<String>,
        errorMessage: String?
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamingMessage = streamingMessage
        self.pendingToolCalls = pendingToolCalls
        self.errorMessage = errorMessage
    }

    internal mutating func _setStreaming(_ value: Bool) { self.isStreaming = value }
    internal mutating func _setStreamingMessage(_ value: AgentMessage?) { self.streamingMessage = value }
    internal mutating func _setPendingToolCalls(_ value: Set<String>) { self.pendingToolCalls = value }
    internal mutating func _insertPendingToolCall(_ id: String) { self.pendingToolCalls.insert(id) }
    internal mutating func _removePendingToolCall(_ id: String) { self.pendingToolCalls.remove(id) }
    internal mutating func _setErrorMessage(_ value: String?) { self.errorMessage = value }
}
