import PiSwiftChord

/// The accepted prefix and the validation error that stopped the next batch.
/// A thrown error has an unknown storage outcome and is never a refusal.
public struct CommitResult: Sendable {
    public let stored: Int
    public let refused: (any Error & Sendable)?

    public init(stored: Int, refused: (any Error & Sendable)? = nil) {
        self.stored = stored
        self.refused = refused
    }
}

/// An entry and the sequence of the commit that first stored it.
public struct EntryLookup: Sendable, Equatable, Codable {
    /// The entry created or selected by this operation.
    public var entry: EntryRecord
    /// The commit sequence that first stored the entry.
    public var commitSeq: Seq
    /// Pairs an entry with the sequence that first stored it.
    public init(entry: EntryRecord, commitSeq: Seq) { self.entry = entry; self.commitSeq = commitSeq }
}

/// Atomic storage for one Session. The Session serializes commits.
/// Storage trusts record references, ancestry, and transitions. It enforces atomicity,
/// global ID ownership, immutable conversation and entry creation, document consistency,
/// and detached values. Index keys (`kind`, document `key`, and `requestId`) must be
/// compared by code units. Swift canonical string equality is not the index rule.
/// A thrown storage error fails the Session. A read can reject an invalid request with
/// `StorageRequestError`, with no durable effect, or reject because its context was
/// aborted; these errors fail only that read. Every thrown commit or mint error is fatal.
/// Retry temporary failures inside the storage method.
/// Context is the Chord context; Swift task cancellation does not replace it.
public protocol DurableStorage: Sendable {
    /// Persists nonempty batches in order, one atomic commit and sequence per batch.
    /// A batch sees the state left by the preceding accepted batch. Durable checks of
    /// global IDs, document actions, and copy resolution refuse the next batch as a
    /// value, leaving only the accepted prefix durable. A backend failure throws and
    /// its outcome is unknown. Receipts run once per durable batch in index order,
    /// after the accepted prefix is durable and before the next commit begins.
    /// A receipt records durability; publication is a later Session action.
    func commit(_ batches: [[StorageWrite]], receive: @Sendable (Int, Seq) -> Void, context: ChordContext) async throws -> CommitResult

    /// Runs one Session publication in this storage's scope, now or soon after.
    /// The publication must run exactly once before the next publication runs.
    func publishing(_ publish: @Sendable () -> Void, context: ChordContext) async throws

    /// Returns a fresh candidate ID from the one global numeric namespace. The kind is a phantom.
    /// Explicitly stored IDs also claim this namespace. Rejects when safe integer IDs are exhausted.
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind>

    /// Returns a detached conversation with this exact ID, or nil if absent.
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord?

    /// Returns detached conversations that match all owner filters, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor>

    /// Returns a detached global entry and its first commit sequence, or nil if absent.
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup?

    /// Returns a detached entry and its first commit sequence only if visible in this ancestry.
    /// An absent entry returns nil; an unknown conversation rejects.
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup?

    /// Returns the newest detached visible entry with a head, at or below the inclusive cutoff.
    /// The returned record is the marker; its non-nil head is the actual context lower bound.
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord?

    /// Returns at most limit detached entries in the inclusive fork-aware range, descending by default.
    /// Honors each ancestry cap. A cursor keeps its order and rejects an order change.
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor>

    /// Returns the latest detached complete task record, or nil if absent.
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord?

    /// Returns detached task records that match every filter, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor>

    /// Returns the latest detached complete submission record, or nil if absent.
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord?

    /// Returns detached submissions that match every filter, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor>

    /// Returns a detached submission for this conversation-scoped code-unit request key, or nil.
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord?

    /// Returns detached metadata for the incarnation at this exact logical address and point, or nil.
    /// An absent key selects the singleton. Historical metadata remains queryable for all scopes.
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord?

    /// Materializes one incarnation as a detached value; never follows a replacement at its address.
    /// Returns nil for an unknown ID or outside its half-open lifetime. Known current-only documents
    /// reject historical content reads. Missing bases, version boundaries in delta tails, and invalid
    /// replay operations are corruption errors. The result counts deltas after the selected base.
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument?

    /// Returns at most limit detached incarnation records alive in the exact scope at the point.
    /// Orders by ascending incarnation ID; an optional kind restricts singleton or family kind.
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor>

    /// Releases storage resources. Every later operation must reject.
    func close(context: ChordContext) async throws
}

public extension DurableStorage {
    /// Default publication has no storage-specific scope.
    func publishing(_ publish: @Sendable () -> Void, context: ChordContext) async throws { publish() }

}
