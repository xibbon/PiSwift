import PiSwiftChord
import Synchronization

/// One first-cause latch shared by the Session and all backend calls.
internal final class SessionFailureLatch: Sendable {
    private struct State {
        var error: (any Error)?
        var notify: (@Sendable (any Error) -> Void)?
    }
    private let state = Mutex(State())
    private let failed = ChordContext.background.withCancel()
    var failure: (any Error)? { state.withLock { $0.error } }
    func install(_ notify: @escaping @Sendable (any Error) -> Void) {
        state.withLock { $0.notify = notify }
    }
    func check() throws {
        if let error = failure { throw SessionFailed(error) }
    }
    /// Claims the first error, or returns the cause that another call already claimed.
    @discardableResult
    func fail(_ error: any Error) -> (any Error)? {
        let (previous, notify) = state.withLock { state -> ((any Error)?, (@Sendable (any Error) -> Void)?) in
            if let previous = state.error { return (previous, nil) }
            state.error = error
            return (nil, state.notify)
        }
        guard previous == nil else { return previous }
        failed.cancel(SessionFailed(error))
        notify?(error)
        return nil
    }
    /// Failure ends this wait even when the work must remain alive for cleanup.
    func awaitHealthy<Value: Sendable>(_ work: Task<Value, any Error>, context: ChordContext) async throws -> Value {
        let waiting = context.withCancel()
        let signal = failed.context.abortSignal!
        let registration = signal.addAbortListener { reason in waiting.cancel(reason) }
        defer { signal.removeAbortListener(registration) }
        // Cover failure before registration and during registration.
        if let cause = failure { waiting.cancel(SessionFailed(cause)) }
        return try await awaitWithContext(work, waiting.context)
    }

}

/// All components use this guard, including reads outside the mutation line.
internal final class GuardedStorage: DurableStorage {
    private let backend: any DurableStorage
    private let latch: SessionFailureLatch
    private struct State {
        var closing = false
        var underway = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    internal var closing: Bool { state.withLock { $0.closing } }
    init(_ backend: any DurableStorage, latch: SessionFailureLatch) {
        self.backend = backend; self.latch = latch
    }
    private func call<T: Sendable>(read: ChordContext? = nil,
                                   _ run: () async throws -> T) async throws -> T {
        try state.withLock { state in
            try latch.check()
            if state.closing { throw SessionError.closed }
            state.underway += 1
        }
        defer {
            let waiters = state.withLock { state in
                state.underway -= 1
                guard state.underway == 0 else { return [CheckedContinuation<Void, Never>]() }
                let waiters = state.waiters; state.waiters.removeAll(); return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        let result: T
        do { result = try await run() }
        catch {
            try latch.check()
            let exempt = read != nil && (error is StorageRequestError || read?.abortSignal?.aborted == true)
            if !exempt, let cause = latch.fail(error) { throw SessionFailed(cause) }
            throw error
        }
        try latch.check()
        return result
    }
    func close(context: ChordContext) async throws {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                state.closing = true
                if state.underway == 0 { return true }
                state.waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
        try await backend.close(context: context)
    }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        try await self.call({ try await backend.commit(writes, context: context) })
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await self.call({ try await backend.mintId() })
    }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await self.call(read: context, { try await backend.conversation(id, context: context) })
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await self.call(read: context, { try await backend.scanConversations(query, limit: limit, cursor: cursor, context: context) })
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await self.call(read: context, { try await backend.entry(id, context: context) })
    }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await self.call(read: context, { try await backend.entry(conversationId, id: id, context: context) })
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await self.call(read: context, { try await backend.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context) })
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await self.call(read: context, { try await backend.scanEntries(query, limit: limit, cursor: cursor, context: context) })
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await self.call(read: context, { try await backend.task(id, context: context) })
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await self.call(read: context, { try await backend.scanTasks(query, limit: limit, cursor: cursor, context: context) })
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await self.call(read: context, { try await backend.submission(id, context: context) })
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await self.call(read: context, { try await backend.scanSubmissions(query, limit: limit, cursor: cursor, context: context) })
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await self.call(read: context, { try await backend.submissionByRequest(conversationId, requestId: requestId, context: context) })
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await self.call(read: context, { try await backend.findDocument(address, at: at, context: context) })
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await self.call(read: context, { try await backend.document(id, at: at, context: context) })
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await self.call(read: context, { try await backend.scanDocuments(query, limit: limit, cursor: cursor, context: context) })
    }
}
