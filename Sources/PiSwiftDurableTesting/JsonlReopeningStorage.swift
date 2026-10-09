import PiSwiftChord
import PiSwiftDurable

/// Reopens a file after each commit, including a rejected commit.
/// Use one wrapper per test case. The test must serialize its calls.
public actor JsonlReopeningStorage: DurableStorage {
    private var current: JsonlStorage
    private let directory: String
    private var closed = false

    /// Wraps JSONL storage and reopens the same directory after every commit.
    public init(storage: JsonlStorage, directory: String) {
        current = storage
        self.directory = directory
    }

    /// Atomically stores the write batch and returns its increasing commit sequence.
    public func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        if closed { return try await current.commit(writes, context: context) }
        let result: Result<Seq, any Error>
        do { result = .success(try await current.commit(writes, context: context)) }
        catch { result = .failure(error) }
        try await current.close(context: .background)
        current = try await JsonlStorage.open(directory: directory, fileSystem: LocalExecutionEnv(cwd: directory))
        return try result.get()
    }

    /// Allocates an unused positive ID from the shared record namespace.
    public func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await current.mintId()
    }

    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await current.conversation(id, context: context)
    }

    /// Returns a page of conversations that match all query filters.
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await current.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }

    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await current.entry(id, context: context)
    }

    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await current.entry(conversationId, id: id, context: context)
    }

    /// Returns the newest visible head marker at or below the inclusive entry cutoff.
    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await current.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }

    /// Returns a page of entries in the visible ancestry and requested range.
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await current.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }

    /// Returns the current stored task record, or nil when absent.
    public func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await current.task(id, context: context)
    }

    /// Returns a page of tasks that match all query filters.
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await current.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    /// Returns the current durable submission, or nil when it is absent.
    public func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await current.submission(id, context: context)
    }

    /// Returns a page of submissions that match all query filters.
    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await current.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }

    /// Returns the submission for the conversation-scoped request key, or nil.
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await current.submissionByRequest(conversationId, requestId: requestId, context: context)
    }

    /// Finds the document incarnation alive at the address and requested point.
    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await current.findDocument(address, at: at, context: context)
    }

    /// Returns the stored document incarnation at the requested point, or nil when absent.
    public func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await current.document(id, at: at, context: context)
    }

    /// Returns a page of document incarnations alive at the requested point.
    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await current.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }

    /// Releases this object's resources and rejects later operations.
    public func close(context: ChordContext) async throws {
        if closed { return }
        closed = true
        try await current.close(context: context)
    }
}
