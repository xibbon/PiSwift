import PiSwiftChord
import Synchronization

/// An authoritative source for one attached state and its document incarnation.
package final class CommittedStateSource<Value: Sendable>: ReplicatedStateSource {
    private struct State {
        var value: Value?
        var cursor = 0
        var retired = false
        var closed = false
        var attachments: [ObjectIdentifier: CommittedSourceAttachment<Value>] = [:]
        var release: (@Sendable () -> Void)?
    }
    private let storage: Mutex<State>
    private let idle = CommittedSourceIdle()

    package init(value: Value, release: @escaping @Sendable () -> Void) {
        storage = Mutex(State(value: .some(value), release: release))
    }

    package func attach() throws -> any ReplicatedStateSourceAttachment<Value> {
        try storage.withLock { state in
            guard !state.closed, let value = state.value else {
                throw SessionError.message("State source is closed")
            }
            let attachment = CommittedSourceAttachment(
                snapshot: .init(value: value, cursor: state.cursor), idle: idle
            ) { [weak self] identity in self?.removeAttachment(identity) }
            state.attachments[ObjectIdentifier(attachment)] = attachment
            return attachment
        }
    }

    /// Register each frame under the source lock, then deliver outside all locks.
    /// Source delivery is synchronous; Chord's public subscribers remain async.
    package func advance(value: Value, ops: [Delta.Op], context: PiSwiftChord.Context,
                         retired: Bool = false) {
        let drains = storage.withLock { state -> [CommittedSourceAttachment<Value>] in
            guard !state.closed, !state.retired else { return [] }
            state.value = .some(value)
            state.cursor += 1
            state.retired = retired
            let frame = ReplicatedStateSourceFrame(cursor: state.cursor, value: value,
                ops: retired ? [.replace(.null)] : ops, context: context.withoutAbortSignal())
            return state.attachments.values.filter { $0.enqueue(frame) }
        }
        for attachment in drains { attachment.drain() }
    }

    package func closeSession() {
        let result = storage.withLock { state ->
            ([CommittedSourceAttachment<Value>], (@Sendable () -> Void)?)? in
            guard !state.closed else { return nil }
            state.closed = true
            state.value = nil
            let result = (Array(state.attachments.values), state.release)
            state.attachments.removeAll()
            state.release = nil
            return result
        }
        guard let (attachments, release) = result else { return }
        for attachment in attachments { attachment.dispose() }
        release?()
    }

    package func waitUntilIdle() async { await idle.wait() }

    private func removeAttachment(_ identity: ObjectIdentifier) {
        let release = storage.withLock { state -> (@Sendable () -> Void)? in
            state.attachments.removeValue(forKey: identity)
            guard !state.closed, state.attachments.isEmpty else { return nil }
            state.closed = true
            state.value = nil
            let release = state.release
            state.release = nil
            return release
        }
        release?()
    }
}

private final class CommittedSourceAttachment<Value: Sendable>: ReplicatedStateSourceAttachment {
    let snapshot: ReplicatedStateSourceSnapshot<Value>
    typealias Listener = @Sendable (ReplicatedStateSourceFrame<Value>) -> Void
    private struct State {
        var listener: Listener?
        var frames: [ReplicatedStateSourceFrame<Value>] = []
        var active = false
        var disposed = false
        var draining = false
        var release: (@Sendable (ObjectIdentifier) -> Void)?
    }
    private let storage: Mutex<State>
    private let idle: CommittedSourceIdle

    init(snapshot: ReplicatedStateSourceSnapshot<Value>, idle: CommittedSourceIdle,
         release: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.snapshot = snapshot
        self.idle = idle
        storage = Mutex(State(release: release))
    }

    func activate(_ listener: @escaping Listener) throws {
        let start = try storage.withLock { state in
            guard !state.active else { throw SessionError.message("State attachment is already active") }
            guard !state.disposed else { throw SessionError.message("State attachment is disposed") }
            state.active = true
            state.listener = listener
            guard !state.draining else { return false }
            state.draining = true
            idle.start()
            return true
        }
        if start { drain() }
    }

    func enqueue(_ frame: ReplicatedStateSourceFrame<Value>) -> Bool {
        storage.withLock { state in
            guard !state.disposed else { return false }
            state.frames.append(frame)
            guard state.active, !state.draining else { return false }
            state.draining = true
            idle.start()
            return true
        }
    }

    func drain() {
        while let next = storage.withLock({ state ->
            (ReplicatedStateSourceFrame<Value>, Listener)? in
            guard !state.disposed, !state.frames.isEmpty, let listener = state.listener else {
                state.draining = false
                return nil
            }
            return (state.frames.removeFirst(), listener)
        }) { next.1(next.0) }
        idle.finish()
    }

    func dispose() {
        let release = storage.withLock { state -> (@Sendable (ObjectIdentifier) -> Void)? in
            guard !state.disposed else { return nil }
            state.disposed = true
            state.frames.removeAll()
            state.listener = nil
            let release = state.release
            state.release = nil
            return release
        }
        release?(ObjectIdentifier(self))
    }
}

private final class CommittedSourceIdle: Sendable {
    private struct State {
        var workers = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let storage = Mutex(State())
    func start() { storage.withLock { $0.workers += 1 } }
    func finish() {
        let waiters = storage.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.workers -= 1
            guard state.workers == 0 else { return [] }
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = storage.withLock { state in
                if state.workers == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
