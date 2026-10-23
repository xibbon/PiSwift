/// The retention timer is separate from the clock used for task times and sleeps.
internal struct SessionDocumentTimer: Sendable {
    let now: @Sendable () -> Int64
    let sleep: @Sendable (Int64) async throws -> Void

    /// Creates an internal timer hook for deterministic retention tests.
    init(now: @escaping @Sendable () -> Int64,
         sleep: @escaping @Sendable (Int64) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }

    /// Uses real elapsed time. Host and scheduler clocks do not control this sleep.
    static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: {
            let elapsed = origin.duration(to: clock.now).components
            return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        }, sleep: { deadline in
            try await clock.sleep(until: origin.advanced(by: .milliseconds(deadline)))
        })
    }
}
