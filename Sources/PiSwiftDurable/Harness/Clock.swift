import Foundation

/// Time is measured in epoch milliseconds.
public protocol DurableClock: Sendable {
    /// Returns the clock time in milliseconds.
    func now() -> Int64
    /// Waits until the millisecond deadline and supports Swift task cancellation.
    func sleep(until deadline: Int64) async throws
}

/// Allows a clock adapter to account for cache timers separately from work waits.
/// Both kinds of wait use the same time source and advance together.
package protocol DurableRetentionClock: DurableClock {
    func sleepForDocumentRetention(until deadline: Int64) async throws
}

/// A wall clock with Swift task cancellation during sleep.
public struct SystemDurableClock: DurableClock {
    /// Creates a wall clock backed by the system time source.
    public init() {}
    /// Returns the current system time in epoch milliseconds.
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Waits until the millisecond deadline or Swift task cancellation.
    public func sleep(until deadline: Int64) async throws {
        let delay = deadline - now()
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        try Task.checkCancellation()
    }
}
