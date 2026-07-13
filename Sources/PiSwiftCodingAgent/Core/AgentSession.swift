import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum AutoCompactionReason: String, Sendable {
    case threshold
    case overflow
}

public enum AgentSessionEvent: Sendable {
    case agent(AgentEvent)
    case agentSettled
    case autoCompactionStart(reason: AutoCompactionReason)
    case autoCompactionEnd(result: CompactionResult?, aborted: Bool, willRetry: Bool)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)

    public var type: String {
        switch self {
        case .agent(let event):
            return event.type
        case .agentSettled:
            return "agent_settled"
        case .autoCompactionStart:
            return "auto_compaction_start"
        case .autoCompactionEnd:
            return "auto_compaction_end"
        case .autoRetryStart:
            return "auto_retry_start"
        case .autoRetryEnd:
            return "auto_retry_end"
        }
    }
}

public struct AgentSessionConfig: Sendable {
    public var agent: Agent
    public var sessionManager: SessionManager
    public var settingsManager: SettingsManager
    public var resourceLoader: ResourceLoader
    public var projectTrusted: Bool
    public var systemPromptOptions: BuildSystemPromptOptions?
    public var scopedModels: [ScopedModel]?
    public var fileCommands: [FileSlashCommand]?
    public var promptTemplates: [PromptTemplate]?
    public var hookRunner: HookRunner?
    public var customTools: [LoadedCustomTool]?
    public var modelRegistry: ModelRegistry
    public var skillsSettings: SkillsSettings?
    public var eventBus: EventBus?
    public var toolRegistry: [String: AgentTool]?
    public var rebuildSystemPrompt: (@Sendable ([String]) -> String)?
    /// Re-discover and re-load extension dylibs. Wired by `createAgentSession()` so it
    /// uses the same paths/cwd/agentDir as the initial load. Invoked by
    /// `AgentSession.reloadExtensions()` (driven by `/reload`).
    public var reloadExtensionsHook: (@Sendable () async -> LoadExtensionsResult)?
    /// Bridge that wraps extension-registered `CustomTool`s into agent-ready
    /// `AgentTool`s (applying the wrapCustomTools + wrapToolsWithHooks pipeline). Wired
    /// by `createAgentSession()`. Invoked by `reloadExtensions()` to add freshly-loaded
    /// extension tools to the agent's roster.
    public var wrapExtensionTools: (@Sendable ([CustomTool]) -> [AgentTool])?

    public init(
        agent: Agent,
        sessionManager: SessionManager,
        settingsManager: SettingsManager,
        resourceLoader: ResourceLoader,
        projectTrusted: Bool = true,
        systemPromptOptions: BuildSystemPromptOptions? = nil,
        scopedModels: [ScopedModel]? = nil,
        fileCommands: [FileSlashCommand]? = nil,
        promptTemplates: [PromptTemplate]? = nil,
        hookRunner: HookRunner? = nil,
        customTools: [LoadedCustomTool]? = nil,
        modelRegistry: ModelRegistry,
        skillsSettings: SkillsSettings? = nil,
        eventBus: EventBus? = nil,
        toolRegistry: [String: AgentTool]? = nil,
        rebuildSystemPrompt: (@Sendable ([String]) -> String)? = nil,
        reloadExtensionsHook: (@Sendable () async -> LoadExtensionsResult)? = nil,
        wrapExtensionTools: (@Sendable ([CustomTool]) -> [AgentTool])? = nil
    ) {
        self.agent = agent
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
        self.resourceLoader = resourceLoader
        self.projectTrusted = projectTrusted
        self.systemPromptOptions = systemPromptOptions
        self.scopedModels = scopedModels
        self.fileCommands = fileCommands
        self.promptTemplates = promptTemplates
        self.hookRunner = hookRunner
        self.customTools = customTools
        self.modelRegistry = modelRegistry
        self.skillsSettings = skillsSettings
        self.eventBus = eventBus
        self.toolRegistry = toolRegistry
        self.rebuildSystemPrompt = rebuildSystemPrompt
        self.reloadExtensionsHook = reloadExtensionsHook
        self.wrapExtensionTools = wrapExtensionTools
    }
}

public struct PromptOptions: Sendable {
    public var expandSlashCommands: Bool?
    public var expandPromptTemplates: Bool?
    public var images: [ImageContent]?

    public init(expandSlashCommands: Bool? = nil, expandPromptTemplates: Bool? = nil, images: [ImageContent]? = nil) {
        self.expandSlashCommands = expandSlashCommands
        self.expandPromptTemplates = expandPromptTemplates
        self.images = images
    }
}

public struct ParsedSkillBlock: Sendable {
    public var name: String
    public var location: String
    public var content: String
    public var userMessage: String?

    public init(name: String, location: String, content: String, userMessage: String? = nil) {
        self.name = name
        self.location = location
        self.content = content
        self.userMessage = userMessage
    }
}

public func parseSkillBlock(_ text: String) -> ParsedSkillBlock? {
    // Pattern: <skill name="..." location="...">content</skill> optionally followed by user message
    let pattern = #"^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n</skill>(?:\n\n([\s\S]+))?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
          let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges >= 4 else {
        return nil
    }

    guard let nameRange = Range(match.range(at: 1), in: text),
          let locationRange = Range(match.range(at: 2), in: text),
          let contentRange = Range(match.range(at: 3), in: text) else {
        return nil
    }

    let name = String(text[nameRange])
    let location = String(text[locationRange])
    let content = String(text[contentRange])

    var userMessage: String?
    if match.numberOfRanges >= 5, match.range(at: 4).location != NSNotFound,
       let userMessageRange = Range(match.range(at: 4), in: text) {
        userMessage = String(text[userMessageRange])
    }

    return ParsedSkillBlock(name: name, location: location, content: content, userMessage: userMessage)
}

public struct ForkableMessage: Sendable {
    public var entryId: String
    public var text: String

    public init(entryId: String, text: String) {
        self.entryId = entryId
        self.text = text
    }
}

/// v0.70.0: token-budget breakdown surfaced via `getSessionStats().contextUsage`.
/// `tokens` is `nil` when the latest assistant usage is pre-compaction (we can only trust
/// usage from an assistant that responded AFTER the last compaction, so right after compaction
/// the value is unknown until the next LLM turn). `percent` is `nil` for the same reason.
public struct ContextUsage: Sendable {
    public var tokens: Int?
    public var contextWindow: Int
    public var percent: Double?

    public init(tokens: Int?, contextWindow: Int, percent: Double?) {
        self.tokens = tokens
        self.contextWindow = contextWindow
        self.percent = percent
    }
}

public struct SessionStats: Sendable {
    public var sessionFile: String?
    public var sessionId: String
    public var userMessages: Int
    public var assistantMessages: Int
    public var toolCalls: Int
    public var toolResults: Int
    public var totalMessages: Int
    public var tokens: TokenStats
    public var cost: Double
    /// v0.70.0: token-budget usage relative to the active model's context window.
    /// `nil` when no model is set or contextWindow is 0; otherwise contains the latest
    /// post-compaction usage estimate.
    public var contextUsage: ContextUsage?

    public struct TokenStats: Sendable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite: Int
        public var total: Int

        public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = total
        }
    }

    public init(
        sessionFile: String?,
        sessionId: String,
        userMessages: Int,
        assistantMessages: Int,
        toolCalls: Int,
        toolResults: Int,
        totalMessages: Int,
        tokens: TokenStats,
        cost: Double,
        contextUsage: ContextUsage? = nil
    ) {
        self.sessionFile = sessionFile
        self.sessionId = sessionId
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.totalMessages = totalMessages
        self.tokens = tokens
        self.cost = cost
        self.contextUsage = contextUsage
    }
}

public enum ModelCycleDirection: String, Sendable {
    case forward
    case backward
}

public struct ModelCycleResult: Sendable {
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var isScoped: Bool

    public init(model: Model, thinkingLevel: ThinkingLevel, isScoped: Bool) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.isScoped = isScoped
    }
}

public enum AgentSessionError: LocalizedError, Sendable {
    case alreadyProcessingQueue
    case noModelSelected(authPath: String)
    case missingApiKeyForProvider(provider: String, authPath: String)
    case alreadyProcessingContinue
    case missingApiKeyForModel(provider: String, modelId: String)
    case invalidEntryIdForForking
    case missingApiKey(provider: String)
    case nothingToCompact
    case compactionCancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyProcessingQueue:
            return "Agent is already processing. Specify streamingBehavior (\"steer\" or \"followUp\") to queue the message."
        case .noModelSelected(let authPath):
            return "No model selected.\n\n" +
                "Use /login, set an API key environment variable, or create \(authPath)\n\n" +
                "Then use /model to select a model."
        case .missingApiKeyForProvider(let provider, let authPath):
            return "No API key found for \(provider).\n\n" +
                "Use /login, set an API key environment variable, or create \(authPath)"
        case .alreadyProcessingContinue:
            return "Agent is already processing. Wait for completion before continuing."
        case .missingApiKeyForModel(let provider, let modelId):
            return "No API key for \(provider)/\(modelId)"
        case .invalidEntryIdForForking:
            return "Invalid entry ID for forking"
        case .missingApiKey(let provider):
            return "No API key for \(provider)"
        case .nothingToCompact:
            return "Nothing to compact (session too small)"
        case .compactionCancelled:
            return "Compaction cancelled"
        }
    }
}

public final class AgentSession: Sendable {
    public let agent: Agent
    public let sessionManager: SessionManager
    public let settingsManager: SettingsManager
    public let modelRegistry: ModelRegistry
    public let eventBus: EventBus
    public let projectTrusted: Bool
    private let state: LockedState<State>

    /// Serial queue for agent event processing.
    /// Ensures tool call/result interception from extensions happens in order.
    private let _agentEventQueue = LockedState<Task<Void, Never>?>(nil)
    private let idleWaiter = AgentSessionIdleWaiter()

    private struct State: Sendable {
        var hookRunner: HookRunner?
        var customToolsInternal: [LoadedCustomTool]
        var scopedModels: [ScopedModel]
        var fileCommands: [FileSlashCommand]
        var promptTemplates: [PromptTemplate]
        var resourceLoader: ResourceLoader
        var unsubscribeAgent: (@Sendable () -> Void)?
        var eventListeners: [UUID: @Sendable (AgentSessionEvent) -> Void]
        var steeringMessages: [String]
        var followUpMessages: [String]
        var pendingNextTurnMessages: [HookMessage]
        var lastAssistantMessage: AssistantMessage?
        var compactionAbort: CancellationToken?
        var branchSummaryAbort: CancellationToken?
        var retryAbort: CancellationToken?
        var retryAttempt: Int
        var retryTask: Task<Void, Never>?
        /// Retry/compaction follow-up work scheduled after an `agent_end` callback.
        /// The run cannot settle while this count is non-zero.
        var pendingPostRunTasks: Int
        var bashAbort: CancellationToken?
        var pendingBashMessages: [BashExecutionMessage]
        var isCompactingInternal: Bool
        var overflowRecoveryAttempted: Bool
        var lastSuccessfulUsage: Usage?
        var isBranchSummarizing: Bool
        var turnIndex: Int
        var baseSystemPrompt: String
        var systemPromptOptions: BuildSystemPromptOptions
        var toolRegistry: [String: AgentTool]
        var rebuildSystemPrompt: (@Sendable ([String]) -> String)?
        var toolPromptSnippets: [String: String]
        var reloadExtensionsHook: (@Sendable () async -> LoadExtensionsResult)?
        var wrapExtensionTools: (@Sendable ([CustomTool]) -> [AgentTool])?
    }

    /// Actor-isolated waiter state keeps the public idle API race-free without
    /// polling or unchecked Sendable storage.
    private actor AgentSessionIdleWaiter {
        private var isRunActive = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func beginRun() {
            isRunActive = true
        }

        func waitForIdle() async {
            guard isRunActive else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func settleRun() -> Bool {
            guard isRunActive else { return false }
            isRunActive = false
            return true
        }

        func resolveWaiters() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    private var _hookRunner: HookRunner? {
        get { state.withLock { $0.hookRunner } }
        set { state.withLock { $0.hookRunner = newValue } }
    }

    private var customToolsInternal: [LoadedCustomTool] {
        get { state.withLock { $0.customToolsInternal } }
        set { state.withLock { $0.customToolsInternal = newValue } }
    }

    private var scopedModelsInternal: [ScopedModel] {
        get { state.withLock { $0.scopedModels } }
        set { state.withLock { $0.scopedModels = newValue } }
    }

    private var fileCommands: [FileSlashCommand] {
        get { state.withLock { $0.fileCommands } }
        set { state.withLock { $0.fileCommands = newValue } }
    }

    public var promptTemplates: [PromptTemplate] {
        state.withLock { $0.promptTemplates }
    }

    private var promptTemplatesInternal: [PromptTemplate] {
        get { state.withLock { $0.promptTemplates } }
        set { state.withLock { $0.promptTemplates = newValue } }
    }

    public var resourceLoader: ResourceLoader {
        state.withLock { $0.resourceLoader }
    }

    private var unsubscribeAgent: (@Sendable () -> Void)? {
        get { state.withLock { $0.unsubscribeAgent } }
        set { state.withLock { $0.unsubscribeAgent = newValue } }
    }

    private var eventListeners: [UUID: @Sendable (AgentSessionEvent) -> Void] {
        get { state.withLock { $0.eventListeners } }
        set { state.withLock { $0.eventListeners = newValue } }
    }

    private var steeringMessages: [String] {
        get { state.withLock { $0.steeringMessages } }
        set { state.withLock { $0.steeringMessages = newValue } }
    }

    private var followUpMessages: [String] {
        get { state.withLock { $0.followUpMessages } }
        set { state.withLock { $0.followUpMessages = newValue } }
    }

    private var pendingNextTurnMessages: [HookMessage] {
        get { state.withLock { $0.pendingNextTurnMessages } }
        set { state.withLock { $0.pendingNextTurnMessages = newValue } }
    }

    private var lastAssistantMessage: AssistantMessage? {
        get { state.withLock { $0.lastAssistantMessage } }
        set { state.withLock { $0.lastAssistantMessage = newValue } }
    }

    private var compactionAbort: CancellationToken? {
        get { state.withLock { $0.compactionAbort } }
        set { state.withLock { $0.compactionAbort = newValue } }
    }

    private var branchSummaryAbort: CancellationToken? {
        get { state.withLock { $0.branchSummaryAbort } }
        set { state.withLock { $0.branchSummaryAbort = newValue } }
    }

    private var retryAbort: CancellationToken? {
        get { state.withLock { $0.retryAbort } }
        set { state.withLock { $0.retryAbort = newValue } }
    }

    private var retryAttempt: Int {
        get { state.withLock { $0.retryAttempt } }
        set { state.withLock { $0.retryAttempt = newValue } }
    }

    private var retryTask: Task<Void, Never>? {
        get { state.withLock { $0.retryTask } }
        set { state.withLock { $0.retryTask = newValue } }
    }

    private var pendingPostRunTasks: Int {
        get { state.withLock { $0.pendingPostRunTasks } }
        set { state.withLock { $0.pendingPostRunTasks = newValue } }
    }

    private var bashAbort: CancellationToken? {
        get { state.withLock { $0.bashAbort } }
        set { state.withLock { $0.bashAbort = newValue } }
    }

    private var pendingBashMessages: [BashExecutionMessage] {
        get { state.withLock { $0.pendingBashMessages } }
        set { state.withLock { $0.pendingBashMessages = newValue } }
    }

    private var isCompactingInternal: Bool {
        get { state.withLock { $0.isCompactingInternal } }
        set { state.withLock { $0.isCompactingInternal = newValue } }
    }

    /// Prevents stale pre-compaction usage from retriggering auto-compaction (4D-3).
    private var overflowRecoveryAttempted: Bool {
        get { state.withLock { $0.overflowRecoveryAttempted } }
        set { state.withLock { $0.overflowRecoveryAttempted = newValue } }
    }

    /// Tracks the last *successful* assistant usage so threshold checks after
    /// error responses don't compare against zero-token stale values (4D-4).
    private var lastSuccessfulUsage: Usage? {
        get { state.withLock { $0.lastSuccessfulUsage } }
        set { state.withLock { $0.lastSuccessfulUsage = newValue } }
    }

    /// Guards message submission during branch summarization (4D-6).
    private var isBranchSummarizing: Bool {
        get { state.withLock { $0.isBranchSummarizing } }
        set { state.withLock { $0.isBranchSummarizing = newValue } }
    }

    private var turnIndex: Int {
        get { state.withLock { $0.turnIndex } }
        set { state.withLock { $0.turnIndex = newValue } }
    }

    private var baseSystemPrompt: String {
        get { state.withLock { $0.baseSystemPrompt } }
        set { state.withLock { $0.baseSystemPrompt = newValue } }
    }

    private var toolRegistry: [String: AgentTool] {
        get { state.withLock { $0.toolRegistry } }
        set { state.withLock { $0.toolRegistry = newValue } }
    }

    private var rebuildSystemPrompt: (@Sendable ([String]) -> String)? {
        get { state.withLock { $0.rebuildSystemPrompt } }
        set { state.withLock { $0.rebuildSystemPrompt = newValue } }
    }

    private var toolPromptSnippets: [String: String] {
        get { state.withLock { $0.toolPromptSnippets } }
        set { state.withLock { $0.toolPromptSnippets = newValue } }
    }

    private var reloadExtensionsHookInternal: (@Sendable () async -> LoadExtensionsResult)? {
        get { state.withLock { $0.reloadExtensionsHook } }
        set { state.withLock { $0.reloadExtensionsHook = newValue } }
    }

    private var wrapExtensionToolsInternal: (@Sendable ([CustomTool]) -> [AgentTool])? {
        get { state.withLock { $0.wrapExtensionTools } }
        set { state.withLock { $0.wrapExtensionTools = newValue } }
    }

    /// Register a prompt snippet that tools can contribute to the system prompt.
    /// Snippets are keyed by name so they can be replaced or removed.
    public func registerToolPromptSnippet(name: String, text: String) {
        toolPromptSnippets[name] = text
        // Rebuild the system prompt to include the new snippet
        agent.systemPrompt = effectiveSystemPrompt(baseSystemPrompt)
    }

    private func expandPromptText(_ text: String, expandSlashCommands: Bool = true, expandPromptTemplates: Bool = true) -> String {
        var expanded = text
        if expandPromptTemplates {
            expanded = expandPromptTemplate(expanded, promptTemplatesInternal)
        }
        if expandSlashCommands {
            expanded = expandSlashCommand(expanded, fileCommands)
        }
        return expanded
    }

    public init(config: AgentSessionConfig) {
        self.agent = config.agent
        self.sessionManager = config.sessionManager
        self.settingsManager = config.settingsManager
        self.modelRegistry = config.modelRegistry
        self.eventBus = config.eventBus ?? createEventBus()
        self.projectTrusted = config.projectTrusted
        self.agent.sessionId = config.sessionManager.getSessionId()
        self.state = LockedState(State(
            hookRunner: config.hookRunner,
            customToolsInternal: config.customTools ?? [],
            scopedModels: config.scopedModels ?? [],
            fileCommands: config.fileCommands ?? [],
            promptTemplates: config.promptTemplates ?? [],
            resourceLoader: config.resourceLoader,
            unsubscribeAgent: nil,
            eventListeners: [:],
            steeringMessages: [],
            followUpMessages: [],
            pendingNextTurnMessages: [],
            lastAssistantMessage: nil,
            compactionAbort: nil,
            branchSummaryAbort: nil,
            retryAbort: nil,
            retryAttempt: 0,
            retryTask: nil,
            pendingPostRunTasks: 0,
            bashAbort: nil,
            pendingBashMessages: [],
            isCompactingInternal: false,
            overflowRecoveryAttempted: false,
            lastSuccessfulUsage: nil,
            isBranchSummarizing: false,
            turnIndex: 0,
            baseSystemPrompt: config.agent.state.systemPrompt,
            systemPromptOptions: config.systemPromptOptions ?? BuildSystemPromptOptions(cwd: config.sessionManager.getCwd()),
            toolRegistry: config.toolRegistry ?? [:],
            rebuildSystemPrompt: config.rebuildSystemPrompt,
            toolPromptSnippets: [:],
            reloadExtensionsHook: config.reloadExtensionsHook,
            wrapExtensionTools: config.wrapExtensionTools
        ))

        self._hookRunner?.initialize(
            getModel: { [weak agent] in agent?.state.model },
            getSystemPrompt: { [weak agent] in agent?.state.systemPrompt },
            getSystemPromptOptions: { config.systemPromptOptions ?? BuildSystemPromptOptions(cwd: config.sessionManager.getCwd()) },
            isProjectTrusted: { config.projectTrusted },
            setSessionNameHandler: { [weak self] name in
                self?.sessionManager.appendSessionInfo(name)
            },
            getSessionNameHandler: { [weak self] in
                self?.sessionManager.getSessionName()
            },
            getActiveToolsHandler: { [weak self] in self?.getActiveToolNames() ?? [] },
            getAllToolsHandler: { [weak self] in self?.getAllTools() ?? [] },
            setActiveToolsHandler: { [weak self] names in self?.setActiveToolsByName(names) },
            getCommandsHandler: { [weak self] in self?.getHookCommands() ?? [] },
            setModelHandler: { [weak self] model in
                guard let self else { return false }
                do {
                    try await self.setModel(model)
                    return true
                } catch {
                    return false
                }
            },
            getThinkingLevelHandler: { [weak agent] in
                agent?.state.thinkingLevel ?? .off
            },
            setThinkingLevelHandler: { [weak self] level in
                self?.setThinkingLevel(level)
            },
            sendUserMessageHandler: { [weak self] content, options in
                Task { [weak self] in
                    guard let self else { return }
                    if self.isStreaming {
                        if options?.deliverAs == .followUp {
                            self.followUp(content)
                        } else {
                            self.steer(content)
                        }
                        return
                    }
                    try? await self.prompt(
                        content,
                        options: PromptOptions(expandSlashCommands: false, expandPromptTemplates: false)
                    )
                }
            },
            setLabelHandler: { [weak self] entryId, label in
                _ = try? self?.sessionManager.appendLabelChange(entryId, label)
            },
            getContextUsage: { [weak self] in self?.getContextUsage() },
            compactHandler: { [weak self] options in
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let result = try await self.compact(customInstructions: options?.customInstructions)
                        options?.onComplete?(result)
                    } catch {
                        options?.onError?(error)
                    }
                }
            },
            newSessionHandler: { [weak self] options in
                guard let self else { return HookCommandResult(cancelled: true) }
                let result = await self.newSession(NewSessionOptions(parentSession: options?.parentSession))
                if result, let setup = options?.setup {
                    await setup(self.sessionManager)
                }
                return HookCommandResult(cancelled: !result)
            },
            forkHandler: { [weak self] entryId in
                guard let self else { return HookCommandResult(cancelled: true) }
                do {
                    let result = try await self.fork(entryId)
                    return HookCommandResult(cancelled: result.cancelled)
                } catch {
                    return HookCommandResult(cancelled: true)
                }
            },
            navigateTreeHandler: { [weak self] targetId, options in
                guard let self else { return HookCommandResult(cancelled: true) }
                let result = await self.navigateTree(targetId, summarize: options?.summarize ?? false)
                return HookCommandResult(cancelled: result.cancelled)
            },
            switchSessionHandler: { [weak self] sessionPath in
                guard let self else { return HookCommandResult(cancelled: true) }
                let result = await self.switchSession(sessionPath)
                return HookCommandResult(cancelled: !result)
            },
            reloadHandler: { [weak self] in
                guard let self else { return }
                await self.reload()
                _ = await self.reloadExtensions()
            },
            hasUI: false
        )

        self.unsubscribeAgent = agent.subscribe { [weak self] event, _ in
            self?.handleAgentEvent(event)
        }
    }

    public func dispose() {
        unsubscribeAgent?()
        unsubscribeAgent = nil
        _hookRunner?.unregisterExtensionProviders()
        // v0.67.4: reap any detached bash subprocesses the user spawned during this session
        // so we don't leave orphans hanging around after `/quit` or session shutdown.
        killTrackedDetachedChildren()
    }

    public var hookRunner: HookRunner? {
        _hookRunner
    }

    public func getCurrentSystemPromptOptions() -> BuildSystemPromptOptions {
        var options = state.withLock { $0.systemPromptOptions }
        options.selectedTools = getActiveToolNames().compactMap { ToolName(rawValue: $0) }
        return options
    }

    public var customTools: [LoadedCustomTool] {
        customToolsInternal
    }

    public func emitCustomToolSessionEvent(
        _ reason: CustomToolSessionEvent.Reason,
        previousSessionFile: String? = nil
    ) async {
        guard !customToolsInternal.isEmpty else { return }

        let event = CustomToolSessionEvent(reason: reason, previousSessionFile: previousSessionFile)
        let context = CustomToolContext(
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: agent.state.model,
            isIdle: { [weak self] in
                !(self?.isStreaming ?? true)
            },
            hasPendingMessages: { [weak self] in
                (self?.pendingMessageCount ?? 0) > 0
            },
            abort: { [weak self] in
                Task { await self?.abort() }
            },
            events: eventBus,
            sendMessage: { [weak self] message, options in
                Task { await self?.sendHookMessage(message, options: options) }
            }
        )

        for tool in customToolsInternal {
            guard let handler = tool.tool.onSession else { continue }
            do {
                try await handler(event, context)
            } catch {
                // Ignore tool errors during session events
            }
        }
    }

    public func subscribe(_ listener: @escaping @Sendable (AgentSessionEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        eventListeners[id] = listener
        return { [weak self] in
            self?.eventListeners[id] = nil
        }
    }

    private func emit(_ event: AgentSessionEvent) {
        for listener in eventListeners.values {
            listener(event)
        }
    }

    /// Enqueue work on the serial agent-event queue so that hook interception
    /// for tool calls/results is processed in order.
    private func enqueueOnEventQueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = _agentEventQueue.withLock { $0 }
        let task = Task<Void, Never> {
            _ = await previous?.value
            await work()
        }
        _agentEventQueue.withLock { $0 = task }
    }

    private func emitAgentSettledIfNeeded() async {
        // `agent_end` may schedule an automatic retry, compaction, or queued
        // continuation. Keep the run active until that follow-up chain finishes.
        guard pendingPostRunTasks == 0 else { return }
        guard await idleWaiter.settleRun() else { return }

        // Agent lifecycle hooks are queued from the Agent callback. Waiting for this
        // queue keeps the observable order `agent_end` then `agent_settled`.
        let previous = _agentEventQueue.withLock { $0 }
        _ = await previous?.value
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(AgentSettledEvent())
        }
        emit(.agentSettled)
        await idleWaiter.resolveWaiters()
    }

    private func runUntilSettled<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await idleWaiter.beginRun()
        defer {
            Task { [weak self] in
                await self?.emitAgentSettledIfNeeded()
            }
        }
        return try await operation()
    }

    private func beginPostRunTask() {
        pendingPostRunTasks += 1
    }

    private func finishPostRunTask() {
        pendingPostRunTasks = max(0, pendingPostRunTasks - 1)
        Task { [weak self] in
            await self?.emitAgentSettledIfNeeded()
        }
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        if case .messageStart(let message) = event, message.role == "user" {
            let text = extractUserMessageText(message)
            if let idx = steeringMessages.firstIndex(of: text) {
                steeringMessages.remove(at: idx)
            } else if let idx = followUpMessages.firstIndex(of: text) {
                followUpMessages.remove(at: idx)
            }
        }

        if case .messageEnd(let message) = event {
            switch message {
            case .user, .assistant, .toolResult:
                _ = sessionManager.appendMessage(message)
            case .custom(let custom):
                if custom.role == "hookMessage" {
                    if let payload = custom.payload?.value as? [String: Any],
                       let customType = payload["customType"] as? String,
                       let display = payload["display"] as? Bool {
                        let content: HookMessageContent
                        if let text = payload["content"] as? String {
                            content = .text(text)
                        } else {
                            content = .text("")
                        }
                        _ = sessionManager.appendCustomMessage(customType, content, display)
                    }
                } else {
                    _ = sessionManager.appendMessage(message)
                }
            }

            if case .assistant(let assistant) = message {
                lastAssistantMessage = assistant
                // Track last successful usage for threshold checks after errors (4D-4).
                if assistant.stopReason != .error {
                    lastSuccessfulUsage = assistant.usage
                }
                if assistant.stopReason != .error, retryAttempt > 0 {
                    let attempt = retryAttempt
                    retryAttempt = 0
                    retryAbort = nil
                    retryTask = nil
                    emit(.autoRetryEnd(success: true, attempt: attempt, finalError: nil))
                }
            }
        }

        if case .agentEnd = event {
            flushPendingBashMessages()
        }

        if let hookRunner = _hookRunner {
            switch event {
            case .agentStart:
                turnIndex = 0
                enqueueOnEventQueue { _ = await hookRunner.emit(AgentStartEvent()) }
            case .agentEnd(let messages):
                enqueueOnEventQueue { _ = await hookRunner.emit(AgentEndEvent(messages: messages)) }
            case .turnStart:
                let currentIndex = self.turnIndex
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                enqueueOnEventQueue { _ = await hookRunner.emit(TurnStartEvent(turnIndex: currentIndex, timestamp: timestamp)) }
            case .turnEnd(let message, let toolResults):
                let currentIndex = self.turnIndex
                self.turnIndex += 1
                enqueueOnEventQueue { _ = await hookRunner.emit(TurnEndEvent(turnIndex: currentIndex, message: message, toolResults: toolResults)) }
            case .messageStart(let message):
                enqueueOnEventQueue { _ = await hookRunner.emit(MessageStartEvent(message: message)) }
            case .messageUpdate(let message, let assistantMessageEvent):
                enqueueOnEventQueue { _ = await hookRunner.emit(MessageUpdateEvent(message: message, assistantMessageEvent: assistantMessageEvent)) }
            case .messageEnd(let message):
                enqueueOnEventQueue { _ = await hookRunner.emit(MessageEndEvent(message: message)) }
            case .toolExecutionStart(let toolCallId, let toolName, let args):
                enqueueOnEventQueue {
                    _ = await hookRunner.emit(ToolExecutionStartEvent(toolCallId: toolCallId, toolName: toolName, args: args))
                }
            case .toolExecutionUpdate(let toolCallId, let toolName, let args, let partialResult):
                enqueueOnEventQueue {
                    _ = await hookRunner.emit(ToolExecutionUpdateEvent(
                        toolCallId: toolCallId,
                        toolName: toolName,
                        args: args,
                        partialResult: partialResult
                    ))
                }
            case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError):
                enqueueOnEventQueue {
                    _ = await hookRunner.emit(ToolExecutionEndEvent(
                        toolCallId: toolCallId,
                        toolName: toolName,
                        result: result,
                        isError: isError
                    ))
                }
            }
        }

        emit(.agent(event))

        if case .agentEnd = event, let lastAssistantMessage {
            self.lastAssistantMessage = nil
            beginPostRunTask()
            Task { [weak self] in
                defer { self?.finishPostRunTask() }
                guard let self else { return }
                if self.isRetryableError(lastAssistantMessage) {
                    let didRetry = await self.handleRetryableError(lastAssistantMessage)
                    if didRetry { return }
                }
                await self.checkAutoCompaction(lastAssistantMessage)
            }
        }
    }

    private func isRetryableError(_ message: AssistantMessage) -> Bool {
        guard message.stopReason == .error, let errorMessage = message.errorMessage else { return false }
        let contextWindow = agent.state.model.contextWindow
        if isContextOverflow(message, contextWindow: contextWindow) { return false }
        // Pattern accumulated across upstream releases:
        //   v0.66.0: `request ended without sending any chunks` (broken upstream connection)
        //   v0.67.67: `Network connection lost.` (dropped provider connection)
        //   v0.70.0: `http2 request did not get a response` (Bedrock/Smithy HTTP/2 transport failure)
        let pattern = "overloaded|rate.?limit|too many requests|429|500|502|503|504|service.?unavailable|server.?error|internal.?error|connection.?error|connection.?refused|other side closed|fetch failed|upstream.?connect|reset before headers|terminated|network.?error|provider.?returned.?error|socket hang up|timed?.?out|timeout|retry.?delay|request ended without sending any chunks|network connection lost|http2 request did not get a response|http/2 request did not get a response"
        return errorMessage.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func handleRetryableError(_ message: AssistantMessage) async -> Bool {
        let settings = settingsManager.getRetrySettings()
        guard settings.enabled ?? true else { return false }

        retryAttempt += 1

        if retryAttempt > (settings.maxRetries ?? 3) {
            emit(.autoRetryEnd(success: false, attempt: retryAttempt - 1, finalError: message.errorMessage))
            retryAttempt = 0
            retryAbort = nil
            retryTask = nil
            return false
        }

        let delayBase = settings.baseDelayMs ?? 2000
        let delayMs = delayBase * (1 << max(0, retryAttempt - 1))

        emit(.autoRetryStart(
            attempt: retryAttempt,
            maxAttempts: settings.maxRetries ?? 3,
            delayMs: delayMs,
            errorMessage: message.errorMessage ?? "Unknown error"
        ))

        let messages = agent.state.messages
        if let last = messages.last, last.role == "assistant" {
            agent.messages = Array(messages.dropLast())
        }

        let token = CancellationToken()
        retryAbort = token
        let attempt = retryAttempt
        beginPostRunTask()
        retryTask = Task { [weak self] in
            defer { self?.finishPostRunTask() }
            await self?.performRetry(delayMs: delayMs, attempt: attempt, token: token)
        }

        return true
    }

    /// Checks whether auto-compaction should be triggered after an assistant
    /// message completes.  Handles both overflow errors and threshold-based
    /// compaction.  Uses `lastSuccessfulUsage` for threshold checks after
    /// error responses (4D-4) and sets `overflowRecoveryAttempted` so stale
    /// pre-compaction usage doesn't retrigger (4D-3).
    private func checkAutoCompaction(_ message: AssistantMessage) async {
        guard autoCompactionEnabled, !isCompactingInternal else { return }

        let contextWindow = agent.state.model.contextWindow
        guard contextWindow > 0 else { return }

        // Overflow-based compaction (error says context too large).
        if isContextOverflow(message, contextWindow: contextWindow) {
            guard !overflowRecoveryAttempted else { return }
            overflowRecoveryAttempted = true
            await runAutoCompaction(reason: .overflow, willRetry: true)
            // After compaction succeeds, clear the flag so a *new* overflow
            // (at a genuinely larger context) can still trigger.
            overflowRecoveryAttempted = false
            return
        }

        // Threshold-based compaction (context usage exceeds 90%).
        // For error responses use the last successful usage, not the error's
        // potentially-zero token counts (4D-4).
        let usage: Usage
        if message.stopReason == .error, let lastGood = lastSuccessfulUsage {
            usage = lastGood
        } else {
            usage = message.usage
        }

        let inputTokens = usage.input + usage.cacheRead
        let threshold = Double(contextWindow) * 0.9
        if Double(inputTokens) >= threshold {
            // Prevent stale pre-compaction usage from retriggering (4D-3).
            guard !overflowRecoveryAttempted else { return }
            overflowRecoveryAttempted = true
            await runAutoCompaction(reason: .threshold, willRetry: false)
            overflowRecoveryAttempted = false
        }
    }

    func runAutoCompaction(
        reason: AutoCompactionReason,
        willRetry: Bool,
        compactBlock: (() async throws -> CompactionResult?)? = nil
    ) async {
        if isCompactingInternal { return }
        if compactBlock != nil {
            isCompactingInternal = true
        }
        defer {
            if compactBlock != nil {
                isCompactingInternal = false
            }
        }

        emit(.autoCompactionStart(reason: reason))

        var result: CompactionResult?
        var aborted = false
        do {
            if let compactBlock {
                result = try await compactBlock()
            } else {
                result = try await compact()
            }
        } catch is CancellationError {
            aborted = true
        } catch AgentSessionError.compactionCancelled {
            aborted = true
        } catch {
            aborted = false
        }

        emit(.autoCompactionEnd(result: result, aborted: aborted, willRetry: willRetry))

        if pendingMessageCount == 0, agent.hasQueuedMessages() {
            try? await agent.continue()
        }
    }

    private func performRetry(delayMs: Int, attempt: Int, token: CancellationToken) async {
        do {
            try await sleepWithCancellation(delayMs: delayMs, token: token)
        } catch {
            let shouldEmit = retryAttempt > 0
            retryAttempt = 0
            retryAbort = nil
            retryTask = nil
            if shouldEmit {
                emit(.autoRetryEnd(success: false, attempt: attempt, finalError: "Retry cancelled"))
            }
            return
        }

        retryAbort = nil
        do {
            try await agent.continue()
        } catch {
            // Retry errors are handled on the next agent_end.
        }
    }

    private func sleepWithCancellation(delayMs: Int, token: CancellationToken) async throws {
        guard delayMs > 0 else { return }
        var remaining = UInt64(delayMs) * 1_000_000
        let step: UInt64 = 100_000_000
        while remaining > 0 {
            if Task.isCancelled || token.isCancelled {
                throw CancellationError()
            }
            let slice = min(step, remaining)
            try await Task.sleep(nanoseconds: slice)
            remaining -= slice
        }
    }

    public var isStreaming: Bool {
        agent.state.isStreaming
    }

    /// Wait until the active agent run has completed its lifecycle hooks.
    /// Returns immediately when the session is already settled.
    public func waitForIdle() async {
        await idleWaiter.waitForIdle()
    }

    public var messages: [AgentMessage] {
        agent.state.messages
    }

    public var sessionFile: String? {
        sessionManager.getSessionFile()
    }

    public var sessionId: String {
        sessionManager.getSessionId()
    }

    public var pendingMessageCount: Int {
        steeringMessages.count + followUpMessages.count
    }

    public var scopedModels: [ScopedModel] {
        scopedModelsInternal
    }

    public func setScopedModels(_ scopedModels: [ScopedModel]) {
        scopedModelsInternal = scopedModels
    }

    public func getActiveToolNames() -> [String] {
        agent.state.tools.map { $0.name }
    }

    public func getAllToolNames() -> [String] {
        Array(toolRegistry.keys)
    }

    public func getAllTools() -> [ToolInfo] {
        toolRegistry.values.map { ToolInfo(name: $0.name, description: $0.description) }
    }

    private func getHookCommands() -> [HookSlashCommandInfo] {
        let extensionCommands = (_hookRunner?.getRegisteredCommands() ?? []).map { command in
            HookSlashCommandInfo(
                name: command.name,
                description: command.description,
                source: "extension",
                sourceInfo: command.sourceInfo
            )
        }
        let prompts = promptTemplates.map { template in
            HookSlashCommandInfo(
                name: template.name,
                description: template.description,
                source: "prompt",
                sourceInfo: template.sourceInfo
            )
        }
        let skills = resourceLoader.getSkills().skills.map { skill in
            HookSlashCommandInfo(
                name: "skill:\(skill.name)",
                description: skill.description,
                source: "skill",
                sourceInfo: skill.sourceInfo
            )
        }
        return extensionCommands + prompts + skills
    }

    /// Build the effective system prompt by appending any registered tool prompt snippets.
    private func effectiveSystemPrompt(_ base: String) -> String {
        let snippets = toolPromptSnippets
        guard !snippets.isEmpty else { return base }
        let combined = snippets.values.sorted().joined(separator: "\n\n")
        return base + "\n\n" + combined
    }

    public func setActiveToolsByName(_ toolNames: [String]) {
        var tools: [AgentTool] = []
        var validNames: [String] = []
        for name in toolNames {
            if let tool = toolRegistry[name] {
                tools.append(tool)
                validNames.append(name)
            }
        }
        agent.tools = tools

        if let rebuildSystemPrompt {
            baseSystemPrompt = rebuildSystemPrompt(validNames)
            agent.systemPrompt = effectiveSystemPrompt(baseSystemPrompt)
        }
    }

    public func reload() async {
        await resourceLoader.reload()
        promptTemplatesInternal = resourceLoader.getPrompts().prompts
        if let rebuildSystemPrompt {
            let activeToolNames = getActiveToolNames()
            baseSystemPrompt = rebuildSystemPrompt(activeToolNames)
            agent.systemPrompt = effectiveSystemPrompt(baseSystemPrompt)
        }
    }

    private func hasAuthForModel(_ model: Model) async -> Bool {
        let auth = await modelRegistry.getApiKeyAndHeaders(model)
        if auth.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        return !(auth.headers?.isEmpty ?? true)
    }

    /// Result of a `/reload`-triggered extension swap.
    public struct ReloadExtensionsResult: Sendable {
        public var droppedPaths: [String]
        public var loadedPaths: [String]
        public var errors: [ExtensionLoadError]

        public init(droppedPaths: [String], loadedPaths: [String], errors: [ExtensionLoadError]) {
            self.droppedPaths = droppedPaths
            self.loadedPaths = loadedPaths
            self.errors = errors
        }
    }

    /// Re-discover, re-compile, and swap extension dylibs while the session is live.
    ///
    /// 1. Emits `session_shutdown(reason: .reload)` to currently-loaded extensions so they can
    ///    release UI widgets, status entries, footers, etc.
    /// 2. Calls the closure provided by `createAgentSession()` to discover and compile fresh
    ///    extensions from disk.
    /// 3. Replaces extension hooks on the runner (settings hooks are preserved).
    /// 4. Emits `session_start(reason: .reload)` to the new extension instances.
    ///
    /// Settings-defined hooks are not touched. Old extension dylibs remain loaded in the
    /// process (RTLD_LOCAL prevents collisions with the new ones), but their handlers are
    /// detached from the runner so they no longer receive events.
    @discardableResult
    public func reloadExtensions() async -> ReloadExtensionsResult {
        guard let hookRunner = _hookRunner, let reloadHook = reloadExtensionsHookInternal else {
            return ReloadExtensionsResult(droppedPaths: [], loadedPaths: [], errors: [])
        }

        // 1. Notify currently-loaded extensions before they're swapped out.
        await hookRunner.emitToExtensions(SessionShutdownEvent(reason: .reload))

        // 2. Snapshot the current extension-tool roster so we can diff after the swap.
        let oldExtensionToolNames = hookRunner.getExtensionToolNames()

        // 3. Re-discover and re-compile.
        let result = await reloadHook()

        // 4. Swap. Returns the paths that were dropped so the caller can log them.
        let dropped = hookRunner.replaceExtensionHooks(result.hooks)

        // 5. Refresh extension tools on the agent: drop the old, add the new.
        if let wrap = wrapExtensionToolsInternal {
            let newExtensionTools = hookRunner.getExtensionTools()
            let newExtensionToolNames = Set(newExtensionTools.map { $0.name })
            let removedToolNames = oldExtensionToolNames.subtracting(newExtensionToolNames)

            if !removedToolNames.isEmpty || !newExtensionTools.isEmpty {
                let wrappedNew = wrap(newExtensionTools)
                var registry = toolRegistry
                for name in removedToolNames {
                    registry.removeValue(forKey: name)
                }
                for tool in wrappedNew {
                    registry[tool.name] = tool
                }
                toolRegistry = registry

                // Apply to agent.tools too: drop removed tools, replace surviving extension
                // tools with their re-wrapped versions, leave built-ins/custom-tools alone.
                let wrappedByName = Dictionary(uniqueKeysWithValues: wrappedNew.map { ($0.name, $0) })
                var newActive: [AgentTool] = []
                for tool in agent.tools {
                    if removedToolNames.contains(tool.name) {
                        continue
                    }
                    if let replacement = wrappedByName[tool.name] {
                        newActive.append(replacement)
                    } else {
                        newActive.append(tool)
                    }
                }
                // Add brand-new extension tools that weren't already active.
                let activeNames = Set(newActive.map { $0.name })
                for tool in wrappedNew where !activeNames.contains(tool.name) {
                    newActive.append(tool)
                }
                agent.tools = newActive
            }
        }

        // 6. Notify the freshly-loaded extensions.
        await hookRunner.emitToExtensions(SessionStartEvent(reason: .reload))
        await extendResourcesFromExtensions(reason: .reload)

        return ReloadExtensionsResult(
            droppedPaths: dropped,
            loadedPaths: result.hooks.map { $0.path },
            errors: result.errors
        )
    }

    private func extendResourcesFromExtensions(reason: ResourcesDiscoverReason) async {
        guard let hookRunner = _hookRunner else {
            return
        }

        let extensionResources = hookRunner.hasHandlers("resources_discover")
            ? await hookRunner.emitResourcesDiscover(cwd: sessionManager.getCwd(), reason: reason)
            : ResourceExtensionPaths()

        resourceLoader.extendResources(extensionResources)
        promptTemplatesInternal = resourceLoader.getPrompts().prompts

        if let rebuildSystemPrompt {
            let activeToolNames = getActiveToolNames()
            baseSystemPrompt = rebuildSystemPrompt(activeToolNames)
            agent.systemPrompt = effectiveSystemPrompt(baseSystemPrompt)
        }
    }

    private func preparePromptMessages(_ text: String, options: PromptOptions? = nil) async throws -> [AgentMessage] {
        if isStreaming || isBranchSummarizing {
            throw AgentSessionError.alreadyProcessingQueue
        }

        if agent.state.model.id.isEmpty {
            throw AgentSessionError.noModelSelected(authPath: getAuthPath())
        }

        if !(await hasAuthForModel(agent.state.model)) {
            throw AgentSessionError.missingApiKeyForProvider(
                provider: agent.state.model.provider,
                authPath: getAuthPath()
            )
        }

        let expandedText = expandPromptText(
            text,
            expandSlashCommands: options?.expandSlashCommands ?? true,
            expandPromptTemplates: options?.expandPromptTemplates ?? true
        )
        var messages: [AgentMessage] = []
        if !pendingNextTurnMessages.isEmpty {
            for message in pendingNextTurnMessages {
                messages.append(makeHookAgentMessage(message))
            }
            pendingNextTurnMessages.removeAll()
        }
        messages.append(buildUserMessage(text: expandedText, images: options?.images))
        var systemPromptAppend: String?
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("before_agent_start") {
            if let result = await hookRunner.emitBeforeAgentStart(expandedText, options?.images) {
                if let hookMessages = result.messages {
                    for message in hookMessages {
                        let hookMessage = HookMessage(
                            customType: message.customType,
                            content: message.content,
                            display: message.display,
                            details: message.details,
                            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                        )
                        messages.append(makeHookAgentMessage(hookMessage))
                    }
                }
                systemPromptAppend = result.systemPromptAppend
            }
        }
        if let systemPromptAppend, !systemPromptAppend.isEmpty {
            agent.systemPrompt = effectiveSystemPrompt("\(baseSystemPrompt)\n\n\(systemPromptAppend)")
        } else {
            agent.systemPrompt = effectiveSystemPrompt(baseSystemPrompt)
        }
        return messages
    }

    /// Submit a prompt after running all synchronous preflight work, then continue the model
    /// turn in the returned task. This lets RPC callers acknowledge accepted prompts without
    /// waiting for the whole assistant response while still surfacing immediate rejection.
    @discardableResult
    public func submitPrompt(_ text: String, options: PromptOptions? = nil) async throws -> Task<Void, Error> {
        let messages = try await preparePromptMessages(text, options: options)
        await idleWaiter.beginRun()
        let task = Task { [weak self, agent] in
            defer {
                Task { [weak self] in
                    await self?.emitAgentSettledIfNeeded()
                }
            }
            try await agent.prompt(messages)
        }
        await Task.yield()
        return task
    }

    public func prompt(_ text: String, options: PromptOptions? = nil) async throws {
        let task = try await submitPrompt(text, options: options)
        try await task.value
    }

    public func `continue`() async throws {
        if isStreaming {
            throw AgentSessionError.alreadyProcessingContinue
        }
        try await runUntilSettled { [agent] in
            try await agent.continue()
        }
    }

    public func steer(_ text: String) {
        let expandedText = expandPromptText(text)
        steeringMessages.append(expandedText)
        agent.steer(buildUserMessage(text: expandedText, images: nil))
    }

    public func followUp(_ text: String) {
        let expandedText = expandPromptText(text)
        followUpMessages.append(expandedText)
        agent.followUp(buildUserMessage(text: expandedText, images: nil))
    }

    public func sendHookMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) async {
        let hookMessage = HookMessage(
            customType: message.customType,
            content: message.content,
            display: message.display,
            details: message.details
        )
        let agentMessage = makeHookAgentMessage(hookMessage)

        if options?.deliverAs == .nextTurn {
            pendingNextTurnMessages.append(hookMessage)
            return
        }

        if isStreaming {
            if options?.deliverAs == .followUp {
                agent.followUp(agentMessage)
            } else {
                agent.steer(agentMessage)
            }
            return
        }

        if options?.triggerTurn == true {
            do {
                try await agent.prompt(agentMessage)
            } catch {
                return
            }
            return
        }

        agent.appendMessage(agentMessage)
        _ = sessionManager.appendCustomMessage(
            message.customType,
            message.content,
            message.display,
            details: message.details
        )
    }

    public func clearQueue() -> (steering: [String], followUp: [String]) {
        let steering = steeringMessages
        let follow = followUpMessages
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        return (steering, follow)
    }

    public func abort() async {
        abortRetry()
        agent.abort()
        await waitForIdle()
        compactionAbort?.cancel()
        branchSummaryAbort?.cancel()
        bashAbort?.cancel()
    }

    public var isBashRunning: Bool {
        bashAbort != nil
    }

    public func executeBash(
        _ command: String,
        excludeFromContext: Bool = false,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> BashResult {
        let abortToken = CancellationToken()
        bashAbort = abortToken
        defer { bashAbort = nil }

        let result = try await PiSwiftCodingAgent.executeBash(command, options: BashExecutorOptions(onChunk: onChunk, signal: abortToken))
        recordBashResult(command, result, excludeFromContext: excludeFromContext)
        return result
    }

    public func recordBashResult(_ command: String, _ result: BashResult, excludeFromContext: Bool) {
        guard !excludeFromContext else { return }
        let message = BashExecutionMessage(
            command: command,
            output: result.output,
            exitCode: result.exitCode,
            cancelled: result.cancelled,
            truncated: result.truncated,
            fullOutputPath: result.fullOutputPath
        )

        if isStreaming {
            pendingBashMessages.append(message)
        } else {
            let agentMessage = makeBashExecutionAgentMessage(message)
            agent.appendMessage(agentMessage)
            _ = sessionManager.appendMessage(agentMessage)
        }
    }

    public func abortBash() {
        bashAbort?.cancel()
    }

    private func flushPendingBashMessages() {
        guard !pendingBashMessages.isEmpty else { return }
        for message in pendingBashMessages {
            let agentMessage = makeBashExecutionAgentMessage(message)
            agent.appendMessage(agentMessage)
            _ = sessionManager.appendMessage(agentMessage)
        }
        pendingBashMessages.removeAll()
    }

    public var autoCompactionEnabled: Bool {
        settingsManager.getCompactionEnabled()
    }

    public var isCompacting: Bool {
        isCompactingInternal
    }

    public var steeringMode: String {
        agent.steeringMode.rawValue
    }

    public var followUpMode: String {
        agent.followUpMode.rawValue
    }

    public func setAutoCompactionEnabled(_ enabled: Bool) {
        settingsManager.setCompactionEnabled(enabled)
    }

    public func setAutoRetryEnabled(_ enabled: Bool) {
        settingsManager.setRetryEnabled(enabled)
    }

    public func abortRetry() {
        retryAbort?.cancel()
        retryTask?.cancel()
    }

    public func newSession(_ options: NewSessionOptions? = nil) async -> Bool {
        let previousSession = sessionFile
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_switch") {
            if let result = await hookRunner.emit(SessionBeforeSwitchEvent(reason: .new)) as? SessionBeforeSwitchResult,
               result.cancel {
                return false
            }
        }
        await abort()
        agent.reset()
        _ = sessionManager.newSession(options)
        agent.sessionId = sessionManager.getSessionId()
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        pendingNextTurnMessages.removeAll()
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionStartEvent(reason: .new, previousSessionFile: previousSession))
        }
        await emitCustomToolSessionEvent(.switch, previousSessionFile: previousSession)
        return true
    }

    public func switchSession(_ sessionPath: String) async -> Bool {
        let previousSession = sessionFile
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_switch") {
            if let result = await hookRunner.emit(SessionBeforeSwitchEvent(reason: .resume, targetSessionFile: sessionPath)) as? SessionBeforeSwitchResult,
               result.cancel {
                return false
            }
        }
        await abort()
        agent.reset()
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        pendingNextTurnMessages.removeAll()
        sessionManager.setSessionFile(sessionPath)
        agent.sessionId = sessionManager.getSessionId()
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionStartEvent(reason: .resume, previousSessionFile: previousSession))
        }
        await syncAgentContext()
        await emitCustomToolSessionEvent(.switch, previousSessionFile: previousSession)
        return true
    }

    public func getAvailableModels() async -> [Model] {
        await modelRegistry.getAvailable()
    }

    /// Re-resolve the active model after provider registration changes (e.g. login/logout).
    /// If the current model is no longer available, switch to the best available model.
    public func refreshActiveModel() async {
        let current = agent.state.model
        // Check if current model still has usable auth, including custom headers.
        if await hasAuthForModel(current) {
            return
        }
        // Current model lost its API key — find a fallback
        let available = await modelRegistry.getAvailable()
        if let fallback = available.first {
            agent.model = fallback
            sessionManager.appendModelChange(fallback.provider, fallback.id)
            settingsManager.setDefaultModelAndProvider(fallback.provider, fallback.id)
            setThinkingLevel(agent.state.thinkingLevel)
        }
    }

    private func emitModelSelect(
        nextModel: Model,
        previousModel: Model?,
        source: ModelSelectSource
    ) async {
        guard let hookRunner = _hookRunner else { return }
        if modelsAreEqual(previousModel, nextModel) { return }
        _ = await hookRunner.emit(ModelSelectEvent(model: nextModel, previousModel: previousModel, source: source))
    }

    public func setModel(_ model: Model) async throws {
        guard await hasAuthForModel(model) else {
            throw AgentSessionError.missingApiKeyForModel(provider: model.provider, modelId: model.id)
        }
        let previousModel = agent.state.model
        agent.model = model
        sessionManager.appendModelChange(model.provider, model.id)
        settingsManager.setDefaultModelAndProvider(model.provider, model.id)
        setThinkingLevel(agent.state.thinkingLevel)
        await emitModelSelect(nextModel: model, previousModel: previousModel, source: .set)
    }

    public func cycleModel(direction: ModelCycleDirection = .forward) async throws -> ModelCycleResult? {
        if !scopedModelsInternal.isEmpty {
            return try await cycleScopedModel(direction)
        }
        return try await cycleAvailableModel(direction)
    }

    private func cycleScopedModel(_ direction: ModelCycleDirection) async throws -> ModelCycleResult? {
        guard scopedModelsInternal.count > 1 else { return nil }
        let current = agent.state.model
        let currentIndex = scopedModelsInternal.firstIndex { modelsAreEqual($0.model, current) } ?? 0
        let count = scopedModelsInternal.count
        let nextIndex = direction == .forward ? (currentIndex + 1) % count : (currentIndex - 1 + count) % count
        let next = scopedModelsInternal[nextIndex]
        guard await hasAuthForModel(next.model) else {
            throw AgentSessionError.missingApiKeyForModel(provider: next.model.provider, modelId: next.model.id)
        }
        let previousModel = agent.state.model
        let currentThinkingLevel = agent.state.thinkingLevel
        agent.model = next.model
        sessionManager.appendModelChange(next.model.provider, next.model.id)
        settingsManager.setDefaultModelAndProvider(next.model.provider, next.model.id)
        // Preserve the user's current thinking level across model switches rather than
        // resetting to the scoped model's default.
        setThinkingLevel(currentThinkingLevel)
        await emitModelSelect(nextModel: next.model, previousModel: previousModel, source: .cycle)
        return ModelCycleResult(model: next.model, thinkingLevel: agent.state.thinkingLevel, isScoped: true)
    }

    private func cycleAvailableModel(_ direction: ModelCycleDirection) async throws -> ModelCycleResult? {
        let models = await modelRegistry.getAvailable()
        guard models.count > 1 else { return nil }
        let current = agent.state.model
        let currentIndex = models.firstIndex { modelsAreEqual($0, current) } ?? 0
        let count = models.count
        let nextIndex = direction == .forward ? (currentIndex + 1) % count : (currentIndex - 1 + count) % count
        let next = models[nextIndex]
        guard await hasAuthForModel(next) else {
            throw AgentSessionError.missingApiKeyForModel(provider: next.provider, modelId: next.id)
        }
        let previousModel = agent.state.model
        agent.model = next
        sessionManager.appendModelChange(next.provider, next.id)
        settingsManager.setDefaultModelAndProvider(next.provider, next.id)
        setThinkingLevel(agent.state.thinkingLevel)
        await emitModelSelect(nextModel: next, previousModel: previousModel, source: .cycle)
        return ModelCycleResult(model: next, thinkingLevel: agent.state.thinkingLevel, isScoped: false)
    }

    public func setThinkingLevel(_ level: ThinkingLevel) {
        var effective = level
        if !agent.state.model.reasoning {
            effective = .off
        } else {
            let requested = PiSwiftAI.ModelThinkingLevel(rawValue: level.rawValue) ?? .off
            let clamped = PiSwiftAI.clampThinkingLevel(model: agent.state.model, requested: requested)
            effective = ThinkingLevel(rawValue: clamped.rawValue) ?? .off
        }
        agent.thinkingLevel = effective
        sessionManager.appendThinkingLevelChange(effective.rawValue)
        settingsManager.setDefaultThinkingLevel(effective.rawValue)
    }

    public func cycleThinkingLevel() -> ThinkingLevel? {
        guard agent.state.model.reasoning else { return nil }
        let levels = PiSwiftAI.getSupportedThinkingLevels(agent.state.model).compactMap { ThinkingLevel(rawValue: $0.rawValue) }
        guard !levels.isEmpty else { return nil }
        let currentIndex = levels.firstIndex(of: agent.state.thinkingLevel) ?? 0
        let next = levels[(currentIndex + 1) % levels.count]
        setThinkingLevel(next)
        return next
    }

    public func setSteeringMode(_ mode: AgentSteeringMode) {
        agent.steeringMode = mode
        settingsManager.setSteeringMode(mode.rawValue)
    }

    public func setFollowUpMode(_ mode: AgentFollowUpMode) {
        agent.followUpMode = mode
        settingsManager.setFollowUpMode(mode.rawValue)
    }

    public func getSessionStats() -> SessionStats {
        let state = agent.state
        let userMessages = state.messages.filter { $0.role == "user" }.count
        let assistantMessages = state.messages.filter { $0.role == "assistant" }.count
        let toolResults = state.messages.filter { $0.role == "toolResult" }.count

        var toolCalls = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0

        for message in state.messages {
            if case .assistant(let assistant) = message {
                toolCalls += assistant.content.filter {
                    if case .toolCall = $0 { return true }
                    return false
                }.count
                totalInput += assistant.usage.input
                totalOutput += assistant.usage.output
                totalCacheRead += assistant.usage.cacheRead
                totalCacheWrite += assistant.usage.cacheWrite
                totalCost += assistant.usage.cost.total
            }
        }

        let tokens = SessionStats.TokenStats(
            input: totalInput,
            output: totalOutput,
            cacheRead: totalCacheRead,
            cacheWrite: totalCacheWrite,
            total: totalInput + totalOutput + totalCacheRead + totalCacheWrite
        )
        return SessionStats(
            sessionFile: sessionFile,
            sessionId: sessionId,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            toolCalls: toolCalls,
            toolResults: toolResults,
            totalMessages: state.messages.count,
            tokens: tokens,
            cost: totalCost,
            contextUsage: getContextUsage()
        )
    }

    /// v0.70.0: token-budget usage relative to the active model's context window.
    /// Returns nil when:
    ///   - no model selected
    ///   - contextWindow <= 0
    /// `tokens` and `percent` are nil when the latest assistant usage is pre-compaction
    /// (we can only trust usage from an assistant that responded after the latest compaction —
    /// otherwise the count reflects a pre-compaction snapshot that's no longer valid).
    public func getContextUsage() -> ContextUsage? {
        let model = agent.state.model
        let contextWindow = model.contextWindow
        guard contextWindow > 0 else { return nil }

        // Find the latest assistant message that responded AFTER any compaction.
        // The simplest approximation: walk messages backwards looking for an assistant
        // whose timestamp is after the latest compaction marker. The Swift port doesn't
        // currently surface a separate compaction-entry timestamp from SessionManager, so
        // we use the last assistant's usage directly. This matches upstream's behavior in
        // the common (no-compaction-since-last-turn) case; a follow-up can refine the
        // post-compaction guard once the SessionManager branch-entry API exposes that
        // marker to PiSwift consumers.
        let lastAssistant = agent.state.messages.reversed().first { message in
            if case .assistant = message { return true }
            return false
        }
        guard case .assistant(let assistant) = lastAssistant else {
            return ContextUsage(tokens: nil, contextWindow: contextWindow, percent: nil)
        }
        let used = assistant.usage.input + assistant.usage.cacheRead
        let percent = Double(used) / Double(contextWindow) * 100.0
        return ContextUsage(tokens: used, contextWindow: contextWindow, percent: percent)
    }

    public func exportToHtml(_ outputPath: String? = nil) throws -> String {
        let themeName = settingsManager.getTheme()
        return try exportSessionToHtml(
            sessionManager,
            agent.state,
            ExportOptions(outputPath: outputPath, themeName: themeName)
        )
    }

    public func getLastAssistantText() -> String? {
        let lastAssistant = agent.state.messages.reversed().first { message in
            if case .assistant(let assistant) = message {
                return !(assistant.stopReason == .aborted && assistant.content.isEmpty)
            }
            return false
        }
        guard case .assistant(let assistant)? = lastAssistant else { return nil }
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let text) = block {
                return text.text
            }
            return nil
        }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    public func getUserMessagesForForking() -> [ForkableMessage] {
        let entries = sessionManager.getEntries()
        var result: [ForkableMessage] = []
        for entry in entries {
            if case .message(let msg) = entry, case .user(let user) = msg.message {
                let text = extractUserContentText(user.content)
                result.append(ForkableMessage(entryId: entry.id, text: text))
            }
        }
        return result
    }

    /// v0.68.0: clone the current branch into a new session at the latest entry.
    ///
    /// Equivalent to upstream `runtimeHost.fork(leafId, { position: "at" })`. Unlike the
    /// regular `fork(_:)` (which forks BEFORE a chosen user message — dropping it from the
    /// new branch), `/clone` includes everything up through and including the leaf entry.
    /// Use this for "duplicate-and-keep-going" workflows where the user wants to branch off
    /// without rewinding any messages.
    @discardableResult
    public func cloneAtLeaf() async throws -> Bool {
        guard let leafId = sessionManager.getLeafId() else {
            throw AgentSessionError.invalidEntryIdForForking
        }
        let previousSession = sessionFile

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_fork") {
            if let result = await hookRunner.emit(SessionBeforeForkEvent(entryId: leafId)) as? SessionBeforeForkResult,
               result.cancel {
                return false
            }
        }

        // position: "at" — branch from the leaf so the new session inherits the leaf entry
        // (rather than forking from its parent, which would drop it).
        guard sessionManager.createBranchedSession(leafId) != nil else {
            throw AgentSessionError.invalidEntryIdForForking
        }
        agent.sessionId = sessionManager.getSessionId()

        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionStartEvent(reason: .fork, previousSessionFile: previousSession))
        }

        await emitCustomToolSessionEvent(.fork, previousSessionFile: previousSession)
        pendingNextTurnMessages.removeAll()
        await syncAgentContext()
        return true
    }

    public func fork(_ entryId: String) async throws -> (selectedText: String, cancelled: Bool) {
        let selectedEntry = sessionManager.getEntry(entryId)
        guard case .message(let msg) = selectedEntry, case .user(let user) = msg.message else {
            throw AgentSessionError.invalidEntryIdForForking
        }

        let selectedText = extractUserContentText(user.content)
        let previousSession = sessionFile
        var skipConversationRestore = false

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_fork") {
            if let result = await hookRunner.emit(SessionBeforeForkEvent(entryId: entryId)) as? SessionBeforeForkResult {
                if result.cancel {
                    return (selectedText, true)
                }
                skipConversationRestore = result.skipConversationRestore
            }
        }

        if msg.parentId == nil {
            _ = sessionManager.newSession()
        } else if let parentId = msg.parentId {
            guard sessionManager.createBranchedSession(parentId) != nil else {
                throw AgentSessionError.invalidEntryIdForForking
            }
        }
        agent.sessionId = sessionManager.getSessionId()

        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionStartEvent(reason: .fork, previousSessionFile: previousSession))
        }

        await emitCustomToolSessionEvent(.fork, previousSessionFile: previousSession)
        pendingNextTurnMessages.removeAll()

        if !skipConversationRestore {
            await syncAgentContext()
        }

        return (selectedText, false)
    }

    public func navigateTree(
        _ targetId: String,
        summarize: Bool = false,
        customInstructions: String? = nil
    ) async -> (editorText: String?, cancelled: Bool, aborted: Bool?, summaryEntry: BranchSummaryEntry?) {
        let oldLeafId = sessionManager.getLeafId()
        if targetId == oldLeafId {
            return (nil, false, nil, nil)
        }

        guard let targetEntry = sessionManager.getEntry(targetId) else {
            return (nil, true, nil, nil)
        }

        let collection = collectEntriesForBranchSummary(sessionManager, oldLeafId, targetId)
        let preparation = TreePreparation(
            targetId: targetId,
            oldLeafId: oldLeafId,
            commonAncestorId: collection.commonAncestorId,
            entriesToSummarize: collection.entries,
            userWantsSummary: summarize
        )

        branchSummaryAbort = CancellationToken()
        isBranchSummarizing = true
        defer { isBranchSummarizing = false }
        var summaryText: String?
        var summaryDetails: AnyCodable?
        var fromHook = false

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_tree") {
            if let result = await hookRunner.emit(SessionBeforeTreeEvent(preparation: preparation, signal: branchSummaryAbort)) as? SessionBeforeTreeResult {
                if result.cancel {
                    return (nil, true, nil, nil)
                }
                if let summary = result.summary {
                    summaryText = summary.summary
                    summaryDetails = AnyCodable([
                        "readFiles": summary.readFiles ?? [],
                        "modifiedFiles": summary.modifiedFiles ?? [],
                    ])
                    fromHook = true
                }
            }
        }

        if summarize && summaryText == nil && !collection.entries.isEmpty {
            guard let model = agent.state.model as Model? else {
                return (nil, true, nil, nil)
            }
            let request = await modelRegistry.resolveModelRequest(model)
            if let apiKey = request.auth.apiKey {
                let options = GenerateBranchSummaryOptions(
                    model: request.model,
                    apiKey: apiKey,
                    headers: request.auth.headers,
                    signal: branchSummaryAbort,
                    customInstructions: customInstructions,
                    reserveTokens: settingsManager.getBranchSummarySettings().reserveTokens
                )
                let result = await generateBranchSummary(collection.entries, options)
                if result.aborted == true {
                    return (nil, true, true, nil)
                }
                if result.error != nil {
                    return (nil, true, nil, nil)
                }
                summaryText = result.summary
                let details = BranchSummaryDetails(readFiles: result.readFiles ?? [], modifiedFiles: result.modifiedFiles ?? [])
                summaryDetails = AnyCodable(["readFiles": details.readFiles, "modifiedFiles": details.modifiedFiles])
            }
        }

        let newLeafId: String?
        var editorText: String?

        switch targetEntry {
        case .message(let msg):
            if case .user(let user) = msg.message {
                newLeafId = msg.parentId
                editorText = extractUserContentText(user.content)
            } else {
                newLeafId = targetId
            }
        case .customMessage(let custom):
            newLeafId = custom.parentId
            switch custom.content {
            case .text(let text):
                editorText = text
            case .blocks(let blocks):
                editorText = blocks.compactMap { block in
                    if case .text(let text) = block { return text.text }
                    return nil
                }.joined()
            }
        default:
            newLeafId = targetId
        }

        var summaryEntry: BranchSummaryEntry?
        do {
            if let summaryText {
                let summaryId = try sessionManager.branchWithSummary(newLeafId, summaryText, details: summaryDetails, fromHook: fromHook)
                if case .branchSummary(let entry) = sessionManager.getEntry(summaryId) {
                    summaryEntry = entry
                }
            } else if newLeafId == nil {
                sessionManager.resetLeaf()
            } else if let newLeafId {
                try sessionManager.branch(newLeafId)
            }
        } catch {
            return (nil, true, nil, nil)
        }

        await syncAgentContext()

        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(SessionTreeEvent(newLeafId: sessionManager.getLeafId(), oldLeafId: oldLeafId, summaryEntry: summaryEntry, fromHook: summaryEntry != nil ? fromHook : nil))
        }

        await emitCustomToolSessionEvent(.tree, previousSessionFile: sessionFile)

        return (editorText, false, nil, summaryEntry)
    }

    public func abortCompaction() {
        compactionAbort?.cancel()
    }

    public func abortBranchSummary() {
        branchSummaryAbort?.cancel()
    }

    public func compact(customInstructions: String? = nil) async throws -> CompactionResult {
        isCompactingInternal = true
        defer { isCompactingInternal = false }
        compactionAbort = CancellationToken()
        defer { compactionAbort = nil }

        let model = agent.state.model
        let request = await modelRegistry.resolveModelRequest(model)
        let apiKey = request.auth.apiKey
        if apiKey == nil {
            throw AgentSessionError.missingApiKey(provider: model.provider)
        }

        let pathEntries = sessionManager.getBranch()
        let settings = settingsManager.getCompactionSettings()
        guard let preparation = prepareCompaction(pathEntries, settings) else {
            throw AgentSessionError.nothingToCompact
        }

        var hookCompaction: CompactionResult?
        var fromHook = false
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_compact") {
            if let result = await hookRunner.emit(SessionBeforeCompactEvent(preparation: preparation, branchEntries: pathEntries, customInstructions: customInstructions, signal: compactionAbort)) as? SessionBeforeCompactResult {
                if result.cancel {
                    throw AgentSessionError.compactionCancelled
                }
                if let compaction = result.compaction {
                    hookCompaction = compaction
                    fromHook = true
                }
            }
        }

        let result: CompactionResult
        if let hookCompaction {
            result = hookCompaction
        } else if let apiKey {
            result = try await PiSwiftCodingAgent.compact(
                preparation,
                request.model,
                apiKey,
                headers: request.auth.headers,
                customInstructions: customInstructions,
                signal: compactionAbort
            )
        } else {
            throw AgentSessionError.missingApiKey(provider: model.provider)
        }

        if compactionAbort?.isCancelled == true {
            throw AgentSessionError.compactionCancelled
        }

        _ = sessionManager.appendCompaction(
            result.summary,
            result.firstKeptEntryId,
            result.tokensBefore,
            details: result.details,
            fromHook: fromHook
        )

        await syncAgentContext()

        if let hookRunner = _hookRunner {
            if let entry = sessionManager.getEntries().compactMap({ entry -> CompactionEntry? in
                if case .compaction(let compaction) = entry { return compaction }
                return nil
            }).last {
                _ = await hookRunner.emit(SessionCompactEvent(compactionEntry: entry, fromHook: fromHook))
            }
        }

        return result
    }

    private func syncAgentContext() async {
        let context = sessionManager.buildSessionContext()
        let previousModel = agent.state.model
        agent.messages = context.messages
        if let modelInfo = context.model {
            if let model = modelRegistry.find(modelInfo.provider, modelInfo.modelId) {
                agent.model = model
                await emitModelSelect(nextModel: model, previousModel: previousModel, source: .restore)
            }
        }
        agent.thinkingLevel = ThinkingLevel(rawValue: context.thinkingLevel) ?? .off
    }

    private func buildUserMessage(text: String, images: [ImageContent]?) -> AgentMessage {
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        if let images {
            if settingsManager.getBlockImages() {
                if let data = "[blockImages] Blocked \(images.count) image(s) from being sent to provider\n".data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            } else {
                blocks.append(contentsOf: images.map { .image($0) })
            }
        }
        return AgentMessage.user(UserMessage(content: .blocks(blocks)))
    }

    private func extractUserMessageText(_ message: AgentMessage) -> String {
        switch message {
        case .user(let user):
            return extractUserContentText(user.content)
        default:
            return ""
        }
    }

    private func extractUserContentText(_ content: UserContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined()
        }
    }
}
