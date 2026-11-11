import Synchronization

/// An in-process watch. It delivers values in order with a bounded backlog.
public final class NativeWatch<Value: Sendable>: NativeWatchHandle, Sendable {
    private final class OverflowReservation: Sendable {}
    private struct Frame: Sendable {
        let value: Value?
        let context: ChordContext
        let reservation: OverflowReservation?
    }
    private struct State {
        var value: Value
        var listener: NativeWatchListener<Value>?
        var started = false
        var running = false
        var ending = false
        var end: WatchEnd?
        var task: Task<Void, Never>?
        var pending: [Frame] = []
        var failure: (WatchFailure, ChordContext)?
        var waiters: [CheckedContinuation<WatchEnd, Never>] = []
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var detach: (@Sendable () -> Void)?
        var report: (@Sendable (any Error) -> Void)?
        var replace: (@Sendable () -> Value)?
        var signal: AbortSignal?
        var registration: AbortListenerRegistration?
    }
    private let state: Mutex<State>
    private let deliveryReady: @Sendable () async -> Void
    private let workerEmpty: @Sendable () async -> Void

    public convenience init(value: Value, detach: @escaping @Sendable () -> Void,
                report: @escaping @Sendable (any Error) -> Void = { _ in },
                replace: (@Sendable () -> Value)? = nil) {
        self.init(value: value, detach: detach, report: report, replace: replace, deliveryReady: {})
    }

    package init(value: Value, detach: @escaping @Sendable () -> Void,
                report: @escaping @Sendable (any Error) -> Void,
                replace: (@Sendable () -> Value)? = nil,
                deliveryReady: @escaping @Sendable () async -> Void,
                workerEmpty: @escaping @Sendable () async -> Void = {}) {
        state = Mutex(State(value: value, detach: detach, report: report, replace: replace))
        self.deliveryReady = deliveryReady
        self.workerEmpty = workerEmpty
    }

    public var value: Value { state.withLock { $0.value } }

    /// Wait for a running delivery worker to exit. Used to synchronize differential replay.
    package func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let idle = state.withLock { s in
                if !s.running { return true }
                s.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    // watch.ts:148-155 start
    public func start(_ listener: @escaping NativeWatchListener<Value>) throws {
        let run = try state.withLock { s in
            if s.started { throw WatchError.alreadyStarted }
            if s.end != nil { throw WatchError.stopped }
            s.started = true
            s.listener = listener
            return schedule(&s)
        }
        if run { launch() }
    }

    // watch.ts:157-177 stop, observeAbort, abort
    public func stop() async -> WatchEnd { terminate(.stopped); return await closed }

    public var closed: WatchEnd {
        get async {
            await withCheckedContinuation { continuation in
                let end = state.withLock { s -> WatchEnd? in
                    if let end = s.end { return end }
                    s.waiters.append(continuation)
                    return nil
                }
                if let end { continuation.resume(returning: end) }
            }
        }
    }

    public func observeAbort(_ signal: AbortSignal) throws {
        let install = try state.withLock { s in
            if s.signal != nil { throw WatchError.abortAlreadyInstalled }
            if s.end != nil { return false }
            s.signal = signal
            return true
        }
        guard install else { return }
        let registration = signal.addAbortListener { [weak self] _ in self?.abort() }
        let keep = state.withLock { s in
            if s.end != nil { return false }
            s.registration = registration
            return true
        }
        if !keep { signal.removeAbortListener(registration) }
        if signal.aborted { abort() }
    }

    public func abort() { terminate(.aborted) }

    // watch.ts:179-202 end, endAfterDelivery
    public func end(_ end: WatchEnd) { terminate(end) }

    public func endAfterDelivery() {
        let finish = state.withLock { s in
            if s.end != nil || s.ending { return false }
            s.ending = true
            return !s.running && s.pending.isEmpty && s.failure == nil
        }
        if finish { terminate(.ended) }
    }

    // watch.ts:416-430 advance
    public func advance(_ value: Value, context: ChordContext) {
        var reservation: OverflowReservation?
        var replacement: (@Sendable () -> Value)?
        let run = state.withLock { s -> Bool in
            if s.end != nil || s.ending { return false }
            s.failure = nil
            if s.pending.count < 100 {
                s.pending.append(Frame(value: value, context: context, reservation: nil))
            } else {
                s.pending.removeAll(keepingCapacity: true)
                let marker = OverflowReservation()
                reservation = marker
                replacement = s.replace
                s.pending.append(Frame(value: nil, context: context, reservation: marker))
            }
            return schedule(&s)
        }
        if run { launch() }
        if let reservation {
            let current = replacement?() ?? value
            let restart = state.withLock { s -> Bool in
                guard s.end == nil,
                      let index = s.pending.firstIndex(where: { $0.reservation === reservation }) else { return false }
                s.pending[index] = Frame(value: current, context: context, reservation: nil)
                return schedule(&s)
            }
            if restart { launch() }
        }
    }

    // watch.ts:436-444 fail
    public func fail(_ error: WatchFailure, context: ChordContext) {
        let run = state.withLock { s -> Bool in
            if s.end != nil || s.ending { return false }
            s.pending.removeAll()
            s.failure = (error, context)
            return schedule(&s)
        }
        if run { launch() }
    }

    private func schedule(_ s: inout State) -> Bool {
        guard s.started, !s.running, s.end == nil,
              s.failure != nil || s.pending.first?.value != nil else { return false }
        s.running = true
        return true
    }

    private func launch() {
        let gate = WatchStartGate()
        let task = Task {
            await gate.wait()
            defer { finishWorker() }
            await deliveryReady()
            if !Task.isCancelled { await drain() }
        }
        let cancel = state.withLock { s -> Bool in
            if s.end != nil { return true }
            s.task = task
            return false
        }
        if cancel { task.cancel() }
        gate.release()
    }

    private func finishWorker() {
        let (finish, restart, waiters) = state.withLock { s -> (Bool, Bool, [CheckedContinuation<Void, Never>]) in
            s.running = false
            s.task = nil
            let finish = s.end == nil && s.ending && s.pending.isEmpty && s.failure == nil
            let restart = finish ? false : schedule(&s)
            let waiters = restart ? [] : s.idleWaiters
            if !restart { s.idleWaiters = [] }
            return (finish, restart, waiters)
        }
        if finish { terminate(.ended) }
        for waiter in waiters { waiter.resume() }
        if restart { launch() }
    }

    private enum Taken {
        case call(NativeWatchCall<Value>, ChordContext)
        case done(Bool)
    }

    // watch.ts:447-492 pendingContext, next, release; watch.ts:223-248 deliver
    private func take() -> Taken {
        state.withLock { s in
            if s.end != nil { return .done(false) }
            if let failure = s.failure {
                s.failure = nil
                return .call(.failed(failure.0), failure.1)
            }
            if let value = s.pending.first?.value {
                let frame = s.pending.removeFirst()
                s.value = value
                return .call(.value(value), frame.context)
            }
            // An overflow replacement is still being computed outside the lock.
            if !s.pending.isEmpty { return .done(false) }
            return .done(s.ending)
        }
    }

    private func drain() async {
        while true {
            switch take() {
            case .done(let ending):
                if ending { terminate(.ended) }
                else { await workerEmpty() }
                return
            case .call(let call, let context):
                guard let listener = state.withLock({ $0.listener }) else { return }
                do { try await listener(call, context.withoutAbortSignal()) }
                catch {
                    let report = state.withLock { s -> (@Sendable (any Error) -> Void)? in
                        s.end == nil ? s.report : nil
                    }
                    if let report {
                        report(error)
                        terminate(.listenerError(String(describing: error)))
                    }
                    return
                }
            }
        }
    }

    // watch.ts:249-270 terminate, release
    private func terminate(_ end: WatchEnd) {
        let closed = state.withLock { s -> (Task<Void, Never>?, (@Sendable () -> Void)?, AbortSignal?, AbortListenerRegistration?, [CheckedContinuation<WatchEnd, Never>])? in
            if s.end != nil { return nil }
            s.end = end
            s.pending.removeAll()
            s.failure = nil
            s.listener = nil
            s.report = nil
            s.replace = nil
            let result = (s.task, s.detach, s.signal, s.registration, s.waiters)
            s.task = nil
            s.detach = nil
            s.signal = nil
            s.registration = nil
            s.waiters = []
            return result
        }
        guard let (task, detach, signal, registration, waiters) = closed else { return }
        if let signal, let registration { signal.removeAbortListener(registration) }
        detach?()
        for waiter in waiters { waiter.resume(returning: end) }
        task?.cancel()
    }
}
