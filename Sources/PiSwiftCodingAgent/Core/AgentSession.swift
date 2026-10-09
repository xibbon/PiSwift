import Foundation
import PiSwiftAI
import PiSwiftAgent

// v1.0.4 #10343: all prompt paths use the same built-in contributions.
private let builtInToolPrompt: [String: ToolSystemPromptContribution] = [
    "read": readToolSystemPromptContribution,
    "bash": bashToolSystemPromptContribution,
    "edit": editToolSystemPromptContribution,
    "write": writeToolSystemPromptContribution,
]

public enum AutoCompactionReason: String, Sendable {
    case threshold
    case overflow
}

public enum AgentSessionEvent: Sendable {
    case agent(AgentEvent)
    case nestedToolExecution(NestedToolExecutionEvent)
    case entryAppended(SessionEntry)
    case agentSettled(aborted: Bool = false)
    case autoCompactionStart(reason: AutoCompactionReason)
    case autoCompactionEnd(result: CompactionResult?, aborted: Bool, willRetry: Bool, errorMessage: String? = nil)
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Int, errorMessage: String)
    case autoRetryEnd(success: Bool, attempt: Int, finalError: String?)

    public var type: String {
        switch self {
        case .agent(let event):
            return event.type
        case .nestedToolExecution(let event):
            switch event {
            case .start: return "tool_execution_start"
            case .update: return "tool_execution_update"
            case .end: return "tool_execution_end"
            }
        case .entryAppended:
            return "entry_appended"
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
    public var cacheWarmer: CacheWarmer?
    public var skillsSettings: SkillsSettings?
    public var eventBus: EventBus?
    /// Activate new defaultTools names on reload when the initial selection uses settings.
    public var usesDefaultTools: Bool
    /// Exact-name modifiers applied to defaults at startup and reload.
    public var defaultToolModifiers: [String]
    /// Tool names or patterns to remove. `*` matches any characters.
    public var excludedToolNames: Set<String>
    /// Tool names or patterns to permit. A non-empty set without an `mcp__` entry
    /// also keeps MCP tools registered for codemode and tool_search. Only tool_search
    /// can declare those unnamed MCP tools. An empty set permits no tools.
    public var allowedToolNames: Set<String>?
    public var toolRegistry: [String: AgentTool]?
    public var toolRegistryOrder: [String]?
    public var toolDefinitions: [String: CustomTool]?
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
    /// Runs user `!` commands when `executeBash` gets no operations. When nil, they use
    /// `BashExecutorRegistry`. Wired by `createAgentSession()` from its `bashOperations`.
    public var bashOperations: BashOperations?

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
        cacheWarmer: CacheWarmer? = nil,
        skillsSettings: SkillsSettings? = nil,
        eventBus: EventBus? = nil,
        usesDefaultTools: Bool = false,
        defaultToolModifiers: [String] = [],
        excludedToolNames: Set<String> = [],
        allowedToolNames: Set<String>? = nil,
        toolRegistry: [String: AgentTool]? = nil,
        toolRegistryOrder: [String]? = nil,
        toolDefinitions: [String: CustomTool]? = nil,
        rebuildSystemPrompt: (@Sendable ([String]) -> String)? = nil,
        reloadExtensionsHook: (@Sendable () async -> LoadExtensionsResult)? = nil,
        wrapExtensionTools: (@Sendable ([CustomTool]) -> [AgentTool])? = nil,
        bashOperations: BashOperations? = nil
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
        self.cacheWarmer = cacheWarmer
        self.skillsSettings = skillsSettings
        self.eventBus = eventBus
        self.usesDefaultTools = usesDefaultTools
        self.defaultToolModifiers = defaultToolModifiers
        self.excludedToolNames = excludedToolNames
        self.allowedToolNames = allowedToolNames
        self.toolRegistry = toolRegistry
        self.toolRegistryOrder = toolRegistryOrder
        self.toolDefinitions = toolDefinitions
        self.rebuildSystemPrompt = rebuildSystemPrompt
        self.reloadExtensionsHook = reloadExtensionsHook
        self.wrapExtensionTools = wrapExtensionTools
        self.bashOperations = bashOperations
    }
}

public struct ModelMutationOptions: Sendable {
    public var persist: Bool
    public init(persist: Bool = false) { self.persist = persist }
}

public struct PromptOptions: Sendable {
    public var expandSlashCommands: Bool?
    public var expandPromptTemplates: Bool?
    public var images: [ImageContent]?
    public var source: HookInputSource
    public var streamingBehavior: HookInputStreamingBehavior?
    public var preflightResult: (@Sendable (PromptDisposition) -> Void)?

    public init(expandSlashCommands: Bool? = nil, expandPromptTemplates: Bool? = nil, images: [ImageContent]? = nil,
                source: HookInputSource = .interactive,
                streamingBehavior: HookInputStreamingBehavior? = nil,
                preflightResult: (@Sendable (PromptDisposition) -> Void)? = nil) {
        self.expandSlashCommands = expandSlashCommands
        self.expandPromptTemplates = expandPromptTemplates
        self.images = images
        self.source = source
        self.streamingBehavior = streamingBehavior
        self.preflightResult = preflightResult
    }
}

public enum QueuedInputDisposition: String, Sendable { case handled, queued }
public enum PromptDisposition: String, Sendable { case handled, queued, started }

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
    case compactionInProgress
    case invalidBoundaryDraft
    case recoveryEntryMissing

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
        case .compactionInProgress:
            return "Compaction is already in progress"
        case .invalidBoundaryDraft:
            return "Invalid boundary draft"
        case .recoveryEntryMissing:
            return "Recovery attempt has no persisted source entry"
        }
    }
}

public final class AgentSession: Sendable {
    public let agent: Agent
    public let sessionManager: SessionManager
    public let settingsManager: SettingsManager
    public let modelRegistry: ModelRegistry
    public let cacheWarmer: CacheWarmer?
    public let eventBus: EventBus
    public let projectTrusted: Bool
    private let defaultToolHtmlRenderer = LockedState<(any ToolHtmlRenderer)?>(nil)

    /// Default renderer for all session exports. A renderer passed to exportToHtml takes precedence.
    public var toolHtmlRenderer: (any ToolHtmlRenderer)? {
        get { defaultToolHtmlRenderer.withLock { $0 } }
        set { defaultToolHtmlRenderer.withLock { $0 = newValue } }
    }

    private let bashOperations: BashOperations?
    private let state: LockedState<State>

    /// Serial queue for agent event processing.
    /// Ensures tool call/result interception from extensions happens in order.
    private let _agentEventQueue = LockedState<Task<Void, Never>?>(nil)
    private let idleWaiter = AgentSessionIdleWaiter()

    private struct QueuedCompactionPrompt: Sendable {
        var text: String
        var options: PromptOptions?
        var completion: QueuedPromptCompletion
    }

    private actor QueuedPromptCompletion {
        private enum Outcome: Sendable {
            case success
            case failure(String)
        }

        private var outcome: Outcome?
        private var waiters: [CheckedContinuation<Outcome, Never>] = []

        func wait() async throws {
            let outcome: Outcome
            if let current = self.outcome {
                outcome = current
            } else {
                outcome = await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }
            if case .failure(let message) = outcome {
                throw QueuedPromptDeliveryError(message: message)
            }
        }

        func succeed() {
            resolve(.success)
        }

        func fail(_ message: String) {
            resolve(.failure(message))
        }

        private func resolve(_ outcome: Outcome) {
            guard self.outcome == nil else { return }
            self.outcome = outcome
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: outcome)
            }
        }
    }

    private struct QueuedPromptDeliveryError: LocalizedError, Sendable {
        var message: String
        var errorDescription: String? { message }
    }

    private struct State: Sendable {
        var hookRunner: HookRunner?
        var hookEventObservers: [UUID: @Sendable (any HookEvent) -> Void] = [:]
        var hookEventUnsubscribe: (@Sendable () -> Void)?
        var hookEventGeneration = UUID()
        var customToolsInternal: [LoadedCustomTool]
        var scopedModels: [ScopedModel]
        var fileCommands: [FileSlashCommand]
        var promptTemplates: [PromptTemplate]
        var resourceLoader: ResourceLoader
        var unsubscribeAgent: (@Sendable () -> Void)?
        var eventListeners: [UUID: @Sendable (AgentSessionEvent) -> Void]
        var steeringMessages: [String]
        var followUpMessages: [String]
        var pendingCustomMessages: [HookMessage] = []
        var compactionFromExtension = false
        var pendingNextTurnMessages: [HookMessage]
        var lastAssistantMessage: AssistantMessage?
        var failedResponse: AssistantMessage?
        var lastAssistantEntryId: String?
        var lastToolResultEntryIds: [String: String] = [:]
        var lastAssistantToolResults: [ToolResultMessage] = []
        var lastActivityOutcome: AgentActivityOutcome = .completed
        var agentRunAbortRequested = false
        var isBeforeSettle = false
        var abortDuringBeforeSettle = false
        var isEmittingAgentSettled = false
        var deferredSettledActions: [@Sendable () async -> Void] = []
        var compactionAbort: CancellationToken?
        var branchSummaryAbort: CancellationToken?
        var retryAbort: CancellationToken?
        var retryAttempt: Int
        var retryTask: Task<Void, Never>?
        /// Retry/compaction follow-up work scheduled after an `agent_end` callback.
        /// The run cannot settle while this count is non-zero.
        var pendingPostRunTasks: Int
        var bashAbortTokens: [UUID: CancellationToken]
        var pendingBashMessages: [BashExecutionMessage]
        var isCompactingInternal: Bool
        var queuedCompactionPrompts: [QueuedCompactionPrompt]
        var overflowRecoveryAttempted: Bool
        var lastSuccessfulUsage: Usage?
        var isBranchSummarizing: Bool
        var turnIndex: Int
        var baseSystemPrompt: String
        var forcedRequestPrompt: String?
        var runSystemPromptAppend: String?
        var systemPromptOptions: BuildSystemPromptOptions
        var pendingToolNames: Set<String> = []
        var addedDefaultToolNames: [String] = []
        var usesDefaultTools: Bool
        var defaultToolModifiers: [String]
        var excludedTools: ToolNameMatcher
        var allowedTools: ToolNameMatcher?
        var allowlistFiltersMcp: Bool
        var toolRegistry: [String: AgentTool]
        var toolRegistryOrder: [String]
        var toolDefinitions: [String: CustomTool]
        var hiddenDeclarations: Set<String> = []
        var nestedToolCalls: NestedToolCallRunner?
        var rebuildSystemPrompt: (@Sendable ([String]) -> String)?
        var toolPromptSnippets: [String: String]
        var toolPromptGuidelines: [String: [String]]
        var reloadExtensionsHook: (@Sendable () async -> LoadExtensionsResult)?
        var wrapExtensionTools: (@Sendable ([CustomTool]) -> [AgentTool])?
    }

    /// Actor-isolated waiter state keeps the public idle API race-free without
    /// polling or unchecked Sendable storage.
    private actor AgentSessionIdleWaiter {
        private var isRunActive = false
        private var abortRequested = false
        private var generation = 0
        private var settlingGeneration: Int?
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func beginRun() {
            generation += 1
            settlingGeneration = nil
            isRunActive = true
            abortRequested = false
        }

        func requestAbort() {
            if isRunActive { abortRequested = true }
        }

        func wasAborted(_ expectedGeneration: Int) -> Bool {
            generation == expectedGeneration && abortRequested
        }

        func waitForIdle() async {
            guard isRunActive else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func settleRun() -> Int? {
            guard isRunActive, settlingGeneration != generation else { return nil }
            settlingGeneration = generation
            return generation
        }

        func isCurrentRun(_ expectedGeneration: Int) -> Bool {
            isRunActive && generation == expectedGeneration
        }

        func cancelSettlement(_ expectedGeneration: Int) {
            if settlingGeneration == expectedGeneration { settlingGeneration = nil }
        }

        func resolveWaiters(_ expectedGeneration: Int) {
            guard generation == expectedGeneration else { return }
            isRunActive = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private var _hookRunner: HookRunner? {
        get { state.withLock { $0.hookRunner } }
        set {
            state.withLock { state in
                state.hookEventUnsubscribe?()
                state.hookRunner = newValue
                let generation = UUID()
                state.hookEventGeneration = generation
                state.hookEventUnsubscribe = newValue?.addEventObserver { [weak self] event in
                    let observers = self?.state.withLock { state in
                        state.hookEventGeneration == generation ? Array(state.hookEventObservers.values) : []
                    } ?? []
                    for observer in observers { observer(event) }
                }
            }
        }
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

    private var failedResponse: AssistantMessage? {
        get { state.withLock { $0.failedResponse } }
        set { state.withLock { $0.failedResponse = newValue } }
    }

    /// The last successful physical response under a virtual selection.
    public var routedModel: ModelRouteResponse? {
        guard isVirtualModel(agent.state.model),
              let latest = findLatestResponse(agent.state.messages),
              let physical = modelRegistry.getPhysicalModel(latest.provider, latest.model) else { return nil }
        return ModelRouteResponse(model: physical, thinkingLevel: latest.thinkingLevel)
    }

    private var limitsModel: Model { routedModel?.model ?? agent.state.model }

    private func modelForMessage(_ message: AssistantMessage) -> Model? {
        let selected = agent.state.model
        if isVirtualModel(selected) { return modelRegistry.getPhysicalModel(message.provider, message.model) }
        return selected.provider == message.provider && selected.id == message.model ? selected : nil
    }

    private func recordSelection() {
        let selected = agent.state.model
        let recorded = getBranchSelection(sessionManager.getBranch(), getModel: modelRegistry.find)
        guard let recorded,
              recorded.provider != selected.provider || recorded.modelId != selected.id else { return }
        let wasVirtual = modelRegistry.find(recorded.provider, recorded.modelId).map(isVirtualModel) ?? false
        guard isVirtualModel(selected) || wasVirtual else { return }
        sessionManager.appendModelChange(selected.provider, selected.id)
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

    private var forcedRequestPrompt: String? {
        get { state.withLock { $0.forcedRequestPrompt } }
        set { state.withLock { $0.forcedRequestPrompt = newValue } }
    }

    private func preparePromptPatch(messages: [AgentMessage]? = nil) throws -> SystemMessage? {
        var options = state.withLock { $0.systemPromptOptions }
        if let append = state.withLock({ $0.runSystemPromptAppend }) {
            options.appendSystemPrompt = [options.appendSystemPrompt, append].compactMap { $0 }.joined(separator: "\n\n")
        }
        let names = getActiveToolNames()
        options.selectedTools = names.compactMap(ToolName.init(rawValue:))
        options.selectedToolNames = names
        var snippets = options.toolSnippets ?? [:]
        for name in names {
            if let contribution = toolPromptSnippets[name] ?? toolDefinitions[name]?.promptSnippet ?? builtInToolPrompt[name]?.snippet {
                snippets[name] = contribution
            }
        }
        options.toolSnippets = snippets
        options.hiddenTools = hiddenDeclarations.sorted()
        var guidelines = builtInToolPrompt.mapValues(\.guidelines).merging(options.toolGuidelines ?? [:]) { _, supplied in supplied }
        guidelines.merge(state.withLock { $0.toolPromptGuidelines }) { _, extensionRules in extensionRules }
        options.toolGuidelines = guidelines
        let prior = getCurrentSystemMessage(messages ?? sessionManager.buildSessionProjection().messages)
        guard let sections = diffSystemPromptSections(prior?.sections, try buildSystemPromptSections(options)) else { return nil }
        return SystemMessage(content: .text(""), sections: sections)
    }

    private var toolRegistry: [String: AgentTool] {
        get { state.withLock { $0.toolRegistry } }
        set { state.withLock { $0.toolRegistry = newValue } }
    }

    private var toolRegistryOrder: [String] {
        get { state.withLock { $0.toolRegistryOrder } }
        set { state.withLock { $0.toolRegistryOrder = newValue } }
    }

    private func registeredTools() -> [AgentTool] {
        let registry = toolRegistry
        return toolRegistryOrder.compactMap { registry[$0] }
    }

    private var toolDefinitions: [String: CustomTool] {
        get { state.withLock { $0.toolDefinitions } }
        set { state.withLock { $0.toolDefinitions = newValue } }
    }

    private var hiddenDeclarations: Set<String> {
        get { state.withLock { $0.hiddenDeclarations } }
        set { state.withLock { $0.hiddenDeclarations = newValue } }
    }

    private var nestedToolCalls: NestedToolCallRunner? {
        get { state.withLock { $0.nestedToolCalls } }
        set { state.withLock { $0.nestedToolCalls = newValue } }
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
    }

    private func expandPromptText(_ text: String, expandSlashCommands: Bool = true, expandPromptTemplates: Bool = true) -> String {
        var expanded = text
        if expandPromptTemplates, text.hasPrefix("/skill:") {
            let parts = text.dropFirst(7).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if let name = parts.first,
               let skill = resourceLoader.getSkills().skills.first(where: { $0.name == name }),
               let content = try? String(contentsOfFile: skill.filePath, encoding: .utf8) {
                let body = parseFrontmatter(content).body
                expanded = "<skill name=\"\(skill.name)\" location=\"\(skill.filePath)\">\nReferences are relative to \(skill.baseDir).\n\n\(body)\n</skill>"
                if parts.count > 1 { expanded += "\n\n" + parts[1] }
            }
        }
        if expandPromptTemplates {
            expanded = expandPromptTemplate(expanded, promptTemplatesInternal)
        }
        if expandSlashCommands {
            expanded = expandSlashCommand(expanded, fileCommands)
        }
        return expanded
    }

    public init(config: AgentSessionConfig) {
        let initialTools = config.agent.state.tools
        let initialRegistry = config.toolRegistry ?? Dictionary(
            initialTools.map { ($0.name, $0) }, uniquingKeysWith: { _, newer in newer })
        let initialRegistryOrder = config.toolRegistryOrder ??
            (config.toolRegistry == nil ? initialTools.map(\.name) : initialRegistry.keys.sorted())
        self.agent = config.agent
        self.sessionManager = config.sessionManager
        self.settingsManager = config.settingsManager
        self.modelRegistry = config.modelRegistry
        self.cacheWarmer = config.cacheWarmer
        self.eventBus = config.eventBus ?? createEventBus()
        self.projectTrusted = config.projectTrusted
        self.bashOperations = config.bashOperations
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
            lastAssistantEntryId: nil,
            compactionAbort: nil,
            branchSummaryAbort: nil,
            retryAbort: nil,
            retryAttempt: 0,
            retryTask: nil,
            pendingPostRunTasks: 0,
            bashAbortTokens: [:],
            pendingBashMessages: [],
            isCompactingInternal: false,
            queuedCompactionPrompts: [],
            overflowRecoveryAttempted: false,
            lastSuccessfulUsage: nil,
            isBranchSummarizing: false,
            turnIndex: 0,
            baseSystemPrompt: config.agent.state.systemPrompt,
            forcedRequestPrompt: nil,
            runSystemPromptAppend: nil,
            systemPromptOptions: config.systemPromptOptions ?? BuildSystemPromptOptions(cwd: config.sessionManager.getCwd()),
            usesDefaultTools: config.usesDefaultTools,
            defaultToolModifiers: config.defaultToolModifiers,
            excludedTools: ToolNameMatcher(Array(config.excludedToolNames)),
            allowedTools: config.allowedToolNames.map { ToolNameMatcher(Array($0)) },
            allowlistFiltersMcp: config.allowedToolNames.map {
                $0.isEmpty || $0.contains { $0.hasPrefix("mcp__") }
            } ?? false,
            toolRegistry: initialRegistry,
            toolRegistryOrder: initialRegistryOrder,
            toolDefinitions: config.toolDefinitions ?? [:],
            rebuildSystemPrompt: config.rebuildSystemPrompt,
            toolPromptSnippets: [:],
            toolPromptGuidelines: ((config.customTools ?? []).map(\.tool) +
                                   (config.hookRunner?.getExtensionTools() ?? []))
                .reduce(into: [String: [String]]()) { rules, tool in
                rules[tool.name] = tool.promptGuidelines
            },
            reloadExtensionsHook: config.reloadExtensionsHook,
            wrapExtensionTools: config.wrapExtensionTools
        ))

        self.agent.prepareToolResultMessage = { [weak self] original in
            guard let runner = self?.nestedToolCalls,
                  let summary = await runner.takeRecord(toolCallId: original.toolCallId) else {
                return original
            }
            var message = original
            message.nestedCalls = summary.calls
            if let usage = summary.usage {
                message.usage = message.usage.map { combineUsage($0, usage) } ?? usage
            }
            return message
        }

        let previousPrepare = self.agent.prepareNextTurn
        let previousPrepareWithContext = self.agent.prepareNextTurnWithContext
        let previousPrepareRequest = self.agent.prepareRequest
        let previousFinishTurn = self.agent.finishTurn
        self.agent.finishTurn = { [weak self] turn, signal in
            let extensionContinue = await self?.dispatchTurnEndBoundary(turn) ?? false
            let previousDecision = await previousFinishTurn?(turn, signal)
            if previousDecision == .end { return .end }
            return extensionContinue || previousDecision == .continue ? .continue : nil
        }
        self.agent.prepareRequest = { [weak self] request, signal in
            guard let self else { return nil }
            let failed = self.failedResponse
            self.failedResponse = nil
            func prepare() async throws -> (AgentRequestUpdate?, AgentContext, SessionProjection) {
                var canonical = request.context
                let projection = self.sessionManager.buildSessionProjection()
                canonical.messages = projection.messages
                canonical.tools = self.agent.state.tools
                let current = PrepareRequestContext(context: canonical, model: self.agent.state.model,
                                                    thinkingLevel: self.agent.state.thinkingLevel)
                let previous = try await previousPrepareRequest?(current, signal)
                return (previous, previous?.context ?? canonical, projection)
            }
            var (previous, context, projection) = try await prepare()
            let selected = previous?.model ?? self.agent.state.model
            let thinking = previous?.thinkingLevel ?? self.agent.state.thinkingLevel
            guard isVirtualModel(selected) else {
                return AgentRequestUpdate(context: context, model: selected, thinkingLevel: thinking)
            }
            let lastAssistantIndex = context.messages.lastIndex { $0.role == "assistant" }
            let afterAssistant = context.messages.dropFirst((lastAssistantIndex ?? -1) + 1)
            let reason: ModelRouteReason = failed != nil ? .retry :
                (afterAssistant.contains { $0.role == "user" } ? .user : .continuation)
            let branch = self.sessionManager.getBranch()
            let oldState = getVirtualModelState(branch, provider: selected.provider, modelId: selected.id)
            let route = try await self.modelRegistry.resolveVirtualModel(
                selected, messages: convertToLlm(context.messages), reason: reason,
                thinkingLevel: ModelThinkingLevel(rawValue: thinking.rawValue) ?? .off,
                signal: signal, failed: failed, state: oldState)
            if let nextState = route.state, nextState != oldState {
                let id = self.sessionManager.appendCustomEntry(VIRTUAL_MODEL_STATE_ENTRY, [
                    "provider": selected.provider, "modelId": selected.id, "state": nextState.value
                ])
                if let entry = self.sessionManager.getEntry(id) { self.emit(.entryAppended(entry)) }
            }
            if self.autoCompactionEnabled, route.model.contextWindow > 0,
               shouldCompact(estimateProjectedContextTokens(projection, self.sessionManager.getBranch()).tokens,
                             route.model.contextWindow,
                             self.settingsManager.getCompactionSettings(model: selected)) {
                await self.runAutoCompaction(reason: .threshold, willRetry: false)
                (previous, context, projection) = try await prepare()
            }
            return AgentRequestUpdate(context: context, model: route.model,
                                      thinkingLevel: ThinkingLevel(rawValue: route.thinkingLevel.rawValue) ?? .off)
        }
        let previousTransformContext = self.agent.transformContext
        self.agent.transformContext = { [weak self] messages, signal in
            let transformed = try await previousTransformContext?(messages, signal) ?? messages
            let hidden = self?.hiddenDeclarations ?? []
            let projected = hidden.isEmpty ? transformed : transformed.map { message -> AgentMessage in
                guard case .system(var system) = message else { return message }
                system.toolsAdded = system.toolsAdded?.filter { !hidden.contains($0.name) }
                system.toolsRemoved = system.toolsRemoved?.filter { !hidden.contains($0.name) }
                if system.toolsAdded?.isEmpty == true { system.toolsAdded = nil }
                if system.toolsRemoved?.isEmpty == true { system.toolsRemoved = nil }
                return .system(system)
            }
            guard let forced = self?.forcedRequestPrompt else { return projected }
            let current = getCurrentSystemMessage(projected)
            let head = SystemMessage(content: .text(forced), toolsAdded: current?.toolsAdded,
                                     timestamp: current?.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000))
            return [.system(head)] + projected.filter { $0.role != "system" }
        }
        self.agent.prepareNextTurnWithContext = { [weak self] turn, signal in
            guard let self else { return nil }
            let events = self._agentEventQueue.withLock { $0 }
            await events?.value
            var next = turn
            let projection = self.sessionManager.buildSessionProjection()
            next.context.messages = projection.messages
            if signal?.isCancelled != true,
               self.autoCompactionEnabled,
               !isVirtualModel(self.agent.state.model),
               self.agent.state.model.contextWindow > 0,
               shouldCompact(estimateProjectedContextTokens(projection, self.sessionManager.getBranch()).tokens,
                             self.agent.state.model.contextWindow,
                             self.settingsManager.getCompactionSettings(model: self.agent.state.model)) {
                await self.runAutoCompaction(reason: .threshold, willRetry: false)
                next.context.messages = self.sessionManager.buildSessionProjection().messages
            }
            let previous: AgentLoopTurnUpdate?
            if let previousPrepareWithContext {
                previous = try await previousPrepareWithContext(next, signal)
            } else {
                previous = try await previousPrepare?(signal)
            }
            var context = previous?.context ?? next.context
            context.tools = self.agent.state.tools
            let update = try self.preparePromptPatch(messages: context.messages)
            return AgentLoopTurnUpdate(context: context,
                                       messages: (previous?.messages ?? []) + (update.map { [.system($0)] } ?? []),
                                       model: self.agent.state.model, thinkingLevel: self.agent.state.thinkingLevel)
        }

        let existingAfterToolCall = self.agent.afterToolCall
        let toolImageSettings = config.settingsManager
        self.agent.afterToolCall = { context, signal in
            let hookResult = try await existingAfterToolCall?(context, signal)
            let sourceContent = hookResult?.content ?? context.result.content
            let normalized = normalizeToolResultImages(
                sourceContent,
                autoResizeImages: toolImageSettings.getAutoResizeImages(),
                resizeOptions: self.limitsModel.inputLimits?.images?.resize
            )
            guard hookResult != nil || normalized.changed else { return nil }
            return AfterToolCallResult(
                content: normalized.content,
                details: hookResult?.details,
                isError: hookResult?.isError,
                usage: hookResult?.usage,
                terminate: hookResult?.terminate,
                structuredContent: hookResult?.structuredContent ?? context.result.structuredContent.map(StructuredContentOverride.set) ?? .absent
            )
        }

        self._hookRunner = config.hookRunner
        self._hookRunner?.initialize(
            getModel: { [weak agent] in agent?.state.model },
            getScopedModels: { [weak self] in self?.scopedModels ?? [] },
            getSystemPrompt: { [weak self] in
                self.map { getCurrentSystemPrompt($0.sessionManager.buildSessionProjection().messages) }
            },
            getSystemPromptOptions: { [weak self] in
                self?.getCurrentSystemPromptOptions() ?? BuildSystemPromptOptions(cwd: config.sessionManager.getCwd())
            },
            isProjectTrusted: { config.projectTrusted },
            sendMessageHandler: { [weak self] message, options in self?.enqueueHookMessage(message, options: options) },
            appendEntryHandler: { [weak self] customType, data in
                self?.sessionManager.appendCustomEntry(customType, data)
            },
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
            registerToolHandler: { [weak self] tool in self?.registerLiveExtensionTool(tool) },
            unregisterToolHandler: { [weak self] name in self?.unregisterLiveExtensionTool(name) },
            sendUserMessageHandler: { [weak self] content, options in
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.sendUserMessage(content, options: options)
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
                let result = await self.navigateTree(
                    targetId,
                    summarize: options?.summarize ?? false,
                    customInstructions: options?.customInstructions,
                    replaceInstructions: options?.replaceInstructions,
                    label: options?.label
                )
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
            isIdle: { [weak self] in self?.isIdle ?? true },
            waitForIdle: { [weak self] in await self?.waitForIdle() },
            abort: { [weak self] in Task { await self?.abort() } },
            hasUI: false
        )

        self.unsubscribeAgent = agent.subscribe { [weak self] event, _ in
            self?.handleAgentEvent(event)
            if case .agentEnd = event, let runner = self?.nestedToolCalls {
                await runner.clear()
            }
        }
        refreshContext()
        if let current = getCurrentSystemMessage(sessionManager.buildSessionProjection().messages) {
            let names = (current.toolsAdded ?? []).map(\.name)
            restoreActiveTools(names)
            let activeNames = getActiveToolNames()
            state.withLock { $0.systemPromptOptions.selectedToolNames = activeNames }
        } else {
            setActiveToolsByName(agent.tools.map(\.name))
        }
    }

    public func dispose() {
        if let cacheWarmer { Task { await cacheWarmer.cancel() } }
        unsubscribeAgent?()
        unsubscribeAgent = nil
        let runner = _hookRunner
        _hookRunner = nil
        runner?.dispose()
        // v0.67.4: reap any detached bash subprocesses the user spawned during this session
        // so we don't leave orphans hanging around after `/quit` or session shutdown.
        killTrackedDetachedChildren()
    }

    public internal(set) var hookRunner: HookRunner? {
        get { _hookRunner }
        set { _hookRunner = newValue }
    }

    public func getCurrentSystemPromptOptions() -> BuildSystemPromptOptions {
        var options = state.withLock { $0.systemPromptOptions }
        options.selectedTools = getActiveToolNames().compactMap { ToolName(rawValue: $0) }
        options.hiddenTools = hiddenDeclarations.sorted()
        return options
    }

    public var customTools: [LoadedCustomTool] {
        customToolsInternal
    }

    /// Get tool display settings, including settings for tools that are not registered.
    public func toolRenderers(for name: String) -> CustomToolRenderers? {
        let runner = hookRunner
        let base: () -> CustomToolRenderers? = {
            if let tool = runner?.getExtensionTools().first(where: { $0.name == name }) {
                return CustomToolRenderers(tool: tool)
            }
            if let tool = self.customTools.first(where: { $0.tool.name == name })?.tool {
                return CustomToolRenderers(tool: tool)
            }
            return nil
        }
        if let runner { return runner.resolveToolRenderers(name, base: base) }
        return base()
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
                self?.isIdle ?? false
            },
            hasPendingMessages: { [weak self] in
                (self?.pendingMessageCount ?? 0) > 0
            },
            abort: { [weak self] in
                Task { await self?.abort() }
            },
            events: eventBus,
            sendMessage: { [weak self] message, options in
                self?.enqueueHookMessage(message, options: options)
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

    /// Observe hook events on the current runner, including after replacement.
    /// A subscription can start before a runner exists.
    /// Calls are synchronous on the emitter's executor, outside the storage lock.
    /// Unsubscribe excludes later snapshots. An event already in progress can still arrive.
    public func subscribeToHookEvents(_ observer: @escaping @Sendable (any HookEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.hookEventObservers[id] = observer }
        return { [weak self] in
            self?.state.withLock { $0.hookEventObservers[id] = nil }
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

    private func applyBoundaryDrafts(_ drafts: [SessionBoundaryDraft], to manager: SessionManager) throws -> [SessionEntry] {
        var appended: [SessionEntry] = []
        for draft in drafts {
            let id: String
            switch draft {
            case .custom(let customType, let data):
                guard data == nil || data?.value is [String: Any] else {
                    throw AgentSessionError.invalidBoundaryDraft
                }
                id = manager.appendCustomEntry(customType, data?.value as? [String: Any] ?? [:])
            case .customMessage(let customType, let content, let display, let details):
                id = manager.appendCustomMessage(customType, content, display, details: details)
            case .contextEdit(let targetId, let replacement):
                id = try manager.appendContextEdit(targetId, replacement)
            case .compaction(let summary, let firstKeptEntryId, let details, let usage):
                let tokensBefore = estimatedContextTokens(manager.buildSessionProjection().messages)
                id = manager.appendCompaction(summary, firstKeptEntryId, tokensBefore, details: details, fromHook: true, usage: usage)
            }
            if let entry = manager.getEntry(id) { appended.append(entry) }
        }
        return appended
    }

    private func boundaryPreview(_ drafts: [SessionBoundaryDraft], boundary: String) throws -> BoundaryContextPreview {
        guard let header = sessionManager.getHeader() else { throw AgentSessionError.invalidBoundaryDraft }
        let entries: [FileEntry] = [.session(header)] + sessionManager.getBranch().map { .entry($0) }
        let manager = SessionManager.inMemory(sessionManager.getCwd(), entries: entries)
        _ = try applyBoundaryDrafts(drafts, to: manager)
        let projection = manager.buildSessionProjection()
        let queued = agent.peekQueuedMessages()
        let custom = state.withLock { $0.pendingCustomMessages.map(makeHookAgentMessage) }
        let llm = convertToLlm(projection.messages)
        let finalRole = llm.last?.role
        let contextCanContinue = llm.contains { $0.role != "system" } && finalRole != "assistant"
        let canContinue = contextCanContinue || !custom.isEmpty ||
            (boundary == "turn_end" ? agent.hasQueuedMessages() : finalRole == "assistant" && agent.hasQueuedMessages())
        return BoundaryContextPreview(contextEntries: projection.entries, contextMessages: projection.messages,
                                      llmMessages: llm, pendingMessages: queued + custom, canContinue: canContinue)
    }

    private func commitBoundaryDrafts(_ drafts: [SessionBoundaryDraft]) throws {
        let appended = try applyBoundaryDrafts(drafts, to: sessionManager)
        refreshContext()
        for entry in appended { emit(.entryAppended(entry)) }
    }

    private func reportBoundaryError(_ event: String, _ message: String) {
        _hookRunner?.emitError(HookError(hookPath: "<boundary>", event: event, error: message))
    }

    private func dispatchTurnEndBoundary(_ turn: AgentTurnContext) async -> Bool {
        let outcome: AgentActivityOutcome = turn.message.stopReason == .aborted ? .aborted :
            turn.message.stopReason == .error ? .error : .completed
        state.withLock { $0.lastActivityOutcome = outcome }
        guard let runner = _hookRunner, runner.hasHandlers("turn_end") else { return false }
        let ids = state.withLock { ($0.lastAssistantEntryId, $0.lastToolResultEntryIds) }
        guard let messageEntryId = ids.0 else {
            reportBoundaryError("turn_end", "Could not resolve the persisted assistant entry ID")
            return false
        }
        let resultIds = turn.toolResults.compactMap { ids.1[$0.toolCallId] }
        let event = TurnEndBoundaryBaseEvent(turnIndex: turnIndex, message: .assistant(turn.message), toolResults: turn.toolResults,
                                 messageEntryId: messageEntryId, toolResultEntryIds: resultIds, outcome: outcome)
        do {
            let result = try await runner.emitBoundary(event) { [weak self] drafts in
                guard let self else { throw AgentSessionError.invalidBoundaryDraft }
                return try self.boundaryPreview(drafts, boundary: "turn_end")
            }
            try commitBoundaryDrafts(result.entries)
            if result.shouldContinue && !result.context.canContinue {
                reportBoundaryError("turn_end", "Continuation has no runnable model context")
                return false
            }
            return result.shouldContinue
        } catch {
            reportBoundaryError("turn_end", error.localizedDescription)
            return false
        }
    }

    private func runBeforeSettleBoundary() async -> Bool {
        guard !state.withLock({ $0.agentRunAbortRequested }) else { return false }
        guard let runner = _hookRunner, runner.hasHandlers("agent_before_settle") else {
            return agent.hasQueuedMessages()
        }
        state.withLock {
            $0.isBeforeSettle = true
            $0.abortDuringBeforeSettle = false
        }
        defer { state.withLock { $0.isBeforeSettle = false } }
        do {
            let event = AgentBeforeSettleBoundaryBaseEvent(outcome: state.withLock { $0.lastActivityOutcome })
            let result = try await runner.emitBoundary(event) { [weak self] drafts in
                guard let self else { throw AgentSessionError.invalidBoundaryDraft }
                return try self.boundaryPreview(drafts, boundary: "agent_before_settle")
            }
            try commitBoundaryDrafts(result.entries)
            flushPendingCustomMessages()
            guard !state.withLock({ $0.abortDuringBeforeSettle || $0.agentRunAbortRequested }) else { return false }
            let shouldContinue = result.shouldContinue || agent.hasQueuedMessages()
            let finalPreview = try boundaryPreview([], boundary: "agent_before_settle")
            if shouldContinue && !finalPreview.canContinue {
                if result.shouldContinue { reportBoundaryError("agent_before_settle", "Continuation has no runnable model context") }
                return false
            }
            return shouldContinue
        } catch {
            reportBoundaryError("agent_before_settle", error.localizedDescription)
            return false
        }
    }

    private func emitAgentSettledIfNeeded() async {
        // `agent_end` may schedule an automatic retry, compaction, or queued
        // continuation. Keep the run active until that follow-up chain finishes.
        guard pendingPostRunTasks == 0, !isStreaming, !isCompactingInternal, !isBranchSummarizing else { return }
        guard let generation = await idleWaiter.settleRun() else { return }

        // Agent lifecycle hooks are queued from the Agent callback. Waiting for this
        // queue keeps the observable order `agent_end` then `agent_settled`.
        let previous = _agentEventQueue.withLock { $0 }
        _ = await previous?.value
        guard pendingPostRunTasks == 0, !isStreaming, !isCompactingInternal, !isBranchSummarizing,
              await idleWaiter.isCurrentRun(generation) else {
            await idleWaiter.cancelSettlement(generation)
            return
        }
        if await runBeforeSettleBoundary() {
            await idleWaiter.cancelSettlement(generation)
            try? await agent.continue()
            Task { [weak self] in await self?.emitAgentSettledIfNeeded() }
            return
        }
        state.withLock { $0.isEmittingAgentSettled = true }
        await cacheWarmer?.onAgentSettled()
        let aborted = await idleWaiter.wasAborted(generation)
        if let hookRunner = _hookRunner {
            _ = await hookRunner.emit(AgentSettledEvent(aborted: aborted))
        }
        emit(.agentSettled(aborted: aborted))
        let deferred = state.withLock { state in
            state.isEmittingAgentSettled = false
            let actions = state.deferredSettledActions
            state.deferredSettledActions.removeAll()
            return actions
        }
        await idleWaiter.resolveWaiters(generation)
        for action in deferred { await action() }
    }

    /// Current warming economics and timer state for `/session` and footers.
    public func cacheWarmingStatus() async -> CacheWarmingStatus? {
        await cacheWarmer?.status()
    }

    public func setCacheWarmingMode(_ mode: CacheWarmingMode) async {
        settingsManager.setCacheWarmingMode(mode)
        await cacheWarmer?.onModeChanged()
    }

    public func emitCacheWarmed(_ entry: UsageEntry) {
        emit(.entryAppended(.usage(entry)))
    }

    private func runUntilSettled<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        state.withLock { $0.agentRunAbortRequested = false }
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
        if case .agentStart = event { turnIndex = 0 }
        if case .turnEnd(_, let toolResults) = event {
            state.withLock { $0.lastAssistantToolResults = toolResults }
            turnIndex += 1
        }
        if case .messageStart(let message) = event, message.role == "user" {
            let text = extractUserMessageText(message)
            if let idx = steeringMessages.firstIndex(of: text) {
                steeringMessages.remove(at: idx)
            } else if let idx = followUpMessages.firstIndex(of: text) {
                followUpMessages.remove(at: idx)
            }
        }

        if case .messageEnd(let message) = event {
            var persistedEntryId: String?
            switch message {
            case .system, .user, .assistant, .toolResult:
                persistedEntryId = sessionManager.appendMessage(message)
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
                    persistedEntryId = sessionManager.appendMessage(message)
                }
            }

            if case .assistant(let assistant) = message {
                state.withLock {
                    $0.lastAssistantEntryId = persistedEntryId
                    $0.lastToolResultEntryIds = [:]
                }
                lastAssistantMessage = assistant
                if assistant.stopReason != .error, assistant.stopReason != .length {
                    overflowRecoveryAttempted = false
                }
                // Track last successful usage for threshold checks after errors (4D-4).
                switch assistant.stopReason {
                case .stop, .length, .toolUse:
                    lastSuccessfulUsage = assistant.usage
                    if retryAttempt > 0 {
                        let attempt = retryAttempt
                        retryAttempt = 0
                        retryAbort = nil
                        retryTask = nil
                        emit(.autoRetryEnd(success: true, attempt: attempt, finalError: nil))
                    }
                case .pending, .error, .aborted, .deferred:
                    break
                }
            } else if case .toolResult(let result) = message, let persistedEntryId {
                state.withLock { $0.lastToolResultEntryIds[result.toolCallId] = persistedEntryId }
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
                // Actionable turn_end is dispatched by Agent.finishTurn, before this notification.
                _ = message
                _ = toolResults
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
            case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError, let durationMs):
                enqueueOnEventQueue {
                    _ = await hookRunner.emit(ToolExecutionEndEvent(
                        toolCallId: toolCallId,
                        toolName: toolName,
                        result: result,
                        isError: isError,
                        durationMs: durationMs
                    ))
                }
            }
        }

        emit(.agent(event))
        if case .turnEnd = event {
            enqueueOnEventQueue { [weak self] in self?.flushPendingCustomMessages() }
        }

        if case .agentEnd = event, let lastAssistantMessage {
            self.lastAssistantMessage = nil
            beginPostRunTask()
            Task { [weak self] in
                defer { self?.finishPostRunTask() }
                guard let self else { return }
                let events = self._agentEventQueue.withLock { $0 }
                await events?.value
                if self.isRetryableError(lastAssistantMessage) {
                    let didRetry = await self.handleRetryableError(lastAssistantMessage)
                    if didRetry { return }
                }
                if lastAssistantMessage.stopReason == .error, self.retryAttempt > 0 {
                    let attempt = self.retryAttempt
                    self.retryAttempt = 0
                    self.retryAbort = nil
                    self.retryTask = nil
                    self.emit(.autoRetryEnd(success: false, attempt: attempt,
                                            finalError: lastAssistantMessage.errorMessage))
                }
                await self.checkAutoCompaction(lastAssistantMessage)
            }
        }
    }

    private func isRetryableError(_ message: AssistantMessage) -> Bool {
        let contextWindow = modelForMessage(message)?.contextWindow ?? agent.state.model.contextWindow
        if isContextOverflow(message, contextWindow: contextWindow) { return false }
        return isRetryableAssistantError(message)
    }

    /// Keep an abandoned attempt in the session log while removing it from later model requests.
    private func omitRecoveryAttempt(_ message: AssistantMessage, toolResults: [ToolResultMessage] = []) throws {
        let ids = try state.withLock { state -> [String] in
            guard let assistantId = state.lastAssistantEntryId else { throw AgentSessionError.recoveryEntryMissing }
            var ids = [assistantId]
            for result in toolResults {
                guard let id = state.lastToolResultEntryIds[result.toolCallId] else {
                    throw AgentSessionError.recoveryEntryMissing
                }
                ids.append(id)
            }
            return ids
        }
        var appended: [SessionEntry] = []
        for id in ids {
            let editId = try sessionManager.appendContextEdit(id, nil)
            if let entry = sessionManager.getEntry(editId) { appended.append(entry) }
        }
        refreshContext()
        for entry in appended { emit(.entryAppended(entry)) }
    }

    private func handleRetryableError(_ message: AssistantMessage) async -> Bool {
        guard !state.withLock({ $0.agentRunAbortRequested }) else { return false }
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

        let delayMs = Int(retryDelayMs(policy: RetryPolicy(
            enabled: true,
            maxRetries: settings.maxRetries ?? 3,
            baseDelayMs: Double(settings.baseDelayMs ?? 2000),
            maxAgentDelayMs: Double(settings.maxAgentDelayMs ?? 60_000)
        ), attempt: retryAttempt))

        emit(.autoRetryStart(
            attempt: retryAttempt,
            maxAttempts: settings.maxRetries ?? 3,
            delayMs: delayMs,
            errorMessage: message.errorMessage ?? "Unknown error"
        ))

        do { try omitRecoveryAttempt(message) } catch {
            emit(.autoRetryEnd(success: false, attempt: retryAttempt, finalError: error.localizedDescription))
            retryAttempt = 0
            return false
        }

        failedResponse = message

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
        guard !state.withLock({ $0.agentRunAbortRequested }) else { return }
        guard autoCompactionEnabled, !isCompactingInternal else { return }
        switch message.stopReason {
        case .pending, .aborted, .deferred:
            return
        case .stop, .length, .toolUse, .error:
            break
        }

        let messageModel = modelForMessage(message)
        let currentModel = messageModel ?? agent.state.model
        let contextWindow = currentModel.contextWindow
        guard contextWindow > 0 else { return }

        // A delayed post-run check must not compact a response that an intervening
        // manual or automatic compaction already replaced.
        if assistantIsBeforeLatestCompaction(message) { return }

        let sameModel = messageModel != nil
        let branch = sessionManager.getBranch()
        let assistantId = state.withLock { $0.lastAssistantEntryId }
        let projection = sessionManager.buildSessionProjection()
        let assistantProjected = projection.entries.contains { entry in
            entry.sourceEntry.id == assistantId && entry.messages.contains { $0.role == "assistant" }
        }
        let assistantIndex = branch.firstIndex { $0.id == assistantId }
        let afterAssistant = assistantIndex.map { Array(branch.dropFirst($0 + 1)) } ?? []
        let hasPostAssistantEdit = afterAssistant.contains { $0.type == "context_edit" }
        let latestAssistantEdit = afterAssistant.reversed().compactMap { entry -> ContextEditEntry? in
            guard case .contextEdit(let edit) = entry, edit.targetId == assistantId else { return nil }
            return edit
        }.first
        let retainedForExplicitRecovery = !afterAssistant.contains { $0.type == "compaction" } &&
            latestAssistantEdit?.replacement != nil || (latestAssistantEdit == nil && assistantProjected)
        let explicitOverflow = message.stopReason == .error && isContextOverflow(message)
        let contextOverflow = sameModel &&
            ((explicitOverflow && retainedForExplicitRecovery) ||
             (assistantProjected && !hasPostAssistantEdit && isContextOverflow(message, contextWindow: contextWindow)))
        let recoverableLength = sameModel && assistantProjected && isRecoverableLength(
            message,
            desiredMaxOutput: currentModel.maxTokens
        )

        // Explicit/silent overflow and a length stop below the intended output
        // limit both get one bounded compact-and-retry recovery attempt.
        if contextOverflow || recoverableLength {
            let willRetry = message.stopReason != .stop
            if willRetry {
                guard !overflowRecoveryAttempted else {
                    await emitCompactionFailure(reason: .overflow, error: contextOverflow ? "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model." : "Truncated response recovery failed after one compact-and-retry attempt.", aborted: false, willRetry: false)
                    return
                }
                overflowRecoveryAttempted = true
                do {
                    try omitRecoveryAttempt(message, toolResults: state.withLock { $0.lastAssistantToolResults })
                    failedResponse = message
                } catch {
                    await emitCompactionFailure(reason: .overflow, error: error.localizedDescription, aborted: false, willRetry: false)
                    return
                }
            }
            await runAutoCompaction(reason: .overflow, willRetry: willRetry)
            return
        }

        let usageTokens = calculateContextTokens(message.usage)
        let thresholdTokens = !hasPostAssistantEdit && message.stopReason != .error && usageTokens > 0
            ? usageTokens : estimatedContextTokens(projection.messages)
        if shouldCompact(thresholdTokens, contextWindow, settingsManager.getCompactionSettings(model: agent.state.model)) {
            guard !overflowRecoveryAttempted else { return }
            await runAutoCompaction(reason: .threshold, willRetry: false)
        }
    }

    private func hasPostCompactionUsage() -> Bool {
        let entries = sessionManager.getBranch()
        guard let index = entries.lastIndex(where: { if case .compaction = $0 { return true }; return false }) else {
            return true
        }
        return entries.dropFirst(index + 1).contains { entry in
            guard case .message(let message) = entry, case .assistant(let assistant) = message.message else { return false }
            return assistant.stopReason != .error && assistant.stopReason != .aborted && calculateContextTokens(assistant.usage) > 0
        }
    }

    private func assistantIsBeforeLatestCompaction(_ message: AssistantMessage) -> Bool {
        guard let latest = sessionManager.getBranch().last(where: { if case .compaction = $0 { return true }; return false }),
              case .compaction(let entry) = latest,
              let milliseconds = sessionTimestampMilliseconds(entry.timestamp) else { return false }
        // Old Swift entries lost milliseconds. Treat their whole boundary second
        // as stale instead of trusting a pre-compaction usage value from that second.
        let boundary = entry.timestamp.contains(".") ? milliseconds : milliseconds + 999
        return message.timestamp <= boundary
    }

    private func estimatedContextTokens(_ messages: [AgentMessage]) -> Int {
        // Retained old assistants appear after the summary in rebuilt context.
        // The session tree, not the context index or a rounded date, identifies
        // whether any valid response was written after compaction.
        guard hasPostCompactionUsage() else {
            return messages.reduce(0) { $0 + estimateTokens($1) }
        }
        for index in messages.indices.reversed() {
            guard case .assistant(let message) = messages[index],
                  message.stopReason != .error, message.stopReason != .aborted,
                  calculateContextTokens(message.usage) > 0 else { continue }
            if assistantIsBeforeLatestCompaction(message) { break }
            return calculateContextTokens(message.usage) + messages.dropFirst(index + 1).reduce(0) { $0 + estimateTokens($1) }
        }
        return messages.reduce(0) { $0 + estimateTokens($1) }
    }

    private func isCompactionCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case AgentSessionError.compactionCancelled = error { return true }
        return false
    }

    private func emitCompactionFailure(reason: SessionCompactionReason, error: String?, aborted: Bool, willRetry: Bool, fromExtension: Bool = false) async {
        if let runner = _hookRunner {
            _ = await runner.emit(SessionCompactFailedEvent(reason: reason, errorMessage: error, aborted: aborted, willRetry: willRetry, fromExtension: fromExtension))
        }
    }

    func runAutoCompaction(
        reason: AutoCompactionReason,
        willRetry: Bool,
        compactBlock: (() async throws -> CompactionResult?)? = nil
    ) async {
        guard !state.withLock({ $0.agentRunAbortRequested }) else { return }
        guard let compactionToken = beginCompaction() else { return }
        await idleWaiter.beginRun()
        defer { Task { [weak self] in await self?.emitAgentSettledIfNeeded() } }

        emit(.autoCompactionStart(reason: reason))
        if compactionToken.isCancelled {
            _ = finishCompaction(compactionToken)
            emit(.autoCompactionEnd(result: nil, aborted: true, willRetry: false))
            await emitCompactionFailure(reason: SessionCompactionReason(rawValue: reason.rawValue) ?? .threshold, error: nil, aborted: true, willRetry: false)
            return
        }

        var result: CompactionResult?
        var aborted = false
        var failure: String?
        do {
            if let compactBlock {
                result = try await compactBlock()
            } else {
                result = try await performCompaction(
                    customInstructions: nil,
                    compactionToken: compactionToken
                )
            }
        } catch is CancellationError {
            aborted = true
        } catch AgentSessionError.compactionCancelled {
            aborted = true
        } catch {
            failure = reason == .overflow ? "Context overflow recovery failed: \(error.localizedDescription)" : "Auto-compaction failed: \(error.localizedDescription)"
        }
        aborted = aborted || compactionToken.isCancelled
        if result == nil || aborted {
            await emitCompactionFailure(reason: SessionCompactionReason(rawValue: reason.rawValue) ?? .threshold, error: failure, aborted: aborted, willRetry: false, fromExtension: state.withLock { $0.compactionFromExtension })
        }

        let queuedPrompts = finishCompaction(compactionToken)
        emit(.autoCompactionEnd(result: result, aborted: aborted, willRetry: result != nil && !aborted && willRetry, errorMessage: aborted ? nil : failure))
        await deliverQueuedCompactionPrompts(queuedPrompts)

        guard result != nil, !aborted else { return }

        if willRetry {
            try? await agent.continue()
            return
        }

        if !isStreaming, queuedPrompts.isEmpty, pendingMessageCount == 0, agent.hasQueuedMessages() {
            try? await agent.continue()
        }
    }

    private func performRetry(delayMs: Int, attempt: Int, token: CancellationToken) async {
        do {
            try await sleepWithCancellation(delayMs: delayMs, token: token)
        } catch {
            finishCancelledRetry(attempt: attempt)
            return
        }

        guard !token.isCancelled, !state.withLock({ $0.agentRunAbortRequested }) else {
            finishCancelledRetry(attempt: attempt)
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

    public var isIdle: Bool {
        !isStreaming && !isCompactingInternal && !isBranchSummarizing && pendingPostRunTasks == 0
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
        toolRegistryOrder
    }

    private func exposure(of name: String) -> ToolExposure {
        toolDefinitions[name]?.exposure ?? .direct
    }

    private func isDeclarable(_ name: String) -> Bool {
        let value = exposure(of: name)
        return value == .direct || value == .modelOnly
    }

    private func isActivatedOnRegistration(_ name: String) -> Bool {
        state.withLock { current in
            let definition = current.toolDefinitions[name]
            let exposure = definition?.exposure ?? .direct
            guard exposure == .direct || exposure == .modelOnly else { return false }
            if let allowed = current.allowedTools { return allowed.matches(name) }
            return definition?.defaultActive != false
        }
    }

    /// Check if a kept tool can be declared, including a restored tool loadout.
    private func isActivatable(_ name: String) -> Bool {
        state.withLock { current in
            guard let allowed = current.allowedTools,
                  !allowed.matches(name), isMcpToolName(name) else { return true }
            return (current.toolDefinitions[name]?.exposure ?? .direct) != .direct &&
                current.toolRegistry[TOOL_SEARCH_TOOL_NAME] != nil
        }
    }

    /// The tools reachable through a tool's context. Model-only and hidden tools never run here.
    public func getCallableTools() -> [AgentTool] {
        let active = Set(getActiveToolNames())
        return registeredTools().filter { tool in
            let value = exposure(of: tool.name)
            return value == .codemode || value == .deferred || (value == .direct && active.contains(tool.name))
        }
    }

    /// Execute a tool from another tool's per-call context.
    public func executeNestedTool(callerId: String, name: String, args: [String: AnyCodable],
                                  options: ExecuteToolOptions = ExecuteToolOptions()) async -> AgentToolCallOutcome {
        let runner: NestedToolCallRunner = state.withLock { state in
            if let existing = state.nestedToolCalls { return existing }
            let host = NestedToolCallHost(
                getTools: { [weak self] in self?.getCallableTools() ?? [] },
                isSequential: { [weak self] in self?.agent.toolExecution == .sequential },
                runToolCall: { [weak self] toolCall, parentId, signal, onUpdate in
                    guard let self, let assistant = self.lastAssistantMessage else {
                        return AgentToolCallOutcome(toolCall: toolCall,
                            result: AgentToolResult(content: [.text(TextContent(text: "No assistant message issued this call"))]),
                            isError: true)
                    }
                    let tools = self.getCallableTools()
                    let context = AgentContext(messages: self.agent.state.messages, tools: self.agent.state.tools)
                    return await runToolCall(toolCall, options: RunToolCallOptions(
                        tools: tools, assistantMessage: assistant, context: context,
                        signal: signal, onUpdate: onUpdate,
                        beforeToolCall: { [weak self] context, signal in
                            guard let self, let runner = self._hookRunner,
                                  runner.hasHandlers("tool_call") else { return nil }
                            let event = ToolCallEvent(toolName: context.toolCall.name,
                                toolCallId: context.toolCall.id, input: context.args,
                                parentToolCallId: parentId)
                            guard let result = await runner.emitToolCall(event, signal: signal), result.block else { return nil }
                            return BeforeToolCallResult(block: true, reason: result.reason,
                                                        terminate: result.terminate)
                        },
                        afterToolCall: { [weak self] context, _ in
                            guard let self else { return nil }
                            let hookResult: AfterToolCallResult?
                            if let runner = self._hookRunner, runner.hasHandlers("tool_result") {
                                let event = ToolResultEvent(toolName: context.toolCall.name,
                                    toolCallId: context.toolCall.id, input: context.args,
                                    content: context.result.content, details: context.result.details,
                                    isError: context.isError,
                                    structuredContent: context.result.structuredContent,
                                    usage: context.result.usage,
                                    parentToolCallId: parentId)
                                if let result = await runner.emitToolResult(event) {
                                    hookResult = AfterToolCallResult(content: result.content,
                                        details: result.details, isError: result.isError,
                                        usage: result.usage,
                                        structuredContent: result.structuredContent.map(StructuredContentOverride.set) ?? .absent)
                                } else { hookResult = nil }
                            } else { hookResult = nil }
                            let content = hookResult?.content ?? context.result.content
                            let normalized = normalizeToolResultImages(content,
                                autoResizeImages: self.settingsManager.getAutoResizeImages(),
                                resizeOptions: self.limitsModel.inputLimits?.images?.resize)
                            guard hookResult != nil || normalized.changed else { return nil }
                            return AfterToolCallResult(content: normalized.content,
                                details: hookResult?.details, isError: hookResult?.isError,
                                usage: hookResult?.usage, terminate: hookResult?.terminate,
                                structuredContent: hookResult?.structuredContent ??
                                    context.result.structuredContent.map(StructuredContentOverride.set) ?? .absent)
                        }
                    ))
                },
                emit: { [weak self] event in
                    await self?.emitNestedToolEvent(event)
                }
            )
            let runner = NestedToolCallRunner(host: host)
            state.nestedToolCalls = runner
            return runner
        }
        return await runner.execute(callerId: callerId, name: name, args: args, options: options)
    }

    private func emitNestedToolEvent(_ event: NestedToolExecutionEvent) async {
        if let runner = _hookRunner {
            switch event {
            case .start(let id, let name, let args, let parent):
                _ = await runner.emit(ToolExecutionStartEvent(toolCallId: id, toolName: name,
                                                               args: args, parentToolCallId: parent))
            case .update(let id, let name, let args, let partial, let parent):
                _ = await runner.emit(ToolExecutionUpdateEvent(toolCallId: id, toolName: name,
                                                                args: args, partialResult: partial,
                                                                parentToolCallId: parent))
            case .end(let id, let name, let result, let isError, let parent, let durationMs):
                _ = await runner.emit(ToolExecutionEndEvent(toolCallId: id, toolName: name,
                                                             result: result, isError: isError,
                                                             parentToolCallId: parent, durationMs: durationMs))
            }
        }
        emit(.nestedToolExecution(event))
    }

    public func getAllTools() -> [ToolInfo] {
        registeredTools().map { tool in
            let definition = toolDefinitions[tool.name]
            let customPath = customToolsInternal.first { $0.tool.name == tool.name }?.path
            let source = _hookRunner?.getToolSourceInfo(tool.name) ??
                (customPath.map { path in SourceInfo(path: path,
                    source: getSyntheticPathSource(path) ?? "custom", scope: "user", origin: "top-level") } ??
                 (ToolName(rawValue: tool.name) == nil
                    ? SourceInfo(path: "<sdk:\(tool.name)>", source: "sdk", scope: "temporary", origin: "top-level")
                    : SourceInfo(path: BUILTIN_PATH_PREFIX + tool.name, source: "builtin",
                                 scope: "user", origin: "top-level")))
            return ToolInfo(name: tool.name, description: definition?.description ?? tool.description,
                            sourceInfo: source, parameters: definition?.parameters ?? tool.parameters,
                            promptGuidelines: definition?.promptGuidelines ?? builtInToolPrompt[tool.name]?.guidelines,
                            exposure: definition?.exposure ?? .direct,
                            namespace: definition?.namespace, annotations: definition?.annotations)
        }
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

    private func refreshPromptResources() {
        let loader = resourceLoader
        state.withLock { state in
            state.systemPromptOptions.customPrompt = loader.getSystemPrompt()
            let appends = loader.getAppendSystemPrompt()
            state.systemPromptOptions.appendSystemPrompt = appends.isEmpty ? nil : appends.joined(separator: "\n\n")
            state.systemPromptOptions.contextFiles = loader.getAgentsFiles()
            state.systemPromptOptions.skills = loader.getSkills().skills
        }
    }

    public func setActiveToolsByName(_ toolNames: [String]) {
        let previous = getActiveToolNames()
        setActiveTools(toolNames)
        let active = Set(getActiveToolNames())
        if previous.contains(where: { !active.contains($0) }) {
            state.withLock { $0.pendingToolNames.removeAll() }
        }
    }

    private func isAllowedTool(_ name: String) -> Bool {
        state.withLock { current in
            if current.excludedTools.matches(name) { return false }
            if current.allowedTools?.matches(name) ?? true { return true }
            return !current.allowlistFiltersMcp && isMcpToolName(name)
        }
    }

    private func restoreActiveTools(_ names: [String]) {
        let pending = Set(names.filter(isAllowedTool))
        state.withLock { $0.pendingToolNames = pending }
        setActiveTools(names)
    }

    private func setActiveTools(_ toolNames: [String]) {
        var tools: [AgentTool] = []
        var seen: Set<String> = []
        for name in toolNames {
            if seen.insert(name).inserted, isAllowedTool(name), isActivatable(name), exposure(of: name) != .hidden,
               let tool = toolRegistry[name] {
                tools.append(tool)
            }
        }
        let active = Set(tools.map(\.name))
        state.withLock { $0.pendingToolNames.subtract(active) }
        let callable = registeredTools().filter { tool in
            let value = exposure(of: tool.name)
            return value == .codemode || value == .deferred || (value == .direct && active.contains(tool.name))
        }
        let definitions = toolDefinitions
        var guidelines = builtInToolPrompt.mapValues(\.guidelines)
        let promptSnapshot = state.withLock { ($0.systemPromptOptions.toolGuidelines ?? [:], $0.toolPromptGuidelines) }
        guidelines.merge(promptSnapshot.0) { _, supplied in supplied }
        for (name, definition) in definitions { guidelines[name] = definition.promptGuidelines }
        guidelines.merge(promptSnapshot.1) { _, extensionRules in extensionRules }
        let guidelineSnapshot = guidelines.mapValues { values in
            var seen = Set<String>()
            return values.compactMap { guideline in
                let trimmed = guideline.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
            }
        }
        let loadout = ToolLoadout(
            declared: tools, callable: callable, registered: registeredTools(),
            getExposure: { definitions[$0]?.exposure ?? .direct },
            getNamespace: { definitions[$0]?.namespace },
            getPromptGuidelines: { guidelineSnapshot[$0] ?? [] }
        )
        var descriptions: [String: String] = [:]
        var hidden: Set<String> = []
        for tool in tools {
            guard let prepare = definitions[tool.name]?.prepareLoadout else { continue }
            do {
                let changes = try prepare(loadout)
                descriptions.merge(changes?.descriptions ?? [:]) { _, new in new }
                hidden.formUnion(changes?.hiddenDeclarations ?? [])
            } catch {
                let path = _hookRunner?.getToolSourceInfo(tool.name)?.path ??
                    customToolsInternal.first { $0.tool.name == tool.name }?.path ?? "<sdk:\(tool.name)>"
                _hookRunner?.emitError(HookError(hookPath: path, event: "prepare_loadout",
                                                 error: error.localizedDescription))
            }
        }
        agent.tools = tools.map { tool in
            var declared = tool
            if let description = descriptions[tool.name] { declared.description = description }
            return declared
        }
        hiddenDeclarations = hidden
        state.withLock { $0.systemPromptOptions.selectedTools = tools.map(\.name).compactMap(ToolName.init(rawValue:)) }
    }

    /// Apply a tool registered after session creation. This is used by MCP
    /// metadata refreshes and gives inline extensions the same live tool
    /// surface as reloaded extensions.
    private func registerLiveExtensionTool(_ tool: CustomTool) {
        guard isAllowedTool(tool.name), let wrapped = wrapExtensionToolsInternal?([tool]).first else { return }
        var registry = toolRegistry
        registry[wrapped.name] = wrapped
        toolRegistry = registry
        if !toolRegistryOrder.contains(wrapped.name) { toolRegistryOrder.append(wrapped.name) }
        var definitions = toolDefinitions
        definitions[tool.name] = tool
        toolDefinitions = definitions
        state.withLock { $0.toolPromptGuidelines[tool.name] = tool.promptGuidelines }

        var activeNames = getActiveToolNames()
        if state.withLock({ $0.allowedTools != nil }) {
            activeNames += toolRegistryOrder.filter(isActivatedOnRegistration)
        }
        if !activeNames.contains(wrapped.name) && (isActivatedOnRegistration(wrapped.name) || state.withLock { $0.pendingToolNames.contains(wrapped.name) }) {
            activeNames.append(wrapped.name)
        }
        setActiveTools(activeNames)
        refreshSystemPromptForActiveTools()
    }

    private func unregisterLiveExtensionTool(_ name: String) {
        var registry = toolRegistry
        registry.removeValue(forKey: name)
        toolRegistry = registry
        toolRegistryOrder.removeAll { $0 == name }
        var definitions = toolDefinitions
        definitions.removeValue(forKey: name)
        toolDefinitions = definitions
        state.withLock { $0.toolPromptGuidelines[name] = nil }
        setActiveTools(getActiveToolNames().filter { $0 != name })
        refreshSystemPromptForActiveTools()
    }

    private func refreshSystemPromptForActiveTools() {
        let activeNames = getActiveToolNames()
        state.withLock { $0.systemPromptOptions.selectedTools = activeNames.compactMap(ToolName.init(rawValue:)) }
    }

    /// Reload settings and resources first. Then call `reloadExtensions()` to rebuild tools
    /// and activate names newly added to defaultTools.
    public func reload() async {
        let (usesDefaults, modifiers) = state.withLock { ($0.usesDefaultTools, $0.defaultToolModifiers) }
        let previousDefaults = Set(usesDefaults ? applyToolModifiers(
            base: settingsManager.getDefaultTools() ?? DEFAULT_TOOL_NAMES, entries: modifiers) : [])
        await settingsManager.reload()
        let added = usesDefaults ? applyToolModifiers(
            base: settingsManager.getDefaultTools() ?? DEFAULT_TOOL_NAMES, entries: modifiers)
            .filter { !previousDefaults.contains($0) } : []
        state.withLock { current in
            current.addedDefaultToolNames.append(contentsOf: added)
        }
        agent.steeringMode = AgentSteeringMode(rawValue: settingsManager.getSteeringMode()) ?? .oneAtATime
        agent.followUpMode = AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()) ?? .oneAtATime
        await resourceLoader.reload()
        promptTemplatesInternal = resourceLoader.getPrompts().prompts
        refreshPromptResources()
    }

    private func hasAuthForModel(_ model: Model) async -> Bool {
        // Upstream session checks configured auth without resolving request keys
        // or headers. Commands run only when the provider request starts.
        await modelRegistry.isAvailable(model)
    }

    private func hasRequestAuth(_ auth: ModelAuth) -> Bool {
        auth.ok && (auth.hasResolvedAuth || auth.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || !(auth.headers?.isEmpty ?? true))
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
        let activeBeforeReload = getActiveToolNames()
        state.withLock { $0.pendingToolNames.formUnion(activeBeforeReload) }
        guard let hookRunner = _hookRunner, let reloadHook = reloadExtensionsHookInternal else {
            applyReloadToolNames()
            return ReloadExtensionsResult(droppedPaths: [], loadedPaths: [], errors: [])
        }

        // 1. Notify currently-loaded extensions before they're swapped out.
        await hookRunner.emitToExtensions(SessionShutdownEvent(reason: .reload))

        // 2. Snapshot the current extension-tool roster so we can diff after the swap.
        let oldExtensionToolNames = hookRunner.getExtensionToolNames()

        // Remove old MCP registrations before loading replacements with normalized names.
        hookRunner.unregisterExtensionMcpServers()

        // 3. Re-discover and re-compile.
        let result = await reloadHook()

        // 4. Swap. Returns the paths that were dropped so the caller can log them.
        let dropped = hookRunner.replaceExtensionHooks(result.hooks)

        // 5. Refresh extension tools on the agent: drop the old, add the new.
        if let wrap = wrapExtensionToolsInternal {
            let newExtensionTools = hookRunner.getExtensionTools().filter { isAllowedTool($0.name) }
            let newExtensionToolNames = Set(newExtensionTools.map { $0.name })
            let removedToolNames = oldExtensionToolNames.subtracting(newExtensionToolNames)

            if !removedToolNames.isEmpty || !newExtensionTools.isEmpty {
                state.withLock { state in
                    for name in removedToolNames { state.toolPromptGuidelines[name] = nil }
                    for tool in newExtensionTools { state.toolPromptGuidelines[tool.name] = tool.promptGuidelines }
                }
                let wrappedNew = wrap(newExtensionTools)
                var registry = toolRegistry
                var order = toolRegistryOrder
                var definitions = toolDefinitions
                for name in removedToolNames {
                    registry.removeValue(forKey: name)
                    definitions.removeValue(forKey: name)
                }
                order.removeAll { removedToolNames.contains($0) }
                for tool in wrappedNew {
                    registry[tool.name] = tool
                    if !order.contains(tool.name) { order.append(tool.name) }
                }
                toolRegistry = registry
                toolRegistryOrder = order
                for tool in newExtensionTools { definitions[tool.name] = tool }
                toolDefinitions = definitions

                var activeNames = getActiveToolNames().filter { !removedToolNames.contains($0) }
                for tool in wrappedNew where !activeNames.contains(tool.name) && isActivatedOnRegistration(tool.name) {
                    activeNames.append(tool.name)
                }
                setActiveTools(activeNames)
            }
        }

        applyReloadToolNames()

        // 6. Notify the freshly-loaded extensions.
        await hookRunner.emitToExtensions(SessionStartEvent(reason: .reload))
        await extendResourcesFromExtensions(reason: .reload)

        return ReloadExtensionsResult(
            droppedPaths: dropped,
            loadedPaths: result.hooks.map { $0.path },
            errors: result.errors
        )
    }

    private func applyReloadToolNames() {
        let names = state.withLock { current in
            let names = current.addedDefaultToolNames + current.pendingToolNames.sorted()
            current.addedDefaultToolNames.removeAll()
            return names
        }
        let matchedNames = state.withLock({ $0.allowedTools != nil })
            ? toolRegistryOrder.filter(isActivatedOnRegistration) : []
        setActiveTools(getActiveToolNames() + matchedNames + names)
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

        refreshPromptResources()
    }

    private func preparePromptMessages(_ text: String, options: PromptOptions? = nil) async throws -> [AgentMessage] {
        if isStreaming || isBranchSummarizing {
            throw AgentSessionError.alreadyProcessingQueue
        }
        flushPendingCustomMessages()

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
            expandSlashCommands: options?.expandSlashCommands ?? options?.expandPromptTemplates ?? true,
            expandPromptTemplates: options?.expandPromptTemplates ?? true
        )
        var messages: [AgentMessage] = []
        forcedRequestPrompt = state.withLock { $0.systemPromptOptions.forceSystemPrompt }
        state.withLock { $0.runSystemPromptAppend = nil }
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
                forcedRequestPrompt = result.systemPrompt
                if !result.sections.isEmpty {
                    state.withLock { state in
                        var sections = state.systemPromptOptions.sections ?? SystemPromptSections([])
                        for name in result.sections.keys.sorted() {
                            if let value = result.sections[name] ?? nil { sections[name] = value }
                            else { sections.remove(name) }
                        }
                        state.systemPromptOptions.sections = sections
                    }
                }
            }
        }
        if let systemPromptAppend, !systemPromptAppend.isEmpty {
            state.withLock { $0.runSystemPromptAppend = systemPromptAppend }
        }
        // The hook may select a different model. Apply its image profile only now.
        if let index = messages.firstIndex(where: { $0.role == "user" }) {
            var omitted = 0
            let images = settingsManager.getAutoResizeImages() ? options?.images?.compactMap { image -> ImageContent? in
                let limits = ImageResizeOptions(modelProfile: limitsModel.inputLimits?.images?.resize)
                let resized = resizeImage(image, options: limits)
                guard imageFitsResizeLimits(resized, options: limits) else {
                    omitted += 1
                    return nil
                }
                return ImageContent(data: resized.data, mimeType: resized.mimeType)
            } : options?.images
            let text = omitted == 0 ? expandedText : expandedText + "\n[\(omitted) image(s) omitted: could not be resized below the inline image size limit.]"
            messages[index] = buildUserMessage(text: text, images: images)
        }
        if let update = try preparePromptPatch() { messages.insert(.system(update), at: 0) }
        return messages
    }

    /// Submit a prompt after running all synchronous preflight work, then continue the model
    /// turn in the returned task. This lets RPC callers acknowledge accepted prompts without
    /// waiting for the whole assistant response while still surfacing immediate rejection.
    @discardableResult
    public func submitPrompt(_ text: String, options: PromptOptions? = nil) async throws -> Task<Void, Error> {
        let deferred = state.withLock { state -> Bool in
            guard state.isEmittingAgentSettled else { return false }
            state.deferredSettledActions.append { [weak self] in
                try? await self?.prompt(text, options: options)
            }
            return true
        }
        if deferred { return Task {} }
        if options?.expandPromptTemplates != false, text.hasPrefix("/"), let runner = _hookRunner {
            let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if let name = parts.first, let command = runner.getCommand(String(name)) {
                try await command.handler(parts.count > 1 ? String(parts[1]) : "", runner.createCommandContext())
                options?.preflightResult?(.handled)
                return Task {}
            }
        }
        // K20: extension commands run first; all other prompts reject during compaction.
        if isCompactingInternal { throw AgentSessionError.compactionInProgress }

        guard let input = await processInput(text, images: options?.images,
                                             source: options?.source ?? .interactive,
                                             behavior: options?.streamingBehavior) else {
            options?.preflightResult?(.handled)
            return Task {}
        }
        if isStreaming {
            guard let behavior = options?.streamingBehavior else { throw AgentSessionError.alreadyProcessingQueue }
            let expandedText = expandPromptText(input.text)
            let message = buildUserMessage(text: expandedText, images: input.images)
            switch behavior {
            case .steer:
                steeringMessages.append(expandedText)
                agent.steer(message)
            case .followUp:
                followUpMessages.append(expandedText)
                agent.followUp(message)
            }
            options?.preflightResult?(.queued)
            return Task {}
        }
        var processedOptions = options ?? PromptOptions()
        processedOptions.images = input.images
        let messages = try await preparePromptMessages(input.text, options: processedOptions)
        failedResponse = nil
        recordSelection()
        state.withLock { $0.pendingToolNames.removeAll() }
        options?.preflightResult?(.started)
        state.withLock { $0.agentRunAbortRequested = false }
        await idleWaiter.beginRun()
        let task = Task { [weak self, agent] in
            defer {
                Task { [weak self] in
                    await self?.emitAgentSettledIfNeeded()
                }
            }
            do {
                try await agent.prompt(messages)
            } catch {
                self?.flushPendingCustomMessages()
                throw error
            }
            let events = self?._agentEventQueue.withLock { $0 }
            await events?.value
            self?.flushPendingCustomMessages()
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
        forcedRequestPrompt = nil
        failedResponse = nil
        state.withLock { $0.runSystemPromptAppend = nil }
        try await runUntilSettled { [agent] in
            try await agent.continue()
        }
    }

    /// Repairs history before a manual retry by atomically removing a trailing
    /// assistant message that ended in `.error`, so a subsequent `continue()` does
    /// not throw `AgentError.lastMessageAssistant`. Returns whether a message was
    /// removed; a no-op (returns `false`) while streaming.
    ///
    /// This is the counterpart of the repair the auto-retry path performs in
    /// `handleRetryableError`, exposed so UI-driven retry does not have to reach
    /// into `agent.state.messages` with a non-atomic get-then-set.
    @discardableResult
    public func dropTrailingErroredAssistant() -> Bool {
        guard !isStreaming else { return false }
        return agent.dropTrailingErroredAssistant()
    }

    private func processInput(_ text: String, images: [ImageContent]?, source: HookInputSource,
                              behavior: HookInputStreamingBehavior? = nil) async -> (text: String, images: [ImageContent]?)? {
        guard let runner = _hookRunner, runner.hasHandlers("input") else { return (text, images) }
        let result = await runner.emitInput(InputEvent(text: text, images: images, source: source,
                                                       streamingBehavior: isStreaming ? behavior : nil))
        switch result {
        case .continue: return (text, images)
        case .transform(let transformed, let transformedImages): return (transformed, transformedImages ?? images)
        case .handled: return nil
        }
    }

    /// Compatibility entry point for callers that queue synchronously.
    public func steer(_ text: String, images: [ImageContent]? = nil) {
        let expandedText = expandPromptText(text)
        steeringMessages.append(expandedText)
        agent.steer(buildUserMessage(text: expandedText, images: images))
    }

    public func followUp(_ text: String) {
        let expandedText = expandPromptText(text)
        followUpMessages.append(expandedText)
        agent.followUp(buildUserMessage(text: expandedText, images: nil))
    }

    /// Queue RPC or interactive input after extension input handlers have processed it.
    @discardableResult
    public func steer(_ text: String, images: [ImageContent]? = nil, source: HookInputSource) async -> QueuedInputDisposition {
        guard let input = await processInput(text, images: images, source: source, behavior: .steer) else { return .handled }
        let expandedText = expandPromptText(input.text)
        steeringMessages.append(expandedText)
        agent.steer(buildUserMessage(text: expandedText, images: input.images))
        return .queued
    }

    /// Queue a follow-up after extension input handlers have processed it.
    @discardableResult
    public func followUp(_ text: String, images: [ImageContent]? = nil, source: HookInputSource) async -> QueuedInputDisposition {
        guard let input = await processInput(text, images: images, source: source, behavior: .followUp) else { return .handled }
        let expandedText = expandPromptText(input.text)
        followUpMessages.append(expandedText)
        agent.followUp(buildUserMessage(text: expandedText, images: input.images))
        return .queued
    }

    /// Queue immediately so a turn-end extension message participates in that turn's flush.
    public func enqueueHookMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) {
        guard let prompt = prepareHookMessage(message, options: options) else { return }
        Task { [weak self] in try? await self?.runHookPrompt(prompt) }
    }

    public func sendHookMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) async {
        guard let prompt = prepareHookMessage(message, options: options) else { return }
        try? await runHookPrompt(prompt)
    }

    private func runHookPrompt(_ prompt: AgentMessage) async throws {
        let deferred = state.withLock { state -> Bool in
            guard state.isEmittingAgentSettled else { return false }
            state.deferredSettledActions.append { [weak self] in
                try? await self?.runHookPrompt(prompt)
            }
            return true
        }
        if deferred { return }
        failedResponse = nil
        recordSelection()
        state.withLock { $0.pendingToolNames.removeAll() }
        try await runUntilSettled { [agent] in try await agent.prompt(prompt) }
        let events = _agentEventQueue.withLock { $0 }
        await events?.value
        flushPendingCustomMessages()
    }

    private func prepareHookMessage(_ message: HookMessageInput, options: HookSendMessageOptions?) -> AgentMessage? {
        let hookMessage = HookMessage(customType: message.customType, content: message.content, display: message.display, details: message.details)
        let agentMessage = makeHookAgentMessage(hookMessage)
        if options?.deliverAs == .nextTurn {
            state.withLock { $0.pendingNextTurnMessages.append(hookMessage) }
        } else if isStreaming {
            if options?.triggerTurn == false {
                state.withLock { $0.pendingCustomMessages.append(hookMessage) }
            } else if options?.deliverAs == .followUp {
                agent.followUp(agentMessage)
            } else {
                agent.steer(agentMessage)
            }
        } else if options?.triggerTurn == true {
            return agentMessage
        } else {
            appendCustomMessage(hookMessage)
        }
        return nil
    }

    private func appendCustomMessage(_ message: HookMessage) {
        let agentMessage = makeHookAgentMessage(message)
        agent.appendMessage(agentMessage)
        _ = sessionManager.appendCustomMessage(message.customType, message.content, message.display, details: message.details)
        emit(.agent(.messageStart(message: agentMessage)))
        emit(.agent(.messageEnd(message: agentMessage)))
    }

    private func flushPendingCustomMessages() {
        let messages = state.withLock { state in
            let messages = state.pendingCustomMessages
            state.pendingCustomMessages.removeAll()
            return messages
        }
        for message in messages { appendCustomMessage(message) }
    }

    public func sendUserMessage(_ content: String, options: HookSendMessageOptions? = nil) async throws {
        let expand = options?.expandPromptTemplates ?? false
        if expand, content.hasPrefix("/"), let runner = _hookRunner {
            let parts = content.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if let name = parts.first, let command = runner.getCommand(String(name)) {
                try await command.handler(parts.count > 1 ? String(parts[1]) : "", runner.createCommandContext())
                return
            }
        }
        if isStreaming {
            let text = expand ? expandPromptText(content) : content
            if options?.deliverAs == .followUp {
                followUpMessages.append(text)
                agent.followUp(buildUserMessage(text: text, images: nil))
            } else {
                steeringMessages.append(text)
                agent.steer(buildUserMessage(text: text, images: nil))
            }
        } else {
            try await prompt(content, options: PromptOptions(expandSlashCommands: expand, expandPromptTemplates: expand))
        }
    }

    public func clearQueue() -> (steering: [String], followUp: [String]) {
        let steering = steeringMessages
        let follow = followUpMessages
        steeringMessages.removeAll()
        followUpMessages.removeAll()
        agent.clearAllQueues()
        return (steering, follow)
    }

    public func abort() async {
        await idleWaiter.requestAbort()
        state.withLock { $0.agentRunAbortRequested = true }
        abortRetry()
        finishCancelledRetry(attempt: retryAttempt)
        agent.abort()
        compactionAbort?.cancel()
        branchSummaryAbort?.cancel()
        abortBash()
        await waitForIdle()
    }

    public var isBashRunning: Bool {
        state.withLock { !$0.bashAbortTokens.isEmpty }
    }

    /// Runs a user command. Explicit `operations` win, then the session's own, then the
    /// process-wide `BashExecutorRegistry`.
    public func executeBash(
        _ command: String,
        excludeFromContext: Bool = false,
        onChunk: (@Sendable (String) -> Void)? = nil,
        operations: BashOperations? = nil
    ) async throws -> BashResult {
        let abortToken = CancellationToken()
        let invocationId = UUID()
        state.withLock { $0.bashAbortTokens[invocationId] = abortToken }
        defer { state.withLock { $0.bashAbortTokens.removeValue(forKey: invocationId) } }

        let options = BashExecutorOptions(
            onChunk: onChunk,
            signal: abortToken,
            environment: bashSessionEnvironment(),
            cwd: sessionManager.getCwd()
        )
        let result = if let operations = operations ?? bashOperations {
            try await executeBashWithOperations(command, operations: operations, options: options)
        } else {
            try await PiSwiftCodingAgent.executeBash(command, options: options)
        }
        recordBashResult(command, result, excludeFromContext: excludeFromContext)
        return result
    }

    private func bashSessionEnvironment() -> [String: String] {
        let current = agent.state
        return makePiSessionEnvironment(
            sessionId: sessionManager.getSessionId(),
            sessionFile: sessionManager.getSessionFile(),
            provider: current.model.provider,
            model: current.model.id,
            reasoningLevel: current.thinkingLevel.rawValue
        )
    }

    public func recordBashResult(_ command: String, _ result: BashResult, excludeFromContext: Bool) {
        let message = BashExecutionMessage(
            command: command,
            output: result.output,
            exitCode: result.exitCode,
            cancelled: result.cancelled,
            truncated: result.truncated,
            fullOutputPath: result.fullOutputPath,
            excludeFromContext: excludeFromContext ? true : nil
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
        let tokens = state.withLock { Array($0.bashAbortTokens.values) }
        for token in tokens {
            token.cancel()
        }
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
        isCompactingInternal || isBranchSummarizing
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

    private func finishCancelledRetry(attempt: Int) {
        guard retryAttempt > 0 else { return }
        retryAttempt = 0
        retryAbort = nil
        retryTask = nil
        emit(.autoRetryEnd(success: false, attempt: attempt, finalError: "Retry cancelled"))
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
        do {
            try agent.reset()
        } catch {
            return false
        }
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

    public func switchSession(_ sessionPath: String, emitBeforeSwitch: Bool = true) async -> Bool {
        guard (try? SessionManager.openValidated(sessionPath)) != nil else { return false }
        let previousSession = sessionFile
        if emitBeforeSwitch, let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_switch") {
            if let result = await hookRunner.emit(SessionBeforeSwitchEvent(reason: .resume, targetSessionFile: sessionPath)) as? SessionBeforeSwitchResult,
               result.cancel {
                return false
            }
        }
        await abort()
        do {
            try agent.reset()
        } catch {
            return false
        }
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

    public func importFromJsonl(_ inputPath: String) async throws -> HookCommandResult {
        let source = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SessionImportError.fileNotFound(source.path)
        }
        let directory = URL(fileURLWithPath: sessionManager.getSessionDir().isEmpty ? URL(fileURLWithPath: getSessionsDir()).appendingPathComponent("imports").path : sessionManager.getSessionDir())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        var destination = original
        let stored = source == original
        var suffix = 1
        if !stored {
            while FileManager.default.fileExists(atPath: destination.path) {
                let extensionPart = original.pathExtension.isEmpty ? "" : "." + original.pathExtension
                destination = directory.appendingPathComponent(original.deletingPathExtension().lastPathComponent + "-\(suffix)" + extensionPart)
                suffix += 1
            }
        }
        if let runner = _hookRunner,
           let result = await runner.emit(SessionBeforeSwitchEvent(reason: .resume, targetSessionFile: destination.path)) as? SessionBeforeSwitchResult,
           result.cancel { return HookCommandResult(cancelled: true) }
        if !stored { try FileManager.default.copyItem(at: source, to: destination) }
        _ = try SessionManager.openValidated(destination.path, directory.path)
        return HookCommandResult(cancelled: !(await switchSession(destination.path, emitBeforeSwitch: false)))
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
            setThinkingLevel(thinkingLevelForModelSwitch(fallback))
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

    public func setModel(_ model: Model, options: ModelMutationOptions = ModelMutationOptions()) async throws {
        guard await hasAuthForModel(model) else {
            throw AgentSessionError.missingApiKeyForModel(provider: model.provider, modelId: model.id)
        }
        let previousModel = agent.state.model
        agent.model = model
        sessionManager.appendModelChange(model.provider, model.id)
        if options.persist { persistDefaultModel(model) }
        setThinkingLevel(thinkingLevelForModelSwitch(model))
        await emitModelSelect(nextModel: model, previousModel: previousModel, source: .set)
    }

    public func cycleModel(direction: ModelCycleDirection = .forward, options: ModelMutationOptions = ModelMutationOptions()) async throws -> ModelCycleResult? {
        if !scopedModelsInternal.isEmpty {
            return try await cycleScopedModel(direction, options: options)
        }
        return try await cycleAvailableModel(direction, options: options)
    }

    private func cycleScopedModel(_ direction: ModelCycleDirection, options: ModelMutationOptions) async throws -> ModelCycleResult? {
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
        agent.model = next.model
        sessionManager.appendModelChange(next.model.provider, next.model.id)
        if options.persist { persistDefaultModel(next.model) }
        setThinkingLevel(thinkingLevelForModelSwitch(next.model, explicit: next.isThinkingExplicit ? next.thinkingLevel : nil))
        await emitModelSelect(nextModel: next.model, previousModel: previousModel, source: .cycle)
        return ModelCycleResult(model: next.model, thinkingLevel: agent.state.thinkingLevel, isScoped: true)
    }

    private func cycleAvailableModel(_ direction: ModelCycleDirection, options: ModelMutationOptions) async throws -> ModelCycleResult? {
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
        if options.persist { persistDefaultModel(next) }
        setThinkingLevel(thinkingLevelForModelSwitch(next))
        await emitModelSelect(nextModel: next, previousModel: previousModel, source: .cycle)
        return ModelCycleResult(model: next, thinkingLevel: agent.state.thinkingLevel, isScoped: false)
    }

    public func setThinkingLevel(_ level: ThinkingLevel, options: ModelMutationOptions = ModelMutationOptions()) {
        var effective = level
        if !agent.state.model.reasoning {
            effective = .off
        } else {
            let requested = PiSwiftAI.ModelThinkingLevel(rawValue: level.rawValue) ?? .off
            let clamped = PiSwiftAI.clampThinkingLevel(model: agent.state.model, requested: requested)
            effective = ThinkingLevel(rawValue: clamped.rawValue) ?? .off
        }
        if agent.state.thinkingLevel != effective {
            agent.thinkingLevel = effective
            sessionManager.appendThinkingLevelChange(effective.rawValue)
        }
        if options.persist { settingsManager.setDefaultThinkingLevel(level.rawValue) }
    }

    public func cycleThinkingLevel(options: ModelMutationOptions = ModelMutationOptions()) -> ThinkingLevel? {
        guard agent.state.model.reasoning else { return nil }
        let levels = PiSwiftAI.getSupportedThinkingLevels(agent.state.model).compactMap { ThinkingLevel(rawValue: $0.rawValue) }
        guard !levels.isEmpty else { return nil }
        let currentIndex = levels.firstIndex(of: agent.state.thinkingLevel) ?? 0
        let next = levels[(currentIndex + 1) % levels.count]
        setThinkingLevel(next, options: options)
        return next
    }

    public func getAvailableThinkingLevels(_ model: Model? = nil) -> [ThinkingLevel] {
        let model = model ?? agent.state.model
        guard !model.id.isEmpty else { return THINKING_LEVEL_OPTIONS }
        return PiSwiftAI.getSupportedThinkingLevels(model).compactMap { ThinkingLevel(rawValue: $0.rawValue) }
    }

    private func thinkingLevelForModelSwitch(_ model: Model, explicit: ThinkingLevel? = nil) -> ThinkingLevel {
        explicit
            ?? settingsManager.getModelThinkingLevel(model.provider, model.id)
            ?? settingsManager.getDefaultThinkingLevel().flatMap(ThinkingLevel.init(rawValue:))
            ?? agent.state.thinkingLevel
    }

    private func persistDefaultModel(_ model: Model) {
        settingsManager.setDefaultModelAndProvider(model.provider, model.id)
        if !scopedModelsInternal.isEmpty && !scopedModelsInternal.contains(where: { modelsAreEqual($0.model, model) }) {
            scopedModelsInternal.append(ScopedModel(model: model))
            guard var enabled = settingsManager.getEnabledModels(), !enabled.isEmpty else { return }
            let id = "\(model.provider)/\(model.id)"
            if !enabled.contains(where: { $0.lowercased() == id.lowercased() }) { enabled.append(id) }
            settingsManager.setEnabledModels(enabled)
        }
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
        var userMessages = 0
        var assistantMessages = 0
        var toolResults = 0
        var totalMessages = 0
        var toolCalls = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0
        func add(_ usage: Usage) {
            totalInput += usage.input
            totalOutput += usage.output
            totalCacheRead += usage.cacheRead
            totalCacheWrite += usage.cacheWrite
            totalCost += usage.cost.total
        }
        for entry in sessionManager.getEntries() {
            switch entry {
            case .usage(let usageEntry): add(usageEntry.usage)
            case .branchSummary(let summary): if let usage = summary.usage { add(usage) }
            case .compaction(let compaction): if let usage = compaction.usage { add(usage) }
            case .message(let messageEntry):
                totalMessages += 1
                switch messageEntry.message {
                case .user: userMessages += 1
                case .toolResult(let result):
                    toolResults += 1
                    if let usage = result.usage { add(usage) }
                case .assistant(let assistant):
                    assistantMessages += 1
                    toolCalls += assistant.content.filter { if case .toolCall = $0 { return true }; return false }.count
                    add(assistant.usage)
                default: break
                }
            default: break
            }
        }
        let tokens = SessionStats.TokenStats(input: totalInput, output: totalOutput,
            cacheRead: totalCacheRead, cacheWrite: totalCacheWrite,
            total: totalInput + totalOutput + totalCacheRead + totalCacheWrite)
        return SessionStats(sessionFile: sessionFile, sessionId: sessionId,
            userMessages: userMessages, assistantMessages: assistantMessages, toolCalls: toolCalls,
            toolResults: toolResults, totalMessages: totalMessages, tokens: tokens, cost: totalCost,
            contextUsage: getContextUsage())
    }

    /// v0.70.0: token-budget usage relative to the active model's context window.
    /// Returns nil when:
    ///   - no model selected
    ///   - contextWindow <= 0
    /// `tokens` and `percent` are nil when the latest assistant usage is pre-compaction
    /// (we can only trust usage from an assistant that responded after the latest compaction —
    /// otherwise the count reflects a pre-compaction snapshot that's no longer valid).
    public func getContextUsage() -> ContextUsage? {
        let model = limitsModel
        let contextWindow = model.contextWindow
        guard contextWindow > 0 else { return nil }

        // Upstream checks the branch after its last compaction entry. Retained
        // pre-compaction assistants do not describe the current context size.
        guard hasPostCompactionUsage() else {
            return ContextUsage(tokens: nil, contextWindow: contextWindow, percent: nil)
        }
        let used = estimatedContextTokens(agent.state.messages)
        let percent = Double(used) / Double(contextWindow) * 100.0
        return ContextUsage(tokens: used, contextWindow: contextWindow, percent: percent)
    }

    public func exportToHtml(_ outputPath: String? = nil, themeName: String? = nil, toolRenderer: (any ToolHtmlRenderer)? = nil) async throws -> String {
        let themeName = [themeName, settingsManager.getTheme()].compactMap { $0 }.first { getThemeByName($0) != nil }
        return try await exportSessionToHtml(
            sessionManager,
            agent.state,
            ExportOptions(outputPath: outputPath, themeName: themeName, toolRenderer: toolRenderer ?? toolHtmlRenderer)
        )
    }

    public func exportToJsonl(_ outputPath: String? = nil) throws -> String {
        try exportSessionToJsonl(sessionManager, outputPath: outputPath)
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

        await abort()
        try agent.reset()

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

        await abort()
        try agent.reset()
        if msg.parentId == nil {
            _ = sessionManager.newSession(NewSessionOptions(parentSession: previousSession))
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
        customInstructions: String? = nil,
        replaceInstructions: Bool? = nil,
        label: String? = nil
    ) async -> (editorText: String?, cancelled: Bool, aborted: Bool?, summaryEntry: BranchSummaryEntry?) {
        guard !isStreaming, !isCompacting else { return (nil, true, nil, nil) }
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
        await idleWaiter.beginRun()
        defer {
            isBranchSummarizing = false
            branchSummaryAbort = nil
            Task { [weak self] in await self?.emitAgentSettledIfNeeded() }
        }
        var summaryText: String?
        var summaryDetails: AnyCodable?
        var summaryUsage: Usage?
        var fromHook = false

        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_tree") {
            if let result = await hookRunner.emit(SessionBeforeTreeEvent(preparation: preparation, signal: branchSummaryAbort)) as? SessionBeforeTreeResult {
                if result.cancel {
                    return (nil, true, nil, nil)
                }
                if let summary = result.summary {
                    summaryUsage = summary.usage
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
            let summary: (request: ResolvedModelRequest, thinkingLevel: PiSwiftAI.ThinkingLevel?)
            do {
                summary = try await getSummarizationRequestAuth(model, signal: branchSummaryAbort)
            } catch {
                reportBoundaryError("model_route", error.localizedDescription)
                return (nil, true, nil, nil)
            }
            let request = summary.request
            let apiKey = request.auth.apiKey
            if hasRequestAuth(request.auth) {
                let options = GenerateBranchSummaryOptions(
                    model: request.model,
                    apiKey: apiKey ?? "",
                    headers: request.auth.headers,
                    env: request.auth.env,
                    thinkingLevel: summary.thinkingLevel,
                    signal: branchSummaryAbort,
                    customInstructions: customInstructions,
                    replaceInstructions: replaceInstructions,
                    reserveTokens: settingsManager.getBranchSummarySettings().reserveTokens,
                    streamFn: agent.streamFn,
                    retry: summaryRetryPolicy,
                    callbacks: summaryRetryCallbacks
                )
                let result = await generateBranchSummary(collection.entries, options)
                if result.aborted == true {
                    return (nil, true, true, nil)
                }
                if result.error != nil {
                    return (nil, true, nil, nil)
                }
                summaryUsage = result.usage
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
                let summaryId = try sessionManager.branchWithSummary(newLeafId, summaryText, details: summaryDetails, fromHook: fromHook, usage: summaryUsage)
                if case .branchSummary(let entry) = sessionManager.getEntry(summaryId) {
                    summaryEntry = entry
                }
                // Attach label to the summary entry
                if let label {
                    _ = try sessionManager.appendLabelChange(summaryId, label)
                }
            } else if newLeafId == nil {
                sessionManager.resetLeaf()
            } else if let newLeafId {
                try sessionManager.branch(newLeafId)
            }
            // Attach label to target entry when not summarizing (no summary entry to label)
            if let label, summaryText == nil {
                _ = try sessionManager.appendLabelChange(targetId, label)
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
        await abort()
        guard let compactionToken = beginCompaction() else {
            throw AgentSessionError.compactionInProgress
        }
        await idleWaiter.beginRun()
        defer { Task { [weak self] in await self?.emitAgentSettledIfNeeded() } }

        do {
            let result = try await performCompaction(
                customInstructions: customInstructions,
                compactionToken: compactionToken
            )
            let queuedPrompts = finishCompaction(compactionToken)
            await deliverQueuedCompactionPrompts(queuedPrompts)
            return result
        } catch {
            let fromExtension = state.withLock { $0.compactionFromExtension }
            let queuedPrompts = finishCompaction(compactionToken)
            if queuedPrompts.isEmpty { await emitAgentSettledIfNeeded() }
            let aborted = compactionToken.isCancelled || isCompactionCancellation(error)
            await emitCompactionFailure(reason: .manual, error: aborted ? nil : "Compaction failed: \(error.localizedDescription)", aborted: aborted, willRetry: false, fromExtension: fromExtension)
            await deliverQueuedCompactionPrompts(queuedPrompts)
            throw error
        }
    }

    private var summaryRetryPolicy: RetryPolicy {
        let settings = settingsManager.getRetrySettings()
        return RetryPolicy(enabled: settings.enabled ?? true, maxRetries: settings.maxRetries ?? 3,
            baseDelayMs: Double(settings.baseDelayMs ?? 2000), maxAgentDelayMs: Double(settings.maxAgentDelayMs ?? 60_000))
    }

    private var summaryRetryCallbacks: RetryCallbacks {
        RetryCallbacks(onRetryScheduled: { [weak self] attempt, maxAttempts, delay, error in
            self?.emit(.autoRetryStart(attempt: attempt, maxAttempts: maxAttempts, delayMs: Int(delay), errorMessage: error))
        }, onRetryFinished: { [weak self] success, attempt, error in
            self?.emit(.autoRetryEnd(success: success, attempt: attempt, finalError: error))
        })
    }

    private func performCompaction(
        customInstructions: String?,
        compactionToken: CancellationToken
    ) async throws -> CompactionResult {

        let model = agent.state.model
        if compactionToken.isCancelled { throw AgentSessionError.compactionCancelled }

        let pathEntries = sessionManager.getBranch()
        let settings = settingsManager.getCompactionSettings(model: agent.state.model)
        guard let preparation = prepareCompaction(pathEntries, settings) else {
            throw AgentSessionError.nothingToCompact
        }

        var hookCompaction: CompactionResult?
        var fromHook = false
        if let hookRunner = _hookRunner, hookRunner.hasHandlers("session_before_compact") {
            if let result = await hookRunner.emit(SessionBeforeCompactEvent(preparation: preparation, branchEntries: pathEntries, customInstructions: customInstructions, signal: compactionToken)) as? SessionBeforeCompactResult {
                if result.cancel {
                    throw AgentSessionError.compactionCancelled
                }
                if let compaction = result.compaction {
                    hookCompaction = compaction
                    fromHook = true
                    state.withLock { $0.compactionFromExtension = true }
                }
            }
        }

        let result: CompactionResult
        if let hookCompaction {
            result = hookCompaction
        } else {
            let summary = try await getSummarizationRequestAuth(model, signal: compactionToken)
            let request = summary.request
            if compactionToken.isCancelled { throw AgentSessionError.compactionCancelled }
            let apiKey = request.auth.apiKey
            if !hasRequestAuth(request.auth) {
                throw AgentSessionError.missingApiKey(provider: request.model.provider)
            }
            result = try await PiSwiftCodingAgent.compact(
                preparation,
                request.model,
                apiKey ?? "",
                headers: request.auth.headers,
                env: request.auth.env,
                customInstructions: customInstructions,
                signal: compactionToken,
                thinkingLevel: summary.thinkingLevel,
                streamFn: agent.streamFn,
                retry: summaryRetryPolicy,
                callbacks: summaryRetryCallbacks
            )
        }

        if compactionToken.isCancelled {
            throw AgentSessionError.compactionCancelled
        }

        _ = sessionManager.appendCompaction(
            result.summary,
            result.firstKeptEntryId,
            result.tokensBefore,
            details: result.details,
            fromHook: fromHook,
            usage: result.usage
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

    private func beginCompaction() -> CancellationToken? {
        state.withLock { state in
            guard !state.isCompactingInternal else { return nil }
            let token = CancellationToken()
            state.isCompactingInternal = true
            state.compactionFromExtension = false
            state.compactionAbort = token
            return token
        }
    }

    private func getSummarizationRequestAuth(
        _ selectedModel: Model, signal: CancellationToken? = nil
    ) async throws -> (request: ResolvedModelRequest, thinkingLevel: PiSwiftAI.ThinkingLevel?) {
        let thinking = agent.state.thinkingLevel
        let route: ModelRoute?
        if isVirtualModel(selectedModel) {
            route = try await modelRegistry.resolveVirtualModel(
                selectedModel, messages: convertToLlm(agent.state.messages), reason: .direct,
                thinkingLevel: ModelThinkingLevel(rawValue: thinking.rawValue) ?? .off,
                signal: signal)
        } else {
            route = nil
        }
        let request = await resolveModelRequestWithHooks(route?.model ?? selectedModel, signal: signal)
        let level = route?.thinkingLevel.rawValue ?? thinking.rawValue
        return (request, PiSwiftAI.ThinkingLevel(rawValue: level))
    }

    private func resolveModelRequestWithHooks(_ model: Model, signal: CancellationToken? = nil) async -> ResolvedModelRequest {
        let request = await modelRegistry.resolveModelRequest(model, signal: signal)
        guard let hookRunner = _hookRunner,
              hookRunner.hasHandlers("before_provider_headers") else {
            return request
        }
        let headers = await hookRunner.emitBeforeProviderHeaders(request.auth.headers ?? [:])
        return ResolvedModelRequest(
            model: request.model,
            auth: ModelAuth(
                ok: request.auth.ok,
                apiKey: request.auth.apiKey,
                headers: headers,
                baseUrl: request.auth.baseUrl,
                error: request.auth.error,
                env: request.auth.env,
                hasResolvedAuth: request.auth.hasResolvedAuth
            )
        )
    }

    private func finishCompaction(_ token: CancellationToken) -> [QueuedCompactionPrompt] {
        return state.withLock { state in
            guard state.compactionAbort === token else { return [] }
            state.compactionAbort = nil
            state.isCompactingInternal = false
            let queued = state.queuedCompactionPrompts
            state.queuedCompactionPrompts.removeAll()
            return queued
        }
    }

    private func deliverQueuedCompactionPrompts(_ prompts: [QueuedCompactionPrompt]) async {
        for prompt in prompts {
            if isStreaming {
                let text = expandPromptText(prompt.text, expandSlashCommands: prompt.options?.expandSlashCommands ?? prompt.options?.expandPromptTemplates ?? true, expandPromptTemplates: prompt.options?.expandPromptTemplates ?? true)
                steeringMessages.append(text)
                agent.steer(buildUserMessage(text: text, images: prompt.options?.images))
                await prompt.completion.succeed()
                continue
            }
            do {
                let task = try await submitPrompt(prompt.text, options: prompt.options)
                try await task.value
                await prompt.completion.succeed()
            } catch {
                await prompt.completion.fail(error.localizedDescription)
            }
        }
    }

    public func refreshContext() {
        refreshContext(sessionManager.buildSessionProjection())
    }

    private func refreshContext(_ projection: SessionProjection) {
        agent.messages = projection.messages
    }

    private func syncAgentContext() async {
        let context = sessionManager.buildSessionProjection()
        let previousModel = agent.state.model
        refreshContext(context)
        // A branch without a system message has no restored pending tools.
        state.withLock { $0.pendingToolNames.removeAll() }
        if let current = getCurrentSystemMessage(context.messages) {
            let names = (current.toolsAdded ?? []).map(\.name)
            restoreActiveTools(names)
            let activeNames = getActiveToolNames()
            state.withLock { $0.systemPromptOptions.selectedTools = activeNames.compactMap(ToolName.init(rawValue:)) }
        }
        if let modelInfo = getBranchSelection(sessionManager.getBranch(), getModel: modelRegistry.find) {
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
