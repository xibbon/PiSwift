import Foundation
import PiSwiftMCP

// MARK: - Lifecycle Manager

public actor McpLifecycleManager {
    private var serverDefinitions: [String: ServerEntry] = [:]
    private var keepAliveServers: Set<String> = []
    private var perServerIdleTimeout: [String: Int] = [:]
    private var globalIdleTimeoutMs: Int = 10 * 60 * 1000
    private var healthCheckTask: Task<Void, Never>?
    private var manager: McpServerManager?

    public var onReconnect: (@Sendable (String) async -> Void)?
    public var onIdleShutdown: (@Sendable (String) async -> Void)?

    public init() {}

    public func setManager(_ manager: McpServerManager) {
        self.manager = manager
    }

    public func registerServer(name: String, definition: ServerEntry, idleTimeout: Int? = nil) {
        serverDefinitions[name] = definition
        if let timeout = idleTimeout {
            perServerIdleTimeout[name] = timeout * 60 * 1000
        }
        if definition.lifecycle == "keep-alive" {
            keepAliveServers.insert(name)
        }
    }

    public func markKeepAlive(name: String, definition: ServerEntry) {
        serverDefinitions[name] = definition
        keepAliveServers.insert(name)
    }

    public func setGlobalIdleTimeout(minutes: Int) {
        if minutes <= 0 {
            globalIdleTimeoutMs = 0
        } else {
            globalIdleTimeoutMs = minutes * 60 * 1000
        }
    }

    public func startHealthChecks(intervalSeconds: Int = 30) {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.checkConnections()
            }
        }
    }

    public func gracefulShutdown() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        await manager?.closeAll()
    }

    // MARK: - Health Check

    private func checkConnections() async {
        guard let manager else { return }

        // Reconnect keep-alive servers
        for name in keepAliveServers {
            guard let definition = serverDefinitions[name] else { continue }
            let isConnected = await manager.isConnected(name: name)
            if !isConnected {
                do {
                    _ = try await manager.connect(name: name, definition: definition)
                    await onReconnect?(name)
                } catch {
                    // Will retry on next health check
                }
            }
        }

        // Check idle servers for timeout
        let allNames = await manager.allConnectionNames()
        for name in allNames {
            guard !keepAliveServers.contains(name) else { continue }
            let timeoutMs = perServerIdleTimeout[name] ?? globalIdleTimeoutMs
            guard timeoutMs > 0 else { continue }

            let isIdle = await manager.isIdle(name: name, timeoutMs: timeoutMs)
            if isIdle {
                await manager.close(name: name)
                await onIdleShutdown?(name)
            }
        }
    }

    public func getEffectiveIdleTimeout(name: String) -> Int {
        if let perServer = perServerIdleTimeout[name] {
            return perServer
        }
        if serverDefinitions[name]?.lifecycle == "eager" {
            return 0
        }
        return globalIdleTimeoutMs
    }
}
