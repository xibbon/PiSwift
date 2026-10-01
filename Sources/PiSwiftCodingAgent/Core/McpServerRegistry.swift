import Foundation
import PiSwiftAI

/// A server registered by an extension. Entries from mcp.json take precedence at connection time.
public struct RegisteredMcpServer: Sendable {
    public var name: String
    public var config: McpServerConfig
    public var extensionPath: String

    public init(name: String, config: McpServerConfig, extensionPath: String) {
        self.name = name
        self.config = config
        self.extensionPath = extensionPath
    }
}

/// Registrations from one extension runtime, kept in registration order.
public final class McpServerRegistry: Sendable {
    private struct State: Sendable {
        var order: [String] = []
        var servers: [String: RegisteredMcpServer] = [:]
        var changeListener: (@Sendable () -> Void)?
    }
    private let state = LockedState(State())

    public init() {}

    public func register(_ server: RegisteredMcpServer) {
        let listener = state.withLock { state -> (@Sendable () -> Void)? in
            if state.servers[server.name] == nil { state.order.append(server.name) }
            state.servers[server.name] = server
            return state.changeListener
        }
        listener?()
    }

    public func unregister(name: String, extensionPath: String) {
        let listener = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.servers[name]?.extensionPath == extensionPath else { return nil }
            state.servers.removeValue(forKey: name)
            state.order.removeAll { $0 == name }
            return state.changeListener
        }
        listener?()
    }

    public func unregisterAll(extensionPath: String) {
        let names = state.withLock { state in
            state.order.filter { state.servers[$0]?.extensionPath == extensionPath }
        }
        for name in names { unregister(name: name, extensionPath: extensionPath) }
    }

    public func get(_ name: String) -> RegisteredMcpServer? {
        state.withLock { $0.servers[name] }
    }

    public func list() -> [RegisteredMcpServer] {
        state.withLock { state in state.order.compactMap { state.servers[$0] } }
    }

    public func setChangeListener(_ listener: (@Sendable () -> Void)?) {
        state.withLock { $0.changeListener = listener }
    }
}
