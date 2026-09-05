import Foundation
import Darwin
import PiSwiftAI
import PiSwiftAgent

public final class HookRunner: Sendable {
    private static let reservedShortcuts: Set<String> = [
        "ctrl+c",
        "ctrl+d",
        "ctrl+z",
        "ctrl+k",
        "ctrl+p",
        "ctrl+l",
        "ctrl+o",
        "ctrl+t",
        "ctrl+g",
        "shift+tab",
        "shift+ctrl+p",
        "alt+enter",
        "escape",
        "enter",
    ]

    public let cwd: String
    private let sessionManager: SessionManager
    private let modelRegistry: ModelRegistry
    private let state: LockedState<State>
    private let eventObservers = LockedState<[UUID: @Sendable (any HookEvent) -> Void]>([:])

    private struct State: Sendable {
        var hooks: [LoadedHook]
        var getModel: @Sendable () -> Model?
        var getScopedModels: @Sendable () -> [ScopedModel]
        var getSystemPrompt: @Sendable () -> String?
        var getSystemPromptOptions: @Sendable () -> BuildSystemPromptOptions
        var isProjectTrusted: @Sendable () -> Bool
        var isIdle: @Sendable () -> Bool
        var waitForIdle: @Sendable () async -> Void
        var abort: @Sendable () -> Void
        var hasPendingMessages: @Sendable () -> Bool
        var getContextUsage: HookGetContextUsageHandler
        var compactHandler: HookCompactHandler
        var newSessionHandler: HookNewSessionHandler
        var forkHandler: HookForkHandler
        var navigateTreeHandler: HookNavigateTreeHandler
        var switchSessionHandler: HookSwitchSessionHandler
        var reloadHandler: HookReloadHandler
        var sendUserMessageHandler: HookSendUserMessageHandler
        var setLabelHandler: HookSetLabelHandler
        var getCommandsHandler: HookGetCommandsHandler
        var setModelHandler: HookSetModelHandler
        var getThinkingLevelHandler: HookGetThinkingLevelHandler
        var setThinkingLevelHandler: HookSetThinkingLevelHandler
        var uiContext: HookUIContext
        var mode: HookMode
        var hasUI: Bool
        var errorListeners: [UUID: @Sendable (HookError) -> Void]
        /// Per-hook setters captured at initialize() so they can be re-applied to hooks
        /// added via `replaceExtensionHooks(_:)` without re-plumbing the whole TUI.
        var wiring: HookWiring?
    }

    /// Captures the setter closures that `initialize(...)` plumbs into each LoadedHook.
    /// Stored on State so the same wiring can be re-applied to hooks loaded later by `/reload`.
    private struct HookWiring: Sendable {
        var sendMessageHandler: HookSendMessageHandler
        var sendUserMessageHandler: HookSendUserMessageHandler
        var appendEntryHandler: HookAppendEntryHandler
        var setSessionNameHandler: HookSetSessionNameHandler
        var getSessionNameHandler: HookGetSessionNameHandler
        var setLabelHandler: HookSetLabelHandler
        var getActiveToolsHandler: HookGetActiveToolsHandler
        var getAllToolsHandler: HookGetAllToolsHandler
        var setActiveToolsHandler: HookSetActiveToolsHandler
        var getCommandsHandler: HookGetCommandsHandler
        var setModelHandler: HookSetModelHandler
        var getThinkingLevelHandler: HookGetThinkingLevelHandler
        var setThinkingLevelHandler: HookSetThinkingLevelHandler
        var registerToolHandler: HookRegisterToolHandler
        var unregisterToolHandler: HookUnregisterToolHandler

        func apply(to hook: LoadedHook) {
            hook.setSendMessageHandler(sendMessageHandler)
            hook.setSendUserMessageHandler(sendUserMessageHandler)
            hook.setAppendEntryHandler(appendEntryHandler)
            hook.setSetSessionNameHandler(setSessionNameHandler)
            hook.setGetSessionNameHandler(getSessionNameHandler)
            hook.setSetLabelHandler(setLabelHandler)
            hook.setGetActiveToolsHandler(getActiveToolsHandler)
            hook.setGetAllToolsHandler(getAllToolsHandler)
            hook.setSetActiveToolsHandler(setActiveToolsHandler)
            hook.setGetCommandsHandler(getCommandsHandler)
            hook.setSetModelHandler(setModelHandler)
            hook.setGetThinkingLevelHandler(getThinkingLevelHandler)
            hook.setSetThinkingLevelHandler(setThinkingLevelHandler)
            hook.setRegisterToolHandler(registerToolHandler)
            hook.setUnregisterToolHandler(unregisterToolHandler)
        }
    }

    private var hooks: [LoadedHook] {
        get { state.withLock { $0.hooks } }
        set { state.withLock { $0.hooks = newValue } }
    }

    private var getModel: @Sendable () -> Model? {
        get { state.withLock { $0.getModel } }
        set { state.withLock { $0.getModel = newValue } }
    }

    private var getScopedModels: @Sendable () -> [ScopedModel] {
        get { state.withLock { $0.getScopedModels } }
        set { state.withLock { $0.getScopedModels = newValue } }
    }

    private var getSystemPrompt: @Sendable () -> String? {
        get { state.withLock { $0.getSystemPrompt } }
        set { state.withLock { $0.getSystemPrompt = newValue } }
    }

    private var isIdle: @Sendable () -> Bool {
        get { state.withLock { $0.isIdle } }
        set { state.withLock { $0.isIdle = newValue } }
    }

    private var waitForIdle: @Sendable () async -> Void {
        get { state.withLock { $0.waitForIdle } }
        set { state.withLock { $0.waitForIdle = newValue } }
    }

    private var abort: @Sendable () -> Void {
        get { state.withLock { $0.abort } }
        set { state.withLock { $0.abort = newValue } }
    }

    private var hasPendingMessages: @Sendable () -> Bool {
        get { state.withLock { $0.hasPendingMessages } }
        set { state.withLock { $0.hasPendingMessages = newValue } }
    }

    private var getContextUsage: HookGetContextUsageHandler {
        get { state.withLock { $0.getContextUsage } }
        set { state.withLock { $0.getContextUsage = newValue } }
    }

    private var compactHandler: HookCompactHandler {
        get { state.withLock { $0.compactHandler } }
        set { state.withLock { $0.compactHandler = newValue } }
    }

    private var newSessionHandler: HookNewSessionHandler {
        get { state.withLock { $0.newSessionHandler } }
        set { state.withLock { $0.newSessionHandler = newValue } }
    }

    private var forkHandler: HookForkHandler {
        get { state.withLock { $0.forkHandler } }
        set { state.withLock { $0.forkHandler = newValue } }
    }

    private var navigateTreeHandler: HookNavigateTreeHandler {
        get { state.withLock { $0.navigateTreeHandler } }
        set { state.withLock { $0.navigateTreeHandler = newValue } }
    }

    private var switchSessionHandler: HookSwitchSessionHandler {
        get { state.withLock { $0.switchSessionHandler } }
        set { state.withLock { $0.switchSessionHandler = newValue } }
    }

    private var reloadHandler: HookReloadHandler {
        get { state.withLock { $0.reloadHandler } }
        set { state.withLock { $0.reloadHandler = newValue } }
    }

    private var sendUserMessageHandler: HookSendUserMessageHandler {
        get { state.withLock { $0.sendUserMessageHandler } }
        set { state.withLock { $0.sendUserMessageHandler = newValue } }
    }

    private var setLabelHandler: HookSetLabelHandler {
        get { state.withLock { $0.setLabelHandler } }
        set { state.withLock { $0.setLabelHandler = newValue } }
    }

    private var getCommandsHandler: HookGetCommandsHandler {
        get { state.withLock { $0.getCommandsHandler } }
        set { state.withLock { $0.getCommandsHandler = newValue } }
    }

    private var setModelHandler: HookSetModelHandler {
        get { state.withLock { $0.setModelHandler } }
        set { state.withLock { $0.setModelHandler = newValue } }
    }

    private var getThinkingLevelHandler: HookGetThinkingLevelHandler {
        get { state.withLock { $0.getThinkingLevelHandler } }
        set { state.withLock { $0.getThinkingLevelHandler = newValue } }
    }

    private var setThinkingLevelHandler: HookSetThinkingLevelHandler {
        get { state.withLock { $0.setThinkingLevelHandler } }
        set { state.withLock { $0.setThinkingLevelHandler = newValue } }
    }

    private var uiContext: HookUIContext {
        get { state.withLock { $0.uiContext } }
        set { state.withLock { $0.uiContext = newValue } }
    }

    private var hasUI: Bool {
        get { state.withLock { $0.hasUI } }
        set { state.withLock { $0.hasUI = newValue } }
    }

    private var errorListeners: [UUID: @Sendable (HookError) -> Void] {
        get { state.withLock { $0.errorListeners } }
        set { state.withLock { $0.errorListeners = newValue } }
    }

    public init(_ hooks: [LoadedHook], _ cwd: String, _ sessionManager: SessionManager, _ modelRegistry: ModelRegistry) {
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.state = LockedState(State(
            hooks: hooks,
            getModel: { nil },
            getScopedModels: { [] },
            getSystemPrompt: { nil },
            getSystemPromptOptions: { BuildSystemPromptOptions(cwd: cwd) },
            isProjectTrusted: { true },
            isIdle: { true },
            waitForIdle: {},
            abort: {},
            hasPendingMessages: { false },
            getContextUsage: { nil },
            compactHandler: { _ in },
            newSessionHandler: { _ in HookCommandResult(cancelled: false) },
            forkHandler: { _ in HookCommandResult(cancelled: false) },
            navigateTreeHandler: { _, _ in HookCommandResult(cancelled: false) },
            switchSessionHandler: { _ in HookCommandResult(cancelled: false) },
            reloadHandler: {},
            sendUserMessageHandler: { _, _ in },
            setLabelHandler: { _, _ in },
            getCommandsHandler: { [] },
            setModelHandler: { _ in false },
            getThinkingLevelHandler: { .off },
            setThinkingLevelHandler: { _ in },
            uiContext: NoOpHookUIContext(),
            mode: .print,
            hasUI: false,
            errorListeners: [:],
            wiring: nil
        ))
        for hook in hooks {
            wireProviderHandlers(for: hook)
        }
    }

    private func wireProviderHandlers(for hook: LoadedHook) {
        let sourceId = hook.resolvedPath
        hook.setRegisterProviderHandler { [modelRegistry] config in
            modelRegistry.registerProvider(config, sourceId: sourceId)
        }
        hook.setUnregisterProviderHandler { [modelRegistry] provider in
            modelRegistry.unregisterProvider(provider, sourceId: sourceId)
        }
        for config in hook.providerRegistrations.values {
            modelRegistry.registerProvider(config, sourceId: sourceId)
        }
    }

    public func initialize(
        getModel: @escaping @Sendable () -> Model?,
        getScopedModels: @escaping @Sendable () -> [ScopedModel] = { [] },
        getSystemPrompt: @escaping @Sendable () -> String? = { nil },
        getSystemPromptOptions: (@Sendable () -> BuildSystemPromptOptions)? = nil,
        isProjectTrusted: (@Sendable () -> Bool)? = nil,
        sendMessageHandler: @escaping HookSendMessageHandler = { _, _ in },
        appendEntryHandler: @escaping HookAppendEntryHandler = { _, _ in },
        setSessionNameHandler: @escaping HookSetSessionNameHandler = { _ in },
        getSessionNameHandler: @escaping HookGetSessionNameHandler = { nil },
        getActiveToolsHandler: HookGetActiveToolsHandler? = nil,
        getAllToolsHandler: HookGetAllToolsHandler? = nil,
        setActiveToolsHandler: HookSetActiveToolsHandler? = nil,
        getCommandsHandler: HookGetCommandsHandler? = nil,
        setModelHandler: HookSetModelHandler? = nil,
        getThinkingLevelHandler: HookGetThinkingLevelHandler? = nil,
        setThinkingLevelHandler: HookSetThinkingLevelHandler? = nil,
        registerToolHandler: HookRegisterToolHandler? = nil,
        unregisterToolHandler: HookUnregisterToolHandler? = nil,
        sendUserMessageHandler: HookSendUserMessageHandler? = nil,
        setLabelHandler: HookSetLabelHandler? = nil,
        getContextUsage: HookGetContextUsageHandler? = nil,
        compactHandler: HookCompactHandler? = nil,
        newSessionHandler: HookNewSessionHandler? = nil,
        forkHandler: HookForkHandler? = nil,
        navigateTreeHandler: HookNavigateTreeHandler? = nil,
        switchSessionHandler: HookSwitchSessionHandler? = nil,
        reloadHandler: HookReloadHandler? = nil,
        isIdle: (@Sendable () -> Bool)? = nil,
        waitForIdle: (@Sendable () async -> Void)? = nil,
        abort: (@Sendable () -> Void)? = nil,
        hasPendingMessages: (@Sendable () -> Bool)? = nil,
        uiContext: HookUIContext? = nil,
        mode: HookMode = .print,
        hasUI: Bool = false
    ) {
        self.getModel = getModel
        self.getScopedModels = getScopedModels
        self.getSystemPrompt = getSystemPrompt
        self.state.withLock { state in
            state.getSystemPromptOptions = getSystemPromptOptions ?? { BuildSystemPromptOptions(cwd: self.cwd) }
            state.isProjectTrusted = isProjectTrusted ?? { true }
            state.mode = mode
        }
        self.isIdle = isIdle ?? { true }
        self.waitForIdle = waitForIdle ?? {}
        self.abort = abort ?? {}
        self.hasPendingMessages = hasPendingMessages ?? { false }
        self.getContextUsage = getContextUsage ?? { nil }
        self.compactHandler = compactHandler ?? { _ in }
        self.sendUserMessageHandler = sendUserMessageHandler ?? { _, _ in }
        self.setLabelHandler = setLabelHandler ?? { _, _ in }
        self.getCommandsHandler = getCommandsHandler ?? { [] }
        self.setModelHandler = setModelHandler ?? { _ in false }
        self.getThinkingLevelHandler = getThinkingLevelHandler ?? { .off }
        self.setThinkingLevelHandler = setThinkingLevelHandler ?? { _ in }
        if let newSessionHandler {
            self.newSessionHandler = newSessionHandler
        }
        if let forkHandler {
            self.forkHandler = forkHandler
        }
        if let navigateTreeHandler {
            self.navigateTreeHandler = navigateTreeHandler
        }
        if let switchSessionHandler {
            self.switchSessionHandler = switchSessionHandler
        }
        if let reloadHandler {
            self.reloadHandler = reloadHandler
        }
        self.uiContext = PromptHookUIContext(base: uiContext ?? NoOpHookUIContext(), runner: self)
        self.hasUI = hasUI

        let wiring = HookWiring(
            sendMessageHandler: sendMessageHandler,
            sendUserMessageHandler: sendUserMessageHandler ?? { _, _ in },
            appendEntryHandler: appendEntryHandler,
            setSessionNameHandler: setSessionNameHandler,
            getSessionNameHandler: getSessionNameHandler,
            setLabelHandler: setLabelHandler ?? { _, _ in },
            getActiveToolsHandler: getActiveToolsHandler ?? { [] },
            getAllToolsHandler: getAllToolsHandler ?? { [] },
            setActiveToolsHandler: setActiveToolsHandler ?? { _ in },
            getCommandsHandler: getCommandsHandler ?? { [] },
            setModelHandler: setModelHandler ?? { _ in false },
            getThinkingLevelHandler: getThinkingLevelHandler ?? { .off },
            setThinkingLevelHandler: setThinkingLevelHandler ?? { _ in },
            registerToolHandler: registerToolHandler ?? { _ in },
            unregisterToolHandler: unregisterToolHandler ?? { _ in }
        )
        state.withLock { $0.wiring = wiring }
        for hook in hooks {
            wireProviderHandlers(for: hook)
            wiring.apply(to: hook)
        }
    }

    public func getUIContext() -> HookUIContext {
        uiContext
    }

    public func getHasUI() -> Bool {
        hasUI
    }

    public func getHookPaths() -> [String] {
        hooks.map { $0.path }
    }

    /// Paths of currently-loaded hooks that originated from extensions (not settings hooks).
    public func getExtensionHookPaths() -> [String] {
        hooks.filter { $0.isExtension }.map { $0.path }
    }

    /// All custom tools registered by extensions (across every loaded extension hook).
    /// On name collision the last hook in iteration order wins; this matches the
    /// command-collision policy in `getRegisteredCommands()`.
    public func getExtensionTools() -> [CustomTool] {
        var byName: [String: CustomTool] = [:]
        for hook in hooks where hook.isExtension {
            for (name, tool) in hook.currentTools() {
                byName[name] = tool
            }
        }
        return Array(byName.values)
    }

    /// Names of every extension-registered tool currently loaded. Used by
    /// `AgentSession.reloadExtensions()` to drop stale tools before adding new ones.
    public func getExtensionToolNames() -> Set<String> {
        var names: Set<String> = []
        for hook in hooks where hook.isExtension {
            for name in hook.currentTools().keys { names.insert(name) }
        }
        return names
    }

    /// Replace the extension-sourced hooks while preserving settings-defined hooks.
    /// Re-applies the wiring captured at `initialize(...)` to the new extension hooks
    /// so their `sendMessage` / `appendEntry` / etc. callbacks are connected.
    /// Returns the paths of extension hooks that were dropped (caller may want to log them).
    @discardableResult
    public func replaceExtensionHooks(_ newExtensionHooks: [LoadedHook]) -> [String] {
        let droppedHooks: [LoadedHook] = state.withLock { state in
            let dropped = state.hooks.filter { $0.isExtension }
            let kept = state.hooks.filter { !$0.isExtension }
            state.hooks = kept + newExtensionHooks
            return dropped
        }
        for hook in droppedHooks {
            modelRegistry.unregisterProviders(sourceId: hook.resolvedPath)
            hook.dispose()
        }
        for hook in newExtensionHooks {
            wireProviderHandlers(for: hook)
        }
        if let wiring = state.withLock({ $0.wiring }) {
            for hook in newExtensionHooks {
                wiring.apply(to: hook)
            }
        }
        return droppedHooks.map { $0.path }
    }

    public func unregisterExtensionProviders() {
        let extensionHooks = hooks.filter { $0.isExtension }
        for hook in extensionHooks {
            modelRegistry.unregisterProviders(sourceId: hook.resolvedPath)
        }
    }

    public func dispose() {
        let oldHooks = state.withLock { state -> [LoadedHook] in
            let oldHooks = state.hooks
            state.hooks = []
            return oldHooks
        }
        for hook in oldHooks {
            if hook.isExtension {
                modelRegistry.unregisterProviders(sourceId: hook.resolvedPath)
            }
            hook.dispose()
        }
    }

    public func emitResourcesDiscover(cwd: String, reason: ResourcesDiscoverReason) async -> ResourceExtensionPaths {
        var skillPaths: [ResourceExtensionPath] = []
        var promptPaths: [ResourceExtensionPath] = []
        var themePaths: [ResourceExtensionPath] = []
        await dispatchEvent(ResourcesDiscoverEvent(cwd: cwd, reason: reason), extensionsOnly: true, consume: { result, hook in
            guard let result = result as? ResourcesDiscoverResult else { return false }
            let metadata = self.extensionResourceMetadata(for: hook)
            skillPaths.append(contentsOf: result.skillPaths.map { ResourceExtensionPath(path: $0, metadata: metadata) })
            promptPaths.append(contentsOf: result.promptPaths.map { ResourceExtensionPath(path: $0, metadata: metadata) })
            themePaths.append(contentsOf: result.themePaths.map { ResourceExtensionPath(path: $0, metadata: metadata) })
            return false
        })

        return ResourceExtensionPaths(skillPaths: skillPaths, promptPaths: promptPaths, themePaths: themePaths)
    }

    private func extensionResourceMetadata(for hook: LoadedHook) -> PathMetadata {
        let source = extensionSourceLabel(for: hook.resolvedPath)
        let baseDir: String? = hook.resolvedPath.hasPrefix("<")
            ? nil
            : URL(fileURLWithPath: hook.resolvedPath).deletingLastPathComponent().path
        return PathMetadata(source: source, scope: "temporary", origin: "top-level", baseDir: baseDir)
    }

    private func extensionSourceLabel(for path: String) -> String {
        if path.hasPrefix("<") {
            return "extension:\(path.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: ""))"
        }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        return "extension:\(name)"
    }

    /// Emit an event only to hooks loaded from extensions (skips settings-defined hooks).
    /// Used by the reload lifecycle to fire `session_shutdown` / `session_start(reason: .reload)`
    /// at the extensions being swapped, without disturbing built-in hooks.
    public func emitToExtensions(_ event: HookEvent) async {
        await dispatchEvent(event, extensionsOnly: true)
    }

    public func getMessageRenderer(_ customType: String) -> HookMessageRenderer? {
        for hook in hooks {
            if let renderer = hook.messageRenderers[customType] {
                return renderer
            }
        }
        return nil
    }

    /// Returns display-only Markdown transformers in hook load and registration order.
    public func getMarkdownTransformers() -> [MarkdownTransformer] {
        hooks.flatMap(\.markdownTransformers)
    }

    /// Applies display-only Markdown transforms without changing session or model messages.
    public func transformMarkdown(_ markdown: String, context: MarkdownTransformContext) -> String {
        getMarkdownTransformers().reduce(markdown) { current, transformer in
            transformer(current, context)
        }
    }

    /// Returns the first entry renderer registered for `customType`, in extension
    /// load order. Entry rendering is intentionally a library surface; terminal
    /// presentation is owned by PiSwiftCodingAgentTui.
    public func getEntryRenderer(_ customType: String) -> EntryRenderer? {
        for hook in hooks {
            if let renderer = hook.entryRenderers[customType] {
                return renderer
            }
        }
        return nil
    }

    /// v0.62.0: when multiple extensions register commands with the same name, conflicting
    /// commands receive numeric invocation suffixes in load order — e.g., the first wins
    /// the bare name, the second becomes `<name>:1`, the third `<name>:2`, etc. This
    /// disambiguates extension command names so users can still invoke each one explicitly.
    public func getRegisteredCommands() -> [RegisteredCommand] {
        var commands: [RegisteredCommand] = []
        var nameCount: [String: Int] = [:]
        for hook in hooks {
            for command in hook.currentCommands().values {
                let baseName = command.name
                let count = nameCount[baseName] ?? 0
                if count == 0 {
                    commands.append(command)
                } else {
                    var renamed = command
                    renamed.name = "\(baseName):\(count)"
                    commands.append(renamed)
                }
                nameCount[baseName] = count + 1
            }
        }
        return commands
    }

    public func getFlags() -> [String: HookFlag] {
        var allFlags: [String: HookFlag] = [:]
        for hook in hooks {
            for (name, flag) in hook.flags {
                allFlags[name] = flag
            }
        }
        return allFlags
    }

    public func setFlagValue(_ name: String, _ value: HookFlagValue) {
        for hook in hooks {
            if hook.flags[name] != nil {
                hook.setFlagValue(name, value)
            }
        }
    }

    public func getShortcuts() -> [KeyId: HookShortcut] {
        var allShortcuts: [KeyId: HookShortcut] = [:]
        for hook in hooks {
            for (key, shortcut) in hook.shortcuts {
                let normalizedKey = key.lowercased()
                if Self.reservedShortcuts.contains(normalizedKey) {
                    logHookWarning("Hook shortcut '\(key)' from \(shortcut.hookPath) conflicts with built-in shortcut. Skipping.")
                    continue
                }
                if let existing = allShortcuts[normalizedKey] {
                    logHookWarning("Hook shortcut conflict: '\(key)' registered by both \(existing.hookPath) and \(shortcut.hookPath). Using \(shortcut.hookPath).")
                }
                allShortcuts[normalizedKey] = shortcut
            }
        }
        return allShortcuts
    }

    public func getCommand(_ name: String) -> RegisteredCommand? {
        for hook in hooks {
            if let command = hook.currentCommands()[name] {
                return command
            }
        }
        return nil
    }

    public func onError(_ listener: @escaping @Sendable (HookError) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        errorListeners[id] = listener
        return { [weak self] in
            self?.errorListeners[id] = nil
        }
    }

    public func emitError(_ error: HookError) {
        for listener in errorListeners.values {
            listener(error)
        }
    }

    public func hasHandlers(_ type: String) -> Bool {
        for hook in hooks {
            if let handlers = hook.handlers[type], !handlers.isEmpty {
                return true
            }
        }
        return false
    }

    private func createContext() -> HookContext {
        HookContext(
            ui: uiContext,
            mode: state.withLock { $0.mode },
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: { [weak self] in
                self?.getModel()
            },
            scopedModels: { [weak self] in
                self?.getScopedModels() ?? []
            },
            systemPrompt: { [weak self] in
                self?.getSystemPrompt()
            },
            isProjectTrusted: { [weak self] in
                self?.state.withLock { $0.isProjectTrusted() } ?? true
            },
            systemPromptOptions: { [weak self] in
                self?.state.withLock { $0.getSystemPromptOptions() } ?? BuildSystemPromptOptions(cwd: self?.cwd)
            },
            isIdle: { [weak self] in self?.isIdle() ?? true },
            abort: { [weak self] in self?.abort() },
            hasPendingMessages: { [weak self] in self?.hasPendingMessages() ?? false },
            getContextUsage: { [weak self] in self?.getContextUsage() },
            compact: { [weak self] options in self?.compactHandler(options) }
        )
    }

    public func createShortcutContext() -> HookContext {
        createContext()
    }

    public func createCommandContext() -> HookCommandContext {
        HookCommandContext(
            ui: uiContext,
            mode: state.withLock { $0.mode },
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: { [weak self] in
                self?.getModel()
            },
            scopedModels: { [weak self] in
                self?.getScopedModels() ?? []
            },
            systemPrompt: { [weak self] in
                self?.getSystemPrompt()
            },
            isProjectTrusted: { [weak self] in
                self?.state.withLock { $0.isProjectTrusted() } ?? true
            },
            systemPromptOptions: { [weak self] in
                self?.state.withLock { $0.getSystemPromptOptions() } ?? BuildSystemPromptOptions(cwd: self?.cwd)
            },
            isIdle: { [weak self] in self?.isIdle() ?? true },
            abort: { [weak self] in self?.abort() },
            hasPendingMessages: { [weak self] in self?.hasPendingMessages() ?? false },
            waitForIdle: { [weak self] in await self?.waitForIdle() },
            newSession: { [weak self] options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.newSessionHandler(options)
            },
            fork: { [weak self] entryId in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.forkHandler(entryId)
            },
            navigateTree: { [weak self] targetId, options in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.navigateTreeHandler(targetId, options)
            },
            switchSession: { [weak self] sessionPath in
                guard let self else { return HookCommandResult(cancelled: true) }
                return await self.switchSessionHandler(sessionPath)
            },
            reload: { [weak self] in
                await self?.reloadHandler()
            },
            sendUserMessage: { [weak self] content, options in
                self?.sendUserMessageHandler(content, options)
            },
            setLabel: { [weak self] entryId, label in
                self?.setLabelHandler(entryId, label)
            },
            getCommands: { [weak self] in
                self?.getCommandsHandler() ?? []
            },
            setModel: { [weak self] model in
                guard let self else { return false }
                return await self.setModelHandler(model)
            },
            getThinkingLevel: { [weak self] in
                self?.getThinkingLevelHandler() ?? .off
            },
            setThinkingLevel: { [weak self] level in
                self?.setThinkingLevelHandler(level)
            },
            getContextUsage: { [weak self] in
                self?.getContextUsage()
            },
            compact: { [weak self] options in
                self?.compactHandler(options)
            }
        )
    }

    /// Observe each event before its handlers run.
    /// Calls are synchronous on the emitter's executor, outside the storage lock.
    /// Concurrent emissions can call the observer concurrently.
    /// Unsubscribe excludes later snapshots. An event already in progress can still arrive.
    public func addEventObserver(_ observer: @escaping @Sendable (any HookEvent) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        eventObservers.withLock { $0[id] = observer }
        return { [weak self] in
            self?.eventObservers.withLock { $0[id] = nil }
        }
    }

    /// Use this path for all event delivery and handler calls.
    private func dispatchEvent(
        _ event: any HookEvent,
        extensionsOnly: Bool = false,
        eventForHandler: (() -> any HookEvent)? = nil,
        consume: (Any, LoadedHook) -> Bool = { _, _ in false }
    ) async {
        let observers = eventObservers.withLock { Array($0.values) }
        for observer in observers { observer(event) }
        let context = createContext()
        for hook in hooks where !extensionsOnly || hook.isExtension {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(eventForHandler?() ?? event, context), consume(result, hook) {
                        return
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription, stack: captureStack()))
                }
            }
        }
    }

    public func emit(_ event: HookEvent) async -> Any? {
        var lastResult: Any?
        await dispatchEvent(event, consume: { result, _ in
            lastResult = result
            if let result = result as? SessionBeforeCompactResult, result.cancel { return true }
            if let result = result as? SessionBeforeTreeResult, result.cancel { return true }
            if let result = result as? SessionBeforeForkResult, result.cancel { return true }
            if let result = result as? SessionBeforeSwitchResult, result.cancel { return true }
            return false
        })
        return lastResult
    }

    /// Apply each returned header set in handler order.
    /// A nil value deletes a provider or API default header.
    public func emitBeforeProviderHeaders(_ headers: ProviderHeaders) async -> ProviderHeaders {
        var currentHeaders = headers
        await dispatchEvent(BeforeProviderHeadersEvent(headers: headers), eventForHandler: {
            BeforeProviderHeadersEvent(headers: currentHeaders)
        }) { result, _ in
            if let result = result as? BeforeProviderHeadersEventResult {
                currentHeaders = mergeProviderHeaders(currentHeaders, result.headers) ?? [:]
            }
            return false
        }
        return currentHeaders
    }

    public func emitProjectTrust(_ event: ProjectTrustEvent) async -> ProjectTrustEventResult? {
        var decision: ProjectTrustEventResult?
        await dispatchEvent(event, consume: { result, _ in
            guard let result = result as? ProjectTrustEventResult else { return false }
            switch result.trusted {
            case .yes, .no:
                decision = result
                return true
            case .undecided:
                return false
            }
        })
        return decision
    }

    public func emitToolCall(_ event: ToolCallEvent) async -> ToolCallEventResult? {
        var lastResult: ToolCallEventResult?
        await dispatchEvent(event, consume: { result, _ in
            guard let result = result as? ToolCallEventResult else { return false }
            lastResult = result
            return result.block
        })
        return lastResult
    }

    public func emitUserBash(_ event: UserBashEvent) async -> UserBashEventResult? {
        var firstResult: UserBashEventResult?
        await dispatchEvent(event, consume: { result, _ in
            guard let result = result as? UserBashEventResult else { return false }
            firstResult = result
            return true
        })
        return firstResult
    }

    public func emitContext(_ messages: [AgentMessage], signal: CancellationToken? = nil) async -> [AgentMessage] {
        _ = signal
        var currentMessages = messages
        await dispatchEvent(ContextEvent(messages: deepCopyMessages(messages)), eventForHandler: {
            ContextEvent(messages: deepCopyMessages(currentMessages))
        }) { result, _ in
            if let result = result as? ContextEventResult, let replacement = result.messages {
                currentMessages = replacement
            }
            return false
        }
        return currentMessages
    }

    public func emitBeforeAgentStart(_ prompt: String, _ images: [ImageContent]?) async -> BeforeAgentStartCombinedResult? {
        var messages: [HookMessageInput] = []
        var systemPromptAppends: [String] = []
        await dispatchEvent(BeforeAgentStartEvent(prompt: prompt, images: images), consume: { result, _ in
            if let result = result as? BeforeAgentStartEventResult {
                if let message = result.message { messages.append(message) }
                if let append = result.systemPromptAppend, !append.isEmpty { systemPromptAppends.append(append) }
            }
            return false
        })
        if messages.isEmpty && systemPromptAppends.isEmpty { return nil }
        return BeforeAgentStartCombinedResult(
            messages: messages.isEmpty ? nil : messages,
            systemPromptAppend: systemPromptAppends.isEmpty ? nil : systemPromptAppends.joined(separator: "\n\n")
        )
    }

}

private func logHookWarning(_ message: String) {
    fputs("Warning: \(message)\n", stderr)
}

private func captureStack() -> String {
    Thread.callStackSymbols.joined(separator: "\n")
}

private func deepCopyMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
    messages.map { deepCopyAgentMessage($0) }
}

private func deepCopyAgentMessage(_ message: AgentMessage) -> AgentMessage {
    switch message {
    case .user(let user):
        return .user(deepCopyUserMessage(user))
    case .assistant(let assistant):
        return .assistant(deepCopyAssistantMessage(assistant))
    case .toolResult(let toolResult):
        return .toolResult(deepCopyToolResultMessage(toolResult))
    case .custom(let custom):
        return .custom(AgentCustomMessage(
            role: custom.role,
            payload: custom.payload.map(deepCopyAnyCodable),
            timestamp: custom.timestamp
        ))
    }
}

private func deepCopyUserMessage(_ message: UserMessage) -> UserMessage {
    switch message.content {
    case .text(let text):
        return UserMessage(content: .text(text), timestamp: message.timestamp)
    case .blocks(let blocks):
        return UserMessage(content: .blocks(blocks.map(deepCopyContentBlock)), timestamp: message.timestamp)
    }
}

private func deepCopyAssistantMessage(_ message: AssistantMessage) -> AssistantMessage {
    AssistantMessage(
        content: message.content.map(deepCopyContentBlock),
        api: message.api,
        provider: message.provider,
        model: message.model,
        usage: message.usage,
        stopReason: message.stopReason,
        errorMessage: message.errorMessage,
        timestamp: message.timestamp
    )
}

private func deepCopyToolResultMessage(_ message: ToolResultMessage) -> ToolResultMessage {
    ToolResultMessage(
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        content: message.content.map(deepCopyContentBlock),
        details: message.details.map(deepCopyAnyCodable),
        isError: message.isError,
        timestamp: message.timestamp
    )
}

private func deepCopyContentBlock(_ block: ContentBlock) -> ContentBlock {
    switch block {
    case .text(let text):
        return .text(TextContent(text: text.text, textSignature: text.textSignature))
    case .thinking(let thinking):
        return .thinking(ThinkingContent(thinking: thinking.thinking, thinkingSignature: thinking.thinkingSignature))
    case .image(let image):
        return .image(ImageContent(data: image.data, mimeType: image.mimeType))
    case .toolCall(let call):
        return .toolCall(ToolCall(
            id: call.id,
            name: call.name,
            arguments: deepCopyAnyCodableMap(call.arguments),
            thoughtSignature: call.thoughtSignature
        ))
    }
}

private func deepCopyAnyCodableMap(_ dict: [String: AnyCodable]) -> [String: AnyCodable] {
    dict.mapValues { deepCopyAnyCodable($0) }
}

private func deepCopyAnyCodable(_ value: AnyCodable) -> AnyCodable {
    AnyCodable(value.jsonValue)
}
