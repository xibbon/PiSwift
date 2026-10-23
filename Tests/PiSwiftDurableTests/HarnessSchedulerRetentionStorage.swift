import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Counts storage reads and holds one conversation read.
final class RetentionProbeStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    struct Counts: Sendable {
        var tasks = 0
        var conversations = 0
        var queuedScans = 0
        var heldConversation: ConversationID?
        var heldReads = 0
    }
    let counts = Mutex(Counts())
    let reached = SessionTestGate()
    let release = SessionTestGate()
    init(_ base: any DurableStorage) { self.base = base }
    var reads: Int { counts.withLock { $0.tasks + $0.conversations } }
    var queuedScans: Int { counts.withLock { $0.queuedScans } }
    func holdSecondRead(of id: ConversationID) {
        counts.withLock { $0.heldConversation = id; $0.heldReads = 0 }
    }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        let pause = counts.withLock { state -> Bool in
            state.conversations += 1
            guard state.heldConversation == id else { return false }
            state.heldReads += 1
            return state.heldReads == 2
        }
        if pause { reached.release(); await release.wait() }
        return try await base.conversation(id, context: context)
    }

    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }

    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(id, context: context)
    }

    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(conversationId, id: id, context: context)
    }

    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }

    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }

    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        counts.withLock { $0.tasks += 1 }
        return try await base.task(id, context: context)
    }

    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submission(id, context: context)
    }

    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        if query.status == .queued { counts.withLock { $0.queuedScans += 1 } }
        return try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }

    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }

    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await base.findDocument(address, at: at, context: context)
    }

    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await base.document(id, at: at, context: context)
    }

    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }

    func close(context: ChordContext) async throws { try await base.close(context: context) }
}
