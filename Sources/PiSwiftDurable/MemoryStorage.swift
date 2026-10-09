import PiSwiftChord
import Synchronization

private final class MemoryApplicationState: Sendable {
    let applied = Mutex(false)
}

/// Detached writes for persistence. Application returns the same sequence on every call.
/// The async boundary enters the storage actor; application itself does not suspend.
public struct PreparedMemoryCommit: Sendable {
    /// The strictly increasing sequence assigned to the commit.
    public let seq: Seq
    /// The ordered storage writes prepared by this commit.
    public let writes: [StorageWrite]
    private let application: @Sendable () async -> Seq
    init(plan: MemoryCommitPlan, application: @escaping @Sendable () async -> Seq) {
        seq = plan.seq; writes = plan.writes; self.application = application
    }
    /// Applies the prepared storage writes. Repeated calls return the same sequence.
    public func apply() async -> Seq { await application() }
}

/// Reference storage with value ownership and one global ID namespace.
/// Context is ignored, as in the upstream memory backend.
public actor MemoryStorage: DurableStorage {
    private var tables = MemoryTables()
    private var closed = false

    /// Creates empty in-memory storage with the reserved root conversation ID.
    public init() {}

    /// Atomically stores the write batch and returns its increasing commit sequence.
    public func commit(_ writes: [StorageWrite], context: ChordContext) throws -> Seq {
        try assertOpen()
        let plan = try tables.prepare(writes, seq: nextSequence())
        tables.apply(plan)
        return plan.seq
    }

    /// Validates without changing observable state. Persistence wrappers must serialize preparation and application.
    /// An explicit sequence permits replay with sequence gaps.
    public func prepareCommit(_ writes: [StorageWrite], seq: Seq? = nil) throws -> PreparedMemoryCommit {
        try assertOpen()
        let plan = try tables.prepare(writes, seq: seq ?? nextSequence())
        let state = MemoryApplicationState()
        return PreparedMemoryCommit(plan: plan) { await self.applyPrepared(plan, state: state) }
    }

    private func applyPrepared(_ plan: MemoryCommitPlan, state: MemoryApplicationState) -> Seq {
        state.applied.withLock {
            if !$0 { tables.apply(plan); $0 = true }
        }
        return plan.seq
    }
    private func nextSequence() throws -> Seq {
        guard tables.nextSeq <= Seq.maximumRawValue else {
            throw DurableStorageError.commitSequenceDoesNotIncrease(tables.nextSeq)
        }
        return try Seq(tables.nextSeq)
    }

    /// Allocates an unused positive ID from the shared record namespace.
    public func mintId<Kind: DurableIDKind>() throws -> DurableID<Kind> {
        try assertOpen()
        guard tables.nextId <= DurableID<Kind>.maximumRawValue else { throw DurableStorageError.idSpaceExhausted }
        let id = try DurableID<Kind>(tables.nextId)
        tables.nextId += 1
        return id
    }

    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID, context: ChordContext) throws -> ConversationRecord? {
        try assertOpen(); return tables.conversations[id]
    }
    /// Returns a page of conversations that match all query filters.
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) throws -> Page<ConversationRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .ascending)
        let ids: [ConversationID]
        if let owner = query.ownerTaskId { ids = tables.conversationIdsByOwnerTask[owner] ?? [] }
        else if let owner = query.ownerConversationId { ids = tables.conversationIdsByOwnerConversation[owner] ?? [] }
        else { ids = tables.conversationIds }
        let values = scan(ids, start: start).compactMap { tables.conversations[$0] }.filter {
            query.ownerConversationId == nil || $0.owner?.conversationId == query.ownerConversationId
        }
        return page(values, limit: limit, order: start.order, id: { $0.id.rawValue })
    }

    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID, context: ChordContext) throws -> EntryLookup? {
        try assertOpen()
        return tables.entries[id].map { EntryLookup(entry: $0, commitSeq: tables.entryCommitSeqs[id]!) }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) throws -> EntryLookup? {
        try assertOpen()
        return try visibleEntries(conversationId, minimum: id.rawValue, maximum: id.rawValue, order: .descending).first.map {
            EntryLookup(entry: $0, commitSeq: tables.entryCommitSeqs[id]!)
        }
    }
    /// Returns the newest visible head marker at or below the inclusive entry cutoff.
    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) throws -> EntryRecord? {
        try assertOpen(); try checkConversation(conversationId)
        var current = conversationId
        var upper = atOrBeforeEntryId?.rawValue ?? Int64.max
        while true {
            let ids = tables.headEntryIds[current] ?? []
            if let id = ids.last(where: { $0.rawValue <= upper }) { return tables.entries[id] }
            guard let parent = tables.conversations[current]!.parent else { return nil }
            upper = min(upper, parent.at.rawValue); current = parent.conversationId
        }
    }
    /// Returns a page of entries in the visible ancestry and requested range.
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) throws -> Page<EntryRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .descending)
        var minimum = query.minEntryId?.rawValue ?? Int64.min
        var maximum = query.maxEntryId?.rawValue ?? Int64.max
        if let after = start.after {
            if start.order == .descending { maximum = min(maximum, after - 1) }
            else { minimum = max(minimum, after + 1) }
        }
        let values = try visibleEntries(query.conversationId, minimum: minimum, maximum: maximum, order: start.order)
        return page(values, limit: limit, order: start.order, id: { $0.id.rawValue })
    }

    /// Returns the stored task record with this ID, or nil when absent.
    public func task(_ id: TaskID, context: ChordContext) throws -> TaskRecord? { try assertOpen(); return tables.tasks[id] }
    /// Returns a page of tasks that match all query filters.
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) throws -> Page<TaskRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .ascending)
        let ids = query.status.map { tables.taskIdsByStatus[$0.rawValue] ?? [] } ?? tables.taskIds
        let values = scan(ids, start: start).compactMap { tables.tasks[$0] }.filter {
            (query.conversationId == nil || $0.conversationId == query.conversationId) &&
            (query.kind == nil || MemoryStringKey($0.kind) == MemoryStringKey(query.kind!)) &&
            (query.abortRequested == nil || $0.abortRequested == query.abortRequested) &&
            (query.background == nil || $0.background == query.background)
        }
        return page(values, limit: limit, order: start.order, id: { $0.id.rawValue })
    }

    /// Returns the current durable submission, or nil when it is absent.
    public func submission(_ id: SubmissionID, context: ChordContext) throws -> SubmissionRecord? { try assertOpen(); return tables.submissions[id] }
    /// Returns a page of submissions that match all query filters.
    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) throws -> Page<SubmissionRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .ascending)
        let ids = query.status.map { tables.submissionIdsByStatus[$0.rawValue] ?? [] } ?? tables.submissionIds
        let values = scan(ids, start: start).compactMap { tables.submissions[$0] }.filter {
            query.conversationId == nil || $0.conversationId == query.conversationId
        }
        return page(values, limit: limit, order: start.order, id: { $0.id.rawValue })
    }
    /// Returns the submission for the conversation-scoped request key, or nil.
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) throws -> SubmissionRecord? {
        try assertOpen()
        guard let id = tables.submissionIdsByRequest[conversationId]?[MemoryStringKey(requestId)] else { return nil }
        return tables.submissions[id]
    }

    /// Finds the document incarnation alive at the address and requested point.
    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) throws -> DocumentRecord? {
        try assertOpen()
        guard let index = tables.documentAddresses[MemoryAddressKey(address)] else { return nil }
        if at == .current { return index.currentId.flatMap { tables.documents[$0]?.record } }
        return index.ids.compactMap { tables.documents[$0]?.record }.first { $0.memoryAlive(at) }
    }
    /// Returns the stored document incarnation at the requested point, or nil when absent.
    public func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) throws -> StoredDocument? {
        try assertOpen(); return try tables.materialize(id, at: at)
    }
    /// Returns a page of document incarnations alive at the requested point.
    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) throws -> Page<DocumentRecord, Cursor> {
        try assertOpen()
        // Unlike ordered table scans, upstream document scans ignore the cursor's order.
        var after: Int64?
        if let value = cursor?["after"] {
            guard let number = value.numberValue, let integer = Int64(exactly: number),
                  integer >= -Seq.maximumRawValue, integer <= Seq.maximumRawValue else { throw DurableStorageError.invalidCursor }
            after = integer
        }
        let ids = tables.documentIdsByScope[MemoryScopeKey(query.scope)] ?? []
        let values = ids.filter { after == nil || $0.rawValue > after! }.compactMap { tables.documents[$0]?.record }.filter {
            (query.kind == nil || MemoryStringKey($0.kind) == MemoryStringKey(query.kind!)) && $0.memoryAlive(query.at)
        }
        return page(values, limit: limit, order: .ascending, id: { $0.id.rawValue })
    }

    /// Closing twice is permitted by the upstream backend. All reads and writes then reject.
    public func close(context: ChordContext) throws { closed = true }

    private func assertOpen() throws { if closed { throw DurableStorageError.closed(backend: "MemoryStorage") } }
    private func checkConversation(_ id: ConversationID) throws {
        if tables.conversations[id] == nil { throw DurableStorageError.unknownConversation(id) }
    }
    private func visibleEntries(_ conversationId: ConversationID, minimum: Int64, maximum: Int64, order: ScanOrder) throws -> [EntryRecord] {
        try checkConversation(conversationId)
        var segments: [(ConversationID, Int64)] = []
        var current = conversationId
        var upper = maximum
        while true {
            segments.append((current, upper))
            guard let parent = tables.conversations[current]!.parent else { break }
            upper = min(upper, parent.at.rawValue)
            if upper < minimum { break }
            current = parent.conversationId
        }
        if order == .ascending { segments.reverse() }
        return segments.flatMap { conversation, cap in
            let ids = (tables.entryIds[conversation] ?? []).filter { $0.rawValue >= minimum && $0.rawValue <= cap }
            let ordered = order == .ascending ? ids : Array(ids.reversed())
            return ordered.map { tables.entries[$0]! }
        }
    }
    private func scan<Kind>(_ ids: [DurableID<Kind>], start: ScanStart) -> [DurableID<Kind>] {
        let ordered = start.order == .ascending ? ids : Array(ids.reversed())
        guard let after = start.after else { return ordered }
        return ordered.filter { start.order == .ascending ? $0.rawValue > after : $0.rawValue < after }
    }
    private func page<Item>(_ values: [Item], limit: Int, order: ScanOrder, id: (Item) -> Int64) -> Page<Item, Cursor> {
        // Storage clients supply positive limits, as required by the upstream contract.
        let items = Array(values.prefix(max(0, limit)))
        let cursor: Cursor? = values.count > limit && !items.isEmpty
            ? ["after": .number(Double(id(items.last!))), "order": .string(order.rawValue)] : nil
        return Page(items: items, next: cursor)
    }
}
