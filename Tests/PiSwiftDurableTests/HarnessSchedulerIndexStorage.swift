import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Records storage commits and can hold one conversation read.
final class SchedulerIndexStorage: DurableStorage, Sendable {
    struct Commit: Sendable {
        let number: Int
        let writes: [StorageWrite]
    }
    let base: any DurableStorage
    let commits = SessionTestLog<Commit>()
    let readEntered = SessionTestGate()
    let readRelease = SessionTestGate()
    private let count = Mutex(0)
    private let heldConversation = Mutex<ConversationID?>(nil)
    init(_ base: any DurableStorage) { self.base = base }
    func holdConversation(_ id: ConversationID) { heldConversation.withLock { $0 = id } }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        let number = count.withLock { $0 += 1; return $0 }
        commits.append(Commit(number: number, writes: writes))
        return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        if heldConversation.withLock({ $0 }) == id {
            readEntered.release()
            await readRelease.wait()
        }
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
        try await base.task(id, context: context)
    }

    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submission(id, context: context)
    }

    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
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
