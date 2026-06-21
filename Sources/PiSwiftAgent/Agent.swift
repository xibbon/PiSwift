import Foundation
import PiSwiftAI

private func defaultConvertToLlm(messages: [AgentMessage]) async -> [Message] {
    messages.compactMap { $0.asMessage }
}

/// Listener signature for `Agent.subscribe(_:)`.
///
/// Listeners are awaited in registration order and receive the active turn's cancellation token
/// so they can forward cancellation into nested async work. `agent.prompt(_:)`, `agent.continue()`,
/// and `agent.waitForIdle()` settle only after all `agent_end` listeners finish; `state.isStreaming`
/// remains `true` until that settlement completes.
public typealias AgentEventListener = @Sendable (AgentEvent, CancellationToken?) async -> Void

public struct AgentOptions: Sendable {
    public var initialState: AgentState?
    public var convertToLlm: (@Sendable ([AgentMessage]) async throws -> [Message])?
    public var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?
    public var steeringMode: AgentSteeringMode?
    public var followUpMode: AgentFollowUpMode?
    public var streamFn: StreamFn?
    public var sessionId: String?
    public var transport: Transport?
    public var thinkingBudgets: ThinkingBudgets?
    public var maxRetryDelayMs: Int?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)?
    public var onPayload: OnPayloadFn?
    /// v0.67.6: invoked after each provider HTTP response is received and before the stream
    /// begins consuming. Use for header / status inspection at the Agent level.
    public var onResponse: ResponseHandler?
    /// v0.68.0: prompt cache retention preference forwarded into provider stream options.
    public var cacheRetention: CacheRetention?
    /// HTTP headers forwarded into provider stream options.
    public var headers: [String: String]?
    /// Provider request metadata forwarded into provider stream options.
    public var metadata: [String: AnyCodable]?
    /// v0.70.1: provider SDK request timeout (ms).
    public var timeoutMs: Int?
    /// v0.70.1: provider SDK max retries.
    public var maxRetries: Int?
    public var toolExecution: ToolExecutionMode?
    public var beforeToolCall: BeforeToolCallFn?
    public var afterToolCall: AfterToolCallFn?

    public init(
        initialState: AgentState? = nil,
        convertToLlm: (@Sendable ([AgentMessage]) async throws -> [Message])? = nil,
        transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = nil,
        steeringMode: AgentSteeringMode? = nil,
        followUpMode: AgentFollowUpMode? = nil,
        streamFn: StreamFn? = nil,
        sessionId: String? = nil,
        transport: Transport? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        maxRetryDelayMs: Int? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)? = nil,
        onPayload: OnPayloadFn? = nil,
        onResponse: ResponseHandler? = nil,
        cacheRetention: CacheRetention? = nil,
        headers: [String: String]? = nil,
        metadata: [String: AnyCodable]? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        toolExecution: ToolExecutionMode? = nil,
        beforeToolCall: BeforeToolCallFn? = nil,
        afterToolCall: AfterToolCallFn? = nil
    ) {
        self.initialState = initialState
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.streamFn = streamFn
        self.sessionId = sessionId
        self.transport = transport
        self.thinkingBudgets = thinkingBudgets
        self.maxRetryDelayMs = maxRetryDelayMs
        self.getApiKey = getApiKey
        self.getModelAuth = getModelAuth
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.cacheRetention = cacheRetention
        self.headers = headers
        self.metadata = metadata
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
    }
}

public final class Agent: Sendable {
    private struct State: Sendable {
        var agentState: AgentState
        var listeners: [UUID: AgentEventListener]
        var abortToken: CancellationToken?
        var convertToLlm: @Sendable ([AgentMessage]) async throws -> [Message]
        var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])?
        var steeringQueue: [AgentMessage]
        var followUpQueue: [AgentMessage]
        var steeringMode: AgentSteeringMode
        var followUpMode: AgentFollowUpMode
        var streamFn: StreamFn
        var sessionId: String?
        var transport: Transport
        var thinkingBudgets: ThinkingBudgets?
        var maxRetryDelayMs: Int?
        var getApiKey: (@Sendable (String) async -> String?)?
        var getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)?
        var onPayload: OnPayloadFn?
        var onResponse: ResponseHandler?
        var cacheRetention: CacheRetention?
        var headers: [String: String]?
        var metadata: [String: AnyCodable]?
        var timeoutMs: Int?
        var maxRetries: Int?
        var toolExecution: ToolExecutionMode
        var beforeToolCall: BeforeToolCallFn?
        var afterToolCall: AfterToolCallFn?
        var runningTask: Task<Void, Never>?
    }

    private let stateBox: LockedState<State>

    private var _state: AgentState {
        get { stateBox.withLock { $0.agentState } }
        set { stateBox.withLock { $0.agentState = newValue } }
    }

    private func mutateState(_ body: (inout AgentState) -> Void) {
        stateBox.withLock { body(&$0.agentState) }
    }

    private var listeners: [UUID: AgentEventListener] {
        get { stateBox.withLock { $0.listeners } }
        set { stateBox.withLock { $0.listeners = newValue } }
    }

    private var abortToken: CancellationToken? {
        get { stateBox.withLock { $0.abortToken } }
        set { stateBox.withLock { $0.abortToken = newValue } }
    }

    private var convertToLlm: @Sendable ([AgentMessage]) async throws -> [Message] {
        get { stateBox.withLock { $0.convertToLlm } }
        set { stateBox.withLock { $0.convertToLlm = newValue } }
    }

    private var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? {
        get { stateBox.withLock { $0.transformContext } }
        set { stateBox.withLock { $0.transformContext = newValue } }
    }

    private var steeringQueue: [AgentMessage] {
        get { stateBox.withLock { $0.steeringQueue } }
        set { stateBox.withLock { $0.steeringQueue = newValue } }
    }

    private var followUpQueue: [AgentMessage] {
        get { stateBox.withLock { $0.followUpQueue } }
        set { stateBox.withLock { $0.followUpQueue = newValue } }
    }

    public var steeringMode: AgentSteeringMode {
        get { stateBox.withLock { $0.steeringMode } }
        set { stateBox.withLock { $0.steeringMode = newValue } }
    }

    public var followUpMode: AgentFollowUpMode {
        get { stateBox.withLock { $0.followUpMode } }
        set { stateBox.withLock { $0.followUpMode = newValue } }
    }

    public var streamFn: StreamFn {
        get { stateBox.withLock { $0.streamFn } }
        set { stateBox.withLock { $0.streamFn = newValue } }
    }

    public var sessionId: String? {
        get { stateBox.withLock { $0.sessionId } }
        set { stateBox.withLock { $0.sessionId = newValue } }
    }

    public var transport: Transport {
        get { stateBox.withLock { $0.transport } }
        set { stateBox.withLock { $0.transport = newValue } }
    }

    public var thinkingBudgets: ThinkingBudgets? {
        get { stateBox.withLock { $0.thinkingBudgets } }
        set { stateBox.withLock { $0.thinkingBudgets = newValue } }
    }

    public var maxRetryDelayMs: Int? {
        get { stateBox.withLock { $0.maxRetryDelayMs } }
        set { stateBox.withLock { $0.maxRetryDelayMs = newValue } }
    }

    public var getApiKey: (@Sendable (String) async -> String?)? {
        get { stateBox.withLock { $0.getApiKey } }
        set { stateBox.withLock { $0.getApiKey = newValue } }
    }

    public var getModelAuth: (@Sendable (Model) async -> AgentModelAuth?)? {
        get { stateBox.withLock { $0.getModelAuth } }
        set { stateBox.withLock { $0.getModelAuth = newValue } }
    }

    public var toolExecution: ToolExecutionMode {
        get { stateBox.withLock { $0.toolExecution } }
        set { stateBox.withLock { $0.toolExecution = newValue } }
    }

    public var onPayload: OnPayloadFn? {
        get { stateBox.withLock { $0.onPayload } }
        set { stateBox.withLock { $0.onPayload = newValue } }
    }

    public var onResponse: ResponseHandler? {
        get { stateBox.withLock { $0.onResponse } }
        set { stateBox.withLock { $0.onResponse = newValue } }
    }

    public var cacheRetention: CacheRetention? {
        get { stateBox.withLock { $0.cacheRetention } }
        set { stateBox.withLock { $0.cacheRetention = newValue } }
    }

    public var headers: [String: String]? {
        get { stateBox.withLock { $0.headers } }
        set { stateBox.withLock { $0.headers = newValue } }
    }

    public var metadata: [String: AnyCodable]? {
        get { stateBox.withLock { $0.metadata } }
        set { stateBox.withLock { $0.metadata = newValue } }
    }

    public var timeoutMs: Int? {
        get { stateBox.withLock { $0.timeoutMs } }
        set { stateBox.withLock { $0.timeoutMs = newValue } }
    }

    public var maxRetries: Int? {
        get { stateBox.withLock { $0.maxRetries } }
        set { stateBox.withLock { $0.maxRetries = newValue } }
    }

    public var beforeToolCall: BeforeToolCallFn? {
        get { stateBox.withLock { $0.beforeToolCall } }
        set { stateBox.withLock { $0.beforeToolCall = newValue } }
    }

    public var afterToolCall: AfterToolCallFn? {
        get { stateBox.withLock { $0.afterToolCall } }
        set { stateBox.withLock { $0.afterToolCall = newValue } }
    }

    private var runningTask: Task<Void, Never>? {
        get { stateBox.withLock { $0.runningTask } }
        set { stateBox.withLock { $0.runningTask = newValue } }
    }

    public init(_ options: AgentOptions = AgentOptions()) {
        let initialState = options.initialState ?? AgentState()
        let convert = options.convertToLlm ?? { messages in
            await defaultConvertToLlm(messages: messages)
        }
        let stream = options.streamFn ?? { model, context, options in
            try streamSimple(model: model, context: context, options: options)
        }
        self.stateBox = LockedState(State(
            agentState: initialState,
            listeners: [:],
            abortToken: nil,
            convertToLlm: convert,
            transformContext: options.transformContext,
            steeringQueue: [],
            followUpQueue: [],
            steeringMode: options.steeringMode ?? .oneAtATime,
            followUpMode: options.followUpMode ?? .oneAtATime,
            streamFn: stream,
            sessionId: options.sessionId,
            transport: options.transport ?? .sse,
            thinkingBudgets: options.thinkingBudgets,
            maxRetryDelayMs: options.maxRetryDelayMs,
            getApiKey: options.getApiKey,
            getModelAuth: options.getModelAuth,
            onPayload: options.onPayload,
            onResponse: options.onResponse,
            cacheRetention: options.cacheRetention,
            headers: options.headers,
            metadata: options.metadata,
            timeoutMs: options.timeoutMs,
            maxRetries: options.maxRetries,
            toolExecution: options.toolExecution ?? .parallel,
            beforeToolCall: options.beforeToolCall,
            afterToolCall: options.afterToolCall,
            runningTask: nil
        ))
    }

    /// Read-only snapshot of the current agent state.
    ///
    /// To mutate writable fields, use the dedicated property setters: `systemPrompt`, `model`,
    /// `thinkingLevel`, `tools`, `messages`, plus convenience helpers `appendMessage(_:)` and
    /// `clearMessages()`. Runtime-owned fields (`isStreaming`, `streamingMessage`,
    /// `pendingToolCalls`, `errorMessage`) are read-only and updated only by the loop.
    public var state: AgentState {
        _state
    }

    /// Active turn's cancellation token, or `nil` when the agent is idle.
    ///
    /// Forward this into nested async work to propagate cancellation when the turn aborts.
    public var signal: CancellationToken? {
        abortToken
    }

    // MARK: - Mutable writable-field properties (replaces removed mutator methods)

    public var systemPrompt: String {
        get { _state.systemPrompt }
        set { mutateState { $0.systemPrompt = newValue } }
    }

    public var model: Model {
        get { _state.model }
        set { mutateState { $0.model = newValue } }
    }

    public var thinkingLevel: ThinkingLevel {
        get { _state.thinkingLevel }
        set { mutateState { $0.thinkingLevel = newValue } }
    }

    public var tools: [AgentTool] {
        get { _state.tools }
        set { mutateState { $0.tools = newValue } }
    }

    public var messages: [AgentMessage] {
        get { _state.messages }
        set { mutateState { $0.messages = newValue } }
    }

    /// Convenience: append a single message to `state.messages`.
    public func appendMessage(_ message: AgentMessage) {
        mutateState { $0.messages.append(message) }
    }

    /// Convenience: clear `state.messages`.
    public func clearMessages() {
        mutateState { $0.messages = [] }
    }

    public func subscribe(_ fn: @escaping AgentEventListener) -> @Sendable () -> Void {
        let id = UUID()
        stateBox.withLock { $0.listeners[id] = fn }
        return { [weak self] in
            self?.stateBox.withLock { $0.listeners[id] = nil }
        }
    }

    /// Queue a steering message while the agent is running.
    /// Delivered after the current assistant turn finishes executing its tool calls,
    /// before the next LLM call.
    public func steer(_ message: AgentMessage) {
        steeringQueue.append(message)
    }

    public func followUp(_ message: AgentMessage) {
        followUpQueue.append(message)
    }

    public func clearMessageQueue() {
        clearAllQueues()
    }

    public func clearSteeringQueue() {
        steeringQueue.removeAll()
    }

    public func clearFollowUpQueue() {
        followUpQueue.removeAll()
    }

    public func clearAllQueues() {
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    public func hasQueuedMessages() -> Bool {
        !steeringQueue.isEmpty || !followUpQueue.isEmpty
    }

    private func dequeueSteeringMessages() -> [AgentMessage] {
        switch steeringMode {
        case .oneAtATime:
            if let first = steeringQueue.first {
                steeringQueue.removeFirst()
                return [first]
            }
            return []
        case .all:
            let queued = steeringQueue
            steeringQueue.removeAll()
            return queued
        }
    }

    private func dequeueFollowUpMessages() -> [AgentMessage] {
        switch followUpMode {
        case .oneAtATime:
            if let first = followUpQueue.first {
                followUpQueue.removeFirst()
                return [first]
            }
            return []
        case .all:
            let queued = followUpQueue
            followUpQueue.removeAll()
            return queued
        }
    }

    public func abort() {
        abortToken?.cancel()
    }

    public func waitForIdle() async {
        if let task = runningTask {
            await task.value
        }
    }

    public func reset() {
        mutateState {
            $0.messages.removeAll()
            $0._setStreaming(false)
            $0._setStreamingMessage(nil)
            $0._setPendingToolCalls([])
            $0._setErrorMessage(nil)
        }
        steeringQueue.removeAll()
        followUpQueue.removeAll()
    }

    public func prompt(_ message: AgentMessage) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        await runLoop(messages: [message])
    }

    public func prompt(_ messages: [AgentMessage]) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        await runLoop(messages: messages)
    }

    public func prompt(_ text: String, images: [ImageContent] = []) async throws {
        try ensureNotStreaming(.alreadyStreamingPrompt)
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        if !images.isEmpty {
            blocks.append(contentsOf: images.map { .image($0) })
        }
        let message = AgentMessage.user(UserMessage(content: .blocks(blocks)))
        await runLoop(messages: [message])
    }

    public func `continue`() async throws {
        try ensureNotStreaming(.alreadyStreamingContinue)
        guard !_state.messages.isEmpty else { throw AgentError.emptyContext }
        if let last = _state.messages.last, last.role == "assistant" {
            let queuedSteering = dequeueSteeringMessages()
            if !queuedSteering.isEmpty {
                await runLoop(messages: queuedSteering, options: RunLoopOptions(skipInitialSteeringPoll: true))
                return
            }

            let queuedFollowUp = dequeueFollowUpMessages()
            if !queuedFollowUp.isEmpty {
                await runLoop(messages: queuedFollowUp)
                return
            }

            throw AgentError.lastMessageAssistant
        }

        await runLoop(messages: nil)
    }

    private struct RunLoopOptions: Sendable {
        var skipInitialSteeringPoll: Bool
    }

    private func runLoop(messages: [AgentMessage]?, options: RunLoopOptions? = nil) async {
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoopInternal(messages: messages, options: options)
        }
        if let task = runningTask {
            await task.value
        }
        runningTask = nil
    }

    // MARK: - Event processing (centralized)

    /// Centralized loop event handler.
    ///
    /// State mutations and listener emission are awaited so subscribers can perform async work
    /// (model calls, IO, cancellation propagation) before the loop advances. The runtime-owned
    /// `isStreaming` flag is intentionally NOT flipped here on `.agentEnd` — it stays `true`
    /// until `runLoopInternal` clears it after the loop and all listeners have settled.
    private func processLoopEvent(_ event: AgentEvent) async {
        switch event {
        case .messageStart(let message):
            mutateState { $0._setStreamingMessage(message) }

        case .messageUpdate(let message, _):
            mutateState { $0._setStreamingMessage(message) }

        case .messageEnd(let message):
            mutateState {
                $0._setStreamingMessage(nil)
                $0.messages.append(message)
            }

        case .toolExecutionStart(let toolCallId, _, _):
            mutateState { $0._insertPendingToolCall(toolCallId) }

        case .toolExecutionEnd(let toolCallId, _, _, _):
            mutateState { $0._removePendingToolCall(toolCallId) }

        case .turnEnd(let message, _):
            if case .assistant(let assistantMessage) = message, let error = assistantMessage.errorMessage {
                mutateState { $0._setErrorMessage(error) }
            }

        case .agentEnd:
            // isStreaming stays true until runLoopInternal flips it after listeners drain.
            mutateState { $0._setStreamingMessage(nil) }

        default:
            break
        }

        await emit(event)
    }

    // MARK: - Loop implementation

    private func runLoopInternal(messages: [AgentMessage]?, options: RunLoopOptions?) async {
        let model = _state.model

        let token = CancellationToken()
        abortToken = token
        mutateState {
            $0._setStreaming(true)
            $0._setStreamingMessage(nil)
            $0._setErrorMessage(nil)
        }

        let reasoning = mapThinkingLevel(_state.thinkingLevel)

        let context = AgentContext(
            systemPrompt: _state.systemPrompt,
            messages: _state.messages,
            tools: _state.tools
        )

        let skipInitialSteeringPoll = LockedState(options?.skipInitialSteeringPoll == true)
        let config = AgentLoopConfig(
            model: model,
            reasoning: reasoning,
            transport: transport,
            sessionId: sessionId,
            thinkingBudgets: thinkingBudgets,
            maxRetryDelayMs: maxRetryDelayMs,
            onPayload: onPayload,
            onResponse: onResponse,
            cacheRetention: cacheRetention,
            headers: headers,
            metadata: metadata,
            timeoutMs: timeoutMs,
            maxRetries: maxRetries,
            toolExecution: toolExecution,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            getApiKey: getApiKey,
            getModelAuth: getModelAuth,
            getSteeringMessages: { [weak self] in
                guard let self else { return [] }
                let shouldSkip = skipInitialSteeringPoll.withLock { flag -> Bool in
                    if flag {
                        flag = false
                        return true
                    }
                    return false
                }
                if shouldSkip {
                    return []
                }
                return self.dequeueSteeringMessages()
            },
            getFollowUpMessages: { [weak self] in
                guard let self else { return [] }
                return self.dequeueFollowUpMessages()
            }
        )

        if let messages {
            _ = await runAgentLoop(
                prompts: messages,
                context: context,
                config: config,
                emit: { [weak self] event in
                    await self?.processLoopEvent(event)
                },
                signal: token,
                streamFn: streamFn
            )
        } else {
            _ = await runAgentLoopContinue(
                context: context,
                config: config,
                emit: { [weak self] event in
                    await self?.processLoopEvent(event)
                },
                signal: token,
                streamFn: streamFn
            )
        }

        // Settle: clear isStreaming AFTER all listeners (including agent_end) have drained.
        mutateState {
            $0._setStreaming(false)
            $0._setStreamingMessage(nil)
            $0._setPendingToolCalls([])
        }
        abortToken = nil
    }

    private func emit(_ event: AgentEvent) async {
        let snapshot = stateBox.withLock { $0.listeners }
        let token = abortToken
        for listener in snapshot.values {
            await listener(event, token)
        }
    }

    private func mapThinkingLevel(_ level: ThinkingLevel) -> ReasoningEffort? {
        guard level != .off else { return nil }
        return ReasoningEffort(rawValue: level.rawValue)
    }

    private func ensureNotStreaming(_ error: AgentError) throws {
        if _state.isStreaming {
            throw error
        }
    }
}

public enum AgentError: Error, LocalizedError {
    case emptyContext
    case lastMessageAssistant
    case alreadyStreamingPrompt
    case alreadyStreamingContinue

    public var errorDescription: String? {
        switch self {
        case .emptyContext:
            return "No messages to continue from"
        case .lastMessageAssistant:
            return "Cannot continue from message role: assistant"
        case .alreadyStreamingPrompt:
            return "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
        case .alreadyStreamingContinue:
            return "Agent is already processing. Wait for completion before continuing."
        }
    }
}
