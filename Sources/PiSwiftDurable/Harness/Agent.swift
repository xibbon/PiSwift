import PiSwiftAI
import PiSwiftChord

public let instructionsKey = "instructions"

public enum ExtensionSelection: Sendable, Equatable, Codable {
    case exact([String])
    case edit(add: [String]? = nil, remove: [String]? = nil)
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let names = try? single.decode([String].self) { self = .exact(names); return }
        let object = try decoder.container(keyedBy: Keys.self)
        self = .edit(add: try object.decodeIfPresent([String].self, forKey: .add),
                     remove: try object.decodeIfPresent([String].self, forKey: .remove))
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .exact(names): var c = encoder.singleValueContainer(); try c.encode(names)
        case let .edit(add, remove):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(add, forKey: .add); try c.encodeIfPresent(remove, forKey: .remove)
        }
    }
    private enum Keys: String, CodingKey { case add, remove }
}
public enum ToolSelection: Sendable, Equatable, Codable {
    case exact([String])
    case remove([String])
    public init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let names = try? single.decode([String].self) { self = .exact(names); return }
        let object = try decoder.container(keyedBy: Keys.self)
        self = .remove(try object.decode([String].self, forKey: .remove))
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .exact(names): var c = encoder.singleValueContainer(); try c.encode(names)
        case let .remove(names): var c = encoder.container(keyedBy: Keys.self); try c.encode(names, forKey: .remove)
        }
    }
    private enum Keys: String, CodingKey { case remove }
}

/// The pi.agent document value. D4/H5 adds its rewindable, asOf document token.
public struct AgentState: Sendable, Equatable, Codable {
    public var model: ModelRef?
    public var thinkingLevel: ModelThinkingLevel?
    public var extensions: ExtensionSelection?
    public var tools: ToolSelection?
    public var instructions: String?
    public var cwd: String?
    public init(model: ModelRef? = nil, thinkingLevel: ModelThinkingLevel? = nil,
                extensions: ExtensionSelection? = nil, tools: ToolSelection? = nil,
                instructions: String? = nil, cwd: String? = nil) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.instructions = instructions; self.cwd = cwd
    }
}

/// Source undefined leaves a field alone; null clears it; a value replaces it.
public enum AgentFieldChange<Value: Sendable>: Sendable { case unchanged, clear, set(Value) }
public enum ExtensionChange: Sendable { case exact([Extension]); case edit(add: [Extension]? = nil, remove: [Extension]? = nil) }
public enum ToolChange: Sendable { case exact([ToolRegistration]); case remove([ToolRegistration]) }
public struct AgentChange: Sendable {
    public var model: AgentFieldChange<ModelRef>
    public var thinkingLevel: AgentFieldChange<ModelThinkingLevel>
    public var extensions: AgentFieldChange<ExtensionChange>
    public var tools: AgentFieldChange<ToolChange>
    public var instructions: AgentFieldChange<String>
    public var cwd: AgentFieldChange<String>
    public init(model: AgentFieldChange<ModelRef> = .unchanged, thinkingLevel: AgentFieldChange<ModelThinkingLevel> = .unchanged,
                extensions: AgentFieldChange<ExtensionChange> = .unchanged, tools: AgentFieldChange<ToolChange> = .unchanged,
                instructions: AgentFieldChange<String> = .unchanged, cwd: AgentFieldChange<String> = .unchanged) {
        self.model = model; self.thinkingLevel = thinkingLevel; self.extensions = extensions
        self.tools = tools; self.instructions = instructions; self.cwd = cwd
    }
}

public func applyAgentChange(_ state: inout AgentState, _ change: AgentChange) {
    apply(&state.model, change.model); apply(&state.thinkingLevel, change.thinkingLevel)
    switch change.extensions {
    case .unchanged: break
    case .clear: state.extensions = nil
    case .set(.exact(let items)): state.extensions = .exact(items.map(\.name))
    case .set(.edit(let add, let remove)): state.extensions = .edit(add: add?.map(\.name), remove: remove?.map(\.name))
    }
    switch change.tools {
    case .unchanged: break
    case .clear: state.tools = nil
    case .set(.exact(let items)): state.tools = .exact(items.map(\.name))
    case .set(.remove(let items)): state.tools = .remove(items.map(\.name))
    }
    apply(&state.instructions, change.instructions); apply(&state.cwd, change.cwd)
}
private func apply<Value>(_ value: inout Value?, _ change: AgentFieldChange<Value>) {
    switch change { case .unchanged: break; case .clear: value = nil; case .set(let next): value = next }
}
public func addAgentTools(_ state: inout AgentState, _ added: [String]) {
    switch state.tools {
    case nil: break
    case .exact(var names):
        for name in added where !names.contains(where: { harnessNamesEqual($0, name) }) { names.append(name) }
        state.tools = .exact(names)
    case .remove(let names):
        let removed = names.filter { name in !added.contains { harnessNamesEqual($0, name) } }
        if removed.count != names.count { state.tools = .remove(removed) }
    }
}

public func agentHooks(_ agent: Agent, taskName: String) -> [HookRegistration] {
    agent.extensions.flatMap(\.hooks).filter { harnessNamesEqual($0.task, taskName) }
}
public func agentHooks<Handlers: Sendable>(_ agent: Agent, taskName: String, as type: Handlers.Type) -> [Handlers] {
    agentHooks(agent, taskName: taskName).compactMap { $0.handlers(as: type) }
}

public func resolveAgent(state: AgentState? = nil, snapshot: RegistrySnapshot, settings: Settings = resolveSettings(),
                         report: (any Error) -> Void = { _ in }) -> Agent {
    let selected: [String]
    switch state?.extensions {
    case .exact(let names): selected = names
    case .edit(let add, let remove):
        selected = ((settings.extensions ?? snapshot.installed()).map(\.name) + (add ?? [])).filter { name in
            !(remove ?? []).contains { harnessNamesEqual($0, name) }
        }
    case nil: selected = (settings.extensions ?? snapshot.installed()).map(\.name)
    }
    let extensions = uniqueHarnessNames(selected).compactMap { snapshot.extension(name: $0) }
    var tools: [ToolRegistration] = []
    var sections: [PromptSection] = []
    for extensionValue in extensions {
        for tool in extensionValue.tools {
            if let index = tools.firstIndex(where: { harnessNamesEqual($0.name, tool.name) }) { tools[index] = tool }
            else { tools.append(tool) }
        }
        for section in extensionValue.sections {
            if let index = sections.firstIndex(where: { harnessNamesEqual($0.key, section.key) }) { sections[index] = section }
            else { sections.append(section) }
        }
    }
    for extensionValue in extensions {
        for wrap in extensionValue.wraps {
            switch wrap {
            case let .tool(name, transform):
                applyWrap(&tools, name: name, nameOf: { $0.name }, transform: transform, report: report)
            case let .section(key, transform):
                applyWrap(&sections, name: key, nameOf: { $0.key }, transform: transform, report: report)
            }
        }
    }
    switch state?.tools {
    case nil: break
    case .exact(let names): tools = uniqueHarnessNames(names).compactMap { name in tools.first { harnessNamesEqual($0.name, name) } }
    case .remove(let names): tools = tools.filter { tool in !names.contains { harnessNamesEqual($0, tool.name) } }
    }
    if let instructions = state?.instructions { sections.append(section(instructionsKey) { _, _ in instructions }) }
    return Agent(model: state?.model, thinkingLevel: state?.thinkingLevel ?? .off, extensions: extensions,
                 tools: tools, sections: sections, instructions: state?.instructions, cwd: state?.cwd)
}

private func applyWrap<Value>(_ values: inout [Value], name: String, nameOf: (Value) -> String,
                              transform: (Value) throws -> Value, report: (any Error) -> Void) {
    guard let index = values.firstIndex(where: { harnessNamesEqual(nameOf($0), name) }) else { return }
    do {
        let changed = try transform(values[index])
        guard harnessNamesEqual(nameOf(changed), name) else { throw HarnessDefinitionError.renamedWrapper(target: name, name: nameOf(changed)) }
        values[index] = changed
    } catch { values.remove(at: index); report(error) }
}
func harnessNamesEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
private func uniqueHarnessNames(_ values: [String]) -> [String] {
    var seen = Set<[UInt16]>()
    return values.filter { seen.insert(Array($0.utf16)).inserted }
}
