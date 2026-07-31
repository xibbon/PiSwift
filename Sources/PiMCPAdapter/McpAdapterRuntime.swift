import Foundation
import PiSwiftAI

/// Versioned EventBus channel for `McpStatusSnapshot` values.
public let mcpStatusEvent = "pi-mcp-adapter/status/v1"

/// A read-only, machine-friendly view of one MCP server.
public enum McpServerRuntimeStatus: String, Sendable {
    case connected
    case cached
    case failed
    case needsAuth = "needs-auth"
    case notConnected = "not-connected"
    case disabled
}

public struct McpServerStatusSnapshot: Sendable {
    public let name: String
    public let status: McpServerRuntimeStatus
    public let toolCount: Int
    public let resourceCount: Int?
    public let failedAgoSeconds: Int?
    public let failureMessage: String?
    public let disabled: Bool

    public init(
        name: String,
        status: McpServerRuntimeStatus,
        toolCount: Int,
        resourceCount: Int? = nil,
        failedAgoSeconds: Int? = nil,
        failureMessage: String? = nil,
        disabled: Bool
    ) {
        self.name = name
        self.status = status
        self.toolCount = toolCount
        self.resourceCount = resourceCount
        self.failedAgoSeconds = failedAgoSeconds
        self.failureMessage = failureMessage
        self.disabled = disabled
    }
}

public struct McpStatusSnapshot: Sendable {
    public let version: Int
    public let servers: [McpServerStatusSnapshot]
    public let totalTools: Int
    public let totalResources: Int
    public let connectedCount: Int
    public let disabledCount: Int

    public init(
        version: Int = 1,
        servers: [McpServerStatusSnapshot],
        totalTools: Int,
        totalResources: Int,
        connectedCount: Int,
        disabledCount: Int
    ) {
        self.version = version
        self.servers = servers
        self.totalTools = totalTools
        self.totalResources = totalResources
        self.connectedCount = connectedCount
        self.disabledCount = disabledCount
    }
}

/// Session-owned adapter runtime. It is intentionally independent from a
/// terminal renderer, so a SwiftUI or service host can inspect and control MCP
/// connections without parsing tool or command output.
public actor McpAdapterRuntime {
    public let config: McpConfig
    private let initialMetadataCache: MetadataCache?
    private let metadataStore: any McpMetadataStore
    private let authorizationProvider: (any McpAuthorizationProvider)?
    private let serverRequestHandler: McpServerRequestHandler?
    private let outputStore: any McpOutputStore
    private let traceSink: (any McpTraceSink)?
    private var state: McpExtensionState?
    private var startTask: Task<McpExtensionState, Error>?
    private var toolSurfaceChangedHandler: (@Sendable () async -> Void)?

    public init(options: McpAdapterOptions) {
        self.config = options.config
        self.initialMetadataCache = options.metadataCache
        self.metadataStore = options.metadataStore
        self.authorizationProvider = options.authorizationProvider
        self.serverRequestHandler = options.serverRequestHandler
        self.outputStore = options.outputStore
        self.traceSink = options.traceSink
    }

    public func start() async throws {
        if state != nil { return }
        if let startTask {
            state = try await startTask.value
            return
        }

        let config = config
        let metadataCache: MetadataCache?
        if let initialMetadataCache {
            metadataCache = initialMetadataCache
        } else {
            metadataCache = await metadataStore.load()
        }
        let metadataStore = metadataStore
        let authorizationProvider = authorizationProvider
        let serverRequestHandler = serverRequestHandler
        let outputStore = outputStore
        let traceSink = traceSink
        let toolSurfaceChangedHandler = toolSurfaceChangedHandler
        let task = Task {
            try await initializeMcp(
                config: config,
                metadataCache: metadataCache,
                metadataStore: metadataStore,
                authorizationProvider: authorizationProvider,
                serverRequestHandler: serverRequestHandler,
                outputStore: outputStore,
                traceSink: traceSink,
                toolSurfaceChangedHandler: toolSurfaceChangedHandler
            )
        }
        startTask = task
        do {
            state = try await task.value
            startTask = nil
            if let toolSurfaceChangedHandler {
                await toolSurfaceChangedHandler()
            }
        } catch {
            startTask = nil
            throw error
        }
    }

    public func shutdown() async {
        if state == nil, let startTask {
            state = try? await startTask.value
        }
        startTask?.cancel()
        startTask = nil
        guard let state else { return }
        await flushMetadataCache(state)
        await state.lifecycle.gracefulShutdown()
        self.state = nil
    }

    public func status() async -> McpStatusSnapshot {
        let metadata = state?.toolMetadata.withLock { $0 } ?? [:]
        let cache = state?.metadataCache.withLock { $0 } ?? initialMetadataCache ?? MetadataCache()
        var servers: [McpServerStatusSnapshot] = []
        var totalTools = 0
        var totalResources = 0
        var connectedCount = 0
        var disabledCount = 0

        for name in config.mcpServers.keys.sorted() {
            guard let definition = config.mcpServers[name] else { continue }
            let disabled = definition.disabled == true
            let cached = cache.servers[name]
            let liveTools = metadata[name]
            let connected = disabled ? false : await state?.manager.isConnected(name: name) ?? false
            let failure = disabled ? nil : await state?.manager.lastFailure(name: name)
            let status: McpServerRuntimeStatus
            if disabled {
                status = .disabled
                disabledCount += 1
            } else if connected {
                status = .connected
                connectedCount += 1
            } else if let failure, failure.needsAuthorization {
                status = .needsAuth
            } else if failure != nil {
                status = .failed
            } else if liveTools != nil || cached != nil {
                status = .cached
            } else {
                status = .notConnected
            }

            let toolCount = disabled ? 0 : (liveTools?.count ?? cached?.tools.count ?? 0)
            let resourceCount = disabled ? nil : (cached?.resources.count)
            totalTools += toolCount
            totalResources += resourceCount ?? 0
            servers.append(McpServerStatusSnapshot(
                name: name,
                status: status,
                toolCount: toolCount,
                resourceCount: resourceCount,
                failedAgoSeconds: failure.map { max(0, Int(Date().timeIntervalSince($0.date))) },
                failureMessage: failure?.message,
                disabled: disabled
            ))
        }

        return McpStatusSnapshot(
            servers: servers,
            totalTools: totalTools,
            totalResources: totalResources,
            connectedCount: connectedCount,
            disabledCount: disabledCount
        )
    }

    public func metadataCache() -> MetadataCache {
        state?.metadataCache.withLock { $0 } ?? initialMetadataCache ?? MetadataCache()
    }

    /// Observe metadata changes that alter the live direct-tool or prompt surface.
    /// The handler is host-owned and may be set before or after `start()`.
    public func setToolSurfaceChangedHandler(_ handler: (@Sendable () async -> Void)?) {
        toolSurfaceChangedHandler = handler
        state?.toolSurfaceChangedHandler.withLock { $0 = handler }
    }

    /// Connect one enabled server and refresh its cached metadata.
    @discardableResult
    public func connect(serverName: String) async throws -> McpServerStatusSnapshot {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName] else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not configured")
        }
        guard definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is disabled")
        }
        let connection = try await state.manager.connect(name: serverName, definition: definition)
        if definition.lifecycle == "lazy-keep-alive" {
            await state.lifecycle.markKeepAlive(name: serverName, definition: definition)
        }
        updateToolMetadata(state: state, serverName: serverName, connection: connection, definition: definition)
        return McpServerStatusSnapshot(
            name: serverName,
            status: .connected,
            toolCount: connection.tools.count,
            resourceCount: connection.resources.count,
            disabled: false
        )
    }

    public func disconnect(serverName: String) async {
        guard let state else { return }
        await state.manager.close(name: serverName)
    }

    /// Drop one transport and establish a new session for an enabled server.
    @discardableResult
    public func reconnect(serverName: String) async throws -> McpServerStatusSnapshot {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        let connection = try await state.manager.reconnect(name: serverName, definition: definition)
        if definition.lifecycle == "lazy-keep-alive" {
            await state.lifecycle.markKeepAlive(name: serverName, definition: definition)
        }
        updateToolMetadata(state: state, serverName: serverName, connection: connection, definition: definition)
        return McpServerStatusSnapshot(
            name: serverName,
            status: .connected,
            toolCount: connection.tools.count,
            resourceCount: connection.resources.count,
            disabled: false
        )
    }

    /// Clear host-owned credentials, when the injected provider supports it,
    /// then disconnect the server. Returns false when credentials remain under
    /// host control and cannot be cleared through this adapter.
    @discardableResult
    public func logout(serverName: String) async throws -> Bool {
        guard let definition = config.mcpServers[serverName] else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not configured")
        }
        await disconnect(serverName: serverName)
        guard let provider = authorizationProvider as? any McpMutableAuthorizationProvider else {
            return false
        }
        await provider.clearAuthorization(for: serverName, configuration: definition)
        return true
    }

    public func listTools(serverName: String) async throws -> [McpTool] {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        guard let connection = await state.manager.getConnection(name: serverName) else {
            throw McpError.connectionFailed("Not connected to \(serverName)")
        }
        return connection.tools
    }

    public func listResources(serverName: String) async throws -> [McpResource] {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        guard let connection = await state.manager.getConnection(name: serverName) else {
            throw McpError.connectionFailed("Not connected to \(serverName)")
        }
        return connection.resources
    }

    /// Call a raw MCP tool without using a model-facing proxy. Hosts can use
    /// this for native controls while the extension remains the tool bridge.
    public func callTool(
        serverName: String,
        toolName: String,
        arguments: [String: AnyCodable] = [:]
    ) async throws -> McpToolResult {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName] else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not configured")
        }
        guard definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is disabled")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        await state.manager.touch(name: serverName)
        return try await state.manager.withSessionRecovery(name: serverName) { client in
            try await client.callTool(name: toolName, arguments: arguments)
        }
    }

    public func readResource(serverName: String, uri: String) async throws -> [McpResourceContent] {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName] else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not configured")
        }
        guard definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is disabled")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        await state.manager.touch(name: serverName)
        return try await state.manager.withSessionRecovery(name: serverName) { client in
            try await client.readResource(uri: uri)
        }
    }

    public func listPrompts(serverName: String) async throws -> [McpPrompt] {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        guard let connection = await state.manager.getConnection(name: serverName) else {
            throw McpError.connectionFailed("Not connected to \(serverName)")
        }
        return connection.prompts
    }

    /// Returns optional usage instructions supplied by the MCP server during
    /// initialization. The server is connected on demand.
    public func instructions(serverName: String) async throws -> String? {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        return await state.manager.getConnection(name: serverName)?.instructions
    }

    public func getPrompt(
        serverName: String,
        name: String,
        arguments: [String: String] = [:]
    ) async throws -> McpPromptResult {
        let state = try await requiredState()
        guard let definition = config.mcpServers[serverName], definition.disabled != true else {
            throw McpError.connectionFailed("Server \"\(serverName)\" is not available")
        }
        if !(await state.manager.isConnected(name: serverName)) {
            _ = try await connect(serverName: serverName)
        }
        await state.manager.touch(name: serverName)
        return try await state.manager.withSessionRecovery(name: serverName) { client in
            try await client.getPrompt(name: name, arguments: arguments)
        }
    }

    func readyState() async -> McpExtensionState? {
        if let state { return state }
        if let startTask {
            let resolved = try? await startTask.value
            if let resolved { state = resolved }
            return resolved
        }
        return nil
    }

    private func requiredState() async throws -> McpExtensionState {
        try await start()
        guard let state else {
            throw McpError.initializationFailed("MCP runtime did not start")
        }
        return state
    }
}
