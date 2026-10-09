import PiSwiftChord
import PiSwiftDurable

/// Storage with commit records, gates, and one injected commit failure.
/// Port of `test/session-support.ts:37-113` by delegation.
actor ControlledStorage: DurableStorage {
    fileprivate actor Signal {
        private var resolved = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if resolved { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func resolve() {
            guard !resolved else { return }
            resolved = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    struct Gate: Sendable {
        private let enteredSignal: Signal
        private let releaseCall: @Sendable () async -> Void

        fileprivate init(entered: Signal, release: @escaping @Sendable () async -> Void) {
            enteredSignal = entered
            releaseCall = release
        }
        func waitUntilEntered() async { await enteredSignal.wait() }
        func release() async { await releaseCall() }
    }

    private struct Held: Sendable {
        let id: Int
        let gate = Signal()
        let entered = Signal()
    }

    private let storage = MemoryStorage()
    private var nextGateID = 0
    private var commitGate: Held?
    private var findGate: Held?
    private var commitFailure: (any Error)?
    private(set) var admittedCommits: [[StorageWrite]] = []
    private(set) var commits: [[StorageWrite]] = []
    private(set) var mintCount = 0
    private(set) var documentReadCount = 0

    func holdCommits() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        commitGate = held
        return Gate(entered: held.entered) { await self.releaseCommit(held) }
    }

    func holdFindDocument() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        findGate = held
        return Gate(entered: held.entered) { await self.releaseFind(held) }
    }

    /// Clears the commit gate. Calls already held remain held until their gate is released.
    func crash() { commitGate = nil }
    func failNextCommit(_ error: any Error) { commitFailure = error }

    private func releaseCommit(_ held: Held) async {
        if commitGate?.id == held.id { commitGate = nil }
        await held.gate.resolve()
    }

    private func releaseFind(_ held: Held) async {
        if findGate?.id == held.id { findGate = nil }
        await held.gate.resolve()
    }

    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        admittedCommits.append(writes)
        commits.append(writes)
        if let held = commitGate {
            await held.entered.resolve()
            await held.gate.wait()
        }
        if let failure = commitFailure {
            commitFailure = nil
            throw failure
        }
        return try await storage.commit(writes, context: context)
    }

    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        mintCount += 1
        return try await storage.mintId()
    }

    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        documentReadCount += 1
        return try await storage.document(id, at: at, context: context)
    }

    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        if let held = findGate {
            await held.entered.resolve()
            await held.gate.wait()
        }
        return try await storage.findDocument(address, at: at, context: context)
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await storage.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await storage.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await storage.entry(id, context: context)
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await storage.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await storage.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await storage.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await storage.task(id, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await storage.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await storage.submission(id, context: context)
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await storage.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await storage.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await storage.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws { try await storage.close(context: context) }
}
