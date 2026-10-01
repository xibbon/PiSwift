import Foundation
import PiSwiftAI
import PiSwiftAgent

public let CODEMODE_TOOL_NAME = "codemode"
public let CODEMODE_STORE_ENTRY_TYPE = "codemode-store"

public struct CodemodeStoreEntryData: Sendable {
    public var set: [String: AnyCodable]
    public var delete: [String]

    public init(set: [String: AnyCodable], delete: [String]) {
        self.set = set
        self.delete = delete
    }
}

public struct CodemodeToolOptions: Sendable {
    public var models: Bool
    public var getToolNamespace: (@Sendable (String) -> ToolNamespace?)?
    public var appendEntry: (@Sendable (String, CodemodeStoreEntryData) -> Void)?
    public var getMode: (@Sendable () -> CodemodeMode)?
    public var getInlineBudget: (@Sendable () -> Double?)?
    /// A test can supply a model runtime without a full session.
    public var modelRuntime: (any CodemodeModelRuntime)?

    public init(models: Bool = false,
                getToolNamespace: (@Sendable (String) -> ToolNamespace?)? = nil,
                appendEntry: (@Sendable (String, CodemodeStoreEntryData) -> Void)? = nil,
                getMode: (@Sendable () -> CodemodeMode)? = nil,
                getInlineBudget: (@Sendable () -> Double?)? = nil,
                modelRuntime: (any CodemodeModelRuntime)? = nil) {
        self.models = models
        self.getToolNamespace = getToolNamespace
        self.appendEntry = appendEntry
        self.getMode = getMode
        self.getInlineBudget = getInlineBudget
        self.modelRuntime = modelRuntime
    }
}

public func getCodemodeCallableTools(_ tools: [AgentTool]) -> [AgentTool] {
    tools.filter { $0.name != CODEMODE_TOOL_NAME }
}

public func isCodemodeTool(_ tool: ToolInfo) -> Bool {
    tool.name == CODEMODE_TOOL_NAME && tool.sourceInfo?.path == "builtin:codemode"
}

private func codemodeDescriptionOptions(_ options: CodemodeToolOptions,
                                        namespaces: [String: ToolNamespace] = [:],
                                        deferred: Set<String> = []) -> CodemodeDescriptionOptions {
    CodemodeDescriptionOptions(
        models: options.models,
        namespaces: namespaces,
        deferred: deferred,
        inlineBudget: options.getInlineBudget?() ?? defaultCodemodeInlineBudget,
        memoryLimitSentence: nil)
}

public func prepareCodemodeLoadout(_ loadout: ToolLoadout,
                                   options: CodemodeToolOptions = .init()) -> ToolLoadoutChanges {
    let mode = options.getMode?() ?? .on
    let callable = getCodemodeCallableTools(loadout.callable)
    let callableNames = Set(callable.map(\.name))
    var descriptions: [String: String] = [:]
    if mode == .on {
        for tool in loadout.declared where callableNames.contains(tool.name) {
            descriptions[tool.name] = renderToolSample(CodemodeDeclaration(tool: tool))
        }
    }
    let listed = mode == .only ? callable : callable.filter { loadout.getExposure($0.name) != .direct }
    let namespaces = Dictionary(uniqueKeysWithValues: listed.compactMap { tool -> (String, ToolNamespace)? in
        loadout.getNamespace(tool.name).map { (tool.name, $0) }
    })
    let deferred = Set(listed.filter { loadout.getExposure($0.name) == .deferred }.map(\.name))
    descriptions[CODEMODE_TOOL_NAME] = createCodemodeDescription(
        listed, options: codemodeDescriptionOptions(options, namespaces: namespaces, deferred: deferred))
    let declaredNames = Set(loadout.declared.map(\.name))
    let hidden = mode == .only ? callable.filter {
        loadout.getExposure($0.name) == .direct && declaredNames.contains($0.name)
    }.map(\.name) : []
    return ToolLoadoutChanges(descriptions: descriptions, hiddenDeclarations: hidden)
}

public func createCodemodeToolDefinition(options: CodemodeToolOptions = .init()) -> CustomTool {
    CustomTool(
        name: CODEMODE_TOOL_NAME,
        label: CODEMODE_TOOL_NAME,
        description: createCodemodeDescription([], options: codemodeDescriptionOptions(options)),
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["code": [
                "type": "string",
                "description": "Raw JavaScript source. Top-level await and return work. May start with a `// @options: {\"max_output_tokens\": 1000}` line."
            ]]),
            "required": AnyCodable(["code"])
        ],
        execute: { toolCallId, params, onUpdate, context, signal in
            try await executeCodemode(toolCallId: toolCallId, params: params, signal: signal,
                                      onUpdate: onUpdate, context: context, options: options)
        },
        promptGuidelines: ["Use codemode to batch or chain several tool calls, or to filter large tool output down to what you need, instead of issuing many individual tool calls. Batch independent calls in one codemode call using await Promise.allSettled([...])."],
        promptSnippet: "Run JavaScript that calls other tools (chains, loops, Promise.all, filtering large results)",
        constrainedSampling: codemodeConstrainedSampling,
        exposure: .modelOnly,
        defaultActive: false,
        prepareLoadout: { loadout in prepareCodemodeLoadout(loadout, options: options) })
}

/// A standalone AgentTool can run scripts without a session. Its nested tool catalog is descriptive;
/// the agent loop supplies callable tools through its context when one is present.
public func createCodemodeTool(_ tools: [AgentTool] = [], options: CodemodeToolOptions = .init()) -> AgentTool {
    let definition = createCodemodeToolDefinition(options: options)
    return AgentTool(
        label: definition.label, name: definition.name,
        description: createCodemodeDescription(tools, options: codemodeDescriptionOptions(options)),
        parameters: definition.parameters ?? [:],
        execute: { id, params, signal, onUpdate in
            try await executeCodemode(toolCallId: id, params: params, signal: signal,
                                      onUpdate: onUpdate, context: nil, options: options)
        },
        constrainedSampling: definition.constrainedSampling,
        outputSchema: definition.outputSchema)
}
