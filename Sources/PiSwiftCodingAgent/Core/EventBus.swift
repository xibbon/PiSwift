import Foundation
import PiSwiftAI

public typealias EventBusHandler = @Sendable ((any Sendable)?) async throws -> Void

public protocol EventBus: Sendable {
    func emit(_ channel: String, _ data: (any Sendable)?)
    @discardableResult func on(_ channel: String, _ handler: @escaping EventBusHandler) -> @Sendable () -> Void
}

public protocol EventBusController: EventBus {
    func clear()
}

public final class EventBusImpl: Sendable, EventBusController {
    private let state = LockedState([String: [(UUID, EventBusHandler)]]())

    public init() {}

    public func emit(_ channel: String, _ data: (any Sendable)?) {
        let payload = data
        let snapshot = state.withLock { handlers in
            handlers[channel] ?? []
        }

        for (_, handler) in snapshot {
            Task { [payload] in
                do {
                    try await handler(payload)
                } catch {
                    logEventBusError(channel, error)
                }
            }
        }
    }

    public func on(_ channel: String, _ handler: @escaping EventBusHandler) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { handlers in
            handlers[channel, default: []].append((id, handler))
        }
        return { [weak self] in
            self?.removeHandler(channel, id)
        }
    }

    public func clear() {
        state.withLock { handlers in
            handlers.removeAll()
        }
    }

    private func removeHandler(_ channel: String, _ id: UUID) {
        state.withLock { handlers in
            if var list = handlers[channel] {
                list.removeAll { $0.0 == id }
                handlers[channel] = list
            }
        }
    }
}

/// Tracks one extension's event-bus subscriptions so reload and disposal can remove them.
final class TrackedEventBus: Sendable, EventBus {
    private struct State: Sendable {
        var unsubscribers: [UUID: @Sendable () -> Void] = [:]
        var disposed = false
    }

    private let base: EventBus
    private let state = LockedState(State())

    init(_ base: EventBus) {
        self.base = base
    }

    func emit(_ channel: String, _ data: (any Sendable)?) {
        guard !state.withLock({ $0.disposed }) else { return }
        base.emit(channel, data)
    }

    @discardableResult
    func on(_ channel: String, _ handler: @escaping EventBusHandler) -> @Sendable () -> Void {
        let id = UUID()
        let unsubscribe = base.on(channel, handler)
        let shouldKeep = state.withLock { state -> Bool in
            guard !state.disposed else { return false }
            state.unsubscribers[id] = unsubscribe
            return true
        }
        if !shouldKeep {
            unsubscribe()
        }
        return { [weak self] in
            self?.remove(id)
        }
    }

    func dispose() {
        let unsubscribers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.disposed else { return [] }
            state.disposed = true
            let values = Array(state.unsubscribers.values)
            state.unsubscribers.removeAll()
            return values
        }
        for unsubscribe in unsubscribers {
            unsubscribe()
        }
    }

    private func remove(_ id: UUID) {
        let unsubscribe = state.withLock { $0.unsubscribers.removeValue(forKey: id) }
        unsubscribe?()
    }
}

public func createEventBus() -> EventBusController {
    EventBusImpl()
}

private func logEventBusError(_ channel: String, _ error: Error) {
    let message = "Event handler error (\(channel)): \(error)\n"
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
