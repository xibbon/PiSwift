import Synchronization

/// Options for a one-shot host timer.
public struct HarnessTimerOptions: Sendable, Equatable {
    /// A background timer only releases memory. The host can decline it.
    public var background: Bool
    /// Selects whether the host can decline this timer.
    public init(background: Bool = false) { self.background = background }
}
/// Cancels a timer. Repeated calls have no effect.
public typealias HarnessDisarm = @Sendable () -> Void
/// Arms a one-shot timer after a delay in milliseconds. Nil declines the timer.
public typealias HarnessSetTimer = @Sendable (_ callback: @escaping @Sendable () -> Void, _ delay: Double, _ options: HarnessTimerOptions) throws -> HarnessDisarm?

private struct TimerFallbackError: Error, Sendable, CustomStringConvertible {
    var description: String { "HarnessOptions.setTimer declined a timer that paces work; using setTimeout" }
}
private struct TimerDeclinedError: Error, Sendable {}

/// Serializes cancellation against a host that fires synchronously or more than once.
private final class HostTimerDelivery: Sendable {
    private struct State: Sendable { var active = true; var disarm: HarnessDisarm? }
    private let state = Mutex(State())
    func install(_ disarm: @escaping HarnessDisarm) {
        let cancel = state.withLock { state in
            if !state.active { return true }
            state.disarm = disarm; return false
        }
        if cancel { disarm() }
    }
    func cancel() {
        let disarm = state.withLock { state in
            state.active = false
            let result = state.disarm; state.disarm = nil; return result
        }
        disarm?()
    }
    func fire(_ callback: @escaping @Sendable () -> Void) {
        // A host can call back while the Session or scheduler holds a lock.
        Task.detached {
            let run = self.state.withLock { state in
                guard state.active else { return false }
                state.active = false; state.disarm = nil; return true
            }
            if run { callback() }
        }
    }
}

internal final class HarnessTimers: Sendable {
    let now: @Sendable () -> Int64
    private let arm: HarnessSetTimer
    private let retentionArm: HarnessSetTimer
    private let absoluteArm: HarnessSetTimer
    private let absoluteRetentionArm: HarnessSetTimer
    private let fallback: HarnessSetTimer
    private let report: @Sendable (any Error) -> Void
    private let reported = Mutex(false)
    init(clock: any DurableClock = SystemDurableClock(), now: (@Sendable () -> Int64)? = nil,
         setTimer: HarnessSetTimer? = nil, report: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.now = now ?? { clock.now() }; self.report = report
        arm = setTimer ?? Self.native(clock: clock)
        retentionArm = setTimer ?? Self.native(clock: DocumentRetentionClock(base: clock))
        absoluteArm = Self.deadlines(clock: clock, now: now, setTimer: setTimer)
        absoluteRetentionArm = Self.deadlines(clock: DocumentRetentionClock(base: clock), now: now, setTimer: setTimer)
        fallback = Self.native(clock: SystemDurableClock())
    }
    var clock: any DurableClock { HostTimerClock(timers: self) }
    func setTimer(_ callback: @escaping @Sendable () -> Void, delay: Double,
                  options: HarnessTimerOptions = .init(), documentRetention: Bool = false) -> HarnessDisarm? {
        armTimer(callback, value: max(0, delay), timer: documentRetention ? retentionArm : arm,
                 options: options, fallbackDelay: { max(0, delay) })
    }
    func setTimer(_ callback: @escaping @Sendable () -> Void, until deadline: Double,
                  options: HarnessTimerOptions = .init(), documentRetention: Bool = false) -> HarnessDisarm? {
        armTimer(callback, value: deadline, timer: documentRetention ? absoluteRetentionArm : absoluteArm,
                 options: options, fallbackDelay: { max(0, deadline - Double(self.now())) })
    }
    private func armTimer(_ callback: @escaping @Sendable () -> Void, value: Double,
                          timer: HarnessSetTimer, options: HarnessTimerOptions,
                          fallbackDelay: () -> Double) -> HarnessDisarm? {
        let delivery = HostTimerDelivery()
        let deliver: @Sendable () -> Void = { delivery.fire(callback) }
        do {
            if let disarm = try timer(deliver, value, options) {
                delivery.install(disarm); return { delivery.cancel() }
            }
            if options.background { delivery.cancel(); return nil }
        } catch {
            if options.background { delivery.cancel(); report(error); return nil }
        }
        let first = reported.withLock { value in let first = !value; value = true; return first }
        if first { report(TimerFallbackError()) }
        let disarm = try? fallback(deliver, fallbackDelay(), .init())
        if let disarm { delivery.install(disarm) }
        return { delivery.cancel() }
    }
    /// Keep absolute deadlines through the native adapter. Only custom hosts
    /// receive a delay, as required by HarnessSetTimer.
    private static func deadlines(clock: any DurableClock, now: (@Sendable () -> Int64)?,
                                  setTimer: HarnessSetTimer?) -> HarnessSetTimer {
        if let setTimer {
            return { callback, until, options in
                try setTimer(callback, max(0, until - Double(now?() ?? clock.now())), options)
            }
        }
        let timer = native(clock: clock, absolute: true)
        guard let now else { return timer }
        return { callback, until, options in
            // Read the adapter clock first so a concurrent advance cannot add
            // an old delay to a newer base. Consumers recheck an early fire.
            let base = Double(clock.now())
            return try timer(callback, base + max(0, until - Double(now())), options)
        }
    }
    private static func native(clock: any DurableClock, absolute: Bool = false) -> HarnessSetTimer {
        { callback, value, _ in
            let until = absolute ? value : Double(clock.now()) + max(0, value)
            let work = Task.detached {
                repeat {
                    if clock.now() == Int64.max, until > Double(Int64.max) {
                        // A convenience clock cannot represent this finite host
                        // deadline. Keep it pending until disarm, without spinning.
                        let wait = HostTimerWait()
                        do {
                            try await withTaskCancellationHandler {
                                try await withCheckedThrowingContinuation { wait.install($0) }
                            } onCancel: { wait.finish(.failure(CancellationError())) }
                        } catch { return }
                    }
                    let step = min(until, Double(clock.now()) + 2_147_483_647)
                    let deadline = step >= Double(Int64.max) ? Int64.max : Int64(step.rounded(.up))
                    do { try await clock.sleep(until: deadline) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                } while Double(clock.now()) < until
                callback()
            }
            return { work.cancel() }
        }
    }
    func sleep(until deadline: Int64, background: Bool = false, documentRetention: Bool = false) async throws {
        repeat {
            let wait = HostTimerWait()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    wait.install(continuation)
                    let disarm = setTimer({ wait.finish(.success(())) }, until: Double(deadline),
                                          options: .init(background: background), documentRetention: documentRetention)
                    if let disarm { wait.install(disarm) }
                    else { wait.finish(.failure(TimerDeclinedError())) }
                }
            } onCancel: { wait.finish(.failure(CancellationError())) }
        } while now() < deadline
    }
}
internal final class HostTimerWait: Sendable {
    private struct State: Sendable {
        var result: Result<Void, any Error>?
        var continuation: CheckedContinuation<Void, any Error>?
        var disarm: HarnessDisarm?
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let result = state.withLock { state -> Result<Void, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation; return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func install(_ disarm: @escaping HarnessDisarm) {
        let ended = state.withLock { state in
            if state.result != nil { return true }
            state.disarm = disarm; return false
        }
        if ended { disarm() }
    }
    func finish(_ result: Result<Void, any Error>) {
        let pending = state.withLock { state -> (CheckedContinuation<Void, any Error>?, HarnessDisarm?)? in
            guard state.result == nil else { return nil }
            state.result = result
            let pending = (state.continuation, state.disarm)
            state.continuation = nil; state.disarm = nil; return pending
        }
        if let pending { pending.1?(); pending.0?.resume(with: result) }
    }
}
private struct HostTimerClock: DurableClock {
    let timers: HarnessTimers
    func now() -> Int64 { timers.now() }
    func sleep(until deadline: Int64) async throws { try await timers.sleep(until: deadline) }
}

/// A phase timer belongs to its invocation and is disarmed when that invocation ends.
internal struct InvocationClock: DurableClock {
    let runtime: TaskRuntime
    func now() -> Int64 { runtime.scheduler.now() }
    func sleep(until deadline: Int64) async throws {
        repeat {
            let wait = HostTimerWait()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    wait.install(continuation)
                    wait.install(runtime.setTimer({ wait.finish(.success(())) }, until: Double(deadline)))
                }
            } onCancel: { wait.finish(.failure(CancellationError())) }
        } while now() < deadline
    }
}

/// Keeps document timer accounting distinct while retaining the host clock.
private struct DocumentRetentionClock: DurableClock {
    let base: any DurableClock
    func now() -> Int64 { base.now() }
    func sleep(until deadline: Int64) async throws {
        if let clock = base as? any DurableRetentionClock {
            try await clock.sleepForDocumentRetention(until: deadline)
        } else {
            try await base.sleep(until: deadline)
        }
    }
}
