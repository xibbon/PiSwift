import PiSwiftChord
import PiSwiftDurable

/// Reopens a file after each commit, including a rejected commit.
/// Use one wrapper per test case. The test must serialize its calls.
public actor ReopeningStorage: DurableStorage {
    private var current: SqliteStorage
    private let path: String
    private var closed = false

    public init(storage: SqliteStorage, path: String) {
        current = storage
        self.path = path
    }

    public func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        if closed { return try await current.commit(writes, context: context) }
        let result: Result<Seq, any Error>
        do { result = .success(try await current.commit(writes, context: context)) }
        catch { result = .failure(error) }
        try await current.close(context: .background)
        current = try await SqliteStorage.open(path: path)
        return try result.get()
    }

    public func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await current.mintId()
    }

    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await current.conversation(id, context: context)
    }

    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await current.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }

    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await current.entry(id, context: context)
    }

    public func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await current.entry(conversationId, id: id, context: context)
    }

    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await current.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }

    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await current.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }

    public func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await current.task(id, context: context)
    }

    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await current.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    public func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await current.submission(id, context: context)
    }

    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await current.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }

    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await current.submissionByRequest(conversationId, requestId: requestId, context: context)
    }

    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await current.findDocument(address, at: at, context: context)
    }

    public func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await current.document(id, at: at, context: context)
    }

    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await current.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }

    public func close(context: ChordContext) async throws {
        if closed { return }
        closed = true
        try await current.close(context: context)
    }
}
