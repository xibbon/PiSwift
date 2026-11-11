import PiSwiftChord
import Synchronization

/// A synchronous observer. Calls must not block or call Session operations.
public struct Observer<Value: Sendable>: Sendable {
    public let advance: @Sendable (WatchCall<Value>, ChordContext) throws -> Void
    public let end: @Sendable (WatchEnd) throws -> Void
    public init(advance: @escaping @Sendable (WatchCall<Value>, ChordContext) throws -> Void,
                end: @escaping @Sendable (WatchEnd) throws -> Void) {
        self.advance = advance; self.end = end
    }
}

/// A synchronous observer of stored commits.
public struct CommitObserver: Sendable {
    public let advance: @Sendable (CommitPublication, ChordContext) throws -> Void
    public let end: @Sendable (WatchEnd) throws -> Void
    public init(advance: @escaping @Sendable (CommitPublication, ChordContext) throws -> Void,
                end: @escaping @Sendable (WatchEnd) throws -> Void) {
        self.advance = advance; self.end = end
    }
}

/// The acquisition value and an idempotent detach operation.
public struct Observation<Value: Sendable>: Sendable {
    public let value: Value
    private let release: @Sendable () -> Void
    internal init(value: Value, detach: @escaping @Sendable () -> Void) { self.value = value; release = detach }
    public func detach() { release() }
}

public struct CommitObservation: Sendable {
    private let release: @Sendable () -> Void
    internal init(detach: @escaping @Sendable () -> Void) { release = detach }
    public func detach() { release() }
}

// v1.5.2 CH3 session/session.ts:1766–1818 guardObserver.
internal final class GuardedObserver<Call: Sendable>: Sendable {
    private struct Attached: Sendable {
        let advance: @Sendable (Call, ChordContext) throws -> Void
        let end: @Sendable (WatchEnd) throws -> Void
        let detach: @Sendable () -> Void
        let report: @Sendable (any Error) -> Void
    }
    private let state: Mutex<Attached?>
    init(advance: @escaping @Sendable (Call, ChordContext) throws -> Void,
         end: @escaping @Sendable (WatchEnd) throws -> Void,
         detach: @escaping @Sendable () -> Void,
         report: @escaping @Sendable (any Error) -> Void) {
        state = Mutex(Attached(advance: advance, end: end, detach: detach, report: report))
    }
    private func release() -> Attached? {
        let result = state.withLock { state in let result = state; state = nil; return result }
        result?.detach()
        return result
    }
    func advance(_ call: Call, context: ChordContext) {
        guard let current = state.withLock({ $0 }) else { return }
        do { try current.advance(call, context) }
        catch {
            current.report(error)
            if release() != nil {
                do { try current.end(.listenerError(String(describing: error))) }
                catch { current.report(error) }
            }
        }
    }
    func end(_ end: WatchEnd) {
        guard let current = release() else { return }
        do { try current.end(end) } catch { current.report(error) }
    }
    func detach() { _ = release() }
}

/// Holds subscriptions that can be detached while acquisition still installs them.
internal final class ObserverSubscriptions: Sendable {
    private struct State { var attached = true; var subscriptions: [SessionSubscription] = [] }
    private let state = Mutex(State())
    var attached: Bool { state.withLock { $0.attached } }
    func add(_ subscription: SessionSubscription) {
        let keep = state.withLock { state in
            guard state.attached else { return false }
            state.subscriptions.append(subscription); return true
        }
        if !keep { subscription.cancel() }
    }
    func detach() {
        let subscriptions = state.withLock { state in
            state.attached = false
            let result = state.subscriptions; state.subscriptions = []; return result
        }
        for subscription in subscriptions { subscription.cancel() }
    }
}
