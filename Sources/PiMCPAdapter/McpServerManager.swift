import Foundation
import PiSwiftAI
#if os(macOS)
import PiSwiftCodingAgent
#endif

// MARK: - Server Connection

public struct ServerConnection: Sendable {
    public var client: McpClient
    public var definition: ServerEntry?
    public var tools: [McpTool]
    public var resources: [McpResource]
    public var prompts: [McpPrompt]
    /// True when the server advertised prompts but prompts/list failed. The
    /// metadata cache then keeps same-config prompt commands until discovery
    /// succeeds or the server explicitly reports an empty list.
    public var promptDiscoveryFailed: Bool
    public var instructions: String?
    /// True only for a remote Streamable HTTP connection that received an
    /// MCP session identifier. It permits the narrow, spec-defined 404 retry.
    public var hasSessionIdentifier: Bool
    public var lastUsedAt: Date
    public var inFlight: Int
    public var status: ConnectionStatus

    public enum ConnectionStatus: String, Sendable {
        case connected
        case connecting
        case disconnected
        case error
    }

    public init(client: McpClient, definition: ServerEntry? = nil, tools: [McpTool] = [], resources: [McpResource] = [], prompts: [McpPrompt] = [], promptDiscoveryFailed: Bool = false, instructions: String? = nil, hasSessionIdentifier: Bool = false, lastUsedAt: Date = Date(), inFlight: Int = 0, status: ConnectionStatus = .connected) {
        self.client = client
        self.definition = definition
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.promptDiscoveryFailed = promptDiscoveryFailed
        self.instructions = instructions
        self.hasSessionIdentifier = hasSessionIdentifier
        self.lastUsedAt = lastUsedAt
        self.inFlight = inFlight
        self.status = status
    }
}

public struct McpConnectionFailure: Sendable {
    public let message: String
    public let date: Date
    public let needsAuthorization: Bool

    public init(message: String, date: Date = Date(), needsAuthorization: Bool = false) {
        self.message = message
        self.date = date
        self.needsAuthorization = needsAuthorization
    }
}

// MARK: - Server Manager

public actor McpServerManager {
    private struct ConnectionAttempt: Sendable {
        let id: UUID
        let task: Task<ServerConnection, Error>
    }

    private var connections: [String: ServerConnection] = [:]
    private var failures: [String: McpConnectionFailure] = [:]
    private var connectionAttempts: [String: ConnectionAttempt] = [:]
    private let authorizationProvider: (any McpAuthorizationProvider)?
    private let serverRequestHandler: McpServerRequestHandler?
    private let defaultRequestTimeoutMs: Int?
    private let clientCapabilities: McpClientCapabilities
    private let traceSettings: McpTraceSettings?
    private let traceSink: (any McpTraceSink)?
    private let transportFactory: (@Sendable (_ name: String, _ definition: ServerEntry) async throws -> any McpTransport)?
    private var metadataChangedHandler: (@Sendable (_ serverName: String, _ connection: ServerConnection) async -> Void)?

    public init(
        authorizationProvider: (any McpAuthorizationProvider)? = nil,
        serverRequestHandler: McpServerRequestHandler? = nil,
        defaultRequestTimeoutMs: Int? = nil,
        clientCapabilities: McpClientCapabilities = McpClientCapabilities(),
        traceSettings: McpTraceSettings? = nil,
        traceSink: (any McpTraceSink)? = nil,
        transportFactory: (@Sendable (_ name: String, _ definition: ServerEntry) async throws -> any McpTransport)? = nil
    ) {
        self.authorizationProvider = authorizationProvider
        self.serverRequestHandler = serverRequestHandler
        self.defaultRequestTimeoutMs = defaultRequestTimeoutMs.flatMap { $0 > 0 ? $0 : nil }
        self.clientCapabilities = clientCapabilities
        self.traceSettings = traceSettings
        self.traceSink = traceSink
        self.transportFactory = transportFactory
    }

    public func connect(name: String, definition: ServerEntry) async throws -> ServerConnection {
        if let existing = connections[name], existing.status == .connected {
            return existing
        }
        if let attempt = connectionAttempts[name] {
            return try await attempt.task.value
        }

        connections[name] = ServerConnection(
            client: McpClient(),
            status: .connecting
        )

        let attemptID = UUID()
        let attempt = Task { [weak self] () throws -> ServerConnection in
            guard let self else { throw McpError.transportClosed }
            return try await self.createConnection(name: name, definition: definition)
        }
        connectionAttempts[name] = ConnectionAttempt(id: attemptID, task: attempt)

        do {
            let conn = try await attempt.value
            guard connectionAttempts[name]?.id == attemptID else {
                await conn.client.close()
                throw McpError.transportClosed
            }
            connections[name] = conn
            failures.removeValue(forKey: name)
            connectionAttempts.removeValue(forKey: name)
            return conn
        } catch {
            if connectionAttempts[name]?.id == attemptID {
                connectionAttempts.removeValue(forKey: name)
                connections.removeValue(forKey: name)
            }
            let message = String(describing: error)
            failures[name] = McpConnectionFailure(
                message: message,
                needsAuthorization: definition.auth == .oauth && message.contains("authorization provider")
            )
            throw error
        }
    }

    public func close(name: String) async {
        connectionAttempts.removeValue(forKey: name)?.task.cancel()
        guard let conn = connections[name] else { return }
        await conn.client.close()
        connections.removeValue(forKey: name)
    }

    public func closeAll() async {
        for attempt in connectionAttempts.values {
            attempt.task.cancel()
        }
        connectionAttempts.removeAll()
        for (_, conn) in connections {
            await conn.client.close()
        }
        connections.removeAll()
    }

    public func getConnection(name: String) -> ServerConnection? {
        connections[name]
    }

    /// Force a fresh transport for a configured server. Concurrent reconnects
    /// share the same single-flight connection attempt.
    public func reconnect(name: String, definition: ServerEntry) async throws -> ServerConnection {
        await close(name: name)
        let connection = try await connect(name: name, definition: definition)
        await metadataChangedHandler?(name, connection)
        return connection
    }

    /// Retry exactly once after the protocol-defined Streamable HTTP session
    /// expiry signal. Other HTTP, JSON-RPC, and local-transport errors pass
    /// through unchanged to avoid duplicate MCP tool execution.
    public func withSessionRecovery<T: Sendable>(
        name: String,
        operation: @Sendable (McpClient) async throws -> T
    ) async throws -> T {
        guard let connection = connections[name],
              connection.status == .connected,
              let definition = connection.definition else {
            throw McpError.connectionFailed("Server \"\(name)\" is not connected")
        }
        do {
            return try await operation(connection.client)
        } catch {
            guard connection.hasSessionIdentifier, isTerminatedHttpSession(error) else { throw error }
            let fresh = try await reconnect(name: name, definition: definition)
            return try await operation(fresh.client)
        }
    }

    public func touch(name: String) {
        connections[name]?.lastUsedAt = Date()
    }

    public func incrementInFlight(name: String) {
        connections[name]?.inFlight += 1
        connections[name]?.lastUsedAt = Date()
    }

    public func decrementInFlight(name: String) {
        if let current = connections[name]?.inFlight, current > 0 {
            connections[name]?.inFlight = current - 1
        }
    }

    public func isIdle(name: String, timeoutMs: Int) -> Bool {
        guard let conn = connections[name],
              conn.status == .connected,
              conn.inFlight == 0 else {
            return false
        }
        let elapsed = Date().timeIntervalSince(conn.lastUsedAt) * 1000
        return elapsed > Double(timeoutMs)
    }

    public func isConnected(name: String) -> Bool {
        connections[name]?.status == .connected
    }

    public func lastFailure(name: String) -> McpConnectionFailure? {
        failures[name]
    }

    public func setMetadataChangedHandler(
        _ handler: (@Sendable (_ serverName: String, _ connection: ServerConnection) async -> Void)?
    ) {
        metadataChangedHandler = handler
    }

    private func refreshMetadata(name: String) async {
        guard var connection = connections[name],
              connection.status == .connected,
              let definition = connection.definition else { return }
        do {
            connection.tools = try await connection.client.listAllTools()
            connection.resources = await fetchResources(connection.client, definition: definition)
            if await connection.client.supportsServerCapability("prompts") {
                do {
                    connection.prompts = try await connection.client.listAllPrompts()
                    connection.promptDiscoveryFailed = false
                } catch {
                    connection.promptDiscoveryFailed = true
                }
            } else {
                connection.prompts = []
                connection.promptDiscoveryFailed = false
            }
            connections[name] = connection
            await metadataChangedHandler?(name, connection)
        } catch {
            failures[name] = McpConnectionFailure(message: String(describing: error))
        }
    }

    private func markConnectionClosed(name: String, connectionID: UUID) {
        guard var connection = connections[name], connection.client.connectionID == connectionID else { return }
        connection.status = .disconnected
        connections[name] = connection
    }

    private func createConnection(name: String, definition: ServerEntry) async throws -> ServerConnection {
        try Task.checkCancellation()
        let baseTransport = try await createTransport(name: name, definition: definition)
        let connectionID = UUID()
        let client = McpClient(
            connectionID: connectionID,
            requestTimeoutMs: resolvedRequestTimeoutMs(definition),
            serverRequestHandler: serverRequestHandler,
            serverNotificationHandler: { [weak self] method, _ in
                guard method == "notifications/tools/list_changed"
                    || method == "notifications/resources/list_changed"
                    || method == "notifications/prompts/list_changed" else { return }
                await self?.refreshMetadata(name: name)
            },
            connectionClosedHandler: { [weak self] in
                await self?.markConnectionClosed(name: name, connectionID: connectionID)
            },
            capabilities: clientCapabilities
        )

        if let stdioTransport = baseTransport as? StdioTransport {
            try await stdioTransport.start()
        } else if let socketTransport = baseTransport as? UnixSocketTransport {
            try await socketTransport.start()
        }

        let transport: any McpTransport
        if definition.trace ?? traceSettings?.enabled == true, let traceSink {
            transport = McpTracingTransport(
                base: baseTransport,
                serverName: name,
                transportName: traceTransportName(definition),
                sink: traceSink
            )
        } else {
            transport = baseTransport
        }
        try await client.connect(transport: transport)
        try Task.checkCancellation()

        let tools = try await client.listAllTools()
        let resources = await fetchResources(client, definition: definition)
        // Prompt support is optional. A server that does not advertise it
        // must remain usable for tools and resources. An advertised prompt
        // list failure is retained so the metadata cache is not erased.
        let prompts: [McpPrompt]
        let promptDiscoveryFailed: Bool
        if await client.supportsServerCapability("prompts") {
            do {
                prompts = try await client.listAllPrompts()
                promptDiscoveryFailed = false
            } catch {
                prompts = []
                promptDiscoveryFailed = true
            }
        } else {
            prompts = []
            promptDiscoveryFailed = false
        }
        let instructions = await client.serverInstructions()
        let hasSessionIdentifier: Bool
        if let sessionTransport = baseTransport as? any McpSessionAwareTransport {
            hasSessionIdentifier = await sessionTransport.hasSessionIdentifier()
        } else {
            hasSessionIdentifier = false
        }
        try Task.checkCancellation()

        return ServerConnection(
            client: client,
            definition: definition,
            tools: tools,
            resources: resources,
            prompts: prompts,
            promptDiscoveryFailed: promptDiscoveryFailed,
            instructions: instructions,
            hasSessionIdentifier: hasSessionIdentifier,
            lastUsedAt: Date(),
            status: .connected
        )
    }

    public func allConnectionNames() -> [String] {
        Array(connections.keys)
    }

    // MARK: - Transport Creation

    private func createTransport(name: String, definition: ServerEntry) async throws -> any McpTransport {
        if let transportFactory {
            return try await transportFactory(name, definition)
        }
        let configuredTransports = [definition.command, definition.url, definition.socket]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard configuredTransports.count == 1 else {
            throw McpError.connectionFailed("Server \"\(name)\" must configure exactly one of command, url, or socket")
        }
        if let url = definition.url {
            let resolvedURL = interpolateEnvVars(url)
            guard let parsedUrl = URL(string: resolvedURL) else {
                throw McpError.connectionFailed("Invalid URL: \(resolvedURL)")
            }
            var headers = try await resolveCommandSecrets(
                in: definition.headers,
                context: { key in "MCP server \"\(name)\" HTTP header \"\(key)\"" }
            ) ?? [:]
            try await applyAuth(name: name, definition: definition, headers: &headers)
            return HttpTransport(url: parsedUrl, headers: headers, debug: definition.debug ?? false)
        }

        if let socket = definition.socket {
            return UnixSocketTransport(path: socket)
        }

        guard let command = definition.command else {
            throw McpError.connectionFailed("Server \"\(name)\" has no command or url")
        }

        var resolvedCommand = command
        var resolvedArgs = definition.args ?? []

        // npx resolver optimization
        let lowerCommand = command.lowercased()
        if lowerCommand == "npx" || lowerCommand.hasSuffix("/npx") ||
           lowerCommand == "npm" || lowerCommand.hasSuffix("/npm") {
            if let resolution = await resolveNpxBinary(command: command, args: resolvedArgs) {
                if resolution.isJs {
                    resolvedCommand = "node"
                    resolvedArgs = [resolution.binPath] + resolution.extraArgs
                } else {
                    resolvedCommand = resolution.binPath
                    resolvedArgs = resolution.extraArgs
                }
            }
        }

        let env = try await resolveCommandSecrets(
            in: definition.env,
            context: { key in "MCP server \"\(name)\" environment variable \"\(key)\"" }
        )
        return StdioTransport(
            command: resolvedCommand,
            args: resolvedArgs,
            env: env,
            cwd: definition.cwd,
            debug: definition.debug ?? false
        )
    }

    private func resolvedRequestTimeoutMs(_ definition: ServerEntry) -> Int? {
        let timeout = definition.requestTimeoutMs ?? defaultRequestTimeoutMs
        guard let timeout, timeout > 0 else { return nil }
        return timeout
    }

    private func traceTransportName(_ definition: ServerEntry) -> String {
        if definition.socket != nil { return "unix-socket" }
        if definition.url != nil { return "streamable-http" }
        if definition.command != nil { return "stdio" }
        return "unknown"
    }

    private func fetchResources(_ client: McpClient, definition: ServerEntry) async -> [McpResource] {
        guard definition.exposeResources != false,
              await client.supportsServerCapability("resources") else {
            return []
        }
        // Resources are optional even when advertised. A broken list request
        // must not make a tools-only connection unusable.
        return (try? await client.listAllResources()) ?? []
    }

    private func applyAuth(name: String, definition: ServerEntry, headers: inout [String: String]) async throws {
        if definition.auth == .bearer {
            let configuredToken = definition.bearerToken
                ?? definition.bearerTokenEnv.flatMap { ProcessInfo.processInfo.environment[$0] }
            let token = try await resolveCommandSecret(
                configuredToken,
                context: "MCP server \"\(name)\" HTTP bearer token"
            )
            if let token {
                headers["Authorization"] = "Bearer \(token)"
            }
        } else if definition.auth == .oauth {
            var resolvedDefinition = definition
            if var oauth = resolvedDefinition.oauth {
                oauth.clientSecret = try await resolveCommandSecret(
                    oauth.clientSecret,
                    context: "MCP server \"\(name)\" OAuth client secret"
                )
                resolvedDefinition.oauth = oauth
            }
            guard let authorization = await authorizationProvider?.authorizationHeader(
                for: name,
                configuration: resolvedDefinition
            ) else {
                throw McpError.connectionFailed("OAuth credentials for \"\(name)\" require a host authorization provider")
            }
            headers["Authorization"] = authorization
        }
    }
}

private func isTerminatedHttpSession(_ error: any Error) -> Bool {
    guard let error = error as? McpError else { return false }
    switch error {
    case .protocolError(let message):
        return message.hasPrefix("HTTP 404:")
    case .rpcError(let code, let message):
        return code == -32_000 && (message == "Server not initialized" || message == "Bad Request: Server not initialized")
    default:
        return false
    }
}

// MARK: - Environment / Header Interpolation

func resolveEnv(_ env: [String: String]?) -> [String: String]? {
    guard let env else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in env {
        resolved[key] = interpolateEnvVars(value)
    }
    return resolved
}

func resolveHeaders(_ headers: [String: String]?) -> [String: String] {
    guard let headers else { return [:] }
    var resolved: [String: String] = [:]
    for (key, value) in headers {
        resolved[key] = interpolateEnvVars(value)
    }
    return resolved
}

/// Resolve a configured value without executing a command marker. This is
/// deliberately separate from the connection-time resolver so cache reads,
/// hashes, previews, and status rendering cannot start external processes.
func resolveCommandSecret(_ value: String?, context: String) async throws -> String? {
    guard let value else { return nil }
    if value.hasPrefix("!!") {
        return interpolateEnvVars(String(value.dropFirst()))
    }
    guard value.hasPrefix("!") else { return interpolateEnvVars(value) }

    #if os(macOS)
    let command = String(value.dropFirst())
    let result = try await execCommand(
        "/bin/sh",
        ["-c", command],
        "/",
        ExecOptions(timeout: 10, maxOutputBytes: 1_024 * 1_024, captureStderr: false)
    )
    if result.outputExceeded {
        throw McpError.connectionFailed("Failed to resolve \(context): command output exceeded 1 MiB")
    }
    if result.killed {
        throw McpError.connectionFailed("Failed to resolve \(context): command timed out after 10 seconds")
    }
    guard result.code == 0 else {
        throw McpError.connectionFailed("Failed to resolve \(context): command exited with code \(result.code)")
    }
    let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolved.isEmpty else {
        throw McpError.connectionFailed("Failed to resolve \(context): command returned empty output")
    }
    return resolved
    #else
    throw McpError.connectionFailed("Failed to resolve \(context): !command secrets are available only on macOS")
    #endif
}

private func resolveCommandSecrets(
    in values: [String: String]?,
    context: (String) -> String
) async throws -> [String: String]? {
    guard let values else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in values {
        resolved[key] = try await resolveCommandSecret(value, context: context(key))
    }
    return resolved
}

private func interpolateEnvVars(_ value: String) -> String {
    var result = value
    // Handle ${VAR} pattern
    let dollarBrace = try? NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
    if let matches = dollarBrace?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let varName = String(result[varRange])
            let envValue = ProcessInfo.processInfo.environment[varName] ?? ""
            result.replaceSubrange(fullRange, with: envValue)
        }
    }
    // Handle $env:VAR pattern
    let envColon = try? NSRegularExpression(pattern: #"\$env:([A-Za-z_][A-Za-z0-9_]*)"#)
    if let matches = envColon?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
        for match in matches.reversed() {
            guard let varRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let varName = String(result[varRange])
            let envValue = ProcessInfo.processInfo.environment[varName] ?? ""
            result.replaceSubrange(fullRange, with: envValue)
        }
    }
    return result
}
