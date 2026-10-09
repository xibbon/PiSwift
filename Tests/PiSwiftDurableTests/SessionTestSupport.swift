import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

/// A synchronous log for Session listeners and concurrent test tasks.
final class SessionTestLog<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])
    var values: [Value] { state.withLock { $0 } }
    var count: Int { state.withLock { $0.count } }
    func append(_ value: Value) { state.withLock { $0.append(value) } }
}

/// A gate with a persistent signal. Tests use signals instead of elapsed time.
final class SessionTestGate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { state in
            state.open = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

struct SessionTestHarness: Sendable {
    let storage: ControlledStorage
    let session: Session
    let publications: SessionTestLog<CommitPublication>
}

func openTestSession(now: @escaping @Sendable () -> Int64 = { 1_000 }) async throws -> SessionTestHarness {
    let storage = ControlledStorage()
    let session = try await Session.open(storage: storage, now: now, context: .background)
    let publications = SessionTestLog<CommitPublication>()
    _ = try session.subscribeCommits { publication, _ in publications.append(publication) }
    return SessionTestHarness(storage: storage, session: session, publications: publications)
}

func createConversation(_ session: Session) async throws -> ConversationID {
    try await session.commit({ tx in
        try await tx.createConversation(ownership: .ownerless()).id
    }, context: .background)
}

func documentChanges(_ publication: CommitPublication) -> [DocumentCommitChange] {
    publication.changes.compactMap { change in
        guard case .document(let document) = change, document.source == nil else { return nil }
        return document
    }
}

func documentCopyChanges(_ publication: CommitPublication) -> [DocumentCommitChange] {
    publication.changes.compactMap { change in
        guard case .document(let document) = change, document.source != nil else { return nil }
        return document
    }
}
