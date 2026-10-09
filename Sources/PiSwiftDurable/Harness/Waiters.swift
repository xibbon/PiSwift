import PiSwiftChord
import Synchronization
import Foundation

/// One result. Completion can occur before the first wait.
internal final class HarnessPromise<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, any Error>?
        var continuations: [CheckedContinuation<Value, any Error>] = []
    }
    private let state = Mutex(State())
    func finish(_ result: Result<Value, any Error>) {
        let continuations = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
            guard state.result == nil else { return [] }
            state.result = result
            let values = state.continuations; state.continuations = []; return values
        }
        for continuation in continuations { continuation.resume(with: result) }
    }
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = state.withLock { state -> Result<Value, any Error>? in
                if let result = state.result { return result }
                state.continuations.append(continuation); return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
}

/// Pending waits by key. Context cancellation removes only that wait.
internal final class Waiters<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Wait: Sendable {
        let promise: HarnessPromise<Value>
        let signal: AbortSignal?
        let registration: AbortListenerRegistration?
    }
    private let state = Mutex<[Key: [UUID: Wait]]>([:])
    func add(_ key: Key, context: PiSwiftChord.Context) throws -> HarnessPromise<Value> {
        try context.abortSignal?.throwIfAborted()
        let id = UUID(), promise = HarnessPromise<Value>()
        // Add before installing cancellation so concurrent resolution cannot miss the wait.
        state.withLock { $0[key, default: [:]][id] = Wait(promise: promise, signal: nil, registration: nil) }
        if let signal = context.abortSignal {
            let registration = signal.addAbortListener { [weak self] reason in self?.reject(key, id: id, error: reason) }
            let keep = state.withLock { state -> Bool in
                guard state[key]?[id] != nil else { return false }
                state[key]?[id] = Wait(promise: promise, signal: signal, registration: registration); return true
            }
            if !keep { signal.removeAbortListener(registration) }
            if let reason = signal.reason { reject(key, id: id, error: reason) }
        }
        return promise
    }
    var keys: [Key] { state.withLock { Array($0.keys) } }
    private func reject(_ key: Key, id: UUID, error: any Error) {
        let wait = state.withLock { state -> Wait? in
            let wait = state[key]?.removeValue(forKey: id)
            if state[key]?.isEmpty == true { state.removeValue(forKey: key) }
            return wait
        }
        if let wait { finish(wait, .failure(error)) }
    }
    func resolve(_ key: Key, value: Value) {
        let waits = state.withLock { $0.removeValue(forKey: key) }
        for wait in waits?.values ?? Dictionary<UUID, Wait>().values { finish(wait, .success(value)) }
    }
    func rejectAll(_ error: any Error) {
        let waits = state.withLock { state in let waits = state; state = [:]; return waits }
        for group in waits.values { for wait in group.values { finish(wait, .failure(error)) } }
    }
    private func finish(_ wait: Wait, _ result: Result<Value, any Error>) {
        if let signal = wait.signal, let registration = wait.registration { signal.removeAbortListener(registration) }
        wait.promise.finish(result)
    }
}
