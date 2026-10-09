import Synchronization

/// Per-harness execution time source. Tests can replace it before scheduling a call.
internal final class ToolServices: Sendable {
    private let time: Mutex<@Sendable () -> Duration>
    init() {
        let origin = ContinuousClock.now
        time = Mutex({ origin.duration(to: ContinuousClock.now) })
    }
    func executionTime() -> @Sendable () -> Duration { time.withLock { $0 } }
    func setExecutionTime(_ now: @escaping @Sendable () -> Duration) { time.withLock { $0 = now } }
}
