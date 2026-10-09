import PiSwiftChord

/// An entry and the sequence of the commit that first stored it.
public struct EntryLookup: Sendable, Equatable, Codable {
    public var entry: EntryRecord
    public var commitSeq: Seq
    public init(entry: EntryRecord, commitSeq: Seq) { self.entry = entry; self.commitSeq = commitSeq }
}

/// Atomic storage for one Session. The Session serializes commits.
/// Storage trusts record references, ancestry, and transitions. It enforces atomicity,
/// global ID ownership, immutable conversation and entry creation, document consistency,
/// and detached values. Index keys (`kind`, document `key`, and `requestId`) must be
/// compared by code units. Swift canonical string equality is not the index rule.
/// Context is the Chord context; Swift task cancellation does not replace it.
public protocol DurableStorage: Sendable {
    /// Atomically stores the batch and returns a strictly increasing sequence; gaps are permitted.
    /// Later reads see the batch after this returns. `StorageRejected` is permitted only
    /// when no durable effect occurred. An unknown failure can have uncertain commit state.
    /// Document copies read committed pre-batch state. Content precedes retirement regardless
    /// of write order; version changes require bases. The Session serializes these calls.
    func commit(_ writes: [StorageWrite], context: PiSwiftChord.Context) async throws -> Seq

    /// Returns a fresh candidate ID from the one global numeric namespace. The kind is a phantom.
    /// Explicitly stored IDs also claim this namespace. Rejects when safe integer IDs are exhausted.
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind>

    /// Returns a detached conversation with this exact ID, or nil if absent.
    func conversation(_ id: ConversationID, context: PiSwiftChord.Context) async throws -> ConversationRecord?

    /// Returns detached conversations that match all owner filters, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<ConversationRecord, Cursor>

    /// Returns a detached global entry and its first commit sequence, or nil if absent.
    func entry(_ id: EntryID, context: PiSwiftChord.Context) async throws -> EntryLookup?

    /// Returns a detached entry and its first commit sequence only if visible in this ancestry.
    /// An absent entry returns nil; an unknown conversation rejects.
    func entry(_ conversationId: ConversationID, id: EntryID, context: PiSwiftChord.Context) async throws -> EntryLookup?

    /// Returns the newest detached visible entry with a head, at or below the inclusive cutoff.
    /// The returned record is the marker; its non-nil head is the actual context lower bound.
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: PiSwiftChord.Context) async throws -> EntryRecord?

    /// Returns at most limit detached entries in the inclusive fork-aware range, descending by default.
    /// Honors each ancestry cap. A cursor keeps its order and rejects an order change.
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<EntryRecord, Cursor>

    /// Returns the latest detached complete task record, or nil if absent.
    func task(_ id: TaskID, context: PiSwiftChord.Context) async throws -> TaskRecord?

    /// Returns detached task records that match every filter, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<TaskRecord, Cursor>

    /// Returns the latest detached complete submission record, or nil if absent.
    func submission(_ id: SubmissionID, context: PiSwiftChord.Context) async throws -> SubmissionRecord?

    /// Returns detached submissions that match every filter, by ID, ascending by default.
    /// Returns at most limit items; a cursor keeps its order and rejects an order change.
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<SubmissionRecord, Cursor>

    /// Returns a detached submission for this conversation-scoped code-unit request key, or nil.
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: PiSwiftChord.Context) async throws -> SubmissionRecord?

    /// Returns detached metadata for the incarnation at this exact logical address and point, or nil.
    /// An absent key selects the singleton. Historical metadata remains queryable for all scopes.
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: PiSwiftChord.Context) async throws -> DocumentRecord?

    /// Materializes one incarnation as a detached value; never follows a replacement at its address.
    /// Returns nil for an unknown ID or outside its half-open lifetime. Known current-only documents
    /// reject historical content reads. Missing bases, version boundaries in delta tails, and invalid
    /// replay operations are corruption errors. The result counts deltas after the selected base.
    func document(_ id: DocumentID, at: DocumentPoint, context: PiSwiftChord.Context) async throws -> StoredDocument?

    /// Returns at most limit detached incarnation records alive in the exact scope at the point.
    /// Orders by ascending incarnation ID; an optional kind restricts singleton or family kind.
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<DocumentRecord, Cursor>

    /// Releases storage resources. Every later operation must reject.
    func close(context: PiSwiftChord.Context) async throws
}
