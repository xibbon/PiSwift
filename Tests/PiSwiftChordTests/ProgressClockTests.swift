import PiSwiftChord
import Synchronization
import Testing

private final class EarlyProgressClock: ProgressClock {
    private struct State: Sendable {
        var now: Int64 = 1000
        var sleeps: [Int64] = []
        var nextID = 0
        var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    }
    private let state = Mutex(State())
    func now() -> Int64 { state.withLock { $0.now } }
    var sleeps: [Int64] { state.withLock { $0.sleeps } }
    var pendingCount: Int { state.withLock { $0.pending.count } }
    func advance(to time: Int64) { state.withLock { $0.now = time } }
    func fire() {
        let continuation = state.withLock { state in
            guard let id = state.pending.keys.min() else { return Optional<CheckedContinuation<Void, any Error>>.none }
            return state.pending.removeValue(forKey: id)
        }
        continuation?.resume()
    }
    func sleep(until deadline: Int64) async throws {
        let id = state.withLock { state in state.nextID += 1; return state.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    if Task.isCancelled { return true }
                    state.sleeps.append(deadline - state.now)
                    state.pending[id] = continuation; return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}
private func progressEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<10000 { if predicate() { return true }; await Task.yield() }
    return predicate()
}

@Test func progressRechecksAnEarlyTimerAndDisarmsOnStop() async {
    // v1.4.0 chord/test/output.test.ts:273, "paces on the clock it is given".
    let clock = EarlyProgressClock()
    let writes = Mutex<[Int64]>([])
    let progress = Progress(write: { writes.withLock { $0.append(clock.now()) }; return 0 },
                            onError: { _ in Issue.record("Unexpected progress error") }, minIntervalMs: 100, clock: clock)
    await progress.mark()
    #expect(await progressEventually { writes.withLock { $0 == [1000] } })
    clock.advance(to: 1040)
    await progress.mark()
    #expect(await progressEventually { clock.sleeps == [60] })
    clock.advance(to: 1080)
    clock.fire()
    #expect(await progressEventually { clock.sleeps == [60, 20] })
    #expect(writes.withLock { $0 } == [1000])
    clock.advance(to: 1100)
    clock.fire()
    #expect(await progressEventually { writes.withLock { $0 == [1000, 1100] } })
    await progress.mark()
    #expect(await progressEventually { clock.pendingCount == 1 })
    _ = await progress.stop()
    #expect(await progressEventually { clock.pendingCount == 0 })
}
