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

    private let storage: any DurableStorage
    init(_ storage: any DurableStorage = MemoryStorage()) { self.storage = storage }
    private var nextGateID = 0
    private var commitGate: Held?
    private var taskAbortMarkGate: (TaskID, Held)?
    private var publicationGate: Held?
    private var publicationGateAt: Int?
    private var publicationCount = 0
    var publicationCalls: Int { publicationCount }
    private var findGate: Held?
    private var taskReadGate: Held?
    private var commitFailure: (any Error)?
    private var publicationScopeFailure: (any Error)?
    private var taskReadFailure: (any Error)?
    // v1.5.2 D3a writer.ts:228–305: controllable prefix refusal/rejection.
    private var batchRefusal: (call: Int, stored: Int, error: any Error)?
    private var batchRejection: (call: Int, stored: Int, error: any Error)?
    private var skippedReceiptCall: Int?
    private var delaySeed: UInt32?
    private(set) var admittedCommits: [[StorageWrite]] = []
    private(set) var commits: [[StorageWrite]] = []
    private(set) var callBatchCounts: [Int] = []
    private(set) var entryReadCount = 0
    private(set) var conversationReadCount = 0
    private(set) var mintCount = 0
    private(set) var documentReadCount = 0
    private(set) var findDocumentReadCount = 0
    private(set) var entryScanCount = 0
    private(set) var headMarkerReadCount = 0
    private(set) var taskReadCount = 0
    private(set) var submissionReadCount = 0
    private(set) var conversationScanCount = 0

    func holdCommits() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        commitGate = held
        return Gate(entered: held.entered) { await self.releaseCommit(held) }
    }
    /// Holds only the storage batch that publishes one task's abort mark.
    func holdTaskAbortMark(_ taskId: TaskID) -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        taskAbortMarkGate = (taskId, held)
        return Gate(entered: held.entered) {
            if await self.taskAbortMarkGate?.1.id == held.id { await self.clearTaskAbortMarkGate() }
            await held.gate.resolve()
        }
    }
    private func clearTaskAbortMarkGate() { taskAbortMarkGate = nil }

    func holdFindDocument() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        findGate = held
        return Gate(entered: held.entered) { await self.releaseFind(held) }
    }
    func holdTaskRead() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        taskReadGate = held
        return Gate(entered: held.entered) { await self.releaseTaskRead(held) }
    }
    private func releaseTaskRead(_ held: Held) async {
        if taskReadGate?.id == held.id { taskReadGate = nil }
        await held.gate.resolve()
    }
    func holdPublication() -> Gate {
        nextGateID += 1
        let held = Held(id: nextGateID)
        publicationGate = held
        return Gate(entered: held.entered) { await self.releasePublication(held) }
    }
    func holdPublication(at ordinal: Int) -> Gate {
        let gate = holdPublication()
        publicationGateAt = ordinal
        return gate
    }

    /// Clears the commit gate. Calls already held remain held until their gate is released.
    func crash() { commitGate = nil }
    func failNextCommit(_ error: any Error) { commitFailure = error }
    func failNextPublicationScope(_ error: any Error) { publicationScopeFailure = error }
    func failNextTaskRead(_ error: any Error) { taskReadFailure = error }
    func refuseCall(_ call: Int, afterStored count: Int, error: any Error) {
        batchRefusal = (call, count, error)
    }
    func rejectCall(_ call: Int, afterStored count: Int, error: any Error) {
        batchRejection = (call, count, error)
    }
    func skipReceipts(onCall call: Int) { skippedReceiptCall = call }
    /// v1.5.2 D3a stress: deterministic gate delays without clocks or sleeps.
    func enableCommitGateDelays(seed: UInt32) { delaySeed = seed }

    private func releaseCommit(_ held: Held) async {
        if commitGate?.id == held.id { commitGate = nil }
        await held.gate.resolve()
    }

    private func releaseFind(_ held: Held) async {
        if findGate?.id == held.id { findGate = nil }
        await held.gate.resolve()
    }
    private func releasePublication(_ held: Held) async {
        if publicationGate?.id == held.id { publicationGate = nil }
        publicationGateAt = nil
        await held.gate.resolve()
    }

    // v1.5.2 D2: mechanical batch forwarding for this storage test double.
    func commit(_ batches: [[StorageWrite]], receive: @Sendable (Int, Seq) -> Void, context: ChordContext) async throws -> CommitResult {
        let writes = batches.flatMap { $0 }
        callBatchCounts.append(batches.count)
        let call = callBatchCounts.count
        let refusal = batchRefusal?.call == call ? batchRefusal : nil
        let rejection = batchRejection?.call == call ? batchRejection : nil
        let skipReceipts = skippedReceiptCall == call
        if refusal != nil { batchRefusal = nil }
        if rejection != nil { batchRejection = nil }
        if skipReceipts { skippedReceiptCall = nil }
        admittedCommits.append(writes)
        commits.append(writes)
        if let held = commitGate {
            await held.entered.resolve()
            await held.gate.wait()
        }
        if let (taskId, held) = taskAbortMarkGate,
           writes.contains(where: { write in
               if case .task(let record) = write { return record.value.id == taskId && record.value.abortRequested }
               return false
           }) {
            await held.entered.resolve()
            await held.gate.wait()
        }
        if var seed = delaySeed {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            delaySeed = seed
            let turns = Int(seed % 4)
            if turns > 0 {
                let release = Signal()
                Task {
                    for _ in 0..<turns { await Task.yield() }
                    await release.resolve()
                }
                await release.wait()
            }
        }
        if let failure = commitFailure {
            commitFailure = nil
            throw failure
        }
        if let refusal {
            _ = try await storage.commit(Array(batches.prefix(refusal.stored)), receive: receive, context: context)
            return CommitResult(stored: refusal.stored, refused: refusal.error)
        }
        if let rejection {
            _ = try await storage.commit(Array(batches.prefix(rejection.stored)), receive: receive, context: context)
            throw rejection.error
        }
        if skipReceipts {
            return try await storage.commit(batches, receive: { _, _ in }, context: context)
        }
        return try await storage.commit(batches, receive: receive, context: context)
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
        findDocumentReadCount += 1
        if let held = findGate {
            await held.entered.resolve()
            await held.gate.wait()
        }
        return try await storage.findDocument(address, at: at, context: context)
    }

    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        conversationReadCount += 1
        return try await storage.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        conversationScanCount += 1
        return try await storage.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        entryReadCount += 1
        return try await storage.entry(id, context: context)
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await storage.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        headMarkerReadCount += 1
        return try await storage.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        entryScanCount += 1
        return try await storage.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        taskReadCount += 1
        if let error = taskReadFailure {
            taskReadFailure = nil
            throw error
        }
        let value = try await storage.task(id, context: context)
        if let held = taskReadGate {
            await held.entered.resolve()
            await held.gate.wait()
        }
        return value
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await storage.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        submissionReadCount += 1
        return try await storage.submission(id, context: context)
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
    func publishing(_ publish: @Sendable () -> Void, context: ChordContext) async throws {
        publicationCount += 1
        if let held = publicationGate, publicationGateAt == nil || publicationGateAt == publicationCount {
            await held.entered.resolve()
            await held.gate.wait()
        }
        if let failure = publicationScopeFailure {
            publicationScopeFailure = nil
            throw failure
        }
        try await storage.publishing(publish, context: context)
    }
    func close(context: ChordContext) async throws { try await storage.close(context: context) }
}
