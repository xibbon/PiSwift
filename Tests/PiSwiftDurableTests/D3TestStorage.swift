import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// A test host keeps its store open across Harness instances.
/// After a simulated crash, cleanup writes have no durable effect.
final class D3TestStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    let events: SessionTestLog<String>
    private struct State {
        var crashed = false
        var failedStatus: String?
        var conversationGate: (entered: SessionTestGate, release: SessionTestGate)?
    }
    private let state = Mutex(State())
    init(_ base: any DurableStorage = MemoryStorage(), events: SessionTestLog<String> = SessionTestLog()) {
        self.base = base; self.events = events
    }
    func crash() { state.withLock { $0.crashed = true } }
    func failNext(_ status: String) { state.withLock { $0.failedStatus = status } }
    func holdConversations(entered: SessionTestGate, release: SessionTestGate) {
        state.withLock { $0.conversationGate = (entered, release) }
    }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        let statuses = writes.compactMap { write -> String? in
            if case .task(let task, _) = write { return task.state.status }; return nil
        }
        let action = state.withLock { current -> Int in
            if current.crashed { return 1 }
            if let status = current.failedStatus, statuses.contains(status) {
                current.failedStatus = nil; return 2
            }
            return 0
        }
        if action == 1 { return try Seq(9_000_000_000) }
        if action == 2 { events.append("failed " + statuses.joined(separator: ",")); throw TaskDefinitionError("D3 write failed") }
        let sequence = try await base.commit(writes, context: context)
        for status in statuses { events.append("saved " + status) }
        return sequence
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        if let gate = state.withLock({ $0.conversationGate }) {
            gate.entered.release(); await gate.release.wait()
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

    func close(context: ChordContext) async throws {}
}
