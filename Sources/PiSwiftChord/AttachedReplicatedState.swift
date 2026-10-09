import Synchronization

/// A read-only value with independent, serial async subscribers.
/// Source values must remain immutable. Sendable reference values are not copied.
public final class AttachedReplicatedState<Value: Sendable>: Sendable {
    private struct Subscriber: Sendable {
        let listener: ReplicatedStateSubscriber<Value>
        let hydratedSequence: Int
    }
    private struct Publication: Sendable {
        let frame: ReplicatedStateSourceFrame<Value>
        let sequence: Int
    }
    private typealias OperationsListener = @Sendable ([Delta.Op], Int, ChordContext) throws -> Void
    private struct State {
        var value: Value
        var cursor: Int
        var sequence = 0
        var disposed = false
        var delivering = false
        var publications: [Publication] = []
        var subscribers: [Subscriber] = []
        var operations: [(ReplicatedStateSubscription, OperationsListener)] = []
    }
    private let storage: Mutex<State>
    private let attachment: any ReplicatedStateSourceAttachment<Value>
    private let onError: @Sendable (any Error) throws -> Void
    private let idle = ReplicatedStateIdle()
    private static var maxSafeCursor: Int { 9_007_199_254_740_991 }

    init(attachment: any ReplicatedStateSourceAttachment<Value>,
         onError: @escaping @Sendable (any Error) throws -> Void) throws {
        let snapshot = attachment.snapshot
        guard Self.isSafe(snapshot.cursor) else {
            throw ReplicatedStateSourceError.invalidSnapshotCursor(snapshot.cursor)
        }
        self.attachment = attachment
        self.onError = onError
        storage = Mutex(State(value: snapshot.value, cursor: snapshot.cursor))
    }

    func activate() throws {
        try attachment.activate { [weak self] frame in self?.receive(frame) }
    }

    /// The last published value. It is also available after disposal.
    public var value: Value { storage.withLock { $0.value } }

    /// Hydrate first with the current local sequence and `ChordContext.background`.
    /// Await each listener call before the next call on this subscription.
    /// At 100 pending deliveries, clear the queue and keep the newest delivery,
    /// plus hydration if it has not started. Sequences can thus skip on overflow.
    /// Errors go to the creation error handler, and delivery continues.
    /// Two subscriptions of the same closure are independent.
    @discardableResult
    public func subscribe(
        _ listener: @escaping @Sendable (Value, ChordContext, ReplicatedStateDelivery) async throws -> Void
    ) -> ReplicatedStateSubscription {
        let subscriber = ReplicatedStateSubscriber<Value>(idle: idle, listener: listener) { [onError] error in
            try? onError(error)
        }
        storage.withLock { state in
            state.subscribers.append(Subscriber(listener: subscriber, hydratedSequence: state.sequence))
            subscriber.push(.init(value: state.value, context: .background,
                                  delivery: .hydrate(sequence: state.sequence)))
        }
        return ReplicatedStateSubscription { [weak self] in
            subscriber.close()
            self?.storage.withLock { state in
                state.subscribers.removeAll { $0.listener === subscriber }
            }
        }
    }

    /// Stop source delivery once. Existing subscribers can finish queued work.
    /// A subscription after disposal still receives the last value as hydration.
    public func dispose() {
        let dispose = storage.withLock { state in
            guard !state.disposed else { return false }
            state.disposed = true
            return true
        }
        if dispose { attachment.dispose() }
    }

    /// Observe exact operation batches, synchronously in publication order.
    /// There is no hydration batch. Errors go to the creation error handler.
    @discardableResult
    package func subscribeOperations(
        _ listener: @escaping @Sendable ([Delta.Op], Int, ChordContext) throws -> Void
    ) -> ReplicatedStateSubscription {
        // The identity token has no capture of this state.
        let identity = ReplicatedStateSubscription {}
        storage.withLock { $0.operations.append((identity, listener)) }
        return ReplicatedStateSubscription { [weak self] in
            self?.storage.withLock { $0.operations.removeAll { $0.0 === identity } }
        }
    }

    /// Wait for publication drains and all queued or running public deliveries.
    /// Call this outside listeners. Waiting inside a listener would wait for itself.
    /// Producers must stop before this call if the caller needs a stable idle boundary.
    package func waitUntilIdle() async { await idle.wait() }

    private static func isSafe(_ cursor: Int) -> Bool {
        cursor >= -maxSafeCursor && cursor <= maxSafeCursor
    }

    private func receive(_ frame: ReplicatedStateSourceFrame<Value>) {
        var failure: ReplicatedStateSourceError?
        let start = storage.withLock { state in
            guard !state.disposed else { return false }
            if !Self.isSafe(frame.cursor) {
                failure = .invalidFrameCursor(frame.cursor)
            } else if frame.cursor != state.cursor + 1 {
                failure = .cursorGap(expected: state.cursor + 1, received: frame.cursor)
            }
            if failure != nil {
                state.disposed = true
                return false
            }
            state.cursor = frame.cursor
            state.value = frame.value
            state.sequence += 1
            state.publications.append(Publication(frame: frame, sequence: state.sequence))
            guard !state.delivering else { return false }
            state.delivering = true
            idle.start()
            return true
        }
        if let failure {
            attachment.dispose()
            report(failure)
        }
        if start { drainPublications() }
    }

    private func drainPublications() {
        var errors: [any Error] = []
        while let next = storage.withLock({ state -> (Publication, [OperationsListener])? in
            guard !state.publications.isEmpty else {
                state.delivering = false
                return nil
            }
            return (state.publications.removeFirst(), state.operations.map { $0.1 })
        }) {
            let (publication, listeners) = next
            for listener in listeners {
                do { try listener(publication.frame.ops, publication.sequence, publication.frame.context) }
                catch { errors.append(error) }
            }
            storage.withLock { state in
                for subscriber in state.subscribers where publication.sequence > subscriber.hydratedSequence {
                    subscriber.listener.push(.init(value: publication.frame.value,
                        context: publication.frame.context, delivery: .update(sequence: publication.sequence)))
                }
            }
        }
        if errors.count == 1, let error = errors.first { report(error) }
        else if !errors.isEmpty { report(ReplicatedStateOperationsErrors(errors: errors)) }
        idle.finish()
    }

    private func report(_ error: any Error) { try? onError(error) }
}

/// Multiple exact operations listeners failed in one publication drain.
package struct ReplicatedStateOperationsErrors: Error, Sendable {
    package let errors: [any Error]
}
