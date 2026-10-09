import PiSwiftAI
import PiSwiftChord

/// Ordered tool declaration. AITool alone cannot retain JSON Schema member order.
public struct DurableToolDeclaration: Sendable {
    public let declaration: AITool
    public let json: JSONObject
    public init(declaration: AITool, json: JSONObject) { self.declaration = declaration; self.json = json }
    public init(name: String, description: String, parameters: JSONObject) throws {
        let fields: JSONObject = ["name": .string(name), "description": .string(description), "parameters": .object(parameters)]
        self = try Self(json: fields)
    }
    public init(json: JSONObject) throws {
        let wrapper = SystemMessage(content: .text(""), timestamp: 0)
        var message = try durableJSON(fromOrdered: systemMessageToOrderedJSON(wrapper)).objectValue!
        message["toolsAdded"] = .array([.object(json)])
        guard let decoded = messageFromJSONObject(try foundationJSON(from: .object(message)) as! [String: Any], ordered: try orderedJSON(from: .object(message))),
              case .system(let system) = decoded, let tool = system.toolsAdded?.first else {
            throw DurableJSONBridgeError.invalidMessage(index: 0)
        }
        declaration = tool; self.json = json
    }
    /// This adapter uses the deterministic order supplied by PiSwiftAI's encoder.
    /// Use the JSON initializer when source key order is part of the declaration.
    public init(_ declaration: AITool) throws {
        let message = SystemMessage(content: .text(""), toolsAdded: [declaration], timestamp: 0)
        let raw = try durableJSON(fromOrdered: systemMessageToOrderedJSON(message))
        self.init(declaration: declaration, json: raw["toolsAdded"]![0]!.objectValue!)
    }
}

/// Upstream compares JSON.stringify text. CH1 keeps object member order.
public func durableDeclarationsEqual(_ left: DurableToolDeclaration, _ right: DurableToolDeclaration) throws -> Bool {
    try left.json.jsonText().utf16.elementsEqual(right.json.jsonText().utf16)
}

/// Replays section updates in place. Null removes a key; re-addition appends it.
public func replaySections(_ messages: [Message]) -> JSONObject {
    var shown = JSONObject()
    for message in messages {
        guard case .system(let system) = message else { continue }
        for entry in system.sections?.entries ?? [] {
            if let value = entry.value { shown[entry.name] = .string(value) }
            else { shown.removeValue(forKey: entry.name) }
        }
    }
    return shown
}

/// Renders sections in order. A failure keeps the shown value and is reported.
/// A render failure after context cancellation is thrown to the caller.
public func renderSections(
    _ sections: [PromptSection], input: PromptInput, shown: JSONObject,
    report: @Sendable (any Error) -> Void = { _ in }, context: ChordContext
) async throws -> JSONObject {
    var desired = JSONObject()
    for section in sections {
        let text: String?
        do { text = try await section.render(input, context) }
        catch {
            if context.abortSignal?.aborted == true { throw error }
            report(error)
            if let kept = shown[section.key] { desired[section.key] = kept }
            continue
        }
        guard let text else { continue }
        desired[section.key] = .string(section.tag == false ? text : "<\(section.key)>\n\(text)\n</\(section.key)>")
    }
    return desired
}

/// Plans positional system entries. Tool changes are placed on the last section entry.
/// Desired section values must be strings; null is only used in emitted patches.
public func planSystemEntries(view: ContextView, desired: JSONObject, tools: [DurableToolDeclaration], timestamp: Int64) throws -> [EntryDraft] {
    for (_, value) in desired { guard case .string = value else { throw PromptPlanError.nonStringSection } }
    if let head = view.head, !view.entries.contains(where: { systemEntry.matches($0) && $0.id > head.id }) {
        let edits = view.entries.filter { systemEntry.matches($0) }.map { ContextEdit.omit(target: $0.id) }
        return [try plannedSystem(sections: desired, added: tools, removed: [], timestamp: timestamp, edits: edits.isEmpty ? nil : edits)]
    }
    let patches = planSectionPatches(shown: replaySections(view.messages), desired: desired)
    let offered = try currentDeclarations(view)
    let wanted = Dictionary(tools.map { (Array($0.declaration.name.utf16), $0) }, uniquingKeysWith: { _, new in new })
    let kept = try offered.filter { old in
        guard let next = wanted[Array(old.declaration.name.utf16)] else { return false }
        return try durableDeclarationsEqual(old, next)
    }
    let keptNames = Set(kept.map { Array($0.declaration.name.utf16) })
    var added = tools.filter { !keptNames.contains(Array($0.declaration.name.utf16)) }
    var removed = offered.filter { !keptNames.contains(Array($0.declaration.name.utf16)) }.map { ToolReference(name: $0.declaration.name) }
    if (kept + added).map({ Array($0.declaration.name.utf16) }) != tools.map({ Array($0.declaration.name.utf16) }) {
        removed = offered.map { ToolReference(name: $0.declaration.name) }; added = tools
    }
    if patches.isEmpty {
        return added.isEmpty && removed.isEmpty ? [] : [try plannedSystem(sections: nil, added: added, removed: removed, timestamp: timestamp)]
    }
    return try patches.enumerated().map { index, patch in
        try plannedSystem(sections: patch, added: index == patches.count - 1 ? added : [], removed: index == patches.count - 1 ? removed : [], timestamp: timestamp)
    }
}

/// Adapter for model declarations that have no source JSON member order.
public func planSystemEntries(view: ContextView, desired: JSONObject, tools: [AITool], timestamp: Int64) throws -> [EntryDraft] {
    try planSystemEntries(view: view, desired: desired, tools: tools.map(DurableToolDeclaration.init), timestamp: timestamp)
}

public enum PromptPlanError: Error, Sendable { case nonStringSection }

private func planSectionPatches(shown: JSONObject, desired: JSONObject) -> [JSONObject] {
    let patchedOrder = shown.keys.filter { desired[$0] != nil } + desired.keys.filter { shown[$0] == nil }
    if patchedOrder.map({ Array($0.utf16) }) != desired.keys.map({ Array($0.utf16) }) {
        return [JSONObject(shown.keys.map { ($0, .null) }), desired]
    }
    var patch = JSONObject()
    for (key, value) in shown where desired[key] != value { patch[key] = desired[key] ?? .null }
    for (key, value) in desired where shown[key] == nil { patch[key] = value }
    return patch.keys.isEmpty ? [] : [patch]
}

private func currentDeclarations(_ view: ContextView) throws -> [DurableToolDeclaration] {
    let raws = try view.rawContributions ?? EntryRecord.encodeMessages(view.messages)
    var tools: [DurableToolDeclaration] = []
    for raw in raws where raw["role"] == .string("system") {
        for removed in raw["toolsRemoved"]?.arrayValue ?? [] {
            guard let name = removed["name"]?.stringValue else { continue }
            tools.removeAll { harnessNamesEqual($0.declaration.name, name) }
        }
        for added in raw["toolsAdded"]?.arrayValue ?? [] {
            guard let json = added.objectValue else { continue }
            let tool = try DurableToolDeclaration(json: json)
            if let at = tools.firstIndex(where: { harnessNamesEqual($0.declaration.name, tool.declaration.name) }) { tools[at] = tool }
            else { tools.append(tool) }
        }
    }
    return tools
}

private func plannedSystem(sections: JSONObject?, added: [DurableToolDeclaration], removed: [ToolReference], timestamp: Int64, edits: [ContextEdit]? = nil) throws -> EntryDraft {
    var raw: JSONObject = ["role": .string("system"), "content": .string("")]
    if let sections { raw["sections"] = .object(sections) }
    if !removed.isEmpty { raw["toolsRemoved"] = .array(removed.map { .object(["name": .string($0.name)]) }) }
    if !added.isEmpty { raw["toolsAdded"] = .array(added.map { .object($0.json) }) }
    raw["timestamp"] = .number(Double(timestamp))
    return EntryDraft(kind: systemEntry.kind, model: [.object(raw)], edits: edits)
}

extension DurableToolDeclaration {
    /// Uses the registration's source JSON Schema order.
    public init(_ registration: ToolRegistration) throws {
        self.init(declaration: registration.declaration, json: try registration.currentOrderedDeclaration())
    }
}

/// Plans the declarations of the resolved tools, with source JSON Schema member order.
public func planSystemEntries(view: ContextView, desired: JSONObject, registrations: [ToolRegistration], timestamp: Int64) throws -> [EntryDraft] {
    try planSystemEntries(view: view, desired: desired, tools: registrations.map(DurableToolDeclaration.init), timestamp: timestamp)
}
