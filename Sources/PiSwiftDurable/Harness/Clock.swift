import Foundation

/// Time is measured in epoch milliseconds.
public protocol DurableClock: Sendable {
    func now() -> Int64
    func sleep(until deadline: Int64) async throws
}

public struct SystemDurableClock: DurableClock {
    public init() {}
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public func sleep(until deadline: Int64) async throws {
        let delay = deadline - now()
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        try Task.checkCancellation()
    }
}
