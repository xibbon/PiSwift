import Foundation
import PiSwiftAI
import PiSwiftAgent

public let CODEMODE_TOOL_NAME = "codemode"
public let CODEMODE_STORE_ENTRY_TYPE = "codemode-store"
public let CODEMODE_LATE_CALL_ENTRY_TYPE = "codemode-late-call"

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
    public var searchResultDetail: CodemodeSearchResultDetail
    /// Observe each searchTools, describeTool, and describeNamespace dispatch.
    public var recordDiscoveryCall: (@Sendable (String) -> Void)?
    public var omitInlineOutputSchemas: Bool
    public var inlineEnumValueLimit: Int?
    public var collisionPolicy: ToolNameCollisionPolicy
    public var defaultTimeoutMs: Int?
    public var maxTimeoutMs: Int?
    public var validationErrorPrefix: String?
    public var getDefaultTimeoutMs: (@Sendable () -> Int?)?
    public var getMaxTimeoutMs: (@Sendable () -> Int?)?
    public var getToolNamespace: (@Sendable (String) -> ToolNamespace?)?
    /// Tool rules shown by describeTool(), searchTools(), and ALL_TOOLS.
    public var getToolGuidelines: (@Sendable () -> [String: [String]])?
    public var appendEntry: (@Sendable (String, CodemodeStoreEntryData) -> Void)?
    /// Persist a bounded call update that arrives after the script result.
    public var recordLateCall: (@Sendable (String, CodemodeNestedCall) -> Void)?
    /// How long an execution records calls from a JavaScriptCore thread that the host abandoned.
    public var lateCallWindow: Duration
    public var getMode: (@Sendable () -> CodemodeMode)?
    public var getInlineBudget: (@Sendable () -> Double?)?
    /// A test can supply a model runtime without a full session.
    public var modelRuntime: (any CodemodeModelRuntime)?

    public init(models: Bool = false,
                getToolNamespace: (@Sendable (String) -> ToolNamespace?)? = nil,
                appendEntry: (@Sendable (String, CodemodeStoreEntryData) -> Void)? = nil,
                getMode: (@Sendable () -> CodemodeMode)? = nil,
                getInlineBudget: (@Sendable () -> Double?)? = nil,
                modelRuntime: (any CodemodeModelRuntime)? = nil,
                getToolGuidelines: (@Sendable () -> [String: [String]])? = nil,
                collisionPolicy: ToolNameCollisionPolicy = .overwrite,
                defaultTimeoutMs: Int? = nil,
                maxTimeoutMs: Int? = nil,
                validationErrorPrefix: String? = nil,
                getDefaultTimeoutMs: (@Sendable () -> Int?)? = nil,
                getMaxTimeoutMs: (@Sendable () -> Int?)? = nil,
                recordLateCall: (@Sendable (String, CodemodeNestedCall) -> Void)? = nil,
                omitInlineOutputSchemas: Bool = false,
                inlineEnumValueLimit: Int? = nil,
                lateCallWindow: Duration = .seconds(60),
                searchResultDetail: CodemodeSearchResultDetail = .full,
                recordDiscoveryCall: (@Sendable (String) -> Void)? = nil) {
        self.models = models
        self.searchResultDetail = searchResultDetail
        self.recordDiscoveryCall = recordDiscoveryCall
        self.lateCallWindow = lateCallWindow
        self.omitInlineOutputSchemas = omitInlineOutputSchemas
        self.inlineEnumValueLimit = inlineEnumValueLimit.map { max(0, $0) }
        self.collisionPolicy = collisionPolicy
        self.defaultTimeoutMs = defaultTimeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.validationErrorPrefix = validationErrorPrefix
        self.getDefaultTimeoutMs = getDefaultTimeoutMs
        self.getMaxTimeoutMs = getMaxTimeoutMs
        self.getToolNamespace = getToolNamespace
        self.getToolGuidelines = getToolGuidelines
        self.appendEntry = appendEntry
        self.recordLateCall = recordLateCall
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
                                        deferred: Set<String> = [],
                                        guidelines: [String: [String]] = [:]) -> CodemodeDescriptionOptions {
    CodemodeDescriptionOptions(
        models: options.models,
        namespaces: namespaces,
        deferred: deferred,
        inlineBudget: options.getInlineBudget?() ?? defaultCodemodeInlineBudget,
        guidelines: guidelines,
        omitInlineOutputSchemas: options.omitInlineOutputSchemas,
        inlineEnumValueLimit: options.inlineEnumValueLimit,
        searchResultDetail: options.searchResultDetail)
}

private func describeFields(_ schema: Any?, depth: Int) -> String? {
    guard let fields = schema as? [String: Any], fields["type"] as? String == "object",
          let properties = fields["properties"] as? [String: Any] else { return nil }
    let required = Set(fields["required"] as? [String] ?? [])
    let names = properties.keys.sorted().map { name in
        let nested = depth > 0 ? describeFields(properties[name], depth: depth - 1) : nil
        return name + (required.contains(name) ? "" : "?") + (nested.map { ": " + $0 } ?? "")
    }
    return "{ \(names.joined(separator: ", ")) }"
}

private func describeScriptCall(_ tool: AgentTool) -> String {
    let schema = CodemodeDeclaration(tool: tool).outputSchema
    let type = renderToolOutputType(schema)
    let output: String
    if type == "string" { output = "a string" }
    else if let fields = describeFields(schema?.value, depth: 1) {
        output = "`\(fields)`"
    } else { output = "`\(type.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))`" }
    return tool.description.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nCodemode: `tools.\(toCodemodeIdentifier(tool.name))(args)` resolves to \(output)."
}

public func prepareCodemodeLoadout(_ loadout: ToolLoadout,
                                   options: CodemodeToolOptions = .init()) -> ToolLoadoutChanges {
    let mode = options.getMode?() ?? .on
    let callable = getCodemodeCallableTools(loadout.callable)
    let callableNames = Set(callable.map(\.name))
    var descriptions: [String: String] = [:]
    if mode == .on {
        for tool in loadout.declared where callableNames.contains(tool.name) {
            descriptions[tool.name] = describeScriptCall(tool)
        }
    }
    let listed = mode == .only ? callable : callable.filter { loadout.getExposure($0.name) != .direct }
    let namespaces = Dictionary(uniqueKeysWithValues: listed.compactMap { tool -> (String, ToolNamespace)? in
        loadout.getNamespace(tool.name).map { (tool.name, $0) }
    })
    let deferred = Set(listed.filter { loadout.getExposure($0.name) == .deferred }.map(\.name))
    let guidelines = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, loadout.getPromptGuidelines($0.name)) })
    descriptions[CODEMODE_TOOL_NAME] = createCodemodeDescription(
        listed, options: codemodeDescriptionOptions(options, namespaces: namespaces, deferred: deferred, guidelines: guidelines))
    let declaredNames = Set(loadout.declared.map(\.name))
    let hidden = mode == .only ? callable.filter {
        loadout.getExposure($0.name) == .direct && declaredNames.contains($0.name)
    }.map(\.name) : []
    return ToolLoadoutChanges(descriptions: descriptions, hiddenDeclarations: hidden)
}

private func codemodeScriptReach(_ input: [String: AnyCodable]) -> ToolReach {
    guard let code = input["code"]?.value as? String else { return .words([]) }
    // JavaScript's \w and \b use ASCII word characters here.
    let wordCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    let words = code.components(separatedBy: wordCharacters.inverted).filter { !$0.isEmpty }
    let discovery = Set(["searchTools", "describeNamespace", "describeTool", "ALL_TOOLS"])
    return words.contains(where: discovery.contains) ? .all : .words(words)
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
                "description": "Raw JavaScript source."
            ]]),
            "required": AnyCodable(["code"])
        ],
        execute: { toolCallId, params, onUpdate, context, signal in
            try await executeCodemode(toolCallId: toolCallId, params: params, signal: signal,
                                      onUpdate: onUpdate, context: context, options: options)
        },
        promptGuidelines: ["Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls."],
        promptSnippet: "Run JavaScript that calls other tools",
        constrainedSampling: codemodeConstrainedSampling,
        exposure: .modelOnly,
        defaultActive: false,
        prepareLoadout: { loadout in prepareCodemodeLoadout(loadout, options: options) },
        reachesTools: { codemodeScriptReach($0) })
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
