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
}

/// Capture immutable bounds on the line, then scan only the missing range off the line.
internal func readContextFrom(session: Session, storage: any DurableStorage, id: ConversationID,
                              context: ChordContext, at: EntryID? = nil,
                              previous: ContextRange? = nil) async throws -> (view: ContextView, range: ContextRange?) {
    let bounds: ContextBounds? = try await session.readOnLine {
        let tail: EntryID
        if let at {
            guard try await storage.entry(id, id: at, context: context) != nil else {
                throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(id.rawValue)")
            }
            tail = at
        } else {
            guard let found = try await storage.scanEntries(.init(conversationId: id), limit: 1, cursor: nil, context: context).items.first else { return nil }
            tail = found.id
        }
        return ContextBounds(head: try await storage.findLatestHeadMarker(id, atOrBeforeEntryId: tail, context: context), tail: tail)
    }
    guard let bounds else { return (ContextView(), nil) }
    let range: ContextRange
    if let previous, previous.bounds.head?.id == bounds.head?.id {
        if previous.bounds.tail == bounds.tail { return (previous.view, previous) }
        if bounds.tail < previous.bounds.tail {
            range = try deriveContextRange(bounds, entries: previous.entries.filter { $0.id <= bounds.tail })
        } else {
            let min = try EntryID(previous.bounds.tail.rawValue + 1)
            let added = try await scanAll { cursor in
                try await storage.scanEntries(.init(conversationId: id, minEntryId: min, maxEntryId: bounds.tail, order: .ascending), limit: 256, cursor: cursor, context: context)
            }
            range = try extendContextRange(previous, bounds: bounds, added: added)
        }
    } else {
        let entries = try await scanAll { cursor in
            try await storage.scanEntries(.init(conversationId: id, minEntryId: bounds.head?.head, maxEntryId: bounds.tail, order: .ascending), limit: 256, cursor: cursor, context: context)
        }
        range = try deriveContextRange(bounds, entries: entries)
    }
    return (range.view, range)
}

private func deriveContextRange(_ bounds: ContextBounds, entries: [EntryRecord]) throws -> ContextRange {
    let data = try deriveContextData(bounds: bounds, entries: entries)
    let view = data.view
    let parts = settleContext([], open: view.contributions.flatMap { $0 })
    let edited = Set(entries.flatMap { entry in (entry.edits ?? []).map { edit -> EntryID in
        switch edit { case .omit(let target, _), .replace(let target, _, _): target }
    } })
    return ContextRange(bounds: bounds, entries: entries, view: view, edited: edited, settled: parts.settled, open: parts.open, baseline: data.baseline, firstSystem: data.firstSystem)
}

/// Edits can affect earlier contributions. Plain appended entries affect only the open suffix.
private func extendContextRange(_ previous: ContextRange, bounds: ContextBounds, added: [EntryRecord]) throws -> ContextRange {
    let entries = previous.entries + added
    if added.contains(where: { $0.edits != nil || $0.head != nil || previous.edited.contains($0.id) }) {
        return try deriveContextRange(bounds, entries: entries)
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
    return ContextRange(bounds: bounds, entries: entries, view: view, edited: previous.edited, settled: parts.settled, open: parts.open, baseline: baseline, firstSystem: firstSystem)
}

private func settleContext(_ settled: [Message], open: [Message]) -> (settled: [Message], open: [Message]) {
    guard let last = open.lastIndex(where: { $0.role == "assistant" }), last > 0 else { return (settled, open) }
    return (settled + orderToolResults(Array(open[..<last])), Array(open[last...]))
}
