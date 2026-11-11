import PiSwiftChord
import Synchronization

/// D4 removes this event-only adapter. It keeps at most 100 pending batches plus one active call.
/// Below that bound it delivers every batch once, in order. Overflow replaces the pending batches
/// with a current snapshot, as required by the existing watchEvents contract. It never folds events.
internal final class DurableEventBuffer: Sendable {
    typealias Listener = @Sendable ([DurableAgentEvent], ChordContext) async throws -> Void
    private struct Frame: Sendable {
        let events: [DurableAgentEvent]
        let context: ChordContext
    }
    private struct State {
        var listener: Listener?
        var pending: [Frame] = []
        var started = false
        var running = false
        var end: WatchEnd?
        var closedWaiters: [CheckedContinuation<WatchEnd, Never>] = []
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var signal: AbortSignal?
        var registration: AbortListenerRegistration?
        var detach: (@Sendable () -> Void)?
        var snapshot: (@Sendable () -> DurableAgentSnapshot)?
        var report: (@Sendable (any Error) -> Void)?
    }
    private let storage: Mutex<State>
    init(detach: @escaping @Sendable () -> Void,
         snapshot: @escaping @Sendable () -> DurableAgentSnapshot,
         report: @escaping @Sendable (any Error) -> Void) {
        storage = Mutex(State(detach: detach, snapshot: snapshot, report: report))
    }

    func start(_ listener: @escaping Listener) throws {
        let run = try storage.withLock { state in
            guard !state.started else { throw WatchError.alreadyStarted }
            guard state.end == nil else { throw WatchError.stopped }
            state.started = true
            state.listener = listener
            return schedule(&state)
        }
        if run { Task { await drain() } }
    }
    func stop() async -> WatchEnd { terminate(.stopped); return await closed }
    var closed: WatchEnd {
        get async {
            await withCheckedContinuation { continuation in
                let end = storage.withLock { state -> WatchEnd? in
                    if let end = state.end { return end }
                    state.closedWaiters.append(continuation)
                    return nil
                }
                if let end { continuation.resume(returning: end) }
            }
        }
    }
    func observeCancellation(_ signal: AbortSignal) throws {
        let install = try storage.withLock { state in
            guard state.signal == nil else { throw WatchError.abortAlreadyInstalled }
            guard state.end == nil else { return false }
            state.signal = signal
            return true
        }
        guard install else { return }
        let registration = signal.addAbortListener { [weak self] _ in self?.cancel() }
        let keep = storage.withLock { state in
            guard state.end == nil else { return false }
            state.registration = registration
            return true
        }
        if !keep { signal.removeAbortListener(registration) }
        if signal.aborted { cancel() }
    }
    func cancel() { terminate(.aborted) }
    func closeSession(_ error: (any Error)? = nil) {
        terminate(error.map { .failed(.message(String(describing: $0))) } ?? .ended)
    }
    func fail(_ error: any Error) {
        storage.withLock { $0.report }?(error)
        terminate(.listenerError(String(describing: error)))
    }
    func advance(_ events: [DurableAgentEvent], context: ChordContext) {
        let run = storage.withLock { state in
            guard state.end == nil else { return false }
            let next: [DurableAgentEvent]
            if state.pending.count >= 100 {
                state.pending.removeAll(keepingCapacity: true)
                // This private supplier reads one snapshot. It does not call the buffer or the Session.
                next = [.snapshot(state.snapshot!())]
            } else { next = events }
            state.pending.append(Frame(events: next, context: context.withoutAbortSignal()))
            return schedule(&state)
        }
        if run { Task { await drain() } }
    }
    private func schedule(_ state: inout State) -> Bool {
        guard state.started, !state.running, !state.pending.isEmpty else { return false }
        state.running = true
        return true
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let ready = storage.withLock { state in
                guard state.running else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func drain() async {
        while true {
            let (frame, listener, waiters) = storage.withLock { state -> (Frame?, Listener?, [CheckedContinuation<Void, Never>]) in
                guard state.end == nil, !state.pending.isEmpty, let listener = state.listener else {
                    state.running = false
                    let waiters = state.idleWaiters; state.idleWaiters = []
                    return (nil, nil, waiters)
                }
                return (state.pending.removeFirst(), listener, [])
            }
            guard let frame, let listener else {
                for waiter in waiters { waiter.resume() }
                return
            }
            do { try await listener(frame.events, frame.context) }
            catch { fail(error) }
        }
    }
    private func terminate(_ end: WatchEnd) {
        let result = storage.withLock { state -> ((@Sendable () -> Void)?, [CheckedContinuation<WatchEnd, Never>], AbortSignal?, AbortListenerRegistration?)? in
            guard state.end == nil else { return nil }
            state.end = end
            state.pending.removeAll()
            state.listener = nil
            let result = (state.detach, state.closedWaiters, state.signal, state.registration)
            state.detach = nil; state.snapshot = nil; state.report = nil
            state.closedWaiters = []; state.signal = nil; state.registration = nil
            return result
        }
        guard let (detach, waiters, signal, registration) = result else { return }
        if let signal, let registration { signal.removeAbortListener(registration) }
        detach?()
        for waiter in waiters { waiter.resume(returning: end) }
    }
}
