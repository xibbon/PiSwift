/// The timer used to release unobserved documents.
internal struct SessionDocumentTimer: Sendable {
    let now: @Sendable () -> Int64
    let sleep: @Sendable (Int64) async throws -> Void

    /// Creates an internal timer hook for deterministic retention tests.
    init(now: @escaping @Sendable () -> Int64,
         sleep: @escaping @Sendable (Int64) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }

    static func host(_ timers: HarnessTimers) -> Self {
        Self(now: timers.now, sleep: { try await timers.sleep(until: $0, background: true, documentRetention: true) })
    }
}
