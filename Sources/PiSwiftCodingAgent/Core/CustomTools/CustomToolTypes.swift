import Foundation
import PiSwiftAI
import PiSwiftAgent

public typealias CustomToolUIContext = HookUIContext
public typealias CustomToolResult = AgentToolResult
public typealias CustomToolUpdateCallback = AgentToolUpdateCallback

public enum ToolRenderShell: String, Sendable, Codable {
    case `default`
    case `self`
}

public enum ToolExposure: String, Sendable, Codable {
    case direct
    case modelOnly = "model-only"
    case codemode
    case deferred
    case hidden
}

public struct ToolNamespace: Sendable, Codable {
    public var name: String
    public var description: String?
    /// Usage instructions returned when a tool describes this namespace.
    public var instructions: String?

    public init(name: String, description: String? = nil, instructions: String? = nil) {
        self.name = name
        self.description = description
        self.instructions = instructions
    }
}

public struct ToolAnnotations: Sendable, Codable {
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

public struct ToolLoadout: Sendable {
    public var declared: [AgentTool]
    public var callable: [AgentTool]
    public var registered: [AgentTool]
    public var getExposure: @Sendable (String) -> ToolExposure
    public var getNamespace: @Sendable (String) -> ToolNamespace?

    public init(declared: [AgentTool], callable: [AgentTool], registered: [AgentTool],
                getExposure: @escaping @Sendable (String) -> ToolExposure,
                getNamespace: @escaping @Sendable (String) -> ToolNamespace?) {
        self.declared = declared
        self.callable = callable
        self.registered = registered
        self.getExposure = getExposure
        self.getNamespace = getNamespace
    }
}

public struct ToolLoadoutChanges: Sendable {
    public var descriptions: [String: String]?
    public var hiddenDeclarations: [String]?

    public init(descriptions: [String: String]? = nil, hiddenDeclarations: [String]? = nil) {
        self.descriptions = descriptions
        self.hiddenDeclarations = hiddenDeclarations
    }
}

public struct ExecuteToolOptions: Sendable {
    public var signal: CancellationToken?
    public var onUpdate: AgentToolUpdateCallback?
    public var argumentsJSON: OrderedJSON?

    public init(signal: CancellationToken? = nil, onUpdate: AgentToolUpdateCallback? = nil, argumentsJSON: OrderedJSON? = nil) {
        self.signal = signal
        self.onUpdate = onUpdate
        self.argumentsJSON = argumentsJSON
    }
}

public typealias NestedToolExecute = @Sendable (
    _ name: String, _ args: [String: AnyCodable], _ options: ExecuteToolOptions
) async -> AgentToolCallOutcome

public struct CustomToolContext: Sendable {
    public var sessionManager: SessionManager
    public var modelRegistry: ModelRegistry
    public var model: Model?
    public var isIdle: @Sendable () -> Bool
    public var hasPendingMessages: @Sendable () -> Bool
    public var abort: @Sendable () -> Void
    public var events: EventBus
    public var sendMessage: HookSendMessageHandler
    public var tools: [AgentTool]
    public var toolCallId: String?
    public var signal: CancellationToken?
    private var nestedToolExecute: NestedToolExecute?

    public init(
        sessionManager: SessionManager,
        modelRegistry: ModelRegistry,
        model: Model?,
        isIdle: @escaping @Sendable () -> Bool,
        hasPendingMessages: @escaping @Sendable () -> Bool,
        abort: @escaping @Sendable () -> Void,
        events: EventBus,
        sendMessage: @escaping HookSendMessageHandler,
        tools: [AgentTool] = [],
        toolCallId: String? = nil,
        signal: CancellationToken? = nil,
        nestedToolExecute: NestedToolExecute? = nil
    ) {
        self.sessionManager = sessionManager
        self.modelRegistry = modelRegistry
        self.model = model
        self.isIdle = isIdle
        self.hasPendingMessages = hasPendingMessages
        self.abort = abort
        self.events = events
        self.sendMessage = sendMessage
        self.tools = tools
        self.toolCallId = toolCallId
        self.signal = signal
        self.nestedToolExecute = nestedToolExecute
    }

    public func executeTool(
        name: String, args: [String: AnyCodable], options: ExecuteToolOptions = ExecuteToolOptions()
    ) async -> AgentToolCallOutcome {
        if let nestedToolExecute {
            var effectiveOptions = options
            effectiveOptions.signal = options.signal ?? signal
            return await nestedToolExecute(name, args, effectiveOptions)
        }
        let toolCall = AgentToolCall(id: "\(toolCallId ?? "undefined")/0", name: name, arguments: [:])
        let result = AgentToolResult(
            content: [.text(TextContent(text: "Nested tool calls are not available in this context"))],
            details: AnyCodable([String: AnyCodable]()), isError: true
        )
        return AgentToolCallOutcome(toolCall: toolCall, result: result, isError: true)
    }

    public mutating func setNestedToolHost(
        tools: [AgentTool], execute: @escaping NestedToolExecute
    ) {
        self.tools = tools
        self.nestedToolExecute = execute
    }

    public mutating func setToolCall(_ id: String, signal: CancellationToken?) {
        toolCallId = id
        self.signal = signal
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

/// A renderer family drawn by the host.
public enum BuiltInToolRenderer: Sendable, Equatable {
    case mcp(label: String)
}

/// Display settings for a tool call. These settings do not register a tool.
public struct CustomToolRenderers: Sendable {
    public var renderShell: ToolRenderShell?
    public var renderCall: CustomToolRenderCall?
    public var renderResult: CustomToolRenderResult?
    public var builtIn: BuiltInToolRenderer?

    public init(renderShell: ToolRenderShell? = nil,
                renderCall: CustomToolRenderCall? = nil,
                renderResult: CustomToolRenderResult? = nil,
                builtIn: BuiltInToolRenderer? = nil) {
        self.renderShell = renderShell
        self.renderCall = renderCall
        self.renderResult = renderResult
        self.builtIn = builtIn
    }

    public init(tool: CustomTool) {
        self.init(renderShell: tool.renderShell, renderCall: tool.renderCall,
                  renderResult: tool.renderResult)
    }
}

/// Calls `next` to get settings from the remaining resolvers and the base tool.
public typealias ToolRendererResolver = @Sendable (_ toolName: String, _ next: () -> CustomToolRenderers?) -> CustomToolRenderers?

public struct CustomTool: Sendable {
    public var name: String
    public var label: String
    public var description: String
    /// Rule bullets in the default system prompt while this tool is active.
    public var promptGuidelines: [String]?
    public var promptSnippet: String?
    public var parameters: [String: AnyCodable]?
    public var execute: CustomToolExecute
    public var onSession: CustomToolSessionHandler?
    public var renderCall: CustomToolRenderCall?
    public var renderResult: CustomToolRenderResult?
    public var renderShell: ToolRenderShell
    /// Explicitly disable provider-side constrained sampling when replacing a built-in tool.
    public var constrainedSampling: ConstrainedSampling?
    public var outputSchema: [String: AnyCodable]?
    public var exposure: ToolExposure?
    public var namespace: ToolNamespace?
    public var annotations: ToolAnnotations?
    public var defaultActive: Bool?
    public var prepareLoadout: (@Sendable (ToolLoadout) throws -> ToolLoadoutChanges?)?
    public var executionMode: ToolExecutionMode?

    public init(
        name: String,
        label: String,
        description: String,
        parameters: [String: AnyCodable]? = nil,
        execute: @escaping CustomToolExecute,
        promptGuidelines: [String]? = nil,
        promptSnippet: String? = nil,
        onSession: CustomToolSessionHandler? = nil,
        renderCall: CustomToolRenderCall? = nil,
        renderResult: CustomToolRenderResult? = nil,
        renderShell: ToolRenderShell = .default,
        constrainedSampling: ConstrainedSampling? = nil,
        outputSchema: [String: AnyCodable]? = nil,
        exposure: ToolExposure? = nil,
        namespace: ToolNamespace? = nil,
        annotations: ToolAnnotations? = nil,
        defaultActive: Bool? = nil,
        prepareLoadout: (@Sendable (ToolLoadout) throws -> ToolLoadoutChanges?)? = nil,
        executionMode: ToolExecutionMode? = nil
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.promptGuidelines = promptGuidelines
        self.promptSnippet = promptSnippet
        self.parameters = parameters
        self.execute = execute
        self.onSession = onSession
        self.renderCall = renderCall
        self.renderResult = renderResult
        self.renderShell = renderShell
        self.constrainedSampling = constrainedSampling
        self.outputSchema = outputSchema
        self.exposure = exposure
        self.namespace = namespace
        self.annotations = annotations
        self.defaultActive = defaultActive
        self.prepareLoadout = prepareLoadout
        self.executionMode = executionMode
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
