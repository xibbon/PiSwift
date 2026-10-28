import Synchronization
import PiSwiftDurable

/// A manually advanced clock for deterministic sleep and retry tests.
public final class TestClock: DurableClock, Sendable {
    private struct Sleeper: Sendable {
        let deadline: Int64
        let documentRetention: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State: Sendable {
        var now: Int64
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }
    private let state: Mutex<State>
    /// Creates a manual clock at the supplied millisecond time.
    public init(now: Int64 = 0) { state = Mutex(State(now: now)) }
    /// The current manually controlled time in milliseconds.
    public func now() -> Int64 { state.withLock { $0.now } }
    /// The number of pending work waits, including task and context timers.
    public var pendingSleeperCount: Int { state.withLock { $0.sleepers.values.filter { !$0.documentRetention }.count } }
    /// The number of document retention timers on this same clock.
    public var pendingDocumentRetentionCount: Int { state.withLock { $0.sleepers.values.filter { $0.documentRetention }.count } }
    /// Moves the test clock forward and wakes sleeps whose deadlines have passed.
    public func advance(by milliseconds: Int64) {
        precondition(milliseconds >= 0)
        let ready = state.withLock { state in
            state.now += milliseconds
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for sleeper in ready { sleeper.continuation.resume() }
    }
    /// Waits until the millisecond deadline or Swift task cancellation.
    public func sleep(until deadline: Int64) async throws {
        try await sleep(until: deadline, documentRetention: false)
    }
    private func sleep(until deadline: Int64, documentRetention: Bool) async throws {
        let id = state.withLock { state in state.nextID += 1; return state.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = state.withLock { state -> Int in
                    if Task.isCancelled { return 1 }
                    if deadline <= state.now { return 2 }
                    state.sleepers[id] = Sleeper(deadline: deadline, documentRetention: documentRetention, continuation: continuation)
                    return 0
                }
                if result == 1 { continuation.resume(throwing: CancellationError()) }
                else if result == 2 { continuation.resume() }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

extension TestClock: DurableRetentionClock {
    package func sleepForDocumentRetention(until deadline: Int64) async throws {
        try await sleep(until: deadline, documentRetention: true)
    }
}
