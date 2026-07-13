import Foundation
import PiSwiftAI
import PiSwiftAgent

public typealias CustomToolUIContext = HookUIContext
public typealias CustomToolResult = AgentToolResult
public typealias CustomToolUpdateCallback = AgentToolUpdateCallback

public struct CustomToolContext: Sendable {
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var isIdle: @Sendable () -> Bool
    public var hasPendingMessages: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var events: EventBus
    public var sendMessage: HookSendMessageHandler

    public init(
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: Model?,
        isIdle: @escaping @Sendable () -> Bool,
        hasPendingMessages: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        events: EventBus,
        sendMessage: @escaping HookSendMessageHandler
    ) {
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.isIdle = isIdle
        self.hasPendingMessages = hasPendingMessages
        self.abort = abort
        self.events = events
        self.sendMessage = sendMessage
    }
}

public struct CustomToolSessionEvent: Sendable {
    public enum Reason: String, Sendable {
        case start
        case `switch`
        case fork
        case tree
        case shutdown
    }

    public var reason: Reason
    public var previousSessionFile: String?

    public init(reason: Reason, previousSessionFile: String?) {
        self.reason = reason
        self.previousSessionFile = previousSessionFile
    }
}

public struct RenderResultOptions: Sendable {
    public var expanded: Bool
    public var isPartial: Bool

    public init(expanded: Bool, isPartial: Bool) {
        self.expanded = expanded
        self.isPartial = isPartial
    }
}

public typealias CustomToolExecute = @Sendable (
    _ toolCallId: String,
    _ params: [String: AnyCodable],
    _ onUpdate: CustomToolUpdateCallback?,
    _ context: CustomToolContext,
    _ signal: CancellationToken?
) async throws -> CustomToolResult

public typealias CustomToolSessionHandler = @Sendable (_ event: CustomToolSessionEvent, _ context: CustomToolContext) async throws -> Void
public typealias CustomToolRenderCall = @Sendable (_ args: [String: AnyCodable], _ theme: Theme) throws -> HookComponent?
public typealias CustomToolRenderResult = @Sendable (_ result: CustomToolResult, _ options: RenderResultOptions, _ theme: Theme) throws -> HookComponent?

public struct CustomTool: Sendable {
    public var name: String
    public var label: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var execute: CustomToolExecute
    public var onSession: CustomToolSessionHandler?
    public var renderCall: CustomToolRenderCall?
    public var renderResult: CustomToolRenderResult?

    public init(
        name: String,
        label: String,
        description: String,
        parameters: [String: AnyCodable],
        execute: @escaping CustomToolExecute,
        onSession: CustomToolSessionHandler? = nil,
        renderCall: CustomToolRenderCall? = nil,
        renderResult: CustomToolRenderResult? = nil
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.parameters = parameters
        self.execute = execute
        self.onSession = onSession
        self.renderCall = renderCall
        self.renderResult = renderResult
    }
}

public struct CustomToolDefinition: Sendable {
    public var path: String?
    public var tool: CustomTool

    public init(path: String? = nil, tool: CustomTool) {
        self.path = path
        self.tool = tool
    }
}

public struct LoadedCustomTool: Sendable {
    public var path: String
    public var resolvedPath: String
    public var tool: CustomTool

    public init(path: String, resolvedPath: String, tool: CustomTool) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.tool = tool
    }
}

public struct CustomToolLoadError: Sendable {
    public var path: String
    public var error: String

    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

public struct CustomToolsLoadResult: Sendable {
    public var tools: [LoadedCustomTool]
    public var errors: [CustomToolLoadError]
    public var setUIContext: (@Sendable (_ uiContext: CustomToolUIContext, _ hasUI: Bool) -> Void)
    public var setSendMessageHandler: (@Sendable (_ handler: @escaping HookSendMessageHandler) -> Void)

    public init(
        tools: [LoadedCustomTool],
        errors: [CustomToolLoadError],
        setUIContext: @escaping @Sendable (_ uiContext: CustomToolUIContext, _ hasUI: Bool) -> Void = { _, _ in },
        setSendMessageHandler: @escaping @Sendable (_ handler: @escaping HookSendMessageHandler) -> Void = { _ in }
    ) {
        self.tools = tools
        self.errors = errors
        self.setUIContext = setUIContext
        self.setSendMessageHandler = setSendMessageHandler
    }
}

public protocol CustomToolPlugin: AnyObject, Sendable {
    init()
    func register(_ api: CustomToolAPI)
}

public final class CustomToolAPI: Sendable {
    public let cwd: String
    public let events: EventBus

    private struct State: Sendable {
        var uiContext: CustomToolUIContext
        var hasUIValue: Bool
        var registeredTools: [CustomTool]
        var sendMessageHandler: HookSendMessageHandler
    }

    private let state: LockedState<State>

    public init(
        cwd: String,
        events: EventBus,
        ui: CustomToolUIContext = NoOpHookUIContext(),
        hasUI: Bool = false
    ) {
        self.cwd = cwd
        self.events = events
        self.state = LockedState(State(
            uiContext: ui,
            hasUIValue: hasUI,
            registeredTools: [],
            sendMessageHandler: { _, _ in }
        ))
    }

    public var ui: CustomToolUIContext {
        get {
            state.withLock { $0.uiContext }
        }
        set {
            state.withLock { $0.uiContext = newValue }
        }
    }

    public var hasUI: Bool {
        get {
            state.withLock { $0.hasUIValue }
        }
        set {
            state.withLock { $0.hasUIValue = newValue }
        }
    }

    public func register(_ tool: CustomTool) {
        state.withLock { $0.registeredTools.append(tool) }
    }

    public func register(_ tools: [CustomTool]) {
        state.withLock { state in
            state.registeredTools.append(contentsOf: tools)
        }
    }

    public func toolsSnapshot() -> [CustomTool] {
        state.withLock { $0.registeredTools }
    }

    public func setSendMessageHandler(_ handler: @escaping HookSendMessageHandler) {
        state.withLock { $0.sendMessageHandler = handler }
    }

    public func sendMessage(_ message: HookMessageInput, options: HookSendMessageOptions? = nil) {
        let handler = state.withLock { $0.sendMessageHandler }
        handler(message, options)
    }

#if canImport(UIKit)
    public func exec(_ command: String, _ args: [String], _ options: ExecOptions? = nil) async -> ExecResult {
        let execCwd = options?.cwd ?? cwd
        return ExecResult(stdout: "Execution is not supported on iOS", stderr: "", code: -1, killed: true)
    }
#else
    public func exec(_ command: String, _ args: [String], _ options: ExecOptions? = nil) async throws -> ExecResult {
        let execCwd = options?.cwd ?? cwd
        return try await execCommand(command, args, execCwd, options)
    }
#endif
}
