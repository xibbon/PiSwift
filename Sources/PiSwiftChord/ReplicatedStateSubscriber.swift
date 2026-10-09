import Synchronization

/// An explicit cancellation token. Dropping the token does not cancel the subscription.
public final class ReplicatedStateSubscription: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    package init(_ action: @escaping @Sendable () -> Void) { self.action = Mutex(action) }

    /// Drop queued work. Do not cancel or wait for a listener that is already running.
    public func cancel() {
        let cancel = action.withLock { action in
            let result = action
            action = nil
            return result
        }
        cancel?()
    }
}

// Count publication drains and subscriber workers, including cancelled workers.
final class ReplicatedStateIdle: Sendable {
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
            let result = state.waiters
            state.waiters = []
            return result
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

final class ReplicatedStateSubscriber<Value: Sendable>: Sendable {
    struct Frame: Sendable {
        let value: Value
        let context: ChordContext
        let delivery: ReplicatedStateDelivery
    }
    private struct State {
        var pending: [Frame] = []
        var running = false
        var started = false
        var closed = false
    }
    private let storage = Mutex(State())
    private let listener: @Sendable (Value, ChordContext, ReplicatedStateDelivery) async throws -> Void
    private let report: @Sendable (any Error) -> Void
    private let idle: ReplicatedStateIdle

    init(idle: ReplicatedStateIdle,
         listener: @escaping @Sendable (Value, ChordContext, ReplicatedStateDelivery) async throws -> Void,
         report: @escaping @Sendable (any Error) -> Void) {
        self.idle = idle
        self.listener = listener
        self.report = report
    }

    func push(_ frame: Frame) {
        let start = storage.withLock { state in
            guard !state.closed else { return false }
            if state.pending.count == 100 {
                let hydration = state.started ? nil : state.pending.first
                state.pending.removeAll(keepingCapacity: true)
                if let hydration { state.pending.append(hydration) }
            }
            state.pending.append(frame)
            guard !state.running else { return false }
            state.running = true
            idle.start()
            return true
        }
        if start { Task { await self.drain() } }
    }

    func close() {
        storage.withLock {
            $0.closed = true
            $0.pending.removeAll()
        }
    }

    private func drain() async {
        while let frame = storage.withLock({ state -> Frame? in
            guard !state.closed, !state.pending.isEmpty else {
                state.running = false
                return nil
            }
            state.started = true
            return state.pending.removeFirst()
        }) {
            do { try await listener(frame.value, frame.context, frame.delivery) }
            catch { report(error) }
        }
        idle.finish()
    }
}
