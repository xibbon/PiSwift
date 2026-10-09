import Synchronization

public let progressBytesPerSecond = 100 * 1024

/// A waiter that the final output commit must settle after progress stops.
public final class ProgressWaiter: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>
    fileprivate init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = Mutex(continuation) }
    public func resolve() { take()?.resume() }
    public func reject(_ error: any Error) { take()?.resume(throwing: error) }
    private func take() -> CheckedContinuation<Void, any Error>? {
        continuation.withLock { value in let result = value; value = nil; return result }
    }
}
/// Commits the first idle change immediately, and coalesces later changes while a commit or timer runs.
public actor Progress {
    private let write: @Sendable () async throws -> Int
    private let onError: @Sendable (any Error) -> Void
    private let minIntervalMs: Int64
    private let clock: any DurableClock
    private var waiters: [ProgressWaiter] = []
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var nextAt: Int64 = 0
    private var dirty = false
    private var stopped = false
    // Internal probes let tests observe registration and stop without timer delays.
    var pendingWaiterCount: Int { waiters.count }
    var isStopped: Bool { stopped }
    public init(write: @escaping @Sendable () async throws -> Int, onError: @escaping @Sendable (any Error) -> Void,
                minIntervalMs: Int64, clock: any DurableClock = SystemDurableClock()) {
        self.write = write; self.onError = onError; self.minIntervalMs = minIntervalMs; self.clock = clock
    }
    public func mark() { dirty = true; schedule() }
    public func markAndWait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(ProgressWaiter(continuation)); mark()
        }
    }
    public func stop() async -> [ProgressWaiter] {
        stopped = true; timer?.cancel(); timer = nil
        await inFlight?.value
        let pending = waiters; waiters = []; return pending
    }
    private func schedule() {
        guard !stopped, timer == nil, inFlight == nil else { return }
        let deadline = nextAt
        if deadline <= clock.now() { flush() }
        else {
            timer = Task {
                do { try await clock.sleep(until: deadline) } catch { return }
                timer = nil; flush()
            }
        }
    }
    private func flush() {
        guard !stopped, dirty else { return }
        dirty = false
        let covered = waiters; waiters = []
        let started = clock.now()
        inFlight = Task {
            do {
                let bytes = try await write()
                let sizeDelay = Int64((Double(bytes) * 1000 / Double(progressBytesPerSecond)).rounded(.up))
                nextAt = started + max(minIntervalMs, sizeDelay)
                for waiter in covered { waiter.resolve() }
            } catch {
                nextAt = started + minIntervalMs
                for waiter in covered { waiter.reject(error) }
                onError(error)
            }
            inFlight = nil
            if dirty { schedule() }
        }
    }
}
