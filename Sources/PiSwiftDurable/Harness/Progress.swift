import PiSwiftChord

/// The byte rate used to delay progress writes after a large publication.
public let progressBytesPerSecond = PiSwiftChord.progressBytesPerSecond
/// A waiter that the final output commit must settle after progress stops.
public typealias ProgressWaiter = PiSwiftChord.ProgressWaiter
/// Commits the first idle change immediately and combines changes while a write or timer runs.
public typealias Progress = PiSwiftChord.Progress

private struct ProgressClockAdapter: PiSwiftChord.ProgressClock {
    let clock: any DurableClock
    func now() -> Int64 { clock.now() }
    func sleep(until deadline: Int64) async throws { try await clock.sleep(until: deadline) }
}

extension PiSwiftChord.Progress {
    /// Creates a writer with a rate limit, error reporting, and a durable clock.
    public init(write: @escaping @Sendable () async throws -> Int,
                onError: @escaping @Sendable (any Error) -> Void,
                minIntervalMs: Int64, clock: any DurableClock) {
        self.init(write: write, onError: onError, minIntervalMs: minIntervalMs,
                  clock: ProgressClockAdapter(clock: clock))
    }
}
