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
    public let mcpServers = McpServerRegistry()
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
    typealias ErrorReporter = @Sendable (any Error) -> Void

    private struct State: Sendable {
        var unsubscribers: [UUID: @Sendable () -> Void] = [:]
        var disposed = false
        var staging = false
        var pending: [UUID: (String, EventBusHandler)] = [:]
        var makeErrorReporter: (@Sendable (String) -> ErrorReporter?)?
    }

    private let base: EventBus
    private let state = LockedState(State())

    init(_ base: EventBus) {
        self.base = base
    }

    func setErrorReporterFactory(_ factory: @escaping @Sendable (String) -> ErrorReporter?) {
        state.withLock {
            if !$0.disposed { $0.makeErrorReporter = factory }
        }
    }

    func emit(_ channel: String, _ data: (any Sendable)?) {
        guard !state.withLock({ $0.disposed }) else { return }
        base.emit(channel, data)
    }

    func beginLoading() { state.withLock { $0.staging = true } }

    func commitLoading() {
        let pending = state.withLock { state -> [UUID: (String, EventBusHandler)] in
            guard !state.disposed else { return [:] }
            state.staging = false
            let pending = state.pending
            state.pending.removeAll()
            return pending
        }
        for (id, (channel, handler)) in pending { subscribe(id, channel, handler) }
    }

    @discardableResult
    func on(_ channel: String, _ handler: @escaping EventBusHandler) -> @Sendable () -> Void {
        let id = UUID()
        let subscribeNow = state.withLock { state -> Bool in
            guard !state.disposed else { return false }
            if state.staging {
                state.pending[id] = (channel, handler)
                return false
            }
            return true
        }
        if subscribeNow { subscribe(id, channel, handler) }
        return { [weak self] in self?.remove(id) }
    }

    private func subscribe(_ id: UUID, _ channel: String, _ handler: @escaping EventBusHandler) {
        let unsubscribe = base.on(channel) { [weak self] data in
            let reportError = self?.errorReporter(for: channel)
            do {
                try await handler(data)
            } catch {
                // The runner can be installed while a handler from extension loading is suspended.
                (reportError ?? self?.errorReporter(for: channel))?(error)
            }
        }
        let keep = state.withLock { state -> Bool in
            guard !state.disposed else { return false }
            state.unsubscribers[id] = unsubscribe
            return true
        }
        if !keep { unsubscribe() }
    }

    private func errorReporter(for channel: String) -> ErrorReporter? {
        let makeErrorReporter = state.withLock { $0.makeErrorReporter }
        return makeErrorReporter?(channel)
    }

    func dispose() {
        let unsubscribers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.disposed else { return [] }
            state.disposed = true
            state.makeErrorReporter = nil
            state.pending.removeAll()
            let values = Array(state.unsubscribers.values)
            state.unsubscribers.removeAll()
            return values
        }
        for unsubscribe in unsubscribers {
            unsubscribe()
        }
    }

    private func remove(_ id: UUID) {
        let unsubscribe = state.withLock { state in
            state.pending.removeValue(forKey: id)
            return state.unsubscribers.removeValue(forKey: id)
        }
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
