import Synchronization

/// Sendable data for a failure that a watch source can recover from.
/// Upstream accepts `unknown`; a Swift task boundary requires a Sendable value.
public enum WatchFailure: Sendable, Equatable, Codable {
    case message(String)
    case value(JSONValue)
}

/// The first terminal reason wins. A recoverable failure is a call instead.
public enum WatchEnd: Sendable, Equatable {
    case stopped
    case aborted
    case ended
    case listenerError(String)
    case failed(WatchFailure)
}

/// A JSON watch call. A retirement is reported with the source's value and does not close the watch.
public enum WatchCall<Value: Sendable>: Sendable {
    case value(value: Value, ops: [Delta.Op], retired: Bool)
    case failed(WatchFailure)
}

extension WatchCall: Equatable where Value: Equatable {}

/// A native watch call without JSON operations.
public enum NativeWatchCall<Value: Sendable>: Sendable {
    case value(Value)
    case failed(WatchFailure)
}

extension NativeWatchCall: Equatable where Value: Equatable {}

public typealias WatchListener<Value: Sendable> = @Sendable (WatchCall<Value>, ChordContext) async throws -> Void
public typealias NativeWatchListener<Value: Sendable> = @Sendable (NativeWatchCall<Value>, ChordContext) async throws -> Void
public typealias WatchSource<Value: Sendable> = @Sendable (ChordContext) async throws -> any WatchHandle<Value>
public typealias NativeWatchSource<Value: Sendable> = @Sendable (ChordContext) async throws -> any NativeWatchHandle<Value>

/// One serial observation of an immutable JSON value.
public protocol WatchHandle<Value>: Sendable {
    associatedtype Value: Sendable
    var value: Value { get }
    func start(_ listener: @escaping WatchListener<Value>) throws
    func stop() async -> WatchEnd
    var closed: WatchEnd { get async }
}

/// A value from which a JSON watch can be acquired.
public protocol Watchable<Value>: Sendable {
    associatedtype Value: Sendable
    var value: Value { get }
    func watch(_ context: ChordContext) async throws -> any WatchHandle<Value>
}

/// One serial observation of an in-process value.
public protocol NativeWatchHandle<Value>: Sendable {
    associatedtype Value: Sendable
    var value: Value { get }
    func start(_ listener: @escaping NativeWatchListener<Value>) throws
    func stop() async -> WatchEnd
    var closed: WatchEnd { get async }
}

/// A value from which a native watch can be acquired.
public protocol NativeWatchable<Value>: Sendable {
    associatedtype Value: Sendable
    var value: Value { get }
    func watch(_ context: ChordContext) async throws -> any NativeWatchHandle<Value>
}

public enum WatchError: Error, Sendable, Equatable {
    case alreadyStarted
    case stopped
    case abortAlreadyInstalled
}

/// Starts a worker only after its cancellation handle is stored.
final class WatchStartGate: Sendable {
    private struct State {
        var open = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.open { return true }
                state.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.open = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

/// A JSON watch. One lock owns lifecycle state; CH1 PendingOps owns its bounded folded operations.
public final class Watch<Value: Sendable>: WatchHandle, Sendable {
    private struct State {
        var value: Value
        var listener: WatchListener<Value>?
        var started = false
        var running = false
        var ending = false
        var end: WatchEnd?
        var task: Task<Void, Never>?
        var waiters: [CheckedContinuation<WatchEnd, Never>] = []
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var newestValue: Value?
        var newestReplacement: JSONValue?
        var newestContext: ChordContext?
        var lone: WatchCall<Value>?
        var failure: WatchFailure?
        var replacing = false
        var retired = false
        var detach: (@Sendable () -> Void)?
        var report: (@Sendable (any Error) -> Void)?
        var replacement: (@Sendable (Value) -> JSONValue)?
        var signal: AbortSignal?
        var registration: AbortListenerRegistration?
    }

    private let state: Mutex<State>
    private let ops = PendingOps()
    private let deliveryReady: @Sendable () async -> Void
    private let workerEmpty: @Sendable () async -> Void

    public convenience init(value: Value, replacement: @escaping @Sendable (Value) -> JSONValue,
                detach: @escaping @Sendable () -> Void,
                report: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.init(value: value, replacement: replacement, detach: detach, report: report, deliveryReady: {})
    }

    package init(value: Value, replacement: @escaping @Sendable (Value) -> JSONValue,
                detach: @escaping @Sendable () -> Void,
                report: @escaping @Sendable (any Error) -> Void,
                deliveryReady: @escaping @Sendable () async -> Void,
                workerEmpty: @escaping @Sendable () async -> Void = {}) {
        state = Mutex(State(value: value, detach: detach, report: report, replacement: replacement))
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

    /// The bounded folded operation count, for the stress memory measurement.
    package var pendingOperationCount: Int { ops.size }

    // watch.ts:148-155 start
    public func start(_ listener: @escaping WatchListener<Value>) throws {
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
            return !s.running && s.newestContext == nil
        }
        if finish { terminate(.ended) }
    }

    // watch.ts:305-324 advance
    public func advance(_ call: WatchCall<Value>, context: ChordContext) {
        advance(call, capturedReplacement: nil, context: context)
    }

    /// Queue a typed value with its exact JSON snapshot. Overflow uses this snapshot,
    /// even if the source advances while the delivery worker takes the value.
    /// v1.5.2 CH3: TypeScript's value is already JSON; Swift's generic value may not be.
    public func advance(_ call: WatchCall<Value>, replacement: JSONValue, context: ChordContext) {
        advance(call, capturedReplacement: replacement, context: context)
    }

    private func advance(_ call: WatchCall<Value>, capturedReplacement: JSONValue?, context: ChordContext) {
        if case .failed(let error) = call { fail(error, context: context); return }
        let run = state.withLock { s -> Bool in
            if s.end != nil || s.ending { return false }
            guard case .value(let value, let operations, let retired) = call else { return false }
            if s.replacing {
                s.failure = nil
            } else {
                s.lone = s.newestContext == nil ? call : nil
                ops.push(operations)
            }
            s.newestValue = value
            s.newestReplacement = capturedReplacement
            s.newestContext = context
            if retired { s.retired = true }
            return schedule(&s)
        }
        if run { launch() }
    }

    // watch.ts:330-342 fail
    public func fail(_ error: WatchFailure, context: ChordContext) {
        let run = state.withLock { s -> Bool in
            if s.end != nil || s.ending { return false }
            _ = ops.take()
            s.lone = nil
            s.newestValue = nil
            s.newestReplacement = nil
            s.failure = error
            s.newestContext = context
            s.replacing = true
            return schedule(&s)
        }
        if run { launch() }
    }

    private func schedule(_ s: inout State) -> Bool {
        guard s.started, !s.running, s.end == nil, s.newestContext != nil else { return false }
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
            // endAfterDelivery can race with the empty-queue observation in take().
            let finish = s.end == nil && s.ending && s.newestContext == nil
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
        case value(Value, PendingTake, Bool, ChordContext, JSONValue?, @Sendable (Value) -> JSONValue)
        case failure(WatchFailure, ChordContext)
        case done(Bool)
    }

    // watch.ts:281-381 deliver, next, nextAfterFailure
    private func take() -> Taken {
        state.withLock { s in
            if s.end != nil { return .done(false) }
            guard let context = s.newestContext else {
                return .done(s.ending)
            }
            s.newestContext = nil
            if s.replacing {
                if let failure = s.failure {
                    s.failure = nil
                    return .failure(failure, context)
                }
                let value = s.newestValue!
                s.newestValue = nil
                let captured = s.newestReplacement
                s.newestReplacement = nil
                let retired = s.retired
                s.retired = false
                s.replacing = false
                s.value = value
                return .value(value, .replace, retired, context, captured, s.replacement!)
            }
            let value = s.newestValue!
            s.newestValue = nil
            let captured = s.newestReplacement
            s.newestReplacement = nil
            let retired = s.retired
            s.retired = false
            let lone = s.lone
            s.lone = nil
            let batch = ops.take()
            let operations: PendingTake
            if case .value(_, let original, _) = lone, case .ops = batch { operations = .ops(original) }
            else { operations = batch }
            s.value = value
            return .value(value, operations, retired, context, captured, s.replacement!)
        }
    }

    private func drain() async {
        while true {
            let next = take()
            if case .done(let ending) = next {
                if ending { terminate(.ended) }
                else { await workerEmpty() }
                return
            }
            guard let listener = state.withLock({ $0.listener }) else { return }
            do {
                switch next {
                case .value(let value, let pending, let retired, let context, let captured, let replacement):
                    let operations: [Delta.Op]
                    switch pending {
                    case .ops(let ops): operations = ops
                    case .replace: operations = [.replace(captured ?? replacement(value))]
                    }
                    try await listener(.value(value: value, ops: operations, retired: retired), context.withoutAbortSignal())
                case .failure(let error, let context):
                    try await listener(.failed(error), context.withoutAbortSignal())
                case .done: break
                }
            } catch {
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

    // watch.ts:249-270 terminate, release
    private func terminate(_ end: WatchEnd) {
        let closed = state.withLock { s -> (Task<Void, Never>?, (@Sendable () -> Void)?, AbortSignal?, AbortListenerRegistration?, [CheckedContinuation<WatchEnd, Never>])? in
            if s.end != nil { return nil }
            s.end = end
            _ = ops.take()
            s.newestValue = nil
            s.newestReplacement = nil
            s.newestContext = nil
            s.lone = nil
            s.failure = nil
            s.retired = false
            s.replacing = false
            s.listener = nil
            s.report = nil
            s.replacement = nil
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

extension Watch where Value == JSONValue {
    public convenience init(value: JSONValue, detach: @escaping @Sendable () -> Void,
                            report: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.init(value: value, replacement: { $0 }, detach: detach, report: report)
    }
}
