import Foundation
import PiSwiftAI

private func defaultConvertToLlm(messages: [AgentMessage]) async -> [Message] {
    messages.compactMap { $0.asMessage }
}

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
    public var onPayload: OnPayloadFn?
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
        onPayload: OnPayloadFn? = nil,
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
        self.onPayload = onPayload
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
    }
}

public final class Agent: Sendable {
    private struct State: Sendable {
        var agentState: AgentState
        var listeners: [UUID: @Sendable (AgentEvent) -> Void]
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
        var onPayload: OnPayloadFn?
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

    private var listeners: [UUID: @Sendable (AgentEvent) -> Void] {
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

    private var steeringMode: AgentSteeringMode {
        get { stateBox.withLock { $0.steeringMode } }
        set { stateBox.withLock { $0.steeringMode = newValue } }
    }

    private var followUpMode: AgentFollowUpMode {
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

    public var toolExecution: ToolExecutionMode {
        get { stateBox.withLock { $0.toolExecution } }
        set { stateBox.withLock { $0.toolExecution = newValue } }
    }

    private var onPayload: OnPayloadFn? {
        get { stateBox.withLock { $0.onPayload } }
        set { stateBox.withLock { $0.onPayload = newValue } }
    }

    private var beforeToolCall: BeforeToolCallFn? {
        get { stateBox.withLock { $0.beforeToolCall } }
        set { stateBox.withLock { $0.beforeToolCall = newValue } }
    }

    private var afterToolCall: AfterToolCallFn? {
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
            onPayload: options.onPayload,
            toolExecution: options.toolExecution ?? .parallel,
            beforeToolCall: options.beforeToolCall,
            afterToolCall: options.afterToolCall,
            runningTask: nil
        ))
    }

    public var state: AgentState {
        _state
    }

    public func subscribe(_ fn: @escaping @Sendable (AgentEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        listeners[id] = fn
        return { [weak self] in
            self?.listeners[id] = nil
        }
    }

    public func setSystemPrompt(_ value: String) {
        _state.systemPrompt = value
    }

    public func setModel(_ model: Model) {
        _state.model = model
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        _state.thinkingLevel = level
    }

    public func setSteeringMode(_ mode: AgentSteeringMode) {
        steeringMode = mode
    }

    public func setFollowUpMode(_ mode: AgentFollowUpMode) {
        followUpMode = mode
    }

    public func getSteeringMode() -> AgentSteeringMode {
        steeringMode
    }

    public func getFollowUpMode() -> AgentFollowUpMode {
        followUpMode
    }

    public func setTransport(_ transport: Transport) {
        self.transport = transport
    }

    public func setTools(_ tools: [AgentTool]) {
        _state.tools = tools
    }

    public func setToolExecution(_ mode: ToolExecutionMode) {
        toolExecution = mode
    }

    public func setBeforeToolCall(_ value: BeforeToolCallFn?) {
        beforeToolCall = value
    }

    public func setAfterToolCall(_ value: AfterToolCallFn?) {
        afterToolCall = value
    }

    public func replaceMessages(_ messages: [AgentMessage]) {
        _state.messages = messages
    }

    public func appendMessage(_ message: AgentMessage) {
        _state.messages.append(message)
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

    public func clearMessages() {
        _state.messages.removeAll()
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
        _state.messages.removeAll()
        _state.isStreaming = false
        _state.streamMessage = nil
        _state.pendingToolCalls = Set<String>()
        _state.error = nil
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

    private func processLoopEvent(_ event: AgentEvent) {
        switch event {
        case .messageStart(let message):
            _state.streamMessage = message

        case .messageUpdate(let message, _):
            _state.streamMessage = message

        case .messageEnd(let message):
            _state.streamMessage = nil
            appendMessage(message)

        case .toolExecutionStart(let toolCallId, _, _):
            var pending = _state.pendingToolCalls
            pending.insert(toolCallId)
            _state.pendingToolCalls = pending

        case .toolExecutionEnd(let toolCallId, _, _, _):
            var pending = _state.pendingToolCalls
            pending.remove(toolCallId)
            _state.pendingToolCalls = pending

        case .turnEnd(let message, _):
            if case .assistant(let assistantMessage) = message, let error = assistantMessage.errorMessage {
                _state.error = error
            }

        case .agentEnd:
            _state.isStreaming = false
            _state.streamMessage = nil

        default:
            break
        }

        emit(event)
    }

    // MARK: - Loop implementation

    private func runLoopInternal(messages: [AgentMessage]?, options: RunLoopOptions?) async {
        let model = _state.model

        abortToken = CancellationToken()
        _state.isStreaming = true
        _state.streamMessage = nil
        _state.error = nil

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
            toolExecution: toolExecution,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            getApiKey: getApiKey,
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
                    self?.processLoopEvent(event)
                },
                signal: abortToken,
                streamFn: streamFn
            )
        } else {
            _ = await runAgentLoopContinue(
                context: context,
                config: config,
                emit: { [weak self] event in
                    self?.processLoopEvent(event)
                },
                signal: abortToken,
                streamFn: streamFn
            )
        }

        _state.isStreaming = false
        _state.streamMessage = nil
        _state.pendingToolCalls = Set<String>()
        abortToken = nil
    }

    private func emit(_ event: AgentEvent) {
        for listener in listeners.values {
            listener(event)
        }
    }

    private func appendErrorMessage(_ message: String) {
        let assistant = AssistantMessage(
            content: [.text(TextContent(text: ""))],
            api: _state.model.api,
            provider: _state.model.provider,
            model: _state.model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: abortToken?.isCancelled == true ? .aborted : .error,
            errorMessage: message
        )
        let agentMessage = AgentMessage.assistant(assistant)
        appendMessage(agentMessage)
        _state.error = message
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
