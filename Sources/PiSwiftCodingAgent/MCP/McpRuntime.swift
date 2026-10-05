import Foundation
import PiSwiftAI
import PiSwiftMCP

public enum McpConnectionState: String, Sendable {
    case connecting, connected, disconnected, needsAuth = "needs-auth", failed, closed
}

public enum McpRuntimeError: Error, LocalizedError, Sendable {
    case invalidConfig(String)
    case connectionFailed(String)
    case signedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let text), .connectionFailed(let text), .signedOut(let text): text
        }
    }
}

public typealias McpTransportFactory = @Sendable (
    _ entry: McpServerEntry, _ cwd: URL, _ authProvider: (any McpAuthProvider)?
) throws -> any McpTransport

private func resolveMcpSecret(_ value: String, context: String) throws -> String {
    do { return try resolveConfigValueOrThrow(value, description: context) }
    catch { throw McpRuntimeError.invalidConfig(error.localizedDescription) }
}

func resolvedMcpOAuthSettings(_ entry: McpServerEntry) throws -> McpOAuthConfig {
    var settings = entry.config.oauth ?? McpOAuthConfig()
    if let secret = settings.clientSecret {
        settings.clientSecret = try resolveMcpSecret(secret, context: "MCP server \"\(entry.name)\" oauth.clientSecret")
    }
    return settings
}

private func expandMcpHome(_ value: String) -> String {
    if value == "~" { return NSHomeDirectory() }
    if value.hasPrefix("~/") { return NSHomeDirectory() + String(value.dropFirst()) }
    return value
}

public func createDefaultMcpTransport(entry: McpServerEntry, cwd: URL,
                                      authProvider: (any McpAuthProvider)?) throws -> any McpTransport {
    let config = entry.config
    if let rawURL = config.url, config.isHTTP, let url = URL(string: rawURL) {
        var headers: [String: String] = [:]
        for (name, value) in config.headers ?? [:] {
            headers[name] = try resolveMcpSecret(value, context: "MCP server \"\(entry.name)\" header \"\(name)\"")
        }
        return StreamableHTTPTransport(url: url, headers: headers, authProvider: authProvider)
    }
    guard let command = config.command, config.isStdio else {
        throw McpRuntimeError.invalidConfig("MCP server \"\(entry.name)\" needs a command or URL")
    }
    #if os(iOS)
    throw McpRuntimeError.invalidConfig("MCP server \"\(entry.name)\": stdio transport is unavailable on iOS")
    #else
    var environment: [String: String] = [:]
    for (name, value) in config.env ?? [:] {
        environment[name] = try resolveMcpSecret(value, context: "MCP server \"\(entry.name)\" env \"\(name)\"")
    }
    let directory = URL(fileURLWithPath: expandMcpHome(config.cwd ?? "."), relativeTo: cwd).standardizedFileURL
    return StdioTransport(command: expandMcpHome(command), args: (config.args ?? []).map(expandMcpHome),
                          env: environment, cwd: directory.path)
    #endif
}

private struct McpProviderAuth: McpAuthProvider {
    let provider: String
    let providerToken: (@Sendable (String) async -> String?)?

    func token() async throws -> String? { await providerToken?(provider) }
    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        // The bearer provider has no MCP refresh flow. End the request on the challenge.
        throw McpOAuthError.authorizationRequired
    }
}

public actor McpServerConnection {
    public nonisolated let entry: McpServerEntry
    public nonisolated let cwd: URL
    public nonisolated let timeoutMs: Int
    public nonisolated var name: String { entry.name }
    private let transportFactory: McpTransportFactory
    private let clientMetadataDocumentURL: URL?
    private let credentials: McpOAuthCredentialStore
    private let log: McpServerLog?
    private let onTools: (@Sendable (McpServerConnection) async -> Void)?
    private let onChange: (@Sendable (McpServerConnection) async -> Void)?
    private var client: McpClient?
    private var transport: (any McpTransport)?
    private var opening: Task<McpClient, any Error>?
    private var connectingClient: McpClient?
    private var closingConnectingClient: Task<Void, Never>?
    private var closed = false
    private var stderrTail: String?
    private var authProvider: (any McpAuthProvider)?
    private let providerToken: (@Sendable (String) async -> String?)?

    public private(set) var state: McpConnectionState = .connecting
    public private(set) var error: String?
    public private(set) var tools: [McpTool] = []
    public private(set) var hasResources = false
    public private(set) var resources: [McpResource] = []
    public private(set) var resourceTemplates: [McpResourceTemplate] = []
    public private(set) var instructions: String?
    public private(set) var challenge: McpOAuthChallenge?

    public init(entry: McpServerEntry, cwd: URL, createTransport: @escaping McpTransportFactory = createDefaultMcpTransport,
                credentials: McpOAuthCredentialStore, log: McpServerLog? = nil,
                clientMetadataDocumentURL: URL? = nil,
                providerToken: (@Sendable (String) async -> String?)? = nil,
                onTools: (@Sendable (McpServerConnection) async -> Void)? = nil,
                onChange: (@Sendable (McpServerConnection) async -> Void)? = nil) {
        self.entry = entry
        self.cwd = cwd
        self.timeoutMs = Int(entry.config.timeoutSeconds * 1000)
        self.transportFactory = createTransport
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.credentials = credentials
        self.providerToken = providerToken
        self.log = log
        self.onTools = onTools
        self.onChange = onChange
    }

    public var oauthURL: URL? {
        guard entry.config.auth == nil, let raw = entry.config.url,
              !(entry.config.headers ?? [:]).keys.contains(where: { $0.caseInsensitiveCompare("authorization") == .orderedSame }) else { return nil }
        return URL(string: raw)
    }

    /// Resolve the client secret on each call, with the same expansion as connections.
    public nonisolated func oauthSettings() throws -> McpOAuthConfig {
        try resolvedMcpOAuthSettings(entry)
    }

    /// Call after successful sign-in, before reconnecting. A failed sign-in keeps its challenge.
    public func clearOAuthChallenge() async {
        challenge = nil
        await changed()
    }

    private var signInRequiredMessage: String {
        let command = entry.config.auth.map { "/login \($0.provider)" } ?? "/mcp"
        return "MCP server \"\(entry.name)\" requires sign-in. Run \(command) to sign in."
    }

    private func needsSignIn(_ error: any Error) -> Bool {
        if case McpOAuthError.authorizationRequired = error { return true }
        return authProvider != nil && error is McpAuthRequiredError
    }

    private func changed() async { await onChange?(self) }

    public func connect() async throws {
        _ = try await getClient()
    }

    private func getClient() async throws -> McpClient {
        if closed { throw McpRuntimeError.connectionFailed("MCP server \"\(entry.name)\" is shut down") }
        if let client {
            let connected = await client.isConnected()
            if closed { throw McpRuntimeError.connectionFailed("MCP server \"\(entry.name)\" is shut down") }
            if connected { return client }
            self.client = nil
        }
        if let opening { return try await opening.value }
        let task = Task { try await open() }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    private func open() async throws -> McpClient {
        guard !closed else { throw await connectFailed(McpRuntimeError.connectionFailed("shut down while connecting")) }
        state = .connecting
        await changed()
        let delays: [UInt64] = entry.config.isHTTP ? [250_000_000, 1_000_000_000] : []
        for attempt in 0...delays.count {
            do { return try await connectOnce() }
            catch {
                if attempt == delays.count || !isTransient(error) || closed {
                    throw await connectFailed(error)
                }
                // Closing wakes the retry wait. Keep the error from the last attempt.
                try? await Task.sleep(nanoseconds: delays[attempt])
                if closed { throw await connectFailed(error) }
            }
        }
        throw McpRuntimeError.connectionFailed("MCP server \"\(entry.name)\" failed to connect")
    }

    private func connectFailed(_ error: any Error) async -> McpRuntimeError {
        if needsSignIn(error), !closed {
            state = .needsAuth
            self.error = nil
            await changed()
            return .connectionFailed(signInRequiredMessage)
        }
        state = closed ? .closed : .failed
        let message = (error as? McpHTTPError)?.message ?? error.localizedDescription
        let tail = stderrTail.map { "\n\($0)" } ?? ""
        let detail = message + tail
        self.error = detail
        await changed()
        return .connectionFailed("MCP server \"\(entry.name)\" failed to connect: \(detail)")
    }

    private func closeConnectingClient() async {
        guard let connectingClient else { return }
        let closing: Task<Void, Never>
        if let current = closingConnectingClient { closing = current }
        else {
            closing = Task { await connectingClient.close() }
            closingConnectingClient = closing
        }
        await closing.value
    }

    private func connectOnce() async throws -> McpClient {
        guard !closed else { throw McpRuntimeError.connectionFailed("shut down while connecting") }
        let identifier = UUID()
        let root = McpRoot(uri: cwd.absoluteString, name: cwd.lastPathComponent)
        let newClient = McpClient(connectionID: identifier, requestTimeoutMs: timeoutMs,
            serverNotificationHandler: { [weak self] method, parameters in
                guard let self else { return }
                await self.notification(method, parameters: parameters, clientID: identifier)
            }, connectionClosedHandler: { [weak self] in
                guard let self else { return }
                await self.didClose(clientID: identifier)
            }, roots: [root])
        connectingClient = newClient
        defer {
            connectingClient = nil
            closingConnectingClient = nil
        }
        var newTransport: (any McpTransport)?
        do {
            let auth: (any McpAuthProvider)?
            if let url = oauthURL {
                auth = McpServerAuthProvider(name: entry.name, serverURL: url, credentials: credentials,
                    settings: { [entry] in try resolvedMcpOAuthSettings(entry) },
                    clientMetadataDocumentURL: clientMetadataDocumentURL)
            } else if let provider = entry.config.auth?.provider {
                auth = McpProviderAuth(provider: provider, providerToken: providerToken)
            } else { auth = nil }
            authProvider = auth
            newTransport = try transportFactory(entry, cwd, auth)
            try await newClient.connect(transport: newTransport!)
            let hasTools = await newClient.supportsServerCapability("tools")
            let resourceCapability = await newClient.supportsServerCapability("resources")
            let listedTools = hasTools ? try await newClient.listAllTools() : []
            let fetched = resourceCapability ? await fetchResources(newClient) : (resources: [McpResource](), templates: [McpResourceTemplate]())
            let connected = await newClient.isConnected()
            let serverInstructions = await newClient.serverInstructions()?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Do not suspend between this check, client publication, and the state change.
            if closed { throw McpRuntimeError.connectionFailed("shut down while connecting") }
            if !connected { throw McpRuntimeError.connectionFailed("connection closed during setup") }
            client = newClient
            transport = newTransport
            tools = listedTools
            hasResources = resourceCapability
            resources = fetched.resources
            resourceTemplates = fetched.templates
            instructions = serverInstructions
            state = .connected
            self.error = nil
            await onTools?(self)
            await changed()
            return newClient
        } catch {
            if let oauth = authProvider as? McpServerAuthProvider { challenge = await oauth.challenge }
            await closeConnectingClient()
            #if os(macOS)
            if let stdio = newTransport as? StdioTransport {
                let value = await stdio.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                stderrTail = String(value.suffix(2_000))
            }
            #endif
            throw error
        }
    }

    private func notification(_ method: String, parameters: AnyCodable?, clientID: UUID) async {
        if method == "notifications/message", let log {
            await log.write(server: entry.name, params: parameters ?? AnyCodable(NSNull()))
        } else if method == "notifications/tools/list_changed" {
            // The client awaits notification handlers on its receive loop. A list request
            // must run in a separate task so that loop can receive its response.
            Task { await refreshTools(clientID: clientID) }
        } else if method == "notifications/resources/list_changed" {
            Task { await refreshResources(clientID: clientID) }
        }
    }

    private func didClose(clientID: UUID) async {
        guard client?.connectionID == clientID, !closed else { return }
        client = nil
        state = .disconnected
        #if os(macOS)
        if let stdio = transport as? StdioTransport {
            let value = await stdio.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            error = value.isEmpty ? "Connection closed" : "Connection closed\n\(value.suffix(2_000))"
        } else { error = "Connection closed" }
        #else
        error = "Connection closed"
        #endif
        transport = nil
        await changed()
    }

    private func refreshTools(clientID: UUID) async {
        guard let client, client.connectionID == clientID else { return }
        do {
            tools = try await client.listAllTools()
            await onTools?(self)
        } catch { self.error = "Failed to refresh tools: \(error.localizedDescription)" }
        await changed()
    }

    private func refreshResources(clientID: UUID) async {
        guard let client, client.connectionID == clientID else { return }
        let fetched = await fetchResources(client)
        resources = fetched.resources
        resourceTemplates = fetched.templates
        await onTools?(self)
        await changed()
    }

    private func fetchResources(_ client: McpClient) async -> (resources: [McpResource], templates: [McpResourceTemplate]) {
        async let resources = (try? client.listAllResources()) ?? []
        async let templates = (try? client.listAllResourceTemplates()) ?? []
        return (await resources.filter { !isMcpAppResource(uri: $0.uri, mimeType: $0.mimeType) },
                await templates.filter { !isMcpAppResource(uri: $0.uriTemplate, mimeType: $0.mimeType) })
    }

    private func withClient<T: Sendable>(readOnly: Bool = false,
        _ body: @Sendable (McpClient) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let current = try await getClient()
            do { return try await body(current) }
            catch {
                if error is McpSessionExpiredError, attempt == 0 {
                    if client?.connectionID == current.connectionID { client = nil }
                    continue
                }
                if readOnly, attempt == 0, isTransient(error) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if needsSignIn(error) {
                    if client?.connectionID == current.connectionID { client = nil; await current.close() }
                    state = .needsAuth
                    self.error = nil
                    await changed()
                    throw McpRuntimeError.connectionFailed(signInRequiredMessage)
                }
                throw error
            }
        }
        throw McpRuntimeError.connectionFailed("MCP request failed")
    }

    public func callTool(name: String, arguments: [String: AnyCodable], signal: CancellationToken? = nil,
                         timeoutMs: Int? = nil, onProgress: McpProgressHandler? = nil) async throws -> McpToolResult {
        try await withClient { try await $0.callTool(name: name, arguments: arguments, signal: signal,
                                                      timeoutMs: timeoutMs, onProgress: onProgress) }
    }

    public func resourcesPage(cursor: String? = nil) async throws -> (resources: [McpResource], nextCursor: String?) {
        try await withClient(readOnly: true) { try await $0.listResources(cursor: cursor) }
    }
    public func resourceTemplatesPage(cursor: String? = nil) async throws -> (resourceTemplates: [McpResourceTemplate], nextCursor: String?) {
        do { return try await withClient(readOnly: true) { try await $0.listResourceTemplates(cursor: cursor) } }
        catch McpError.rpcError(let code, _) where code == -32601 { return ([], nil) }
    }
    public func allResources() async throws -> [McpResource] { try await withClient(readOnly: true) { try await $0.listAllResources() } }
    public func allResourceTemplates() async throws -> [McpResourceTemplate] {
        do { return try await withClient(readOnly: true) { try await $0.listAllResourceTemplates() } }
        catch McpError.rpcError(let code, _) where code == -32601 { return [] }
    }
    public func readResource(_ uri: String, signal: CancellationToken? = nil) async throws -> [McpResourceContent] {
        try await withClient(readOnly: true) { try await $0.readResource(uri: uri, signal: signal) }
    }

    public func reconnect() async throws {
        if let opening { _ = try? await opening.value }
        if let client { self.client = nil; await client.close() }
        _ = try await getClient()
    }

    public func signOut() async {
        if let opening { _ = try? await opening.value }
        if let client { self.client = nil; await client.close() }
        if !closed { state = .needsAuth; await changed() }
    }

    /// Return after all server transports close, including a client that is still connecting.
    public func close() async {
        closed = true
        state = .closed
        let opening = self.opening
        await changed()
        // Close from a separate task before cancellation. Transport shutdown can await sleeps.
        await closeConnectingClient()
        opening?.cancel()
        if let opening { _ = await opening.result }
        if let client { self.client = nil; await client.close() }
        await (authProvider as? McpServerAuthProvider)?.settled()
    }
}

private func isTransient(_ error: any Error) -> Bool {
    if let http = error as? McpHTTPError {
        return http.status == 408 || http.status == 429 || (http.status >= 500 && http.status != 501)
    }
    return error is URLError
}
