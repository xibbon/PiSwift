import Synchronization

/// The default abort reason.
public struct AbortError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Creates the default abort error.
    public init() {}
    /// The text description of this value or error.
    public var description: String { "The operation was aborted" }
}

/// Identifies one listener. Use `AbortSignal.removeAbortListener(_:)` to remove it.
/// Discarding a registration does not remove the listener.
public struct AbortListenerRegistration: Sendable {
    fileprivate let identity = ListenerIdentity()
}

fileprivate final class ListenerIdentity: Sendable {}

/// A cancellation signal with synchronous, ordered abort listeners.
public final class AbortSignal: Sendable {
    private static let nextCreationOrder = Mutex<UInt64>(0)
    private let creationOrder: UInt64
    private struct Listener: Sendable {
        let registration: AbortListenerRegistration
        let callback: (@Sendable (any Error) -> Void)?
        let prepare: (@Sendable (any Error) -> Delivery?)?
    }

    private struct Source: Sendable {
        let signal: AbortSignal
        let registration: AbortListenerRegistration

        func removeListener() { signal.removeAbortListener(registration) }
    }

    private struct State: Sendable {
        var reason: (any Error)?
        var listeners: [Listener] = []
        var sources: [Source] = []
    }

    private struct Delivery: Sendable {
        let signal: AbortSignal
        let reason: any Error
        let registrations: [AbortListenerRegistration]
        let sources: [Source]
        let dependencies: [@Sendable (any Error) -> Delivery?]
    }

    private let state = Mutex(State())

    fileprivate init() {
        creationOrder = Self.nextCreationOrder.withLock { next in
            let order = next
            next += 1
            return order
        }
    }

    deinit {
        let sources = state.withLock { state in
            let sources = state.sources
            state.sources = []
            return sources
        }
        for source in sources { source.removeListener() }
    }

    /// Whether this signal has an abort reason.
    public var aborted: Bool { state.withLock { $0.reason != nil } }
    /// The first abort reason, or nil before abort.
    public var reason: (any Error)? { state.withLock { $0.reason } }

    /// Throws the stored reason if this signal is aborted.
    public func throwIfAborted() throws {
        if let reason { throw reason }
    }

    /// Adds one listener. A listener added after abort starts is never called.
    /// Listeners run once, in registration order, on the thread that calls `abort`.
    @discardableResult
    public func addAbortListener(
        _ listener: @escaping @Sendable (any Error) -> Void
    ) -> AbortListenerRegistration {
        let registration = AbortListenerRegistration()
        state.withLock { state in
            if state.reason == nil {
                state.listeners.append(Listener(registration: registration, callback: listener, prepare: nil))
            }
        }
        return registration
    }

    /// Removes the identified listener. If its callback has started, it can finish.
    /// A registration from another signal has no effect.
    public func removeAbortListener(_ registration: AbortListenerRegistration) {
        // Release the callback outside the lock, including its captured values.
        let removed = state.withLock { state -> Listener? in
            guard let index = state.listeners.firstIndex(where: {
                $0.registration.identity === registration.identity
            }) else { return nil }
            return state.listeners.remove(at: index)
        }
        withExtendedLifetime(removed) {}
    }

    internal var listenerCount: Int { state.withLock { $0.listeners.count } }

    private func prepareAbort(_ reason: any Error) -> Delivery? {
        state.withLock { state -> Delivery? in
            guard state.reason == nil else { return nil }
            state.reason = reason
            let sources = state.sources
            state.sources = []
            return Delivery(
                signal: self, reason: reason,
                registrations: state.listeners.map(\.registration), sources: sources,
                dependencies: state.listeners.compactMap(\.prepare)
            )
        }
    }

    fileprivate func abort(_ reason: any Error) {
        guard let initial = prepareAbort(reason) else { return }
        var deliveries = [initial]
        var index = 0
        // Set all dependent states before a user callback can abort another source.
        // Source callbacks run before dependent callbacks, as in AbortSignal.any.
        while index < deliveries.count {
            let delivery = deliveries[index]
            for prepare in delivery.dependencies {
                if let dependent = prepare(delivery.reason) { deliveries.append(dependent) }
            }
            index += 1
        }
        // Native any keeps dependent signals in creation order, including nested
        // combinations. Graph depth alone does not give that order.
        deliveries.sort { $0.signal.creationOrder < $1.signal.creationOrder }
        for delivery in deliveries { delivery.signal.deliver(delivery) }
    }

    private func deliver(_ delivery: Delivery) {
        for source in delivery.sources { source.removeListener() }
        for registration in delivery.registrations {
            let listener = state.withLock { state -> Listener? in
                guard let index = state.listeners.firstIndex(where: {
                    $0.registration.identity === registration.identity
                }) else { return nil }
                return state.listeners.remove(at: index)
            }
            // Removal by an earlier listener prevents this callback from running.
            listener?.callback?(delivery.reason)
        }
    }

    /// Aborts with the first source reason. An already aborted source wins in
    /// array order. An empty array gives a signal that never aborts.
    /// Source listeners hold this signal weakly and are removed on abort or deinit.
    public static func any(_ signals: [AbortSignal]) -> AbortSignal {
        let combined = AbortSignal()
        for signal in signals {
            if let reason = signal.reason {
                combined.abort(reason)
                return combined
            }
        }
        for signal in signals {
            let registration = AbortListenerRegistration()
            signal.state.withLock { state in
                if state.reason == nil {
                    state.listeners.append(Listener(
                        registration: registration, callback: nil,
                        prepare: { [weak combined] reason in combined?.prepareAbort(reason) }
                    ))
                }
            }
            let source = Source(signal: signal, registration: registration)
            let keep = combined.state.withLock { state in
                guard state.reason == nil else { return false }
                state.sources.append(source)
                return true
            }
            if !keep { source.removeListener() }
            // Close the race between the initial check and listener registration.
            if let reason = signal.reason { combined.abort(reason) }
            if combined.aborted { break }
        }
        return combined
    }
}

/// Owns a signal. The first abort reason wins; later calls have no effect.
public final class AbortController: Sendable {
    /// The signal controlled by this controller.
    public let signal = AbortSignal()

    /// Creates an independent cancellation controller.
    public init() {}

    /// Aborts the signal once, using AbortError when no reason is supplied.
    public func abort(_ reason: (any Error)? = nil) {
        signal.abort(reason ?? AbortError())
    }
}
