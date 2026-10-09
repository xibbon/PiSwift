import PiSwiftChord
import Synchronization

/// The first condition that stops a watch. A listener error stops only its watch.
public enum WatchEnd: Sendable {
    /// The attachment stopped delivering values.
    case stopped
    /// The caller cancelled the watch.
    case cancelled
    /// The session closed and ended its watches.
    case sessionClosed
    /// The watched document incarnation ended.
    case retired
    /// A watch listener failed while processing an update.
    case listenerError(any Error)
}

/// A serial watch of committed values from one document incarnation.
public final class CommittedWatch<Value: Sendable>: Sendable {
    /// Receives each committed value and its JSON operations serially with the delivery context.
    public typealias Listener = @Sendable (Value, [Delta.Op], ChordContext) async throws -> Void

    private final class OverflowReservation: Sendable {}
    private struct Frame: Sendable {
        let value: Value
        let ops: [Delta.Op]
        let context: ChordContext
        let retired: Bool
        let reservation: OverflowReservation?
    }
    private struct State {
        var value: Value
        var listener: Listener?
        var pending: [Frame] = []
        var started = false
        var running = false
        var replacements = 0
        var retired = false
        var end: WatchEnd?
        var closedWaiters: [CheckedContinuation<WatchEnd, Never>] = []
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var cancellationSignal: AbortSignal?
        var cancellationRegistration: AbortListenerRegistration?
    }
    private let storage: Mutex<State>
    private let replacement: @Sendable (Value) -> JSONValue
    private let replace: (@Sendable () -> Value)?
    private let detach: @Sendable () -> Void

    package init(value: Value, replacement: @escaping @Sendable (Value) -> JSONValue,
                 detach: @escaping @Sendable () -> Void,
                 replace: (@Sendable () -> Value)? = nil) {
        storage = Mutex(State(value: value))
        self.replacement = replacement
        self.replace = replace
        self.detach = detach
    }

    /// The acquisition value, followed by the value of the last delivered frame.
    public var value: Value { storage.withLock { $0.value } }

    /// Install one listener. Each call runs on a Task, and calls do not overlap.
    public func start(_ listener: @escaping Listener) throws {
        let start = try storage.withLock { state in
            guard !state.started else { throw SessionError.message("Watch is already started") }
            guard state.end == nil else { throw SessionError.message("Watch is stopped") }
            state.started = true
            state.listener = listener
            guard let first = state.pending.first, first.reservation == nil, !state.running else { return false }
            state.running = true
            return true
        }
        if start { Task { await self.drain() } }
    }

    /// Stop future delivery. Do not wait for a listener call that has started.
    public func stop() async -> WatchEnd {
        terminate(.stopped)
        return await closed
    }

    /// End task watches before the invocation signal is aborted.
    internal func stopForInvocation() { terminate(.stopped) }

    /// Await the terminal condition. An in-flight listener can finish afterwards.
    public var closed: WatchEnd {
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

    package func observeCancellation(_ signal: AbortSignal) throws {
        let install = try storage.withLock { state in
            guard state.cancellationSignal == nil else {
                throw SessionError.message("Watch cancellation is already installed")
            }
            guard state.end == nil else { return false }
            state.cancellationSignal = signal
            return true
        }
        guard install else { return }
        let registration = signal.addAbortListener { [weak self] _ in self?.cancel() }
        let keep = storage.withLock { state in
            guard state.end == nil else { return false }
            state.cancellationRegistration = registration
            return true
        }
        if !keep { signal.removeAbortListener(registration) }
        if signal.aborted { cancel() }
    }

    package func cancel() { terminate(.cancelled) }
    package func closeSession() { terminate(.sessionClosed) }
    package func fail(_ error: any Error) { terminate(.listenerError(error)) }

    /// Keep at most 100 pending frames. Overflow replaces only the pending suffix.
    package func advance(value: Value, ops: [Delta.Op], context: ChordContext,
                         retired: Bool = false) {
        let deliveryContext = context.withoutAbortSignal()
        let (start, reservation) = storage.withLock { state -> (Bool, OverflowReservation?) in
            guard state.end == nil, !state.retired else { return (false, nil) }
            if retired { state.retired = true }
            var reservation: OverflowReservation?
            var operations = retired ? [.replace(.null)] : ops
            if state.pending.count >= 100 {
                state.pending.removeAll(keepingCapacity: true)
                if !retired {
                    reservation = OverflowReservation()
                    state.replacements += 1
                    operations = []
                }
            }
            state.pending.append(Frame(value: value, ops: operations,
                context: deliveryContext, retired: retired, reservation: reservation))
            guard state.started, !state.running, state.pending.first?.reservation == nil else {
                return (false, reservation)
            }
            state.running = true
            return (true, reservation)
        }
        if start { Task { await self.drain() } }
        guard let reservation else { return }
        // Reserve a queue position before these closures run. They can read
        // another source or publish a reentrant frame without holding our lock.
        let overflowValue = replace?() ?? value
        let operation = Delta.Op.replace(replacement(overflowValue))
        let (restart, waiters) = storage.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
            state.replacements -= 1
            if state.end == nil, let index = state.pending.firstIndex(where: { $0.reservation === reservation }) {
                state.pending[index] = Frame(value: overflowValue, ops: [operation], context: deliveryContext,
                    retired: false, reservation: nil)
            }
            if state.end == nil, state.started, !state.running,
               let first = state.pending.first, first.reservation == nil {
                state.running = true
                return (true, [])
            }
            return (false, Self.takeIdleWaiters(&state))
        }
        for waiter in waiters { waiter.resume() }
        if restart { Task { await self.drain() } }
    }

    /// Await queued and running delivery. Call this outside a listener.
    /// An unstarted watch is idle; its acquisition queue has no delivery worker.
    package func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let ready = storage.withLock { state in
                if !state.running, state.replacements == 0 { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func drain() async {
        while true {
            let (frame, listener, waiters) = storage.withLock { state ->
                (Frame?, Listener?, [CheckedContinuation<Void, Never>]) in
                guard state.end == nil, let first = state.pending.first, first.reservation == nil,
                      let listener = state.listener else {
                    state.running = false
                    return (nil, nil, Self.takeIdleWaiters(&state))
                }
                let frame = state.pending.removeFirst()
                state.value = frame.value
                return (frame, listener, [])
            }
            guard let frame, let listener else {
                for waiter in waiters { waiter.resume() }
                return
            }
            do { try await listener(frame.value, frame.ops, frame.context) }
            catch { terminate(.listenerError(error)) }
            if frame.retired { terminate(.retired) }
        }
    }

    private static func takeIdleWaiters(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        guard !state.running, state.replacements == 0 else { return [] }
        let waiters = state.idleWaiters
        state.idleWaiters = []
        return waiters
    }

    private func terminate(_ end: WatchEnd) {
        let result = storage.withLock { state ->
            ([CheckedContinuation<WatchEnd, Never>], AbortSignal?, AbortListenerRegistration?)? in
            guard state.end == nil else { return nil }
            state.end = end
            state.pending.removeAll()
            state.listener = nil
            let result = (state.closedWaiters, state.cancellationSignal, state.cancellationRegistration)
            state.closedWaiters = []
            state.cancellationSignal = nil
            state.cancellationRegistration = nil
            return result
        }
        guard let (waiters, signal, registration) = result else { return }
        if let signal, let registration { signal.removeAbortListener(registration) }
        detach()
        for waiter in waiters { waiter.resume(returning: end) }
    }
}
