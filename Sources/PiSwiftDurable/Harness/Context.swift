import PiSwiftAI
import PiSwiftChord

/// Raw active entries and their model contributions. Values do not share mutable state.
public struct ContextView: Sendable {
    /// The visible entry that sets the lower context bound, when present.
    public let head: EntryRecord?
    /// The active entries from the context head through its inclusive upper bound.
    public let entries: [EntryRecord]
    /// The model messages retained for each active entry after edits.
    public let contributions: [[Message]]
    /// The flattened model messages after entry edits and tool-result ordering.
    public let messages: [Message]
    /// Raw contributions retain declaration member order at the AI boundary.
    let rawContributions: [JSONValue]?
    /// Creates a detached view of active entries and their model contributions.
    public init(head: EntryRecord? = nil, entries: [EntryRecord] = [], contributions: [[Message]] = [], messages: [Message] = [], rawContributions: [JSONValue]? = nil) {
        self.head = head; self.entries = entries; self.contributions = contributions; self.messages = messages; self.rawContributions = rawContributions
    }
}

/// Inclusive limits captured before a context scan. A head marker must have a head ID.
public struct ContextBounds: Sendable {
    /// The entry that defines the active model-context lower bound.
    public let head: EntryRecord?
    /// The inclusive upper entry boundary of this context.
    public let tail: EntryID
    /// Records the context head and inclusive upper entry boundary.
    public init(head: EntryRecord?, tail: EntryID) { self.head = head; self.tail = tail }
}

/// Derives context from visible entries in ascending ID order. No Session is required.
/// With `at`, only entries at or before that ID participate.
public func deriveContext(entries: [EntryRecord], at: EntryID? = nil) throws -> ContextView {
    let visible = entries.filter { at == nil || $0.id <= at! }
    guard let tail = visible.last?.id else { return ContextView() }
    let head = visible.last { $0.head != nil }
    return try deriveContext(bounds: ContextBounds(head: head, tail: tail), entries: visible)
}

/// Derives the range from captured bounds. Edits on older head markers still count.
public func deriveContext(bounds: ContextBounds?, entries: [EntryRecord]) throws -> ContextView {
    try deriveContextData(bounds: bounds, entries: entries).view
}

/// A message's source preserves the identity that JavaScript object references supply.
internal struct ContextMessageSource: Sendable, Equatable {
    let entry: EntryID
    let offset: Int
    let replacement: Bool
}
internal enum ContextBaseline: Sendable, Equatable {
    case pending
    case absent
    case message(ContextMessageSource)
}
internal struct ContextData: Sendable {
    let view: ContextView
    let baseline: ContextBaseline
    let firstSystem: ContextMessageSource?
}
internal func deriveContextData(bounds: ContextBounds?, entries: [EntryRecord]) throws -> ContextData {
    guard let bounds else { return ContextData(view: ContextView(), baseline: .pending, firstSystem: nil) }
    let range = entries.filter { $0.id <= bounds.tail && (bounds.head?.head == nil || $0.id >= bounds.head!.head!) }
    var edits: [EntryID: ContextEdit] = [:]
    for entry in range {
        for edit in entry.edits ?? [] {
            switch edit {
            case .omit(let target, _), .replace(let target, _, _): edits[target] = edit
            }
        }
    }
    let active = bounds.head.map { [$0] + range.filter { $0.head == nil } } ?? range
    var rawContributions: [JSONValue] = []
    var firstSystem: ContextMessageSource?
    let contributions = try active.map { entry -> [Message] in
        let raw: [JSONValue]?
        switch edits[entry.id] {
        case .omit?: return []
        case .replace(_, let messages, _)?: raw = messages
        case nil: raw = entry.model
        }
        if firstSystem == nil, let offset = raw?.firstIndex(where: { $0["role"] == "system" }) {
            firstSystem = ContextMessageSource(entry: entry.id, offset: offset, replacement: edits[entry.id] != nil)
        }
        rawContributions.append(contentsOf: raw ?? [])
        let typed = try EntryRecord(id: entry.id, conversationId: entry.conversationId, kind: entry.kind, model: raw).messages() ?? []
        return typed.filter { message in
            guard case .assistant(let answer) = message else { return true }
            return ![StopReason.aborted, .error, .deferred].contains(answer.stopReason)
        }
    }
    let baseline = findContextBaseline(head: bounds.head, entries: active)
    let messages = leadContextWithSystem(orderToolResults(contributions.flatMap { $0 }), baseline: baseline, firstSystem: firstSystem)
    let view = ContextView(head: bounds.head, entries: active, contributions: contributions, messages: messages, rawContributions: rawContributions)
    return ContextData(view: view, baseline: baseline, firstSystem: firstSystem)
}

/// Finds the first built-in system entry written after the head marker.
internal func findContextBaseline(head: EntryRecord?, entries: [EntryRecord]) -> ContextBaseline {
    for entry in entries {
        if let head, entry.id <= head.id { continue }
        if entry.kind.utf8.elementsEqual("pi.system".utf8) {
            guard let offset = entry.model?.firstIndex(where: { $0["role"] == "system" }) else { return .absent }
            return .message(ContextMessageSource(entry: entry.id, offset: offset, replacement: false))
        }
        if head == nil {
            if entry.model?.contains(where: { $0["role"] == "system" }) == true { return .absent }
            for edit in entry.edits ?? [] {
                if case .replace(_, let messages, _) = edit, messages.contains(where: { $0["role"] == "system" }) { return .absent }
            }
        }
    }
    return .pending
}

/// Moves only the first system message, if it is the baseline or follows only users.
internal func leadContextWithSystem(_ messages: [Message], baseline: ContextBaseline, firstSystem: ContextMessageSource?) -> [Message] {
    guard let first = messages.firstIndex(where: { $0.role == "system" }), first > 0 else { return messages }
    let isBaseline: Bool
    if case .message(let source) = baseline { isBaseline = source == firstSystem } else { isBaseline = false }
    if !isBaseline && messages[..<first].contains(where: { $0.role != "user" }) { return messages }
    var messages = messages
    let system = messages.remove(at: first); messages.insert(system, at: 0)
    return messages
}

/// Places results directly after their assistant, in call order. First result wins.
/// Unmatched results are omitted. Missing results are model-visible error messages.
public func orderToolResults(_ messages: [Message]) -> [Message] {
    var ordered: [Message] = []
    for (index, message) in messages.enumerated() {
        if case .toolResult = message { continue }
        ordered.append(message)
        guard case .assistant(let assistant) = message else { continue }
        let calls = assistant.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }; return nil
        }
        guard !calls.isEmpty else { continue }
        var results: [[UInt16]: ToolResultMessage] = [:]
        for candidate in messages.dropFirst(index + 1) {
            if case .assistant = candidate { break }
            if case .toolResult(let result) = candidate, results[Array(result.toolCallId.utf16)] == nil { results[Array(result.toolCallId.utf16)] = result }
        }
        for call in calls {
            ordered.append(.toolResult(results[Array(call.id.utf16)] ?? ToolResultMessage(
                toolCallId: call.id, toolName: call.name,
                content: [.text(TextContent(text: "Tool result unavailable: history ends before this call completed."))],
                details: AnyCodable(["reason": "missing_result"]), isError: true, timestamp: assistant.timestamp)))
        }
    }
    return ordered
}
