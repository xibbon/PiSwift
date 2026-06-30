import Foundation
import PiSwiftAI
import PiSwiftAgent

/// UI host passed into hook renderers for optional UI integrations.
public protocol HookUIHost: AnyObject {}

/// UI component returned by hook renderers (UI-specific implementations can supply their own types).
public typealias HookComponent = Any

public enum HookNotificationType: String, Sendable {
    case info
    case warning
    case error
}

public enum HookFlagType: String, Sendable {
    case boolean
    case string
}

public enum HookFlagValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)

    public var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string:
            return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .bool:
            return nil
        case .string(let value):
            return value
        }
    }
}

public struct HookFlag: Sendable {
    public var name: String
    public var hookPath: String
    public var description: String?
    public var type: HookFlagType
    public var defaultValue: HookFlagValue?

    public init(
        name: String,
        hookPath: String,
        description: String? = nil,
        type: HookFlagType,
        defaultValue: HookFlagValue? = nil
    ) {
        self.name = name
        self.hookPath = hookPath
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
    }
}

public struct HookFlagOptions: Sendable {
    public var description: String?
    public var type: HookFlagType
    public var defaultValue: HookFlagValue?

    public init(description: String? = nil, type: HookFlagType, defaultValue: HookFlagValue? = nil) {
        self.description = description
        self.type = type
        self.defaultValue = defaultValue
    }
}

public typealias HookWidgetFactory = @Sendable (_ ui: HookUIHost, _ theme: Theme) -> HookComponent

public typealias HookFooterFactory = @Sendable (_ ui: HookUIHost, _ theme: Theme, _ footerData: FooterDataProviding) -> HookComponent

public enum HookOverlayAnchor: String, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case topCenter
    case bottomCenter
    case leftCenter
    case rightCenter
}

public enum HookOverlaySize: Sendable {
    case absolute(Int)
    case percent(Int)
}

public struct HookOverlayMargin: Sendable {
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var left: Int

    public init(top: Int, right: Int, bottom: Int, left: Int) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(all: Int) {
        self.init(top: all, right: all, bottom: all, left: all)
    }
}

public struct HookOverlayOptions: Sendable {
    public var width: HookOverlaySize?
    public var minWidth: Int?
    public var maxHeight: HookOverlaySize?
    public var anchor: HookOverlayAnchor?
    public var offsetX: Int?
    public var offsetY: Int?
    public var row: HookOverlaySize?
    public var col: HookOverlaySize?
    public var margin: HookOverlayMargin?

    public init(
        width: HookOverlaySize? = nil,
        minWidth: Int? = nil,
        maxHeight: HookOverlaySize? = nil,
        anchor: HookOverlayAnchor? = nil,
        offsetX: Int? = nil,
        offsetY: Int? = nil,
        row: HookOverlaySize? = nil,
        col: HookOverlaySize? = nil,
        margin: HookOverlayMargin? = nil
    ) {
        self.width = width
        self.minWidth = minWidth
        self.maxHeight = maxHeight
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.row = row
        self.col = col
        self.margin = margin
    }
}

@MainActor
public protocol HookOverlayHandle: Sendable {
    func hide()
    func setHidden(_ hidden: Bool)
    func isHidden() -> Bool
}

public enum HookOverlayOptionsSource: Sendable {
    case fixed(HookOverlayOptions)
    case dynamic(@Sendable () -> HookOverlayOptions)
}

public struct HookCustomOptions: Sendable {
    public var overlay: Bool
    public var overlayOptions: HookOverlayOptionsSource?
    public var onHandle: (@Sendable (HookOverlayHandle) -> Void)?

    public init(
        overlay: Bool = false,
        overlayOptions: HookOverlayOptionsSource? = nil,
        onHandle: (@Sendable (HookOverlayHandle) -> Void)? = nil
    ) {
        self.overlay = overlay
        self.overlayOptions = overlayOptions
        self.onHandle = onHandle
    }
}

public protocol HookEditorTheme: Sendable {}

public protocol HookKeybindings: Sendable {
    func matches(_ data: String, _ action: AppAction) -> Bool
    func getDisplayString(_ action: AppAction) -> String
}

public typealias HookEditorComponentFactory = @MainActor @Sendable (_ ui: HookUIHost, _ theme: HookEditorTheme, _ keybindings: HookKeybindings) -> HookComponent

public enum HookWidgetContent {
    case lines([String])
    case component(HookWidgetFactory)
}

public struct HookMessageRenderOptions: Sendable {
    public var expanded: Bool

    public init(expanded: Bool) {
        self.expanded = expanded
    }
}

public typealias HookMessageRenderer = @Sendable (HookMessage, HookMessageRenderOptions, Theme) -> HookComponent?

public enum HookDeliverAs: String, Sendable {
    case steer
    case followUp
    case nextTurn
}

public struct HookSendMessageOptions: Sendable {
    public var triggerTurn: Bool
    public var deliverAs: HookDeliverAs?

    public init(triggerTurn: Bool = false, deliverAs: HookDeliverAs? = nil) {
        self.triggerTurn = triggerTurn
        self.deliverAs = deliverAs
    }
}

public struct HookMessageInput: Sendable {
    public var customType: String
    public var content: HookMessageContent
    public var display: Bool
    public var details: AnyCodable?

    public init(customType: String, content: HookMessageContent, display: Bool, details: AnyCodable? = nil) {
        self.customType = customType
        self.content = content
        self.display = display
        self.details = details
    }
}

public typealias HookSendMessageHandler = @Sendable (_ message: HookMessageInput, _ options: HookSendMessageOptions?) -> Void
public typealias HookAppendEntryHandler = @Sendable (_ customType: String, _ data: [String: Any]) -> Void
public typealias HookSetSessionNameHandler = @Sendable (_ name: String) -> Void
public typealias HookGetSessionNameHandler = @Sendable () -> String?
public typealias HookSendMessageSetter = @Sendable (@escaping HookSendMessageHandler) -> Void
public typealias HookAppendEntrySetter = @Sendable (@escaping HookAppendEntryHandler) -> Void
public typealias HookGetActiveToolsHandler = @Sendable () -> [String]
public struct ToolInfo: Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public typealias HookGetAllToolsHandler = @Sendable () -> [ToolInfo]
public typealias HookSetActiveToolsHandler = @Sendable (_ toolNames: [String]) -> Void
public typealias HookGetActiveToolsSetter = @Sendable (@escaping HookGetActiveToolsHandler) -> Void
public typealias HookGetAllToolsSetter = @Sendable (@escaping HookGetAllToolsHandler) -> Void
public typealias HookSetActiveToolsSetter = @Sendable (@escaping HookSetActiveToolsHandler) -> Void
public typealias HookSetFlagValue = @Sendable (_ name: String, _ value: HookFlagValue) -> Void
public typealias HookRegisterProviderHandler = @Sendable (_ config: HookProviderConfig) -> Void
public typealias HookUnregisterProviderHandler = @Sendable (_ provider: String) -> Void
public typealias HookRegisterProviderSetter = @Sendable (@escaping HookRegisterProviderHandler) -> Void
public typealias HookUnregisterProviderSetter = @Sendable (@escaping HookUnregisterProviderHandler) -> Void

public struct HookProviderModel: Sendable {
    public var id: String
    public var name: String?
    public var api: Api?
    public var baseUrl: String?
    public var reasoning: Bool
    public var input: [ModelInput]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]?
    public var compat: OpenAICompat?
    public var thinkingLevelMap: ThinkingLevelMap?

    public init(
        id: String,
        name: String? = nil,
        api: Api? = nil,
        baseUrl: String? = nil,
        reasoning: Bool = false,
        input: [ModelInput] = [.text],
        cost: ModelCost = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: Int = 128_000,
        maxTokens: Int = 16_384,
        headers: [String: String]? = nil,
        compat: OpenAICompat? = nil,
        thinkingLevelMap: ThinkingLevelMap? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.baseUrl = baseUrl
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
        self.compat = compat
        self.thinkingLevelMap = thinkingLevelMap
    }
}

public struct HookProviderConfig: Sendable {
    public var provider: String
    public var api: Api
    public var baseUrl: String
    public var apiKey: String?
    public var headers: [String: String]?
    public var compat: OpenAICompat?
    public var models: [HookProviderModel]

    public init(
        provider: String,
        api: Api,
        baseUrl: String,
        apiKey: String? = nil,
        headers: [String: String]? = nil,
        compat: OpenAICompat? = nil,
        models: [HookProviderModel]
    ) {
        self.provider = provider
        self.api = api
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.headers = headers
        self.compat = compat
        self.models = models
    }
}

public struct HookCommandResult: Sendable {
    public var cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

public struct HookNewSessionOptions: Sendable {
    public var parentSession: String?
    public var setup: (@Sendable (SessionManager) async -> Void)?

    public init(parentSession: String? = nil, setup: (@Sendable (SessionManager) async -> Void)? = nil) {
        self.parentSession = parentSession
        self.setup = setup
    }
}

public struct HookNavigateTreeOptions: Sendable {
    public var summarize: Bool

    public init(summarize: Bool = false) {
        self.summarize = summarize
    }
}

public typealias HookNewSessionHandler = @Sendable (_ options: HookNewSessionOptions?) async -> HookCommandResult
public typealias HookForkHandler = @Sendable (_ entryId: String) async -> HookCommandResult
public typealias HookNavigateTreeHandler = @Sendable (_ targetId: String, _ options: HookNavigateTreeOptions?) async -> HookCommandResult

public struct RegisteredCommand: Sendable {
    public var name: String
    public var description: String?
    public var handler: @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void
    /// v0.62.0: structured provenance — replaces the legacy `extensionPath` and `location` fields.
    /// Should be set by the loader to the extension's source info.
    public var sourceInfo: SourceInfo?
    /// v0.67.6: optional argument hint rendered before the description.
    public var argumentHint: String?

    public init(
        name: String,
        description: String? = nil,
        sourceInfo: SourceInfo? = nil,
        argumentHint: String? = nil,
        handler: @escaping @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void
    ) {
        self.name = name
        self.description = description
        self.sourceInfo = sourceInfo
        self.argumentHint = argumentHint
        self.handler = handler
    }
}

public protocol HookDisposableComponent {
    func dispose()
}

public struct HookCustomResult: Sendable {
    public var value: (any Sendable)?

    public init(_ value: (any Sendable)?) {
        self.value = value
    }
}

public typealias HookCustomClose = @MainActor @Sendable ((any Sendable)?) -> Void
public typealias HookCustomFactory = @Sendable (_ ui: HookUIHost, _ theme: Theme, _ keybindings: HookKeybindings, _ done: @escaping HookCustomClose) async -> HookComponent

public struct HookThemeInfo: Sendable {
    public var name: String
    public var path: String?

    public init(name: String, path: String?) {
        self.name = name
        self.path = path
    }
}

public enum HookThemeInput: Sendable {
    case name(String)
    case theme(Theme)
}

public struct HookThemeResult: Sendable {
    public var success: Bool
    public var error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}

/// Configuration for the interactive streaming loader animation surfaced to extensions via
/// `ctx.ui.setWorkingIndicator(_:)`.
public struct WorkingIndicatorOptions: Sendable {
    /// Animation frames. Use an empty array to hide the indicator entirely. Custom frames
    /// are rendered verbatim.
    public var frames: [String]?
    /// Frame interval in milliseconds for animated indicators.
    public var intervalMs: Int?

    public init(frames: [String]? = nil, intervalMs: Int? = nil) {
        self.frames = frames
        self.intervalMs = intervalMs
    }
}

/// v0.70.0+: extensions can stack autocomplete providers by wrapping the current one. Each
/// factory receives the live provider and returns a wrapped replacement.
public typealias HookAutocompleteProviderFactory = @MainActor @Sendable (Any) -> Any

public enum HookMode: String, Sendable {
    case tui
    case rpc
    case json
    case print
}

@MainActor
public protocol HookUIContext: Sendable {
    func select(_ title: String, _ options: [String]) async -> String?
    func confirm(_ title: String, _ message: String) async -> Bool
    func input(_ title: String, _ placeholder: String?) async -> String?
    func notify(_ message: String, _ type: HookNotificationType?)
    func setStatus(_ key: String, _ text: String?)
    func setWorkingMessage(_ message: String?)
    func setWidget(_ key: String, _ content: HookWidgetContent?)
    func setFooter(_ factory: HookFooterFactory?)
    func setTitle(_ title: String)
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult?
    func setEditorText(_ text: String)
    func getEditorText() -> String
    func editor(_ title: String, _ prefill: String?) async -> String?
    func setEditorComponent(_ factory: HookEditorComponentFactory?)
    func getAllThemes() -> [HookThemeInfo]
    func getTheme(_ name: String) -> Theme?
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult
    var theme: Theme { get }
}

public extension HookUIContext {
    func setWidget(_ key: String, _ lines: [String]) {
        setWidget(key, .lines(lines))
    }

    func setWidget(_ key: String, _ factory: @escaping HookWidgetFactory) {
        setWidget(key, .component(factory))
    }

    /// v0.70.0+: control whether the working/loading indicator is rendered. Default no-op.
    /// Concrete implementations (interactive mode) override this to drive the loader.
    func setWorkingVisible(_ visible: Bool) {}

    /// v0.70.0+: configure the working indicator's animation frames and interval. Pass `nil`
    /// to restore defaults. Default no-op.
    func setWorkingIndicator(_ options: WorkingIndicatorOptions?) {}

    /// v0.70.0+: customize the label shown in place of streaming thinking content. Pass `nil`
    /// to restore the default. Default no-op.
    func setHiddenThinkingLabel(_ label: String?) {}

    /// v0.70.0+: register a wrapper that decorates the current autocomplete provider.
    /// Multiple factories stack in registration order. Default no-op.
    func addAutocompleteProvider(_ factory: @escaping HookAutocompleteProviderFactory) {}
}

public final class NoOpHookUIContext: HookUIContext {
    public nonisolated init() {}

    public func select(_ title: String, _ options: [String]) async -> String? { nil }
    public func confirm(_ title: String, _ message: String) async -> Bool { false }
    public func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    public func notify(_ message: String, _ type: HookNotificationType?) {}
    public func setStatus(_ key: String, _ text: String?) {}
    public func setWorkingMessage(_ message: String?) {}
    public func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    public func setFooter(_ factory: HookFooterFactory?) {}
    public func setTitle(_ title: String) {}
    public func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    public func setEditorText(_ text: String) {}
    public func getEditorText() -> String { "" }
    public func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    public func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    public func getAllThemes() -> [HookThemeInfo] { [] }
    public func getTheme(_ name: String) -> Theme? { nil }
    public func setTheme(_ theme: HookThemeInput) -> HookThemeResult {
        HookThemeResult(success: false, error: "UI not available")
    }
    public var theme: Theme { Theme.fallback() }
}

public struct HookContext: Sendable {
    public var ui: HookUIContext
    public var mode: HookMode
    public var hasUI: Bool
    public var cwd: String
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    private var getModelHandler: @Sendable () -> Model?
    private var getSystemPromptHandler: @Sendable () -> String?
    private var isProjectTrustedHandler: @Sendable () -> Bool
    private var getSystemPromptOptionsHandler: @Sendable () -> BuildSystemPromptOptions
    public var isIdle: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var hasPendingMessages: @Sendable () -> Bool

    public init(
        ui: HookUIContext,
        mode: HookMode = .print,
        hasUI: Bool,
        cwd: String,
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: @escaping @Sendable () -> Model?,
        systemPrompt: @escaping @Sendable () -> String?,
        isProjectTrusted: @escaping @Sendable () -> Bool = { true },
        systemPromptOptions: (@Sendable () -> BuildSystemPromptOptions)? = nil,
        isIdle: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        hasPendingMessages: @escaping @Sendable () -> Bool
    ) {
        self.ui = ui
        self.mode = mode
        self.hasUI = hasUI
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.getModelHandler = model
        self.getSystemPromptHandler = systemPrompt
        self.isProjectTrustedHandler = isProjectTrusted
        self.getSystemPromptOptionsHandler = systemPromptOptions ?? { BuildSystemPromptOptions(cwd: cwd) }
        self.isIdle = isIdle
        self.abort = abort
        self.hasPendingMessages = hasPendingMessages
    }

    public init(sessionManager: SessionManager, modelRegistry: ModelRegistry, model: Model?, hasUI: Bool) {
        self.init(
            ui: NoOpHookUIContext(),
            hasUI: hasUI,
            cwd: FileManager.default.currentDirectoryPath,
            sessionManager: sessionManager,
            modelRegistry: modelRegistry,
            model: { model },
            systemPrompt: { nil },
            isIdle: { true },
            abort: {},
            hasPendingMessages: { false }
        )
    }

    public var model: Model? {
        getModelHandler()
    }

    public func getSystemPrompt() -> String? {
        getSystemPromptHandler()
    }

    public func isProjectTrusted() -> Bool {
        isProjectTrustedHandler()
    }

    public func getSystemPromptOptions() -> BuildSystemPromptOptions {
        getSystemPromptOptionsHandler()
    }
}

public struct HookCommandContext: Sendable {
    public var ui: HookUIContext
    public var mode: HookMode
    public var hasUI: Bool
    public var cwd: String
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    private var getModelHandler: @Sendable () -> Model?
    private var getSystemPromptHandler: @Sendable () -> String?
    private var isProjectTrustedHandler: @Sendable () -> Bool
    private var getSystemPromptOptionsHandler: @Sendable () -> BuildSystemPromptOptions
    public var isIdle: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var hasPendingMessages: @Sendable () -> Bool
    public var waitForIdle: @Sendable () async -> Void
    public var newSession: HookNewSessionHandler
    public var fork: HookForkHandler
    public var navigateTree: HookNavigateTreeHandler

    public init(
        ui: HookUIContext,
        mode: HookMode = .print,
        hasUI: Bool,
        cwd: String,
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: @escaping @Sendable () -> Model?,
        systemPrompt: @escaping @Sendable () -> String?,
        isProjectTrusted: @escaping @Sendable () -> Bool = { true },
        systemPromptOptions: (@Sendable () -> BuildSystemPromptOptions)? = nil,
        isIdle: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        hasPendingMessages: @escaping @Sendable () -> Bool,
        waitForIdle: @escaping @Sendable () async -> Void,
        newSession: @escaping HookNewSessionHandler,
        fork: @escaping HookForkHandler,
        navigateTree: @escaping HookNavigateTreeHandler
    ) {
        self.ui = ui
        self.mode = mode
        self.hasUI = hasUI
        self.cwd = cwd
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.getModelHandler = model
        self.getSystemPromptHandler = systemPrompt
        self.isProjectTrustedHandler = isProjectTrusted
        self.getSystemPromptOptionsHandler = systemPromptOptions ?? { BuildSystemPromptOptions(cwd: cwd) }
        self.isIdle = isIdle
        self.abort = abort
        self.hasPendingMessages = hasPendingMessages
        self.waitForIdle = waitForIdle
        self.newSession = newSession
        self.fork = fork
        self.navigateTree = navigateTree
    }

    public var model: Model? {
        getModelHandler()
    }

    public func getSystemPrompt() -> String? {
        getSystemPromptHandler()
    }

    public func isProjectTrusted() -> Bool {
        isProjectTrustedHandler()
    }

    public func getSystemPromptOptions() -> BuildSystemPromptOptions {
        getSystemPromptOptionsHandler()
    }
}

public struct HookShortcut: Sendable {
    public var shortcut: KeyId
    public var hookPath: String
    public var description: String?
    public var handler: @Sendable (_ context: HookContext) async -> Void

    public init(
        shortcut: KeyId,
        hookPath: String,
        description: String? = nil,
        handler: @escaping @Sendable (_ context: HookContext) async -> Void
    ) {
        self.shortcut = shortcut
        self.hookPath = hookPath
        self.description = description
        self.handler = handler
    }
}

public protocol HookEvent: Sendable {
    var type: String { get }
}

public enum SessionSwitchReason: String, Sendable {
    case new
    case resume
}

/// v0.65.0 + v0.69.0: discriminator on `session_start` events.
/// Replaces the separate `session_switch` and `session_fork` events.
public enum SessionStartReason: String, Sendable {
    case startup
    case reload
    case new
    case resume
    case fork
}

public struct SessionStartEvent: HookEvent, Sendable {
    public let type: String = "session_start"
    /// v0.65.0: distinguishes the lifecycle phase that triggered the event.
    /// `.startup` and `.reload` are emitted by the host on initial load / reload;
    /// `.new` / `.resume` / `.fork` are emitted by `AgentSession` (and `AgentSessionRuntime`)
    /// on session-replacement operations.
    public var reason: SessionStartReason
    /// v0.65.0: previous session's file path. Set for `.new`, `.resume`, `.fork`.
    /// Nil for `.startup` and `.reload`.
    public var previousSessionFile: String?

    public init(reason: SessionStartReason = .startup, previousSessionFile: String? = nil) {
        self.reason = reason
        self.previousSessionFile = previousSessionFile
    }
}

public struct SessionBeforeSwitchEvent: HookEvent, Sendable {
    public let type: String = "session_before_switch"
    public var reason: SessionSwitchReason
    public var targetSessionFile: String?

    public init(reason: SessionSwitchReason, targetSessionFile: String? = nil) {
        self.reason = reason
        self.targetSessionFile = targetSessionFile
    }
}

public struct ProjectTrustEvent: HookEvent, Sendable {
    public let type: String = "project_trust"
    public var cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }
}

public enum ProjectTrustEventDecision: String, Sendable {
    case yes
    case no
    case undecided
}

public struct ProjectTrustEventResult: Sendable {
    public var trusted: ProjectTrustEventDecision
    public var remember: Bool?

    public init(trusted: ProjectTrustEventDecision, remember: Bool? = nil) {
        self.trusted = trusted
        self.remember = remember
    }
}

// v0.65.0: SessionSwitchEvent removed. Use SessionStartEvent(reason: .new | .resume).

/// v0.68.0: discriminator on `session_shutdown` events. Tells extensions which lifecycle
/// path triggered the shutdown so they can run targeted cleanup (e.g., release resources
/// permanently on quit, but not on reload).
public enum SessionShutdownReason: String, Sendable {
    case quit
    case reload
    case new
    case resume
    case fork
}

public struct SessionShutdownEvent: HookEvent, Sendable {
    public let type: String = "session_shutdown"
    /// v0.68.0: shutdown lifecycle phase.
    public var reason: SessionShutdownReason
    /// v0.68.0: target session file when the shutdown is followed by a switch.
    /// Set for `.new`, `.resume`, `.fork`. Nil for `.quit` / `.reload`.
    public var targetSessionFile: String?

    public init(reason: SessionShutdownReason = .quit, targetSessionFile: String? = nil) {
        self.reason = reason
        self.targetSessionFile = targetSessionFile
    }
}

public struct ContextEvent: HookEvent, Sendable {
    public let type: String = "context"
    public var messages: [AgentMessage]

    public init(messages: [AgentMessage]) {
        self.messages = messages
    }
}

public struct BeforeAgentStartEvent: HookEvent, Sendable {
    public let type: String = "before_agent_start"
    public var prompt: String
    public var images: [ImageContent]?

    public init(prompt: String, images: [ImageContent]?) {
        self.prompt = prompt
        self.images = images
    }
}

public struct AgentStartEvent: HookEvent, Sendable {
    public let type: String = "agent_start"

    public init() {}
}

public struct AgentEndEvent: HookEvent, Sendable {
    public let type: String = "agent_end"
    public var messages: [AgentMessage]

    public init(messages: [AgentMessage]) {
        self.messages = messages
    }
}

public struct TurnStartEvent: HookEvent, Sendable {
    public let type: String = "turn_start"
    public var turnIndex: Int
    public var timestamp: Int64

    public init(turnIndex: Int, timestamp: Int64) {
        self.turnIndex = turnIndex
        self.timestamp = timestamp
    }
}

public struct TurnEndEvent: HookEvent, Sendable {
    public let type: String = "turn_end"
    public var turnIndex: Int
    public var message: AgentMessage
    public var toolResults: [ToolResultMessage]

    public init(turnIndex: Int, message: AgentMessage, toolResults: [ToolResultMessage]) {
        self.turnIndex = turnIndex
        self.message = message
        self.toolResults = toolResults
    }
}

public enum ModelSelectSource: String, Sendable {
    case set
    case cycle
    case restore
}

public struct ModelSelectEvent: HookEvent, Sendable {
    public let type: String = "model_select"
    public var model: Model
    public var previousModel: Model?
    public var source: ModelSelectSource

    public init(model: Model, previousModel: Model?, source: ModelSelectSource) {
        self.model = model
        self.previousModel = previousModel
        self.source = source
    }
}

public struct UserBashEvent: HookEvent, Sendable {
    public let type: String = "user_bash"
    public var command: String
    public var excludeFromContext: Bool
    public var cwd: String

    public init(command: String, excludeFromContext: Bool, cwd: String) {
        self.command = command
        self.excludeFromContext = excludeFromContext
        self.cwd = cwd
    }
}

public struct UserBashEventResult: Sendable {
    public var operations: BashOperations?
    public var result: BashResult?

    public init(operations: BashOperations? = nil, result: BashResult? = nil) {
        self.operations = operations
        self.result = result
    }
}

public struct SessionBeforeCompactEvent: HookEvent, Sendable {
    public let type: String = "session_before_compact"
    public var preparation: CompactionPreparation
    public var branchEntries: [SessionEntry]
    public var customInstructions: String?
    public var signal: CancellationToken?

    public init(preparation: CompactionPreparation, branchEntries: [SessionEntry], customInstructions: String?, signal: CancellationToken?) {
        self.preparation = preparation
        self.branchEntries = branchEntries
        self.customInstructions = customInstructions
        self.signal = signal
    }
}

public struct SessionCompactEvent: HookEvent, Sendable {
    public let type: String = "session_compact"
    public var compactionEntry: CompactionEntry
    public var fromHook: Bool

    public init(compactionEntry: CompactionEntry, fromHook: Bool) {
        self.compactionEntry = compactionEntry
        self.fromHook = fromHook
    }
}

public struct SessionBeforeForkEvent: HookEvent, Sendable {
    public let type: String = "session_before_fork"
    public var entryId: String

    public init(entryId: String) {
        self.entryId = entryId
    }
}

// v0.65.0: SessionForkEvent removed. Use SessionStartEvent(reason: .fork).

public struct SessionBeforeTreeEvent: HookEvent, Sendable {
    public let type: String = "session_before_tree"
    public var preparation: TreePreparation
    public var signal: CancellationToken?

    public init(preparation: TreePreparation, signal: CancellationToken?) {
        self.preparation = preparation
        self.signal = signal
    }
}

public struct SessionTreeEvent: HookEvent, Sendable {
    public let type: String = "session_tree"
    public var newLeafId: String?
    public var oldLeafId: String?
    public var summaryEntry: BranchSummaryEntry?
    public var fromHook: Bool?

    public init(newLeafId: String?, oldLeafId: String?, summaryEntry: BranchSummaryEntry?, fromHook: Bool?) {
        self.newLeafId = newLeafId
        self.oldLeafId = oldLeafId
        self.summaryEntry = summaryEntry
        self.fromHook = fromHook
    }
}

public struct BeforeProviderRequestEvent: HookEvent, Sendable {
    public let type: String = "before_provider_request"
    public var payload: String

    public init(payload: String) {
        self.payload = payload
    }
}

/// v0.68.0: emitted after a provider HTTP response is received and BEFORE the stream begins
/// consuming. Lets extensions inspect status / headers — useful for tracing, debugging
/// rate-limit/auth failures, surfacing provider-specific telemetry.
public struct AfterProviderResponseEvent: HookEvent, Sendable {
    public let type: String = "after_provider_response"
    public var status: Int
    public var headers: [String: String]

    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }
}

public struct ToolCallEvent: HookEvent, Sendable {
    public let type: String = "tool_call"
    public var toolName: String
    public var toolCallId: String
    public var input: [String: AnyCodable]

    public init(toolName: String, toolCallId: String, input: [String: AnyCodable]) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.input = input
    }
}

public struct ToolCallEventResult: Sendable {
    public var block: Bool
    public var reason: String?

    public init(block: Bool = false, reason: String? = nil) {
        self.block = block
        self.reason = reason
    }
}

public struct ToolResultEvent: HookEvent, Sendable {
    public let type: String = "tool_result"
    public var toolName: String
    public var toolCallId: String
    public var input: [String: AnyCodable]
    public var content: [ContentBlock]
    public var details: AnyCodable?
    public var isError: Bool

    public init(
        toolName: String,
        toolCallId: String,
        input: [String: AnyCodable],
        content: [ContentBlock],
        details: AnyCodable?,
        isError: Bool
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.input = input
        self.content = content
        self.details = details
        self.isError = isError
    }
}

public struct ToolResultEventResult: Sendable {
    public var content: [ContentBlock]?
    public var details: AnyCodable?
    public var isError: Bool?

    public init(content: [ContentBlock]? = nil, details: AnyCodable? = nil, isError: Bool? = nil) {
        self.content = content
        self.details = details
        self.isError = isError
    }
}

public struct SessionBeforeCompactResult: Sendable {
    public var cancel: Bool
    public var compaction: CompactionResult?

    public init(cancel: Bool = false, compaction: CompactionResult? = nil) {
        self.cancel = cancel
        self.compaction = compaction
    }
}

public struct BeforeAgentStartEventResult: Sendable {
    public var message: HookMessageInput?
    public var systemPromptAppend: String?

    public init(message: HookMessageInput? = nil, systemPromptAppend: String? = nil) {
        self.message = message
        self.systemPromptAppend = systemPromptAppend
    }
}

public struct BeforeAgentStartCombinedResult: Sendable {
    public var messages: [HookMessageInput]?
    public var systemPromptAppend: String?

    public init(messages: [HookMessageInput]? = nil, systemPromptAppend: String? = nil) {
        self.messages = messages
        self.systemPromptAppend = systemPromptAppend
    }
}

public struct SessionBeforeSwitchResult: Sendable {
    public var cancel: Bool

    public init(cancel: Bool = false) {
        self.cancel = cancel
    }
}

public struct SessionBeforeForkResult: Sendable {
    public var cancel: Bool
    public var skipConversationRestore: Bool

    public init(cancel: Bool = false, skipConversationRestore: Bool = false) {
        self.cancel = cancel
        self.skipConversationRestore = skipConversationRestore
    }
}

public struct SessionBeforeTreeResult: Sendable {
    public var cancel: Bool
    public var summary: BranchSummaryResult?

    public init(cancel: Bool = false, summary: BranchSummaryResult? = nil) {
        self.cancel = cancel
        self.summary = summary
    }
}

public struct ContextEventResult: Sendable {
    public var messages: [AgentMessage]?

    public init(messages: [AgentMessage]? = nil) {
        self.messages = messages
    }
}

public typealias HookHandler = @Sendable (_ event: HookEvent, _ context: HookContext) async throws -> Any?

public struct HookError: Sendable {
    public var hookPath: String
    public var event: String
    public var error: String
    public var stack: String?

    public init(hookPath: String, event: String, error: String, stack: String? = nil) {
        self.hookPath = hookPath
        self.event = event
        self.error = error
        self.stack = stack
    }
}

public struct LoadedHook: Sendable {
    public var path: String
    public var resolvedPath: String
    public var handlers: [String: [HookHandler]]
    public var messageRenderers: [String: HookMessageRenderer]
    public var commands: [String: RegisteredCommand]
    public var flags: [String: HookFlag]
    public var shortcuts: [KeyId: HookShortcut]
    /// Custom tools registered by the extension via `pi.registerTool(_:)`. Empty for
    /// settings-defined hooks (which use the legacy `--tool` flag pathway instead).
    public var tools: [String: CustomTool]
    public var providerRegistrations: [String: HookProviderConfig]
    public var setSendMessageHandler: HookSendMessageSetter
    public var setAppendEntryHandler: HookAppendEntrySetter
    public var setSetSessionNameHandler: (@Sendable (@escaping HookSetSessionNameHandler) -> Void)
    public var setGetSessionNameHandler: (@Sendable (@escaping HookGetSessionNameHandler) -> Void)
    public var setGetActiveToolsHandler: HookGetActiveToolsSetter
    public var setGetAllToolsHandler: HookGetAllToolsSetter
    public var setSetActiveToolsHandler: HookSetActiveToolsSetter
    public var setRegisterProviderHandler: HookRegisterProviderSetter
    public var setUnregisterProviderHandler: HookUnregisterProviderSetter
    public var setFlagValue: HookSetFlagValue
    /// True when this hook was loaded from a `.swift`/SPM extension (vs a settings-defined hook).
    /// Used by the reload lifecycle to swap extensions without disturbing built-in hooks.
    public var isExtension: Bool

    public init(
        path: String,
        resolvedPath: String,
        handlers: [String: [HookHandler]],
        messageRenderers: [String: HookMessageRenderer] = [:],
        commands: [String: RegisteredCommand] = [:],
        flags: [String: HookFlag] = [:],
        shortcuts: [KeyId: HookShortcut] = [:],
        tools: [String: CustomTool] = [:],
        providerRegistrations: [String: HookProviderConfig] = [:],
        setSendMessageHandler: @escaping HookSendMessageSetter = { _ in },
        setAppendEntryHandler: @escaping HookAppendEntrySetter = { _ in },
        setSetSessionNameHandler: @escaping (@Sendable (@escaping HookSetSessionNameHandler) -> Void) = { _ in },
        setGetSessionNameHandler: @escaping (@Sendable (@escaping HookGetSessionNameHandler) -> Void) = { _ in },
        setGetActiveToolsHandler: @escaping HookGetActiveToolsSetter = { _ in },
        setGetAllToolsHandler: @escaping HookGetAllToolsSetter = { _ in },
        setSetActiveToolsHandler: @escaping HookSetActiveToolsSetter = { _ in },
        setRegisterProviderHandler: @escaping HookRegisterProviderSetter = { _ in },
        setUnregisterProviderHandler: @escaping HookUnregisterProviderSetter = { _ in },
        setFlagValue: @escaping HookSetFlagValue = { _, _ in },
        isExtension: Bool = false
    ) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.handlers = handlers
        self.messageRenderers = messageRenderers
        self.commands = commands
        self.flags = flags
        self.shortcuts = shortcuts
        self.tools = tools
        self.providerRegistrations = providerRegistrations
        self.setSendMessageHandler = setSendMessageHandler
        self.setAppendEntryHandler = setAppendEntryHandler
        self.setSetSessionNameHandler = setSetSessionNameHandler
        self.setGetSessionNameHandler = setGetSessionNameHandler
        self.setGetActiveToolsHandler = setGetActiveToolsHandler
        self.setGetAllToolsHandler = setGetAllToolsHandler
        self.setSetActiveToolsHandler = setSetActiveToolsHandler
        self.setRegisterProviderHandler = setRegisterProviderHandler
        self.setUnregisterProviderHandler = setUnregisterProviderHandler
        self.setFlagValue = setFlagValue
        self.isExtension = isExtension
    }
}

public struct TreePreparation: Sendable {
    public var targetId: String
    public var oldLeafId: String?
    public var commonAncestorId: String?
    public var entriesToSummarize: [SessionEntry]
    public var userWantsSummary: Bool

    public init(targetId: String, oldLeafId: String?, commonAncestorId: String?, entriesToSummarize: [SessionEntry], userWantsSummary: Bool) {
        self.targetId = targetId
        self.oldLeafId = oldLeafId
        self.commonAncestorId = commonAncestorId
        self.entriesToSummarize = entriesToSummarize
        self.userWantsSummary = userWantsSummary
    }
}

public final class HookAPI: Sendable {
    public let events: EventBus
    private let state: LockedState<State>

    private struct State: Sendable {
        var handlers: [String: [HookHandler]]
        var messageRenderers: [String: HookMessageRenderer]
        var commands: [String: RegisteredCommand]
        var flags: [String: HookFlag]
        var shortcuts: [KeyId: HookShortcut]
        /// Custom tools registered by the extension via `pi.registerTool(_:)`.
        /// Keyed by tool name; collisions overwrite (last write wins).
        var tools: [String: CustomTool]
        var providerRegistrations: [String: HookProviderConfig]
        var registerProviderHandler: HookRegisterProviderHandler
        var unregisterProviderHandler: HookUnregisterProviderHandler
        var sendMessageHandler: HookSendMessageHandler
        var appendEntryHandler: HookAppendEntryHandler
        var setSessionNameHandler: HookSetSessionNameHandler
        var getSessionNameHandler: HookGetSessionNameHandler
        var getActiveToolsHandler: HookGetActiveToolsHandler
        var getAllToolsHandler: HookGetAllToolsHandler
        var setActiveToolsHandler: HookSetActiveToolsHandler
        var flagValues: [String: HookFlagValue]
        var execCwd: String?
        var hookPath: String
    }

    public private(set) var handlers: [String: [HookHandler]] {
        get { state.withLock { $0.handlers } }
        set { state.withLock { $0.handlers = newValue } }
    }

    public private(set) var messageRenderers: [String: HookMessageRenderer] {
        get { state.withLock { $0.messageRenderers } }
        set { state.withLock { $0.messageRenderers = newValue } }
    }

    public private(set) var commands: [String: RegisteredCommand] {
        get { state.withLock { $0.commands } }
        set { state.withLock { $0.commands = newValue } }
    }

    public private(set) var flags: [String: HookFlag] {
        get { state.withLock { $0.flags } }
        set { state.withLock { $0.flags = newValue } }
    }

    public private(set) var shortcuts: [KeyId: HookShortcut] {
        get { state.withLock { $0.shortcuts } }
        set { state.withLock { $0.shortcuts = newValue } }
    }

    public private(set) var tools: [String: CustomTool] {
        get { state.withLock { $0.tools } }
        set { state.withLock { $0.tools = newValue } }
    }

    public private(set) var providerRegistrations: [String: HookProviderConfig] {
        get { state.withLock { $0.providerRegistrations } }
        set { state.withLock { $0.providerRegistrations = newValue } }
    }

    private var registerProviderHandler: HookRegisterProviderHandler {
        get { state.withLock { $0.registerProviderHandler } }
        set { state.withLock { $0.registerProviderHandler = newValue } }
    }

    private var unregisterProviderHandler: HookUnregisterProviderHandler {
        get { state.withLock { $0.unregisterProviderHandler } }
        set { state.withLock { $0.unregisterProviderHandler = newValue } }
    }

    private var sendMessageHandler: HookSendMessageHandler {
        get { state.withLock { $0.sendMessageHandler } }
        set { state.withLock { $0.sendMessageHandler = newValue } }
    }

    private var appendEntryHandler: HookAppendEntryHandler {
        get { state.withLock { $0.appendEntryHandler } }
        set { state.withLock { $0.appendEntryHandler = newValue } }
    }

    private var setSessionNameHandler: HookSetSessionNameHandler {
        get { state.withLock { $0.setSessionNameHandler } }
        set { state.withLock { $0.setSessionNameHandler = newValue } }
    }

    private var getSessionNameHandler: HookGetSessionNameHandler {
        get { state.withLock { $0.getSessionNameHandler } }
        set { state.withLock { $0.getSessionNameHandler = newValue } }
    }

    private var getActiveToolsHandler: HookGetActiveToolsHandler {
        get { state.withLock { $0.getActiveToolsHandler } }
        set { state.withLock { $0.getActiveToolsHandler = newValue } }
    }

    private var getAllToolsHandler: HookGetAllToolsHandler {
        get { state.withLock { $0.getAllToolsHandler } }
        set { state.withLock { $0.getAllToolsHandler = newValue } }
    }

    private var setActiveToolsHandler: HookSetActiveToolsHandler {
        get { state.withLock { $0.setActiveToolsHandler } }
        set { state.withLock { $0.setActiveToolsHandler = newValue } }
    }

    private var flagValues: [String: HookFlagValue] {
        get { state.withLock { $0.flagValues } }
        set { state.withLock { $0.flagValues = newValue } }
    }

    private var execCwd: String? {
        get { state.withLock { $0.execCwd } }
        set { state.withLock { $0.execCwd = newValue } }
    }

    private var hookPath: String {
        get { state.withLock { $0.hookPath } }
        set { state.withLock { $0.hookPath = newValue } }
    }

    public init(events: EventBus = createEventBus(), hookPath: String? = nil) {
        self.events = events
        let resolvedHookPath = hookPath ?? "<hook>"
        self.state = LockedState(State(
            handlers: [:],
            messageRenderers: [:],
            commands: [:],
            flags: [:],
            shortcuts: [:],
            tools: [:],
            providerRegistrations: [:],
            registerProviderHandler: { _ in },
            unregisterProviderHandler: { _ in },
            sendMessageHandler: { _, _ in },
            appendEntryHandler: { _, _ in },
            setSessionNameHandler: { _ in },
            getSessionNameHandler: { nil },
            getActiveToolsHandler: { [] },
            getAllToolsHandler: { [] },
            setActiveToolsHandler: { _ in },
            flagValues: [:],
            execCwd: nil,
            hookPath: resolvedHookPath
        ))
    }

    public func setExecCwd(_ cwd: String) {
        execCwd = cwd
    }

    public func setHookPath(_ path: String) {
        hookPath = path
    }

    public func setSendMessageHandler(_ handler: @escaping HookSendMessageHandler) {
        sendMessageHandler = handler
    }

    public func setAppendEntryHandler(_ handler: @escaping HookAppendEntryHandler) {
        appendEntryHandler = handler
    }

    public func setSetSessionNameHandler(_ handler: @escaping HookSetSessionNameHandler) {
        setSessionNameHandler = handler
    }

    public func setGetSessionNameHandler(_ handler: @escaping HookGetSessionNameHandler) {
        getSessionNameHandler = handler
    }

    public func setGetActiveToolsHandler(_ handler: @escaping HookGetActiveToolsHandler) {
        getActiveToolsHandler = handler
    }

    public func setGetAllToolsHandler(_ handler: @escaping HookGetAllToolsHandler) {
        getAllToolsHandler = handler
    }

    public func setSetActiveToolsHandler(_ handler: @escaping HookSetActiveToolsHandler) {
        setActiveToolsHandler = handler
    }

    public func setRegisterProviderHandler(_ handler: @escaping HookRegisterProviderHandler) {
        registerProviderHandler = handler
    }

    public func setUnregisterProviderHandler(_ handler: @escaping HookUnregisterProviderHandler) {
        unregisterProviderHandler = handler
    }

    public func setFlagValue(_ name: String, _ value: HookFlagValue) {
        flagValues[name] = value
    }

    public func on<T: HookEvent>(_ type: String, _ handler: @Sendable @escaping (T, HookContext) async throws -> Any?) {
        let wrapper: HookHandler = { event, context in
            guard let typed = event as? T else { return nil }
            return try await handler(typed, context)
        }
        handlers[type, default: []].append(wrapper)
    }

    public func onAny(_ type: String, _ handler: @Sendable @escaping (HookEvent, HookContext) async throws -> Any?) {
        handlers[type, default: []].append(handler)
    }

    public func sendMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) {
        sendMessageHandler(message, options)
    }

    public func appendEntry(_ customType: String, _ data: [String: Any]) {
        appendEntryHandler(customType, data)
    }

    public func setSessionName(_ name: String) {
        setSessionNameHandler(name)
    }

    public func getSessionName() -> String? {
        getSessionNameHandler()
    }

    public func getActiveTools() -> [String] {
        getActiveToolsHandler()
    }

    public func getAllTools() -> [ToolInfo] {
        getAllToolsHandler()
    }

    public func setActiveTools(_ toolNames: [String]) {
        setActiveToolsHandler(toolNames)
    }

    public func registerFlag(_ name: String, _ options: HookFlagOptions) {
        let flag = HookFlag(
            name: name,
            hookPath: hookPath,
            description: options.description,
            type: options.type,
            defaultValue: options.defaultValue
        )
        flags[name] = flag
        if let defaultValue = options.defaultValue {
            flagValues[name] = defaultValue
        }
    }

    public func getFlag(_ name: String) -> HookFlagValue? {
        flagValues[name]
    }

    public func registerShortcut(_ shortcut: KeyId, description: String? = nil, handler: @escaping @Sendable (_ context: HookContext) async -> Void) {
        shortcuts[shortcut] = HookShortcut(
            shortcut: shortcut,
            hookPath: hookPath,
            description: description,
            handler: handler
        )
    }

    public func registerMessageRenderer(_ customType: String, _ renderer: @escaping HookMessageRenderer) {
        messageRenderers[customType] = renderer
    }

    public func registerCommand(_ name: String, description: String? = nil, handler: @escaping @Sendable (_ args: String, _ context: HookCommandContext) async throws -> Void) {
        commands[name] = RegisteredCommand(name: name, description: description, handler: handler)
    }

    /// Register a custom tool callable by the LLM. Mirrors pi-mono's `pi.registerTool(_)`.
    /// The tool's `name` must be unique across the session (collisions overwrite). The
    /// extension that registered the tool owns its lifetime — when the extension is
    /// dropped via `/reload`, its tools are removed from the agent's roster.
    public func registerTool(_ tool: CustomTool) {
        tools[tool.name] = tool
    }

    public func registerProvider(_ config: HookProviderConfig) {
        providerRegistrations[config.provider] = config
        registerProviderHandler(config)
    }

    public func unregisterProvider(_ provider: String) {
        providerRegistrations.removeValue(forKey: provider)
        unregisterProviderHandler(provider)
    }

#if !canImport(UIKit)
    public func exec(_ command: String, _ args: [String], _ options: ExecOptions? = nil) async -> ExecResult {
        let cwd = options?.cwd ?? execCwd ?? FileManager.default.currentDirectoryPath
        return await execCommand(command, args, cwd, options)
    }
#endif
}
