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

    private let cwd: String
    private let sessionManager: SessionManager
    private let modelRegistry: ModelRegistry
    private let state: LockedState<State>

    private struct State: Sendable {
        var hooks: [LoadedHook]
        var getModel: @Sendable () -> Model?
        var getSystemPrompt: @Sendable () -> String?
        var isIdle: @Sendable () -> Bool
        var waitForIdle: @Sendable () async -> Void
        var abort: @Sendable () -> Void
        var hasPendingMessages: @Sendable () -> Bool
        var newSessionHandler: HookNewSessionHandler
        var forkHandler: HookForkHandler
        var navigateTreeHandler: HookNavigateTreeHandler
        var uiContext: HookUIContext
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
        var appendEntryHandler: HookAppendEntryHandler
        var setSessionNameHandler: HookSetSessionNameHandler
        var getSessionNameHandler: HookGetSessionNameHandler
        var getActiveToolsHandler: HookGetActiveToolsHandler
        var getAllToolsHandler: HookGetAllToolsHandler
        var setActiveToolsHandler: HookSetActiveToolsHandler

        func apply(to hook: LoadedHook) {
            hook.setSendMessageHandler(sendMessageHandler)
            hook.setAppendEntryHandler(appendEntryHandler)
            hook.setSetSessionNameHandler(setSessionNameHandler)
            hook.setGetSessionNameHandler(getSessionNameHandler)
            hook.setGetActiveToolsHandler(getActiveToolsHandler)
            hook.setGetAllToolsHandler(getAllToolsHandler)
            hook.setSetActiveToolsHandler(setActiveToolsHandler)
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
            getSystemPrompt: { nil },
            isIdle: { true },
            waitForIdle: {},
            abort: {},
            hasPendingMessages: { false },
            newSessionHandler: { _ in HookCommandResult(cancelled: false) },
            forkHandler: { _ in HookCommandResult(cancelled: false) },
            navigateTreeHandler: { _, _ in HookCommandResult(cancelled: false) },
            uiContext: NoOpHookUIContext(),
            hasUI: false,
            errorListeners: [:],
            wiring: nil
        ))
    }

    public func initialize(
        getModel: @escaping @Sendable () -> Model?,
        getSystemPrompt: @escaping @Sendable () -> String? = { nil },
        sendMessageHandler: @escaping HookSendMessageHandler = { _, _ in },
        appendEntryHandler: @escaping HookAppendEntryHandler = { _, _ in },
        setSessionNameHandler: @escaping HookSetSessionNameHandler = { _ in },
        getSessionNameHandler: @escaping HookGetSessionNameHandler = { nil },
        getActiveToolsHandler: HookGetActiveToolsHandler? = nil,
        getAllToolsHandler: HookGetAllToolsHandler? = nil,
        setActiveToolsHandler: HookSetActiveToolsHandler? = nil,
        newSessionHandler: HookNewSessionHandler? = nil,
        forkHandler: HookForkHandler? = nil,
        navigateTreeHandler: HookNavigateTreeHandler? = nil,
        isIdle: (@Sendable () -> Bool)? = nil,
        waitForIdle: (@Sendable () async -> Void)? = nil,
        abort: (@Sendable () -> Void)? = nil,
        hasPendingMessages: (@Sendable () -> Bool)? = nil,
        uiContext: HookUIContext? = nil,
        hasUI: Bool = false
    ) {
        self.getModel = getModel
        self.getSystemPrompt = getSystemPrompt
        self.isIdle = isIdle ?? { true }
        self.waitForIdle = waitForIdle ?? {}
        self.abort = abort ?? {}
        self.hasPendingMessages = hasPendingMessages ?? { false }
        if let newSessionHandler {
            self.newSessionHandler = newSessionHandler
        }
        if let forkHandler {
            self.forkHandler = forkHandler
        }
        if let navigateTreeHandler {
            self.navigateTreeHandler = navigateTreeHandler
        }
        self.uiContext = uiContext ?? NoOpHookUIContext()
        self.hasUI = hasUI

        let wiring = HookWiring(
            sendMessageHandler: sendMessageHandler,
            appendEntryHandler: appendEntryHandler,
            setSessionNameHandler: setSessionNameHandler,
            getSessionNameHandler: getSessionNameHandler,
            getActiveToolsHandler: getActiveToolsHandler ?? { [] },
            getAllToolsHandler: getAllToolsHandler ?? { [] },
            setActiveToolsHandler: setActiveToolsHandler ?? { _ in }
        )
        state.withLock { $0.wiring = wiring }
        for hook in hooks {
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
            for (name, tool) in hook.tools {
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
            for name in hook.tools.keys { names.insert(name) }
        }
        return names
    }

    /// Replace the extension-sourced hooks while preserving settings-defined hooks.
    /// Re-applies the wiring captured at `initialize(...)` to the new extension hooks
    /// so their `sendMessage` / `appendEntry` / etc. callbacks are connected.
    /// Returns the paths of extension hooks that were dropped (caller may want to log them).
    @discardableResult
    public func replaceExtensionHooks(_ newExtensionHooks: [LoadedHook]) -> [String] {
        let droppedPaths: [String] = state.withLock { state in
            let dropped = state.hooks.filter { $0.isExtension }.map { $0.path }
            let kept = state.hooks.filter { !$0.isExtension }
            state.hooks = kept + newExtensionHooks
            return dropped
        }
        if let wiring = state.withLock({ $0.wiring }) {
            for hook in newExtensionHooks {
                wiring.apply(to: hook)
            }
        }
        return droppedPaths
    }

    /// Emit an event only to hooks loaded from extensions (skips settings-defined hooks).
    /// Used by the reload lifecycle to fire `session_shutdown` / `session_start(reason: .reload)`
    /// at the extensions being swapped, without disturbing built-in hooks.
    public func emitToExtensions(_ event: HookEvent) async {
        let context = createContext()
        let extensionHooks = hooks.filter { $0.isExtension }
        for hook in extensionHooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    _ = try await handler(event, context)
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription, stack: captureStack()))
                }
            }
        }
    }

    public func getMessageRenderer(_ customType: String) -> HookMessageRenderer? {
        for hook in hooks {
            if let renderer = hook.messageRenderers[customType] {
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
            for command in hook.commands.values {
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
            if let command = hook.commands[name] {
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
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: { [weak self] in
                self?.getModel()
            },
            systemPrompt: { [weak self] in
                self?.getSystemPrompt()
            },
            isIdle: { [weak self] in self?.isIdle() ?? true },
            abort: { [weak self] in self?.abort() },
            hasPendingMessages: { [weak self] in self?.hasPendingMessages() ?? false }
        )
    }

    public func createShortcutContext() -> HookContext {
        createContext()
    }

    public func createCommandContext() -> HookCommandContext {
        HookCommandContext(
            ui: uiContext,
            hasUI: hasUI,
            cwd: cwd,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: { [weak self] in
                self?.getModel()
            },
            systemPrompt: { [weak self] in
                self?.getSystemPrompt()
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
            }
        )
    }

    public func emit(_ event: HookEvent) async -> Any? {
        let context = createContext()
        var lastResult: Any? = nil

        for hook in hooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(event, context) {
                        lastResult = result
                        if let result = result as? SessionBeforeCompactResult, result.cancel {
                            return result
                        }
                        if let result = result as? SessionBeforeTreeResult, result.cancel {
                            return result
                        }
                        if let result = result as? SessionBeforeForkResult, result.cancel {
                            return result
                        }
                        if let result = result as? SessionBeforeSwitchResult, result.cancel {
                            return result
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription, stack: captureStack()))
                }
            }
        }

        return lastResult
    }

    public func emitToolCall(_ event: ToolCallEvent) async -> ToolCallEventResult? {
        let context = createContext()
        var lastResult: ToolCallEventResult? = nil

        for hook in hooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(event, context) as? ToolCallEventResult {
                        lastResult = result
                        if result.block {
                            return result
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription, stack: captureStack()))
                }
            }
        }

        return lastResult
    }

    public func emitUserBash(_ event: UserBashEvent) async -> UserBashEventResult? {
        let context = createContext()

        for hook in hooks {
            guard let handlers = hook.handlers[event.type] else { continue }
            for handler in handlers {
                do {
                    if let result = try await handler(event, context) as? UserBashEventResult {
                        return result
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: event.type, error: error.localizedDescription, stack: captureStack()))
                }
            }
        }

        return nil
    }

    public func emitContext(_ messages: [AgentMessage], signal: CancellationToken? = nil) async -> [AgentMessage] {
        _ = signal
        let context = createContext()
        var currentMessages = messages

        for hook in hooks {
            guard let handlers = hook.handlers["context"] else { continue }
            for handler in handlers {
                do {
                    let safeMessages = deepCopyMessages(currentMessages)
                    if let result = try await handler(ContextEvent(messages: safeMessages), context) as? ContextEventResult,
                       let replacement = result.messages {
                        currentMessages = replacement
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: "context", error: error.localizedDescription, stack: captureStack()))
                }
            }
        }

        return currentMessages
    }

    public func emitBeforeAgentStart(_ prompt: String, _ images: [ImageContent]?) async -> BeforeAgentStartCombinedResult? {
        let context = createContext()
        var messages: [HookMessageInput] = []
        var systemPromptAppends: [String] = []

        for hook in hooks {
            guard let handlers = hook.handlers["before_agent_start"] else { continue }
            for handler in handlers {
                do {
                    if let handlerResult = try await handler(BeforeAgentStartEvent(prompt: prompt, images: images), context) as? BeforeAgentStartEventResult {
                        if let message = handlerResult.message {
                            messages.append(message)
                        }
                        if let append = handlerResult.systemPromptAppend, !append.isEmpty {
                            systemPromptAppends.append(append)
                        }
                    }
                } catch {
                    emitError(HookError(hookPath: hook.path, event: "before_agent_start", error: error.localizedDescription, stack: captureStack()))
                }
            }
        }

        if messages.isEmpty && systemPromptAppends.isEmpty {
            return nil
        }
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
