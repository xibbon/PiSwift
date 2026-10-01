import Foundation
import Testing

/// Shares one gate between the test targets that change the process environment.
public actor ProcessEnvironmentTestLock {
    public static let shared = ProcessEnvironmentTestLock()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isLocked {
                    waiters.append(Waiter(id: id, continuation: continuation))
                } else {
                    isLocked = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    /// Hold the gate until the whole operation, including its cleanup, completes.
    public func withLock<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// Use this trait when the API under test cannot take an injected environment.
public struct ProcessEnvironmentTrait: TestTrait, TestScoping {
    public init() {}

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ProcessEnvironmentTestLock.shared.withLock {
            try await function()
        }
    }
}

public extension Trait where Self == ProcessEnvironmentTrait {
    static var processEnvironment: Self { Self() }
}
