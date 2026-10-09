import Synchronization

private final class ContextWaiter<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case waiting(CheckedContinuation<Value, any Error>?)
        case finished(Result<Value, any Error>)
    }

    private let state = Mutex<State>(.waiting(nil))

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = state.withLock { state -> Result<Value, any Error>? in
            switch state {
            case .waiting:
                state = .waiting(continuation)
                return nil
            case .finished(let result):
                return result
            }
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard case .waiting(let continuation) = state else { return nil }
            state = .finished(result)
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// Waits for work or context cancellation. Cancellation rejects only this waiter;
/// it does not cancel the underlying promise (the work task).
/// Swift task cancellation does not end this wait. Use
/// `withTaskCancellationContext(_:_:)` to connect task cancellation to a context.
public func awaitWithContext<T: Sendable>(
    _ work: Task<T, any Error>, _ context: Context
) async throws -> T {
    guard let signal = context.abortSignal else { return try await work.value }
    try signal.throwIfAborted()
    let waiter = ContextWaiter<T>()
    let registration = signal.addAbortListener { reason in waiter.finish(.failure(reason)) }
    defer { signal.removeAbortListener(registration) }
    // Close the race between the initial check and listener registration.
    if let reason = signal.reason { waiter.finish(.failure(reason)) }
    return try await withCheckedThrowingContinuation { continuation in
        waiter.install(continuation)
        // An unstructured observer lets the waiter return while work continues.
        // Its weak reference releases waiter state after a context abort.
        Task.detached { [weak waiter] in
            let result = await work.result
            waiter?.finish(result)
        }
    }
}

/// The nonthrowing-work form of `awaitWithContext(_:_:)`.
/// Context cancellation can still throw. It never cancels work.
public func awaitWithContext<T: Sendable>(
    _ work: Task<T, Never>, _ context: Context
) async throws -> T {
    guard let signal = context.abortSignal else { return await work.value }
    try signal.throwIfAborted()
    let waiter = ContextWaiter<T>()
    let registration = signal.addAbortListener { reason in waiter.finish(.failure(reason)) }
    defer { signal.removeAbortListener(registration) }
    if let reason = signal.reason { waiter.finish(.failure(reason)) }
    return try await withCheckedThrowingContinuation { continuation in
        waiter.install(continuation)
        Task.detached { [weak waiter] in
            let value = await work.value
            waiter?.finish(.success(value))
        }
    }
}

/// Runs body with a cancellable child context. Swift task cancellation aborts
/// the child with `CancellationError`, including cancellation before this call.
/// Parent cancellation also reaches the child. The parent does not change.
/// The first abort reason wins if parent and task cancellation both occur.
public func withTaskCancellationContext<T>(
    _ context: Context, _ body: (Context) async throws -> T
) async rethrows -> T {
    let child = context.withCancel()
    return try await withTaskCancellationHandler {
        try await body(child.context)
    } onCancel: {
        child.cancel(CancellationError())
    }
}
