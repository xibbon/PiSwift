import Foundation
import PiSwiftAI
import PiSwiftChord

public struct ToolControl: Sendable, Equatable, Codable {
    public var addTools: [String]?
    public var terminate: Bool?
    public var handoff: String?
    public init(addTools: [String]? = nil, terminate: Bool? = nil, handoff: String? = nil) {
        self.addTools = addTools; self.terminate = terminate; self.handoff = handoff
    }
}
public struct ToolDiagnostic: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable { case info, warn, error }
    public var severity: Severity
    public var message: String
    public var code: String?
    public init(severity: Severity, message: String, code: String? = nil) {
        self.severity = severity; self.message = message; self.code = code
    }
}
public struct ToolExecutionResult: Sendable {
    public var content: [ContentBlock]? { didSet { contentIdentity = UUID() } }
    internal var contentIdentity = UUID()
    public var isError: Bool?
    public var details: JSONValue?
    public var diagnostics: [ToolDiagnostic]?
    public var usage: Usage?
    public var control: ToolControl?
    public init(content: [ContentBlock]? = nil, isError: Bool? = nil, details: JSONValue? = nil,
                diagnostics: [ToolDiagnostic]? = nil, usage: Usage? = nil, control: ToolControl? = nil) {
        self.content = content; self.isError = isError; self.details = details
        self.diagnostics = diagnostics; self.usage = usage; self.control = control
    }
}

public enum ToolOutputChunk: Sendable { case text(String), bytes(Data) }

/// Tool operations bound to a task invocation.
public struct ToolExecutionApi: Sendable {
    internal var pendingDetailsCount: @Sendable () -> Int = { 0 }
    public var runtime: TaskRuntime?
    public var taskId: TaskID
    public var conversationId: ConversationID
    public var callId: String
    public var registry: RegistrySnapshot
    public var agent: @Sendable (PiSwiftChord.Context) async throws -> Agent
    public var models: any DurableModels
    public var env: (any ExecutionEnv)?
    public var read: HarnessDocumentReader
    public var output: @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void
    public var outputWindow: ShellOutputWindow?
    public var diagnostic: @Sendable (ToolDiagnostic) throws -> Void
    public var details: @Sendable (JSONValue, PiSwiftChord.Context) async throws -> Void
    /// A nil candidate reads; a supplied candidate installs only when no value exists.
    public var memo: @Sendable (String, JSONValue?, PiSwiftChord.Context) async throws -> JSONValue?
    public init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime? = nil,
                agent: @escaping @Sendable (PiSwiftChord.Context) async throws -> Agent,
                output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void = { _, _ in },
                diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void = { _ in },
                details: @escaping @Sendable (JSONValue, PiSwiftChord.Context) async throws -> Void = { _, _ in },
                memo: @escaping @Sendable (String, JSONValue?, PiSwiftChord.Context) async throws -> JSONValue? = { _, _, _ in nil }) {
        self.runtime = runtime
        self.taskId = taskId; self.conversationId = conversationId; self.callId = callId; self.registry = registry
        self.models = models; self.env = env; self.read = read; self.outputWindow = outputWindow; self.agent = agent
        self.output = output; self.diagnostic = diagnostic; self.details = details; self.memo = memo
    }
    internal init(taskId: TaskID, conversationId: ConversationID, callId: String, registry: RegistrySnapshot,
                  models: any DurableModels, env: (any ExecutionEnv)? = nil, read: HarnessDocumentReader = .init(),
                  outputWindow: ShellOutputWindow? = nil, runtime: TaskRuntime,
                  lifetime: ToolInvocationLifetime,
                  agent: @escaping @Sendable (PiSwiftChord.Context) async throws -> Agent,
                  output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void,
                  diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void,
                  details: @escaping @Sendable (JSONValue, PiSwiftChord.Context) async throws -> Void,
                  memo: @escaping @Sendable (String, JSONValue?, PiSwiftChord.Context) async throws -> JSONValue?) {
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

public struct ToolRegistration: Sendable {
    public var declaration: AITool {
        didSet {
            orderedDeclaration["name"] = .string(declaration.name)
            orderedDeclaration["description"] = .string(declaration.description)
        }
    }
    /// Full declaration with the original JSON member order, including nested schema objects.
    public var orderedDeclaration: JSONObject
    public var replay: ToolReplay?
    public var executionMode: ToolExecutionMode?
    public var prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)?
    public var outputLimits: OutputLimitOverrides?
    /// The caller supplies repaired and validated arguments. defineTool also checks at the typed boundary.
    public var execute: @Sendable (JSONValue, ToolExecutionApi, PiSwiftChord.Context) async throws -> ToolExecutionResult
    public var name: String { get { declaration.name } set { declaration.name = newValue; orderedDeclaration["name"] = .string(newValue) } }
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
    public init(declaration: AITool, orderedDeclaration: JSONObject? = nil,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, PiSwiftChord.Context) async throws -> ToolExecutionResult) throws {
        self.declaration = declaration
        self.orderedDeclaration = try orderedDeclaration ?? JSONObject([
            ("name", .string(declaration.name)), ("description", .string(declaration.description)),
            ("parameters", durableJSON(fromFoundation: declaration.parameters.mapValues(\.value)))])
        self.replay = replay; self.executionMode = executionMode; self.prepareArguments = prepareArguments
        self.outputLimits = outputLimits; self.execute = execute
    }
    public init(name: String, description: String, parameters: JSONObject,
                replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
                prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                outputLimits: OutputLimitOverrides? = nil,
                execute: @escaping @Sendable (JSONValue, ToolExecutionApi, PiSwiftChord.Context) async throws -> ToolExecutionResult) throws {
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
    public var maxBytes: Int?
    public var maxLines: Int?
    public var retain: OutputRetention?
    public init(maxBytes: Int? = nil, maxLines: Int? = nil, retain: OutputRetention? = nil) {
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.retain = retain
    }
}

public func defineTool<Args: Decodable & Sendable>(
    name: String, description: String, parameters: JSONObject, args: Args.Type = Args.self,
    replay: ToolReplay? = nil, executionMode: ToolExecutionMode? = nil,
    prepareArguments: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
    outputLimits: OutputLimitOverrides? = nil,
    execute: @escaping @Sendable (Args, ToolExecutionApi, PiSwiftChord.Context) async throws -> ToolExecutionResult
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
