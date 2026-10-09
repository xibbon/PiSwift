import Foundation
import PiSwiftAI
import PiSwiftChord

/// A tool result can add tools, end the run, or hand off to another agent.
public struct ToolControl: Sendable, Equatable, Codable {
    /// Tool names to add to the conversation offer policy.
    public var addTools: [String]?
    /// Whether the tool requests the current run to end.
    public var terminate: Bool?
    /// Optional text passed to the next agent or conversation boundary.
    public var handoff: String?
    /// Selects tool additions, run termination, or handoff text.
    public init(addTools: [String]? = nil, terminate: Bool? = nil, handoff: String? = nil) {
        self.addTools = addTools; self.terminate = terminate; self.handoff = handoff
    }
}
/// A tool report with a severity, message, and optional stable code.
public struct ToolDiagnostic: Sendable, Equatable, Codable {
    /// The level assigned to a tool diagnostic.
    public enum Severity: String, Sendable, Codable {
        /// Reports information without an execution failure.
        case info
        /// Reports a condition that can require attention.
        case warn
        /// Reports a tool execution error.
        case error
    }
    /// The level assigned to this tool diagnostic.
    public var severity: Severity
    /// Text that describes the error, diagnostic, or model response.
    public var message: String
    /// An optional stable identifier for the diagnostic.
    public var code: String?
    /// Pairs a diagnostic level and message with an optional stable code.
    public init(severity: Severity, message: String, code: String? = nil) {
        self.severity = severity; self.message = message; self.code = code
    }
}
/// Tool content, details, diagnostics, usage, and optional run control.
public struct ToolExecutionResult: Sendable {
    /// The text or content blocks supplied by this result.
    public var content: [ContentBlock]? { didSet { contentIdentity = UUID() } }
    internal var contentIdentity = UUID()
    /// Whether the tool content reports an execution failure.
    public var isError: Bool?
    /// Application-defined JSON details reported by a tool.
    public var details: JSONValue?
    /// The diagnostics reported by this tool call.
    public var diagnostics: [ToolDiagnostic]?
    /// The recorded model or tool token and cost totals.
    public var usage: Usage?
    /// Optional run control returned by the tool.
    public var control: ToolControl?
    /// Creates a tool result with optional content, details, diagnostics, usage, and control.
    public init(content: [ContentBlock]? = nil, isError: Bool? = nil, details: JSONValue? = nil,
                diagnostics: [ToolDiagnostic]? = nil, usage: Usage? = nil, control: ToolControl? = nil) {
        self.content = content; self.isError = isError; self.details = details
        self.diagnostics = diagnostics; self.usage = usage; self.control = control
    }
}

/// Incremental tool output supplied as text or raw bytes.
public enum ToolOutputChunk: Sendable {
    /// Stores text output.
    case text(String)
    /// The byte limit removed output.
    case bytes(Data)
}

/// Tool operations bound to a task invocation.
public struct ToolExecutionApi: Sendable {
    internal var pendingDetailsCount: @Sendable () -> Int = { 0 }
    /// The optional task runtime bound to this tool invocation.
    public var runtime: TaskRuntime?
    /// The ID of the task bound to this value or invocation.
    public var taskId: TaskID
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID
    /// The model-supplied identifier of the tool call.
    public var callId: String
    /// The installed extension and task definitions used by this harness.
    public var registry: RegistrySnapshot
    /// The agent configuration used for this conversation.
    public var agent: @Sendable (ChordContext) async throws -> Agent
    /// The model service used by this harness or task.
    public var models: any DurableModels
    /// The optional execution environment for the conversation.
    public var env: (any ExecutionEnv)?
    /// Document snapshot services available to this hook or renderer.
    public var read: HarnessDocumentReader
    /// Publishes incremental output from this tool invocation.
    public var output: @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void
    /// The requested output window passed to the environment.
    public var outputWindow: ShellOutputWindow?
    /// Publishes a tool diagnostic during execution.
    public var diagnostic: @Sendable (ToolDiagnostic) throws -> Void
    /// Application-defined JSON details reported by a tool.
    public var details: @Sendable (JSONValue, ChordContext) async throws -> Void
    /// A nil candidate reads; a supplied candidate installs only when no value exists.
    public var memo: @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?
    /// Binds tool services and publication callbacks to one task invocation.
    public init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime? = nil,
                agent: @escaping @Sendable (ChordContext) async throws -> Agent,
                output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void = { _, _ in },
                diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void = { _ in },
                details: @escaping @Sendable (JSONValue, ChordContext) async throws -> Void = { _, _ in },
                memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue? = { _, _, _ in nil }) {
        self.runtime = runtime
        self.taskId = taskId; self.conversationId = conversationId; self.callId = callId; self.registry = registry
        self.models = models; self.env = env; self.read = read; self.outputWindow = outputWindow; self.agent = agent
        self.output = output; self.diagnostic = diagnostic; self.details = details; self.memo = memo
    }
    internal init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                  models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                  outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime,
                  lifetime: ToolInvocationLifetime,
                  agent: @escaping @Sendable (ChordContext) async throws -> Agent,
                  output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void,
                  diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void,
                  details: @escaping @Sendable (JSONValue, ChordContext) async throws -> Void,
                  memo: @escaping @Sendable (String, JSONValue?, ChordContext) async throws -> JSONValue?) {
        let check: @Sendable () throws -> Void = {
            try runtime.invocation.check()
        }
        self.init(taskId: taskId, conversationId: conversationId, callId: callId, registry: registry,
                  models: models, env: env, read: toolBoundReader(read, check: check),
                  outputWindow: outputWindow, runtime: runtime,
                  agent: { context in try check(); return try await agent(context) },
                  output: { chunk, skipped in try lifetime.check(); try check(); try output(chunk, skipped) },
                  diagnostic: { value in try lifetime.check(); try check(); try diagnostic(value) },
                  details: { value, context in try lifetime.check(); try check(); try await details(value, context) },
                  memo: { name, candidate, context in try check(); return try await memo(name, candidate, context) })
    }

}

/// A tool declaration and execution callback with replay and output policies.
public struct ToolRegistration: Sendable {
    /// The model-facing tool name, description, and argument schema.
    public var declaration: AITool {
        didSet {
            orderedDeclaration["name"] = .string(declaration.name)
            orderedDeclaration["description"] = .string(declaration.description)
        }
    }
    /// Full declaration with the original JSON member order, including nested schema objects.
    public var orderedDeclaration: JSONObject
    /// An optional override of the tool replay policy.
    public var replay: ToolReplay?
    /// An optional per-tool execution policy.
    public var executionMode: ToolExecutionMode?
    /// An optional repair callback applied before tool argument validation.
    public var prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)?
    /// Optional per-tool limits for retained output.
    public var outputLimits: OutputLimitOverrides?
    /// The caller supplies repaired and validated arguments. defineTool also checks at the typed boundary.
    public var execute: @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
    /// The stable name used to resolve this definition in the registry.
    public var name: String { get { declaration.name } set { declaration.name = newValue; orderedDeclaration["name"] = .string(newValue) } }
    /// Text that describes this value or error to the caller.
    public var description: String { get { declaration.description } set { declaration.description = newValue; orderedDeclaration["description"] = .string(newValue) } }
    /// Updates the schema without losing its JSON member order.
    public mutating func setParameters(_ parameters: JSONObject) throws {
        let dictionary = try foundationJSON(from: .object(parameters)) as! [String: Any]
        declaration.parameters = dictionary.mapValues(AnyCodable.init)
        orderedDeclaration["parameters"] = .object(parameters)
    }
    /// Reflects direct AITool edits. Retained schema members keep their prior order.
    /// New members of a dictionary-only edit use the deterministic bridge order.
    public func currentOrderedDeclaration() throws -> JSONObject {
        let encoded = try DurableToolDeclaration(declaration).json
        guard case .object(let object) = mergeDeclarationOrder(old: .object(orderedDeclaration), new: .object(encoded)) else {
            preconditionFailure("The tool declaration is an object")
        }
        return object
    }
    /// Creates a tool declaration and its execution callback, preserving schema member order.
    public init(declaration: AITool, orderedDeclaration: JSONObject? = nil,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult) throws {
        self.declaration = declaration
        self.orderedDeclaration = try orderedDeclaration ?? JSONObject([
            ("name", .string(declaration.name)), ("description", .string(declaration.description)),
            ("parameters", durableJSON(fromFoundation: declaration.parameters.mapValues(\.value)))])
        self.replay = replay; self.executionMode = executionMode; self.prepareArguments = prepareArguments
        self.outputLimits = outputLimits; self.execute = execute
    }
    /// Creates a tool declaration and its execution callback, preserving schema member order.
    public init(name: String, description: String, parameters: JSONObject,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult) throws {
        let dictionary = try foundationJSON(from: .object(parameters)) as! [String: Any]
        try self.init(declaration: AITool(name: name, description: description, parameters: dictionary.mapValues(AnyCodable.init)),
            orderedDeclaration: ["name": .string(name), "description": .string(description), "parameters": .object(parameters)],
            replay: replay, executionMode: executionMode, prepareArguments: prepareArguments,
            outputLimits: outputLimits, execute: execute)
    }
}

private func mergeDeclarationOrder(old: JSONValue, new: JSONValue) -> JSONValue {
    switch (old, new) {
    case let (.object(previous), .object(current)):
        var result = JSONObject()
        for (key, value) in previous {
            if let replacement = current[key] { result[key] = mergeDeclarationOrder(old: value, new: replacement) }
        }
        for (key, value) in current where previous[key] == nil { result[key] = value }
        return .object(result)
    case let (.array(previous), .array(current)):
        return .array(current.enumerated().map { index, value in
            index < previous.count ? mergeDeclarationOrder(old: previous[index], new: value) : value
        })
    default: return new
    }
}

/// Per-tool overrides merge with the harness output limits.
public struct OutputLimitOverrides: Sendable, Equatable {
    /// The maximum UTF-8 byte count to retain.
    public var maxBytes: Int?
    /// The maximum number of lines to retain.
    public var maxLines: Int?
    /// Which end of output remains when limits remove content.
    public var retain: OutputRetention?
    /// Selects per-tool byte, line, and retention overrides.
    public init(maxBytes: Int? = nil, maxLines: Int? = nil, retain: OutputRetention? = nil) {
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.retain = retain
    }
}

/// Creates a tool that validates its schema arguments before decoding them for execution.
public func defineTool<Args: Decodable & Sendable>(
    name: String, description: String, parameters: JSONObject, args: Args.Type = Args.self,
    replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
    prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
    outputLimits: OutputLimitOverrides? = nil,
    execute: @escaping @Sendable (Args, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult
) throws -> ToolRegistration {
    let schema = try foundationJSON(from: .object(parameters)) as! [String: Any]
    let declaration = AITool(name: name, description: description, parameters: schema.mapValues(AnyCodable.init))
    return try ToolRegistration(name: name, description: description, parameters: parameters,
        replay: replay, executionMode: executionMode, prepareArguments: prepareArguments,
        outputLimits: outputLimits) { value, api, context in
            guard let object = try foundationJSON(from: value) as? [String: Any] else {
                throw HarnessDefinitionError.argumentsMustBeObject(name)
            }
            let call = ToolCall(id: api.callId, name: name, arguments: object.mapValues(AnyCodable.init))
            let checked = try PiSwiftAI.validateToolArguments(tool: declaration, toolCall: call)
            let decoded = try JSONDecoder().decode(Args.self, from: JSONEncoder().encode(checked))
            return try await execute(decoded, api, context)
        }
}
