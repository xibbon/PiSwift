import Foundation
import PiSwiftAI
import PiSwiftAgent

public typealias HookFactory = @Sendable (HookAPI) -> Void

public struct HookDefinition: Sendable {
    public var path: String?
    public var factory: HookFactory

    public init(path: String? = nil, factory: @escaping HookFactory) {
        self.path = path
        self.factory = factory
    }
}


public enum SystemPromptInput: Sendable {
    case text(String)
    case builder(@Sendable (String) -> String)
}

/// v0.68.0 / v0.70.0: NoToolsMode controls scope of `--no-tools` / `noTools` SDK option.
/// `.all` disables every tool (built-in + extension + custom). `.builtin` disables only
/// the default built-in set, keeping extension/custom tools active.
public enum NoToolsMode: String, Sendable {
    case all
    case builtin
}

public struct CreateAgentSessionOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var authStorage: AuthStorage?
    public var modelRegistry: ModelRegistry?
    public var model: Model?
    public var thinkingLevel: ThinkingLevel?
    public var scopedModels: [ScopedModel]?
    public var sessionId: String?
    public var projectTrusted: Bool?
    public var offline: Bool?
    public var systemPrompt: SystemPromptInput?
    /// v0.68.0: tool-name allowlist for built-in tools. When set, only the named tools are
    /// activated. Names match `ToolName.rawValue` (e.g., "read", "bash", "edit", "write",
    /// "grep", "find", "ls", "subagent").
    public var toolNames: [String]?
    /// v0.79.4: tool-name denylist applied after built-in, custom, and extension tools
    /// are resolved. Names match the final tool names, so custom/extension tools can be
    /// excluded as well as built-ins.
    public var excludeTools: [String]?
    /// v0.68.0 / v0.70.0: disable tools in batch.
    /// `.all`: disable everything (no built-ins, no extensions, no custom tools).
    /// `.builtin`: keep extension/custom tools, disable only the default built-in set.
    public var noTools: NoToolsMode?
    public var customTools: [CustomToolDefinition]?
    public var additionalCustomToolPaths: [String]?
    public var resourceLoader: ResourceLoader?
    public var hooks: [HookDefinition]?
    public var additionalHookPaths: [String]?
    public var additionalExtensionPaths: [String]?
    public var eventBus: EventBus?
    public var skills: [Skill]?
    public var contextFiles: [ContextFile]?
    public var slashCommands: [FileSlashCommand]?
    public var promptTemplates: [PromptTemplate]?
    public var sessionManager: SessionManager?
    public var settingsManager: SettingsManager?

    public init(
        cwd: String? = nil,
        agentDir: String? = nil,
        authStorage: AuthStorage? = nil,
        modelRegistry: ModelRegistry? = nil,
        model: Model? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        scopedModels: [ScopedModel]? = nil,
        sessionId: String? = nil,
        projectTrusted: Bool? = nil,
        offline: Bool? = nil,
        systemPrompt: SystemPromptInput? = nil,
        toolNames: [String]? = nil,
        excludeTools: [String]? = nil,
        noTools: NoToolsMode? = nil,
        customTools: [CustomToolDefinition]? = nil,
        additionalCustomToolPaths: [String]? = nil,
        resourceLoader: ResourceLoader? = nil,
        hooks: [HookDefinition]? = nil,
        additionalHookPaths: [String]? = nil,
        additionalExtensionPaths: [String]? = nil,
        eventBus: EventBus? = nil,
        skills: [Skill]? = nil,
        contextFiles: [ContextFile]? = nil,
        slashCommands: [FileSlashCommand]? = nil,
        promptTemplates: [PromptTemplate]? = nil,
        sessionManager: SessionManager? = nil,
        settingsManager: SettingsManager? = nil
    ) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.authStorage = authStorage
        self.modelRegistry = modelRegistry
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.scopedModels = scopedModels
        self.sessionId = sessionId
        self.projectTrusted = projectTrusted
        self.offline = offline
        self.systemPrompt = systemPrompt
        self.toolNames = toolNames
        self.excludeTools = excludeTools
        self.noTools = noTools
        self.customTools = customTools
        self.additionalCustomToolPaths = additionalCustomToolPaths
        self.resourceLoader = resourceLoader
        self.hooks = hooks
        self.additionalHookPaths = additionalHookPaths
        self.additionalExtensionPaths = additionalExtensionPaths
        self.eventBus = eventBus
        self.skills = skills
        self.contextFiles = contextFiles
        self.slashCommands = slashCommands
        self.promptTemplates = promptTemplates
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
    }
}

public struct CreateAgentSessionResult: Sendable {
    public var session: AgentSession
    public var customToolsResult: CustomToolsLoadResult
    public var modelFallbackMessage: String?

    public init(session: AgentSession, customToolsResult: CustomToolsLoadResult, modelFallbackMessage: String?) {
        self.session = session
        self.customToolsResult = customToolsResult
        self.modelFallbackMessage = modelFallbackMessage
    }
}

public struct SettingsSnapshot: Sendable {
    public var defaultProvider: String?
    public var defaultModel: String?
    public var defaultThinkingLevel: String?
    public var steeringMode: String
    public var followUpMode: String
    public var transport: Transport
    public var theme: String?
    public var compaction: CompactionSettings
    public var retry: RetrySettings
    public var hideThinkingBlock: Bool
    public var shellPath: String?
    public var collapseChangelog: Bool
    public var hooks: [String]
    public var customTools: [String]
    public var skills: SkillsSettings
    public var terminal: TerminalSettings
    public var images: ImageSettings
    public var enabledModels: [String]?
    public var doubleEscapeAction: String
    public var thinkingBudgets: ThinkingBudgets?

    public init(
        defaultProvider: String?,
        defaultModel: String?,
        defaultThinkingLevel: String?,
        steeringMode: String,
        followUpMode: String,
        transport: Transport,
        theme: String?,
        compaction: CompactionSettings,
        retry: RetrySettings,
        hideThinkingBlock: Bool,
        shellPath: String?,
        collapseChangelog: Bool,
        hooks: [String],
        customTools: [String],
        skills: SkillsSettings,
        terminal: TerminalSettings,
        images: ImageSettings,
        enabledModels: [String]?,
        doubleEscapeAction: String,
        thinkingBudgets: ThinkingBudgets?
    ) {
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
        self.defaultThinkingLevel = defaultThinkingLevel
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.transport = transport
        self.theme = theme
        self.compaction = compaction
        self.retry = retry
        self.hideThinkingBlock = hideThinkingBlock
        self.shellPath = shellPath
        self.collapseChangelog = collapseChangelog
        self.hooks = hooks
        self.customTools = customTools
        self.skills = skills
        self.terminal = terminal
        self.images = images
        self.enabledModels = enabledModels
        self.doubleEscapeAction = doubleEscapeAction
        self.thinkingBudgets = thinkingBudgets
    }
}

private func writeStderr(_ message: String) {
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

package let defaultModelPerProvider: [(KnownProvider, String)] = [
    (.amazonBedrock, "us.anthropic.claude-opus-4-20250514-v1:0"),
    (.anthropic, "claude-opus-4-5"),
    (.openai, "gpt-5.4"),
    (.azureOpenAIResponses, "gpt-5.2"),
    (.openaiCodex, "gpt-5.4"),
    (.google, "gemini-2.5-pro"),
    (.googleVertex, "gemini-3-pro-preview"),
    (.githubCopilot, "gpt-4o"),
    (.openrouter, "openai/gpt-5.1-codex"),
    (.vercelAiGateway, "anthropic/claude-opus-4.5"),
    (.xai, "grok-4-fast-non-reasoning"),
    (.groq, "openai/gpt-oss-120b"),
    (.cerebras, "zai-glm-5"),
    (.zai, "glm-5"),
    (.mistral, "devstral-medium-latest"),
    (.minimax, "MiniMax-M2.7"),
    (.minimaxCn, "MiniMax-M2.7"),
    (.huggingface, "moonshotai/Kimi-K2.5"),
    (.opencode, "claude-opus-4-5"),
    (.kimiCoding, "kimi-k2-thinking"),
]

package func selectDefaultModel(available: [Model], registry: ModelRegistry) async -> Model? {
    for (provider, modelId) in defaultModelPerProvider {
        if let match = available.first(where: { $0.provider == provider.rawValue && $0.id == modelId }),
           await registry.getApiKeyForProvider(match.provider) != nil {
            return match
        }
    }
    return nil
}

public func discoverAuthStorage(agentDir: String = getAgentDir()) -> AuthStorage {
    AuthStorage.create((agentDir as NSString).appendingPathComponent("auth.json"))
}

public func discoverModels(authStorage: AuthStorage, agentDir: String = getAgentDir()) -> ModelRegistry {
    ModelRegistry(authStorage, agentDir)
}

public func discoverHooks(_ eventBus: EventBus, cwd: String? = nil, agentDir: String? = nil) async -> [HookDefinition] {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = agentDir ?? getAgentDir()

    let result = discoverAndLoadHooks([], resolvedCwd, resolvedAgentDir, eventBus)
    for error in result.errors {
        writeStderr("Failed to load hook \"\(error.path)\": \(error.error)\n")
    }

    return result.hooks.map { loaded in
        HookDefinition(path: loaded.path, factory: createFactoryFromLoadedHook(loaded))
    }
}

public func discoverHooks(cwd: String? = nil, agentDir: String? = nil) async -> [HookDefinition] {
    await discoverHooks(createEventBus(), cwd: cwd, agentDir: agentDir)
}

public func discoverCustomTools(_ eventBus: EventBus, cwd: String? = nil, agentDir: String? = nil) async -> [CustomToolDefinition] {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = agentDir ?? getAgentDir()

    var builtInToolNames = createAllTools(cwd: resolvedCwd).keys.map { $0.rawValue }
    if !builtInToolNames.contains("subagent") {
        builtInToolNames.append("subagent")
    }
    let result = discoverAndLoadCustomTools([], resolvedCwd, builtInToolNames, resolvedAgentDir, eventBus)
    for error in result.errors {
        writeStderr("Failed to load custom tool \"\(error.path)\": \(error.error)\n")
    }

    return result.tools.map { CustomToolDefinition(path: $0.path, tool: $0.tool) }
}

public func discoverCustomTools(cwd: String? = nil, agentDir: String? = nil) async -> [CustomToolDefinition] {
    await discoverCustomTools(createEventBus(), cwd: cwd, agentDir: agentDir)
}

public func discoverSkills(cwd: String? = nil, agentDir: String? = nil, settings: SkillsSettings? = nil) -> [Skill] {
    let resolvedCwd = cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = agentDir ?? getAgentDir()
    let settings = settings ?? SkillsSettings()
    return loadSkills(LoadSkillsOptions(
        cwd: resolvedCwd,
        agentDir: resolvedAgentDir,
        enableCodexUser: settings.enableCodexUser,
        enableClaudeUser: settings.enableClaudeUser,
        enableClaudeProject: settings.enableClaudeProject,
        enablePiUser: settings.enablePiUser,
        enablePiProject: settings.enablePiProject,
        customDirectories: settings.customDirectories,
        ignoredSkills: settings.ignoredSkills,
        includeSkills: settings.includeSkills
    )).skills
}

public func discoverContextFiles(cwd: String? = nil, agentDir: String? = nil) -> [ContextFile] {
    loadProjectContextFiles(LoadContextFilesOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir()
    ))
}

public func discoverSlashCommands(cwd: String? = nil, agentDir: String? = nil) -> [FileSlashCommand] {
    loadSlashCommands(LoadSlashCommandsOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir()
    ))
}

public func discoverPromptTemplates(cwd: String? = nil, agentDir: String? = nil) -> [PromptTemplate] {
    loadPromptTemplates(LoadPromptTemplatesOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir()
    ))
}

public func discoverSubagents(cwd: String? = nil, agentDir: String? = nil, scope: SubagentScope? = nil) -> SubagentDiscoveryResult {
    loadSubagents(LoadSubagentsOptions(
        cwd: cwd ?? FileManager.default.currentDirectoryPath,
        agentDir: agentDir ?? getAgentDir(),
        scope: scope
    ))
}

public func loadSettings(cwd: String? = nil, agentDir: String? = nil) -> SettingsSnapshot {
    let manager = SettingsManager.create(cwd ?? FileManager.default.currentDirectoryPath, agentDir ?? getAgentDir())
    return SettingsSnapshot(
        defaultProvider: manager.getDefaultProvider(),
        defaultModel: manager.getDefaultModel(),
        defaultThinkingLevel: manager.getDefaultThinkingLevel(),
        steeringMode: manager.getSteeringMode(),
        followUpMode: manager.getFollowUpMode(),
        transport: manager.getTransport(),
        theme: manager.getTheme(),
        compaction: manager.getCompactionSettings(),
        retry: manager.getRetrySettings(),
        hideThinkingBlock: manager.getHideThinkingBlock(),
        shellPath: manager.getShellPath(),
        collapseChangelog: manager.getCollapseChangelog(),
        hooks: manager.getHooks(),
        customTools: manager.getCustomTools(),
        skills: manager.getSkillsSettings(),
        terminal: manager.getTerminalSettings(),
        images: ImageSettings(autoResize: manager.getAutoResizeImages(), blockImages: manager.getBlockImages()),
        enabledModels: manager.getEnabledModels(),
        doubleEscapeAction: manager.getDoubleEscapeAction(),
        thinkingBudgets: manager.getThinkingBudgets()
    )
}

private func createLoadedHooksFromDefinitions(_ definitions: [HookDefinition], eventBus: EventBus) -> [LoadedHook] {
    definitions.map { definition in
        let path = definition.path ?? "<inline>"
        let api = HookAPI(events: eventBus, hookPath: path)
        api.setExecCwd(FileManager.default.currentDirectoryPath)
        definition.factory(api)
        return LoadedHook(
            path: path,
            resolvedPath: path,
            handlers: api.handlers,
            messageRenderers: api.messageRenderers,
            commands: api.commands,
            flags: api.flags,
            shortcuts: api.shortcuts,
            setSendMessageHandler: api.setSendMessageHandler,
            setAppendEntryHandler: api.setAppendEntryHandler,
            setGetActiveToolsHandler: api.setGetActiveToolsHandler,
            setGetAllToolsHandler: api.setGetAllToolsHandler,
            setSetActiveToolsHandler: api.setSetActiveToolsHandler,
            setFlagValue: api.setFlagValue
        )
    }
}

private func createFactoryFromLoadedHook(_ loaded: LoadedHook) -> HookFactory {
    { api in
        for (eventType, handlers) in loaded.handlers {
            for handler in handlers {
                api.onAny(eventType, handler)
            }
        }
        for (customType, renderer) in loaded.messageRenderers {
            api.registerMessageRenderer(customType, renderer)
        }
        for command in loaded.commands.values {
            api.registerCommand(command.name, description: command.description, handler: command.handler)
        }
        for flag in loaded.flags.values {
            api.registerFlag(flag.name, HookFlagOptions(
                description: flag.description,
                type: flag.type,
                defaultValue: flag.defaultValue
            ))
        }
        for shortcut in loaded.shortcuts.values {
            api.registerShortcut(shortcut.shortcut, description: shortcut.description, handler: shortcut.handler)
        }
    }
}

public func createAgentSession(_ options: CreateAgentSessionOptions = CreateAgentSessionOptions()) async -> CreateAgentSessionResult {
    let cwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let agentDir = options.agentDir ?? getAgentDir()
    let eventBus = options.eventBus ?? createEventBus()
    var resourceLoader = options.resourceLoader

    let authStorage = options.authStorage ?? discoverAuthStorage(agentDir: agentDir)
    let modelRegistry = options.modelRegistry ?? discoverModels(authStorage: authStorage, agentDir: agentDir)
    time("discoverModels")

    let projectTrusted = options.projectTrusted ?? true
    let settingsManager = options.settingsManager ?? SettingsManager.create(cwd, agentDir, projectTrusted: projectTrusted)
    time("settingsManager")
    let sessionManager = options.sessionManager ?? SessionManager.create(cwd, nil, sessionId: options.sessionId)
    time("sessionManager")

    if resourceLoader == nil {
        let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(
            cwd: cwd,
            agentDir: agentDir,
            settingsManager: settingsManager,
            projectTrusted: projectTrusted,
            offline: options.offline ?? false
        ))
        await loader.reload()
        time("resourceLoader.reload")
        resourceLoader = loader
    }

    let resolvedResourceLoader = resourceLoader!

    let existingSession = sessionManager.buildSessionContext()
    time("loadSession")
    let hasExistingSession = !existingSession.messages.isEmpty

    var model = options.model
    var modelFallbackMessage: String?

    if model == nil, hasExistingSession, let existingModel = existingSession.model {
        if let restored = modelRegistry.find(existingModel.provider, existingModel.modelId),
           await modelRegistry.getApiKeyForProvider(restored.provider) != nil,
           await modelRegistry.isAvailable(restored) {
            model = restored
        }
        if model == nil {
            modelFallbackMessage = "Could not restore model \(existingModel.provider)/\(existingModel.modelId)"
        }
    }

    if model == nil {
        if let provider = settingsManager.getDefaultProvider(),
           let modelId = settingsManager.getDefaultModel(),
           let settingsModel = modelRegistry.find(provider, modelId),
           await modelRegistry.getApiKeyForProvider(settingsModel.provider) != nil,
           await modelRegistry.isAvailable(settingsModel) {
            model = settingsModel
        }
    }

    if model == nil {
        let available = await modelRegistry.getAvailable()
        if let preferred = await selectDefaultModel(available: available, registry: modelRegistry) {
            model = preferred
        } else {
            for candidate in available {
                if await modelRegistry.getApiKeyForProvider(candidate.provider) != nil {
                    model = candidate
                    break
                }
            }
        }
        time("findAvailableModel")

        if model == nil {
            modelFallbackMessage = "No models available. Use /login or set an API key environment variable."
        } else if let existingMessage = modelFallbackMessage {
            modelFallbackMessage = "\(existingMessage). Using \(model!.provider)/\(model!.id)"
        }
    }

    let resolvedModel = model ?? getModel(provider: .openai, modelId: "gpt-4o-mini")

    var thinkingLevel = options.thinkingLevel
    if thinkingLevel == nil, hasExistingSession {
        thinkingLevel = ThinkingLevel(rawValue: existingSession.thinkingLevel) ?? .off
    }
    if thinkingLevel == nil {
        thinkingLevel = ThinkingLevel(rawValue: settingsManager.getDefaultThinkingLevel() ?? "off") ?? .off
    }

    if !resolvedModel.reasoning {
        thinkingLevel = .off
    } else if let requested = thinkingLevel {
        let modelLevel = PiSwiftAI.ModelThinkingLevel(rawValue: requested.rawValue) ?? .off
        let clamped = PiSwiftAI.clampThinkingLevel(model: resolvedModel, requested: modelLevel)
        thinkingLevel = ThinkingLevel(rawValue: clamped.rawValue) ?? .off
    }

    let resolvedThinkingLevel = thinkingLevel ?? .off
    let subagentContext = SubagentToolContext()
    subagentContext.update(SubagentToolDependencies(
        cwd: cwd,
        agentDir: agentDir,
        modelRegistry: modelRegistry,
        settingsManager: settingsManager,
        defaultModel: resolvedModel,
        defaultThinkingLevel: resolvedThinkingLevel
    ))

    let loaderSkills = resolvedResourceLoader.getSkills().skills
    _ = options.skills ?? loaderSkills
    time("discoverSkills")

    let loaderContextFiles = resolvedResourceLoader.getAgentsFiles()
    _ = options.contextFiles ?? loaderContextFiles
    time("discoverContextFiles")

    let blockImages = settingsManager.getBlockImages()
    let toolsOptions = ToolsOptions(read: ReadToolOptions(
        autoResizeImages: settingsManager.getAutoResizeImages(),
        blockImages: blockImages
    ))
    let excludedToolNames = Set(options.excludeTools ?? [])
    // v0.68.0 / v0.70.0: tool selection layered logic.
    //   noTools == .all       → no built-ins, no extension/custom tools.
    //   noTools == .builtin   → no built-ins, BUT keep extension/custom tools.
    //   toolNames non-nil     → allowlist by name (intersected with built-ins).
    //   default               → all built-ins (createCodingTools).
    let builtInTools: [Tool] = {
        if options.noTools == .all || options.noTools == .builtin { return [] }
        if let names = options.toolNames {
            let allByName = createAllTools(cwd: cwd, options: toolsOptions, subagentContext: subagentContext)
            return names.compactMap { name -> Tool? in
                guard !excludedToolNames.contains(name) else { return nil }
                guard let toolName = ToolName(rawValue: name) else { return nil }
                return allByName[toolName]
            }
        }
        return createCodingTools(cwd: cwd, options: toolsOptions, subagentContext: subagentContext)
            .filter { !excludedToolNames.contains($0.name) }
    }()
    time("createCodingTools")

    var customToolsResult: CustomToolsLoadResult
    if options.noTools == .all {
        // v0.68.0/v0.70.0: --no-tools disables extension/custom tools too. Don't load any.
        customToolsResult = CustomToolsLoadResult(tools: [], errors: [])
    } else if let customTools = options.customTools {
        let loadedTools = customTools.map { definition in
            let path = definition.path ?? "<inline>"
            return LoadedCustomTool(path: path, resolvedPath: path, tool: definition.tool)
        }
        customToolsResult = CustomToolsLoadResult(tools: loadedTools, errors: [])
    } else {
        let configuredPaths = settingsManager.getCustomTools() + (options.additionalCustomToolPaths ?? [])
        let builtInToolNames = createAllTools(cwd: cwd, options: toolsOptions, subagentContext: subagentContext).keys.map { $0.rawValue }
        customToolsResult = discoverAndLoadCustomTools(configuredPaths, cwd, builtInToolNames, agentDir, eventBus)
        for error in customToolsResult.errors {
            writeStderr("Failed to load custom tool \"\(error.path)\": \(error.error)\n")
        }
    }

    var allLoadedHooks: [LoadedHook] = []

    if let hooks = options.hooks {
        if !hooks.isEmpty {
            allLoadedHooks = createLoadedHooksFromDefinitions(hooks, eventBus: eventBus)
        }
    } else {
        let hookPaths = settingsManager.getHooks() + (options.additionalHookPaths ?? [])
        let loadResult = discoverAndLoadHooks(hookPaths, cwd, agentDir, eventBus)
        time("discoverAndLoadHooks")
        for error in loadResult.errors {
            writeStderr("Failed to load hook \"\(error.path)\": \(error.error)\n")
        }
        allLoadedHooks = loadResult.hooks
    }

    // Load extensions (plain .swift files) and merge into hooks
    let extensionPaths = settingsManager.getExtensionPaths() + (options.additionalExtensionPaths ?? [])
    let extensionResult = await discoverAndLoadExtensions(
        extensionPaths,
        cwd,
        agentDir,
        eventBus,
        includeProjectExtensions: projectTrusted
    )
    time("discoverAndLoadExtensions")
    for error in extensionResult.errors {
        writeStderr("Failed to load extension: \(error.localizedDescription)\n")
    }
    allLoadedHooks += extensionResult.hooks

    // Closure used by AgentSession.reloadExtensions() so /reload can swap extensions live.
    // Captures the same paths/cwd/agentDir/eventBus the initial load used. SDK extension
    // resolution is repeated inside discoverAndLoadExtensions so it picks up newly-installed
    // SDKs too.
    let reloadExtensionsHook: @Sendable () async -> LoadExtensionsResult = {
        await discoverAndLoadExtensions(
            extensionPaths,
            cwd,
            agentDir,
            eventBus,
            includeProjectExtensions: projectTrusted
        )
    }

    // Always create a HookRunner — even with zero hooks at startup, /reload can add
    // extensions later, and the agent's beforeToolCall/onPayload/onResponse closures need
    // a runner instance to forward events to. The closures gate at call-time on
    // `hasHandlers(...)`, so empty runners cost nothing.
    let hookRunner = HookRunner(allLoadedHooks, cwd, sessionManager, modelRegistry)

    let agentBox = LockedState<Agent?>(nil)
    let sessionBox = LockedState<AgentSession?>(nil)
    let sendMessageHandlerBox = LockedState<HookSendMessageHandler>({ _, _ in })
    let getCustomToolContext: @Sendable () -> CustomToolContext = { [sessionManager, modelRegistry, eventBus] in
        let agent = agentBox.withLock { $0 }
        let session = sessionBox.withLock { $0 }
        let sendMessageHandler = sendMessageHandlerBox.withLock { $0 }
        return CustomToolContext(
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: agent?.state.model,
            isIdle: { !(session?.isStreaming ?? true) },
            hasPendingMessages: { (session?.pendingMessageCount ?? 0) > 0 },
            abort: { Task { await session?.abort() } },
            events: eventBus,
            sendMessage: { message, options in
                sendMessageHandler(message, options)
            }
        )
    }
    let wrappedCustomTools = wrapCustomTools(customToolsResult.tools, getCustomToolContext)
        .filter { !excludedToolNames.contains($0.name) }

    // Tools registered by extensions via `pi.registerTool(_:)`. Wrapped through the same
    // CustomTool→AgentTool bridge as settings-defined custom tools.
    let extensionTools = hookRunner.getExtensionTools()
    let extensionToolDefinitions = extensionTools.map { tool in
        LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: tool)
    }
    let wrappedExtensionTools = wrapCustomTools(extensionToolDefinitions, getCustomToolContext)
        .filter { !excludedToolNames.contains($0.name) }

    let allBuiltInToolsMap = createAllTools(cwd: cwd, options: toolsOptions, subagentContext: subagentContext)
    var toolRegistry: [String: AgentTool] = [:]
    for (name, tool) in allBuiltInToolsMap {
        toolRegistry[name.rawValue] = tool
    }
    for tool in wrappedCustomTools {
        toolRegistry[tool.name] = tool
    }
    for tool in wrappedExtensionTools {
        toolRegistry[tool.name] = tool
    }
    for name in excludedToolNames {
        toolRegistry.removeValue(forKey: name)
    }

    let allTools = builtInTools + wrappedCustomTools + wrappedExtensionTools
    time("combineTools")

    let makeSystemPromptOptions: @Sendable ([String]) -> BuildSystemPromptOptions = { toolNames in
        let validToolNames = toolNames.compactMap { ToolName(rawValue: $0) }
        let loaderSystemPrompt = resolvedResourceLoader.getSystemPrompt()
        let loaderAppend = resolvedResourceLoader.getAppendSystemPrompt()
        let appendSystemPrompt = loaderAppend.isEmpty ? nil : loaderAppend.joined(separator: "\n\n")
        let activeSkills = options.skills ?? resolvedResourceLoader.getSkills().skills
        let activeContextFiles = options.contextFiles ?? resolvedResourceLoader.getAgentsFiles()
        return BuildSystemPromptOptions(
            customPrompt: loaderSystemPrompt,
            selectedTools: validToolNames,
            appendSystemPrompt: appendSystemPrompt,
            cwd: cwd,
            agentDir: agentDir,
            contextFiles: activeContextFiles,
            skills: activeSkills
        )
    }

    let rebuildSystemPrompt: @Sendable ([String]) -> String = { toolNames in
        let promptOptions = makeSystemPromptOptions(toolNames)
        let defaultPrompt = buildSystemPrompt(promptOptions)
        if let systemPromptInput = options.systemPrompt {
            switch systemPromptInput {
            case .text(let text):
                var customOptions = promptOptions
                customOptions.customPrompt = text
                return buildSystemPrompt(customOptions)
            case .builder(let builder):
                return builder(defaultPrompt)
            }
        }
        return defaultPrompt
    }

    let initialActiveToolNames = allTools.map { $0.name }
    let systemPrompt = rebuildSystemPrompt(initialActiveToolNames)
    time("buildSystemPrompt")

    let slashCommands = options.slashCommands ?? discoverSlashCommands(cwd: cwd, agentDir: agentDir)
    time("discoverSlashCommands")
    let loaderPrompts = resolvedResourceLoader.getPrompts().prompts
    let promptTemplates = options.promptTemplates ?? loaderPrompts
    time("discoverPromptTemplates")

    let transformContext: (@Sendable ([AgentMessage], CancellationToken?) async throws -> [AgentMessage])? = { [hookRunner] messages, signal in
        await hookRunner.emitContext(messages, signal: signal)
    }

    let convertToLlmWithBlockImages: @Sendable ([AgentMessage]) -> [Message] = { messages in
        let converted = convertToLlm(messages)
        guard blockImages else { return converted }
        let filtered = filterImagesFromMessages(converted)
        if filtered.filtered > 0 {
            if let data = "[blockImages] Defense-in-depth: filtered \(filtered.filtered) image(s) at convertToLlm layer\n".data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        return filtered.messages
    }

    // Wire agent-level beforeToolCall/afterToolCall from hook runner (extensions + hooks).
    // The closures are always installed; they cheaply gate on `hasHandlers(...)` at call
    // time so a `/reload` that introduces new tool_call hooks Just Works.
    let beforeToolCallHook: BeforeToolCallFn? = makeHookRunnerBeforeToolCallHook(hookRunner)
    let afterToolCallHook: AfterToolCallFn? = makeHookRunnerAfterToolCallHook(hookRunner)

    // Wire onPayload to emit BeforeProviderRequestEvent to extensions.
    let onPayloadHook: OnPayloadFn? = { [hookRunner] snapshot in
        guard hookRunner.hasHandlers("before_provider_request") else { return }
        let event = BeforeProviderRequestEvent(payload: snapshot.json)
        Task {
            _ = await hookRunner.emit(event)
        }
    }

    // v0.68.0: wire onResponse to emit AfterProviderResponseEvent so extensions can
    // inspect provider HTTP status / headers immediately after the response arrives
    // and before the stream is consumed.
    let onResponseHook: ResponseHandler? = { [hookRunner] snapshot in
        guard hookRunner.hasHandlers("after_provider_response") else { return }
        let event = AfterProviderResponseEvent(status: snapshot.statusCode, headers: snapshot.headers)
        Task {
            _ = await hookRunner.emit(event)
        }
    }

    let createdAgent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: systemPrompt,
            model: resolvedModel,
            thinkingLevel: thinkingLevel ?? .off,
            tools: allTools
        ),
        convertToLlm: { messages in
            convertToLlmWithBlockImages(messages)
        },
        transformContext: transformContext,
        steeringMode: AgentSteeringMode(rawValue: settingsManager.getSteeringMode()),
        followUpMode: AgentFollowUpMode(rawValue: settingsManager.getFollowUpMode()),
        sessionId: sessionManager.getSessionId(),
        transport: settingsManager.getTransport(),
        thinkingBudgets: settingsManager.getThinkingBudgets(),
        getApiKey: { provider in
            await modelRegistry.getApiKeyForProvider(provider)
        },
        getModelAuth: { model in
            let auth = await modelRegistry.getApiKeyAndHeaders(model)
            return AgentModelAuth(apiKey: auth.apiKey, headers: auth.headers, baseUrl: auth.baseUrl)
        },
        onPayload: onPayloadHook,
        onResponse: onResponseHook,
        beforeToolCall: beforeToolCallHook,
        afterToolCall: afterToolCallHook
    ))
    time("createAgent")
    agentBox.withLock { $0 = createdAgent }

    if hasExistingSession {
        createdAgent.messages = existingSession.messages
    } else {
        sessionManager.appendModelChange(resolvedModel.provider, resolvedModel.id)
        sessionManager.appendThinkingLevelChange((thinkingLevel ?? .off).rawValue)
    }

    let createdSession = AgentSession(config: AgentSessionConfig(
        agent: createdAgent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: resolvedResourceLoader,
        projectTrusted: projectTrusted,
        systemPromptOptions: makeSystemPromptOptions(initialActiveToolNames),
        scopedModels: options.scopedModels,
        fileCommands: slashCommands,
        promptTemplates: promptTemplates,
        hookRunner: hookRunner,
        customTools: customToolsResult.tools,
        modelRegistry: modelRegistry,
        skillsSettings: settingsManager.getSkillsSettings(),
        eventBus: eventBus,
        toolRegistry: toolRegistry,
        rebuildSystemPrompt: rebuildSystemPrompt,
        reloadExtensionsHook: reloadExtensionsHook,
        wrapExtensionTools: { tools in
            let definitions = tools.map { tool in
                LoadedCustomTool(path: "<extension>", resolvedPath: "<extension>", tool: tool)
            }
            let wrapped = wrapCustomTools(definitions, getCustomToolContext)
                .filter { !excludedToolNames.contains($0.name) }
            return wrapped
        }
    ))
    time("createAgentSession")
    sessionBox.withLock { $0 = createdSession }
    let sendMessageHandler: HookSendMessageHandler = { [weak createdSession] message, options in
        guard let session = createdSession else { return }
        Task {
            await session.sendHookMessage(message, options: options)
        }
    }
    customToolsResult.setSendMessageHandler(sendMessageHandler)
    sendMessageHandlerBox.withLock { $0 = sendMessageHandler }

    return CreateAgentSessionResult(session: createdSession, customToolsResult: customToolsResult, modelFallbackMessage: modelFallbackMessage)
}
