import Foundation

/// Serializes write operations per file path while allowing different files
/// to be written in parallel. Each file's operations chain sequentially
/// via a `Task` dictionary.
public actor FileMutationQueue {
    public static let shared = FileMutationQueue()

    /// Each entry is (generation, task). The generation counter disambiguates tasks for cleanup.
    private var pending: [String: (gen: UInt64, task: Task<Void, Never>)] = [:]
    private var generation: UInt64 = 0

    public func withFileLock<T: Sendable>(_ path: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = pending[path]?.task

        let resultHolder = LockedResultHolder<T>()

        let task = Task<Void, Never> {
            // Wait for the previous operation on this path to finish.
            _ = await previous?.value

            do {
                let value = try await operation()
                resultHolder.setSuccess(value)
            } catch {
                resultHolder.setFailure(error)
            }
        }

        generation &+= 1
        let gen = generation
        pending[path] = (gen, task)
        _ = await task.value

        // Clean up if this is still the latest task for this path.
        if pending[path]?.gen == gen {
            pending[path] = nil
        }

        return try resultHolder.get()
    }
}

/// Thread-safe holder for passing a result out of a `Task<Void, Never>`.
private final class LockedResultHolder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var error: (any Error)?

    func setSuccess(_ v: T) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func setFailure(_ e: any Error) {
        lock.lock()
        error = e
        lock.unlock()
    }

    func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let value else {
            fatalError("FileMutationQueue: result was never set")
        }
        return value
    }
}
