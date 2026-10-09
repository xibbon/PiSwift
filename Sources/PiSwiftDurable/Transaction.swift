import PiSwiftChord
import Synchronization

internal struct TransactionScope: Sendable {
    let conversationId: ConversationID?
    let taskId: TaskID?
    init(conversationId: ConversationID? = nil, taskId: TaskID? = nil) {
        self.conversationId = conversationId; self.taskId = taskId
    }
}

/// One change callback. All operations and draft handles end when the callback settles.
public final class Transaction: Sendable {
    internal let session: Session
    internal let storage: any DurableStorage
    internal let context: ChordContext
    internal let scope: TransactionScope
    internal let now: @Sendable () -> Int64
    internal let conversationCreated: @Sendable (Transaction, ConversationRecord) async throws -> Void
    internal let tableState = Mutex(TransactionTableState())
    internal let documents = TransactionDocuments()
    internal let lifetime = DraftLifetime()
    private struct State: Sendable {
        var sealed = false
        var hasTableWrite = false
        var pending = 0
        var drain: [CheckedContinuation<Void, Never>] = []
        var settlementWaiters: [CheckedContinuation<Void, Never>] = []
        var pendingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())
    internal init(session: Session, context: ChordContext, scope: TransactionScope) {
        self.session = session; storage = session.storage; self.context = context; self.scope = scope
        now = session.now
        conversationCreated = { tx, record in try await session.hooks.conversationCreated(tx, record: record) }
    }
    internal func assertOpen() throws {
        try state.withLock { if $0.sealed { throw SessionError.settled } }
    }
    private func beginOperation(tableRead: String?, tableWrite: Bool) throws {
        let waiters = try state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if state.sealed { throw SessionError.settled }
            if let tableRead, state.hasTableWrite { throw ReadAfterWrite(tableRead) }
            if tableWrite { state.hasTableWrite = true }
            state.pending += 1
            let ready = state.pendingWaiters.filter { $0.count <= state.pending }
            state.pendingWaiters.removeAll { $0.count <= state.pending }
            return ready.map(\.continuation)
        }
        for waiter in waiters { waiter.resume() }
    }
    internal func operation<T>(tableRead: String? = nil, tableWrite: Bool = false,
                               _ body: () async throws -> T) async throws -> T {
        try beginOperation(tableRead: tableRead, tableWrite: tableWrite)
        defer { endOperation() }
        return try await body()
    }
    internal func synchronousOperation<T>(tableWrite: Bool = false, _ body: () throws -> T) throws -> T {
        try beginOperation(tableRead: nil, tableWrite: tableWrite)
        defer { endOperation() }
        return try body()
    }
    /// Wait for admitted operations. Used by deterministic settlement tests.
    internal func waitUntilPendingOperations(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.pending >= count { return true }
                state.pendingWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func endOperation() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.pending -= 1
            guard state.pending == 0 else { return [] }
            let waiters = state.drain; state.drain = []; return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func drain() async {
        await withCheckedContinuation { continuation in
            let complete = state.withLock { state in
                if state.pending == 0 { return true }
                state.drain.append(continuation); return false
            }
            if complete { continuation.resume() }
        }
    }
    internal func waitUntilSettled() async {
        await withCheckedContinuation { continuation in
            let complete = state.withLock { state in
                if state.sealed { return true }
                state.settlementWaiters.append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }
    private func seal() -> Bool {
        let (pending, waiters) = state.withLock { state in
            // Seal admission and draft access together before any change is prepared or aborted.
            lifetime.revoke()
            state.sealed = true
            let waiters = state.settlementWaiters
            state.settlementWaiters = []
            return (state.pending > 0, waiters)
        }
        for waiter in waiters { waiter.resume() }
        return pending
    }
    internal func settleFailure() async {
        _ = seal()
        documents.abort()
        await drain()
        documents.abort()
    }
    internal func settleSuccess() async throws -> [StorageWrite] {
        let pending = seal()
        if pending {
            documents.abort()
            await drain()
            documents.abort()
            throw SessionError.pendingOperations
        }
        do {
            try documents.prepare()
            let tables = try await assembleTables()
            return tables + (try await documents.assemble(tx: self))
        } catch {
            documents.abort()
            throw error
        }
    }
    internal func discard() { documents.abort() }
    internal func adopt(_ seq: Seq) throws -> [DocumentCommitChange] {
        try documents.adopt(seq: seq, session: session)
    }
}
