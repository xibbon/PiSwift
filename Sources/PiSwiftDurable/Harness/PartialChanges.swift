import PiSwiftAI
import PiSwiftChord

/// Changes taken for one partial write. Values can cross the transaction task boundary.
struct PartialCommit: Sendable {
    struct ToolChanges: Sendable {
        let index: Int
        let changes: [JSONChange]
        let snapshot: JSONValue
    }
    let plan: AssignPlan
    let toolCalls: [ToolChanges]
}

/// Tracks new text and tool arguments between partial writes.
/// The actor confines the mutable JSON parsers to one executor.
actor PartialChanges {
    private struct TextChange {
        let index: Int
        let field: String
        var text: String
    }
    private struct ToolState {
        let parser = StreamingJSONParser()
        var changes: [JSONChange] = []
        var committed = false
    }
    private var latest: AssistantMessage?
    private var text: [TextChange] = []
    private var toolCalls: [Int: ToolState] = [:]
    private var toolOrder: [Int] = []

    // partial-changes.ts:47, v1.5.2.
    func observe(_ event: AssistantMessageEvent) {
        switch event {
        case .start(let partial), .textStart(_, let partial), .textDelta(_, _, let partial),
             .textEnd(_, _, let partial), .thinkingStart(_, let partial), .thinkingDelta(_, _, let partial),
             .thinkingEnd(_, _, let partial), .toolCallStart(_, let partial), .toolCallDelta(_, _, let partial),
             .toolCallEnd(_, _, let partial): latest = partial
        case .done, .error: break
        }
        switch event {
        case .textDelta(let index, let delta, _): recordText(index, field: "text", delta: delta)
        case .thinkingDelta(let index, let delta, _): recordText(index, field: "thinking", delta: delta)
        case .toolCallStart(let index, _):
            if toolCalls[index] == nil { toolOrder.append(index) }
            toolCalls[index] = ToolState()
        case .toolCallDelta(let index, let delta, _):
            guard var call = toolCalls[index] else { return }
            for change in call.parser.append(delta) {
                if change.path.isEmpty {
                    guard change.kind == .set, case .object? = change.value else {
                        removeTool(index)
                        return
                    }
                }
                call.changes.append(change)
            }
            toolCalls[index] = call
        case .textEnd(let index, _, _), .thinkingEnd(let index, _, _):
            text.removeAll { $0.index == index }
        case .toolCallEnd(let index, _, _): removeTool(index)
        default: break
        }
    }

    private func recordText(_ index: Int, field: String, delta: String) {
        if let position = text.firstIndex(where: { $0.index == index }) {
            if text[position].field == field { text[position].text += delta }
            else { text[position] = TextChange(index: index, field: field, text: delta) }
        } else { text.append(TextChange(index: index, field: field, text: delta)) }
    }

    private func removeTool(_ index: Int) {
        toolCalls.removeValue(forKey: index)
        toolOrder.removeAll { $0 == index }
    }

    /// Copy the latest partial and take its changes without an actor suspension.
    func takeLatest() throws -> (message: JSONValue, commit: PartialCommit)? {
        guard let latest else { return nil }
        let message = try EntryRecord.encodeMessages([.assistant(latest)])[0]
        self.latest = nil
        return take(message)
    }

    // partial-changes.ts:91, v1.5.2.
    func take(_ message: JSONValue) -> (message: JSONValue, commit: PartialCommit) {
        var blocks: [Delta.PathSegment: AssignPlan] = [:]
        for change in text {
            blocks[.index(change.index)] = .fields([.key(change.field): .append(change.text)])
        }
        text = []
        var calls: [PartialCommit.ToolChanges] = []
        var messageObject = message.objectValue ?? [:]
        var content = message["content"]?.arrayValue ?? []
        for index in toolOrder {
            guard var call = toolCalls[index], content.indices.contains(index),
                  var block = content[index].objectValue, block["type"] == .string("toolCall") else { continue }
            calls.append(.init(index: index, changes: call.changes, snapshot: block["arguments"] ?? .object([:])))
            block["arguments"] = .object([:])
            content[index] = .object(block)
            blocks[.index(index)] = .fields([.key("arguments"): .keep])
            call.changes = []
            toolCalls[index] = call
        }
        messageObject["content"] = .array(content)
        return (.object(messageObject), PartialCommit(plan: .fields([.key("content"): .fields(blocks)]), toolCalls: calls))
    }

    // partial-changes.ts:119, v1.5.2.
    func commit(_ generation: JSONDraft, message: JSONValue, taken: PartialCommit) throws {
        let committedBlocks = try generation.get("message")?["content"]?.arrayValue?.count ?? 0
        var apply: [PartialCommit.ToolChanges] = []
        var messageObject = message.objectValue ?? [:]
        var content = message["content"]?.arrayValue ?? []
        for entry in taken.toolCalls {
            guard var call = toolCalls[entry.index] else { continue }
            if entry.index >= committedBlocks, call.committed, content.indices.contains(entry.index),
               var block = content[entry.index].objectValue, block["type"] == .string("toolCall") {
                removeTool(entry.index)
                block["arguments"] = entry.snapshot
                content[entry.index] = .object(block)
                continue
            }
            call.committed = true
            toolCalls[entry.index] = call
            apply.append(entry)
        }
        messageObject["content"] = .array(content)
        try assignJSON(target: generation, key: "message", value: .object(messageObject), plan: taken.plan)
        guard let blocks = try generation.child("message")?.child("content") else { return }
        for entry in apply {
            guard let block = try blocks.child(entry.index), try block.get("type") == .string("toolCall") else { continue }
            for change in entry.changes { try applyChange(block, change) }
        }
    }

    // partial-changes.ts:149, v1.5.2.
    func restore(_ commit: PartialCommit) {
        for entry in commit.toolCalls {
            guard var call = toolCalls[entry.index] else { continue }
            call.changes = entry.changes + call.changes
            toolCalls[entry.index] = call
        }
    }
}

/// Apply parser changes in order. Array strings use ordinary assignment.
private func applyChange(_ block: JSONDraft, _ change: JSONChange) throws {
    guard let key = change.path.last else {
        if change.kind == .set, case .object? = change.value, let value = change.value {
            try block.set("arguments", durableJSON(fromOrdered: value))
        }
        return
    }
    guard var parent = try block.child("arguments") else { throw DocumentDefinitionError("Arguments draft is missing") }
    for segment in change.path.dropLast() {
        let child: JSONDraft?
        switch segment {
        case .key(let key): child = try parent.child(key)
        case .index(let index): child = try parent.child(index)
        }
        guard let child else { throw DocumentDefinitionError("Argument container is missing") }
        parent = child
    }
    switch (change.kind, key) {
    case (.set, .key(let key)):
        if let value = change.value { try parent.set(key, durableJSON(fromOrdered: value)) }
    case (.set, .index(let index)):
        if let value = change.value { try parent.set(index, durableJSON(fromOrdered: value)) }
    case (.append, .key(let key)): try parent.appendText(key, change.text ?? "")
    case (.append, .index(let index)):
        let current = try parent.get(index)?.stringValue ?? ""
        try parent.set(index, .string(current + (change.text ?? "")))
    }
}
