import PiSwiftAI
import PiSwiftChord

internal struct ContextRange: Sendable {
    let bounds: ContextBounds
    let entries: [EntryRecord]
    let view: ContextView
    let edited: Set<EntryID>
    let settled: [Message]
    let open: [Message]
    let baseline: ContextBaseline
    let firstSystem: ContextMessageSource?
    let current: Bool
}

/// Capture immutable bounds on the line, then scan only the missing range off the line.
internal func readContextFrom(session: Session, storage: any DurableStorage, id: ConversationID,
                              context: ChordContext, at: EntryID? = nil,
                              previous: ContextRange? = nil) async throws -> (view: ContextView, range: ContextRange?) {
    let bounds: ContextBounds? = try await session.readOnLine {
        let tail: EntryID
        if let at {
            if previous.flatMap({ rangeEntry($0, id: at) }) == nil {
                guard try await storage.entry(id, id: at, context: context) != nil else {
                    throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(id.rawValue)")
                }
            }
            tail = at
        } else {
            guard let found = try await session.latestEntryId(id, context: context) else { return nil }
            tail = found
        }
        return ContextBounds(head: try await session.latestHeadMarker(id, atOrBefore: tail, context: context), tail: tail)
    }
    guard let bounds else { return (ContextView(), nil) }
    let range: ContextRange
    if let previous, previous.bounds.head?.id == bounds.head?.id {
        if previous.bounds.tail == bounds.tail { return (previous.view, previous) }
        if bounds.tail < previous.bounds.tail {
            range = try deriveContextRange(bounds, entries: previous.entries.filter { $0.id <= bounds.tail }, current: false)
        } else {
            let min = try EntryID(previous.bounds.tail.rawValue + 1)
            let added = try await scanAll { cursor in
                try await storage.scanEntries(.init(conversationId: id, minEntryId: min, maxEntryId: bounds.tail, order: .ascending), limit: 256, cursor: cursor, context: context)
            }
            range = try extendContextRange(previous, bounds: bounds, added: added, current: at == nil)
        }
    } else {
        let entries = try await scanAll { cursor in
            try await storage.scanEntries(.init(conversationId: id, minEntryId: bounds.head?.head, maxEntryId: bounds.tail, order: .ascending), limit: 256, cursor: cursor, context: context)
        }
        range = try deriveContextRange(bounds, entries: entries, current: at == nil)
    }
    if range.current && session.knownLatestEntryId(id) != range.bounds.tail {
        let stale = ContextRange(bounds: range.bounds, entries: range.entries, view: range.view,
                                 edited: range.edited, settled: range.settled, open: range.open,
                                 baseline: range.baseline, firstSystem: range.firstSystem, current: false)
        return (stale.view, stale)
    }
    return (range.view, range)
}

/// v1.5.2 context.ts:175–192: a cached range proves visibility for its entries.
internal func rangeEntry(_ range: ContextRange, id: EntryID) -> EntryRecord? {
    var low = 0, high = range.entries.count - 1
    while low <= high {
        let middle = low + (high - low) / 2
        let entry = range.entries[middle]
        if entry.id == id { return entry }
        if entry.id < id { low = middle + 1 } else { high = middle - 1 }
    }
    return nil
}

/// v1.5.2 context.ts:199–212: publication advances a current range without a storage scan.
internal func advanceContextRange(_ range: ContextRange, appended: [EntryRecord]) throws -> ContextRange? {
    guard range.current, !appended.isEmpty else { return range }
    var head = range.bounds.head
    for entry in appended where entry.head != nil { head = entry }
    let bounds = ContextBounds(head: head, tail: appended[appended.count - 1].id)
    if head?.id == range.bounds.head?.id {
        return try extendContextRange(range, bounds: bounds, added: appended, current: true)
    }
    guard let start = head?.head else { return nil }
    if let oldStart = range.bounds.head?.head, start < oldStart { return nil }
    return try deriveContextRange(bounds, entries: (range.entries + appended).filter { $0.id >= start }, current: true)
}

private func deriveContextRange(_ bounds: ContextBounds, entries: [EntryRecord], current: Bool) throws -> ContextRange {
    let data = try deriveContextData(bounds: bounds, entries: entries)
    let view = data.view
    let parts = settleContext([], open: view.contributions.flatMap { $0 })
    let edited = Set(entries.flatMap { entry in (entry.edits ?? []).map { edit -> EntryID in
        switch edit { case .omit(let target, _), .replace(let target, _, _): target }
    } })
    return ContextRange(bounds: bounds, entries: entries, view: view, edited: edited, settled: parts.settled, open: parts.open, baseline: data.baseline, firstSystem: data.firstSystem, current: current)
}

/// Edits can affect earlier contributions. Plain appended entries affect only the open suffix.
private func extendContextRange(_ previous: ContextRange, bounds: ContextBounds, added: [EntryRecord], current: Bool) throws -> ContextRange {
    let entries = previous.entries + added
    if added.contains(where: { $0.edits != nil || $0.head != nil || previous.edited.contains($0.id) }) {
        return try deriveContextRange(bounds, entries: entries, current: current)
    }
    let data = try deriveContextData(bounds: ContextBounds(head: nil, tail: bounds.tail), entries: added)
    let contributions = data.view
    let baseline = previous.baseline == .pending ? findContextBaseline(head: bounds.head, entries: added) : previous.baseline
    let firstSystem = previous.firstSystem ?? data.firstSystem
    let parts = settleContext(previous.settled, open: previous.open + contributions.contributions.flatMap { $0 })
    let view = ContextView(head: bounds.head, entries: previous.view.entries + added,
                          contributions: previous.view.contributions + contributions.contributions,
                          messages: leadContextWithSystem(parts.settled + orderToolResults(parts.open), baseline: baseline, firstSystem: firstSystem),
                          rawContributions: (previous.view.rawContributions ?? []) + (contributions.rawContributions ?? []))
    return ContextRange(bounds: bounds, entries: entries, view: view, edited: previous.edited, settled: parts.settled, open: parts.open, baseline: baseline, firstSystem: firstSystem, current: current)
}

private func settleContext(_ settled: [Message], open: [Message]) -> (settled: [Message], open: [Message]) {
    guard let last = open.lastIndex(where: { $0.role == "assistant" }), last > 0 else { return (settled, open) }
    return (settled + orderToolResults(Array(open[..<last])), Array(open[last...]))
}
