import PiSwiftChord

/// Entries strictly between these bounds are missing from the transcript.
public struct TranscriptGap: Sendable, Equatable, Hashable, Codable {
    public let after: EntryID
    public let upTo: EntryID
    public init(after: EntryID, upTo: EntryID) { self.after = after; self.upTo = upTo }
}

/// One entry or one load marker in a client's transcript.
public enum TranscriptItem: Sendable, Equatable, Codable {
    case entry(EntryRecord)
    case gap(TranscriptGap)
    case earlier

    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let kind: String = try recordRequired(object, "kind")
        switch kind {
        case "entry": self = .entry(try recordRequired(object, "entry"))
        case "gap": self = .gap(.init(after: try recordRequired(object, "after"), upTo: try recordRequired(object, "upTo")))
        case "earlier": self = .earlier
        default: throw recordUnknown("kind", kind)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject
        switch self {
        case .entry(let entry): object = ["kind": "entry"]; try recordSet(&object, "entry", entry)
        case .gap(let gap): object = ["kind": "gap"]; try recordSet(&object, "after", gap.after); try recordSet(&object, "upTo", gap.upTo)
        case .earlier: object = ["kind": "earlier"]
        }
        try object.encode(to: encoder)
    }
}

/// The conversation view with all entries held by the client and its load markers.
public struct TranscriptView: Sendable, Equatable, Codable {
    public let conversation: ConversationRecord
    public let docs: [String: JSONObject]
    public let items: [TranscriptItem]
    public init(conversation: ConversationRecord, docs: [String: JSONObject], items: [TranscriptItem]) {
        self.conversation = conversation; self.docs = docs; self.items = items
    }
}

/// Loads a page with the same bounds as Conversation.entries, without a cursor.
public typealias EntryLoader = @Sendable (ConversationEntryQuery, Int, ChordContext) async throws -> Page<EntryRecord, Cursor>

/// The number of entries that each transcript load requests.
public struct ConversationTranscriptOptions: Sendable, Equatable {
    public let pageSize: Int
    public init(pageSize: Int = 50) { self.pageSize = pageSize }
}

/// Keeps all received entries and the gaps between view windows.
/// Calls are actor isolated. Concurrent loads for the same range share one task.
/// Swift arrays use value semantics and retain their storage when no entries change.
public actor ConversationTranscript {
    private let load: EntryLoader
    private let pageSize: Int
    private var state = TranscriptState()
    private var last: ConversationView?
    private var earlier: Task<TranscriptView, any Error>?
    private var filling: [TranscriptGap: Task<TranscriptView, any Error>] = [:]

    public init(_ load: @escaping EntryLoader, options: ConversationTranscriptOptions = .init()) throws {
        guard options.pageSize >= 1, Int64(options.pageSize) <= EntryID.maximumRawValue else {
            throw SessionError.message("Page size must be an integer >= 1, got \(options.pageSize)")
        }
        self.load = load; self.pageSize = options.pageSize
    }

    /// The newest entry, or the before bound of a later empty window.
    public var newest: EntryID? { state.tail == TranscriptState.start ? nil : try? EntryID(state.tail) }

    /// The window to use after a connection stops. Nil means no view was merged.
    /// This getter throws when the next ID exceeds the valid Swift ID range.
    public var resume: ConversationWindow? {
        get throws {
            guard state.started else { return nil }
            guard let newest else { return .init() }
            return .init(from: try EntryID(newest.rawValue + 1))
        }
    }

    /// Adds a view window. Entries from previous windows remain in the transcript.
    /// This method throws if a gap bound exceeds the valid Swift ID range.
    public func merge(_ view: ConversationView) throws -> TranscriptView {
        let hi = view.entries.last?.id.rawValue ?? view.before?.rawValue ?? TranscriptState.start
        try cover(lo: view.before?.rawValue ?? TranscriptState.start, hi: hi, added: view.entries)
        last = view
        return try result()
    }

    /// Loads the page before the oldest entry held by this client.
    public func loadEarlier(context: ChordContext) async throws -> TranscriptView {
        guard last != nil else { throw notStarted() }
        guard state.low != TranscriptState.start else { return try result() }
        if let earlier { return try await earlier.value }
        let low = state.low
        // ID 0 is an exclusive bound at the start, and cannot be sent to a Swift loader.
        if low == 0 {
            try cover(lo: TranscriptState.start, hi: low, added: [])
            return try result()
        }
        let loading = Task {
            defer { self.earlier = nil }
            let page = try await load(.init(maxEntryId: EntryID(low), order: .descending), pageSize, context)
            let items = Array(page.items.reversed())
            let lo = page.next == nil || items.isEmpty ? TranscriptState.start : items[0].id.rawValue - 1
            try cover(lo: lo, hi: low, added: items)
            return try result()
        }
        earlier = loading
        return try await loading.value
    }

    /// Loads the start of a gap. A stale gap selects the current overlapping gap.
    public func fillGap(_ gap: TranscriptGap, context: ChordContext) async throws -> TranscriptView {
        guard let current = state.gaps.first(where: { $0 == gap }) ?? state.gaps.first(where: {
            $0.after < gap.upTo && gap.after < $0.upTo
        }) else { return try result() }
        if let running = filling[current] { return try await running.value }
        let loading = Task {
            defer { self.filling.removeValue(forKey: current) }
            let query = try ConversationEntryQuery(minEntryId: EntryID(current.after.rawValue + 1),
                maxEntryId: EntryID(current.upTo.rawValue - 1), order: .ascending)
            let page = try await load(query, pageSize, context)
            let hi = page.next == nil || page.items.isEmpty ? current.upTo.rawValue - 1 : page.items.last!.id.rawValue
            try cover(lo: current.after.rawValue, hi: hi, added: page.items)
            return try result()
        }
        filling[current] = loading
        return try await loading.value
    }

    private func notStarted() -> SessionError { .message("ConversationTranscript: merge a view first") }
    private func result() throws -> TranscriptView {
        guard let last else { throw notStarted() }
        return .init(conversation: last.conversation, docs: last.docs, items: state.items)
    }
    private func cover(lo: Int64, hi: Int64, added: [EntryRecord]) throws {
        // Publish the state only after all gap bounds pass validation.
        var next = state
        try next.cover(lo: lo, hi: hi, added: added)
        state = next
    }
}

private struct TranscriptState {
    static let start = Int64.min
    var entries: [EntryRecord] = []
    var ids: Set<EntryID> = []
    var gaps: [TranscriptGap] = []
    var started = false
    var low = start
    var tail = start
    var items: [TranscriptItem] = []

    /// Marks (lo, hi] as known and merges its entries in ID order.
    mutating func cover(lo: Int64, hi: Int64, added: [EntryRecord]) throws {
        let fresh = added.filter { !ids.contains($0.id) }
        for entry in fresh { ids.insert(entry.id) }
        let held = entries
        let appended = fresh.isEmpty || held.isEmpty || fresh[0].id > held[held.count - 1].id
        if !fresh.isEmpty { entries = appended ? held + fresh : mergeByID(held, fresh) }
        var rebuild = false
        if !started || (held.isEmpty && gaps.isEmpty && lo >= tail) {
            rebuild = !started || lo != low
            started = true; low = lo; tail = max(tail, hi)
        } else if lo > tail {
            gaps.append(try gapOf(after: tail, upTo: added.first?.id.rawValue ?? lo + 1))
            tail = hi; rebuild = true
        } else if hi != Self.start && hi < low {
            let upTo = held.first(where: { $0.id.rawValue > hi })?.id.rawValue ?? low + 1
            gaps.insert(try gapOf(after: hi, upTo: upTo), at: 0)
            low = lo; rebuild = true
        } else {
            if try subtract(lo: lo, hi: hi) { rebuild = true }
            if lo < low { low = lo; rebuild = true }
            if hi > tail { tail = hi }
        }
        if rebuild || !appended { build() }
        else if !fresh.isEmpty { items += fresh.map(TranscriptItem.entry) }
    }

    /// Removes (lo, hi] from each gap. An empty range makes no changes.
    private mutating func subtract(lo: Int64, hi: Int64) throws -> Bool {
        guard hi > lo else { return false }
        var changed = false
        var remaining: [TranscriptGap] = []
        for gap in gaps {
            if hi <= gap.after.rawValue || lo + 1 >= gap.upTo.rawValue {
                remaining.append(gap); continue
            }
            changed = true
            if lo > gap.after.rawValue {
                let first = entries.first(where: { $0.id.rawValue > lo })?.id.rawValue ?? lo + 1
                remaining.append(try gapOf(after: gap.after.rawValue, upTo: min(gap.upTo.rawValue, first)))
            }
            if hi + 1 < gap.upTo.rawValue { remaining.append(try gapOf(after: hi, upTo: gap.upTo.rawValue)) }
        }
        if changed { gaps = remaining }
        return changed
    }

    private mutating func build() {
        var result: [TranscriptItem] = low == Self.start ? [] : [.earlier]
        var next = 0
        for entry in entries {
            while next < gaps.count && gaps[next].after < entry.id {
                result.append(.gap(gaps[next])); next += 1
            }
            result.append(.entry(entry))
        }
        while next < gaps.count { result.append(.gap(gaps[next])); next += 1 }
        items = result
    }
}

private func gapOf(after: Int64, upTo: Int64) throws -> TranscriptGap {
    try .init(after: EntryID(after), upTo: EntryID(upTo))
}

/// Merges two ID-ordered arrays in one pass.
private func mergeByID(_ left: [EntryRecord], _ right: [EntryRecord]) -> [EntryRecord] {
    var merged: [EntryRecord] = []
    merged.reserveCapacity(left.count + right.count)
    var i = 0; var j = 0
    while i < left.count && j < right.count {
        if left[i].id < right[j].id { merged.append(left[i]); i += 1 }
        else { merged.append(right[j]); j += 1 }
    }
    merged.append(contentsOf: left[i...]); merged.append(contentsOf: right[j...])
    return merged
}
