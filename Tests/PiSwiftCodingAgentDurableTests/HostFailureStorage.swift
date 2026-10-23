import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization

final class HostFailureStorage: DurableStorage {
    private struct State: Sendable {
        var nextFailure: (any Error)?
        var commits = 0
        var closes = 0
    }
    let base: any DurableStorage
    let closeFailure: (any Error)?
    private let state = Mutex(State())
    init(base: any DurableStorage = MemoryStorage(), closeFailure: (any Error)? = nil) {
        self.base = base
        self.closeFailure = closeFailure
    }
    var commitCount: Int { state.withLock { $0.commits } }
    var closeCount: Int { state.withLock { $0.closes } }
    func failNextCommit(_ error: any Error) { state.withLock { $0.nextFailure = error } }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        let failure = state.withLock { state in
            state.commits += 1
            let failure = state.nextFailure
            state.nextFailure = nil
            return failure
        }
        if let failure { throw failure }
        return try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await base.conversation(id, context: context)
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

    func close(context: ChordContext) async throws {
        state.withLock { $0.closes += 1 }
        try await base.close(context: context)
        if let closeFailure { throw closeFailure }
    }
}
