import Foundation
import PiSwiftAI
import PiSwiftMCP
#if os(macOS)
import AppKit
#endif

public struct McpExtensionOptions: Sendable {
    public var agentDir: URL
    public var loadConfig: (@Sendable (HookContext) -> LoadedMcpConfig)?
    public var createTransport: McpTransportFactory
    public var credentials: McpOAuthCredentialStore?
    public var logPath: URL?
    public var presenter: (any McpSignInPresenter)?
    public var ui: (any McpUi)?
    /// The HTTPS document must list all accepted presenter redirect URIs. No default is supplied.
    public var clientMetadataDocumentURL: URL?
    public var startupWaitMs: Int

    public init(agentDir: URL = URL(fileURLWithPath: getAgentDir()),
                loadConfig: (@Sendable (HookContext) -> LoadedMcpConfig)? = nil,
                createTransport: @escaping McpTransportFactory = createDefaultMcpTransport,
                credentials: McpOAuthCredentialStore? = nil, logPath: URL? = nil,
                presenter: (any McpSignInPresenter)? = nil, ui: (any McpUi)? = nil,
                clientMetadataDocumentURL: URL? = nil, startupWaitMs: Int = 10_000) {
        self.agentDir = agentDir; self.loadConfig = loadConfig; self.createTransport = createTransport
        self.credentials = credentials; self.logPath = logPath; self.presenter = presenter; self.ui = ui
        self.clientMetadataDocumentURL = clientMetadataDocumentURL
        self.startupWaitMs = startupWaitMs
    }
}

private let mcpExposureDescriptions: [(McpExposure, String)] = [
    (.codemode, "called from codemode scripts, which find them with searchTools()"),
    (.deferred, "not declared until tool_search loads them, then called directly; no codemode needed"),
    (.direct, "declared to the model like built-in tools"),
]

private struct McpManagerPresenter: McpSignInPresenter {
    let base: any McpSignInPresenter
    let ui: any McpUi
    let title: String
    let onCancel: @MainActor @Sendable () -> Void

    func redirectURL(for state: String) async throws -> URL { try await base.redirectURL(for: state) }

    func present(authorizationURL: URL, state: String) async throws -> URL {
        do {
            let result = try await base.present(authorizationURL: authorizationURL, state: state)
            try Task.checkCancellation()
            await ui.status(title: title, message: "Connecting…", onCancel: onCancel)
            return result
        } catch {
            if isMcpSignInCancellation(error) {
                if !Task.isCancelled {
                    await ui.status(title: title, message: "Connecting…", onCancel: onCancel)
                }
                throw CancellationError()
            }
            throw error
        }
    }

    func cancel() async { await base.cancel() }
}

private struct McpCommandPresenter: McpSignInPresenter {
    let base: any McpSignInPresenter
    let notify: @Sendable (URL) async -> Void

    func redirectURL(for state: String) async throws -> URL { try await base.redirectURL(for: state) }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        await notify(authorizationURL)
        return try await base.present(authorizationURL: authorizationURL, state: state)
    }
    func cancel() async { await base.cancel() }
}

private struct BuiltinMcpServer: Sendable {
    var entry: McpServerEntry
    var connection: McpServerConnection?
    var registeredConfig: McpServerConfig?
    var readyComplete = false
    var attempt = UUID()
    var readyTask: Task<Void, Never>?
    var closing: Task<Void, Never>?
}

private enum McpWork: Sendable {
    case action(Task<Void, Never>)
    case signIn(Task<String?, Never>)

    func cancelSignIn() {
        if case .signIn(let task) = self { task.cancel() }
    }

    func wait() async {
        switch self {
        case .action(let task): await task.value
        case .signIn(let task): _ = await task.value
        }
    }
}

/// The built-in's per-session state. Dynamic tool registration stays on the hook pipeline.
public actor McpBuiltinRuntime {
    private let api: HookAPI
    private let options: McpExtensionOptions
    private let credentials: McpOAuthCredentialStore
    private let log: McpServerLog
    private var servers: [String: BuiltinMcpServer] = [:]
    private var serverNames: [String] = []
    private var orderedServers: [BuiltinMcpServer] { serverNames.compactMap { servers[$0] } }
    private var configuredEntries: [McpServerEntry] = []
    private var configErrors: [String] = []
    private var projectConfig: String?
    private var overridden: [String] = []
    private var startup: Task<Void, Never>?
    private var startupComplete = true
    private var waitedForStartup = false
    private var sessionActive = false
    private var generation = 0
    private var sessionCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    private var modelRegistry: ModelRegistry?
    private var autoEnableCodemode = true
    private var warnedUnreachable = false
    private var serverTools: [String: Set<String>] = [:]
    private var toolOwners: [String: String] = [:]
    private var definitions: [String: CustomTool] = [:]
    private var resourceExposure: McpExposure?
    private var tokensAtSignIn: [String: String] = [:]
    private var serverMessages: [String: String] = [:]
    private var work: [UUID: McpWork] = [:]
    private var menuChanges: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(api: HookAPI, options: McpExtensionOptions) {
        self.api = api; self.options = options
        self.credentials = options.credentials ?? McpOAuthCredentialStore(agentDir: options.agentDir)
        self.log = McpServerLog(path: options.logPath ?? options.agentDir.appendingPathComponent("mcp.log"))
    }

    public func start(context: HookContext) async {
        modelRegistry = context.modelRegistry
        let loaded = options.loadConfig?(context) ?? loadMcpConfig(
            agentDir: options.agentDir, cwd: URL(fileURLWithPath: context.cwd, isDirectory: true),
            projectTrusted: context.isProjectTrusted())
        configErrors = loaded.errors
        projectConfig = loaded.projectConfig
        configuredEntries = loaded.servers
        autoEnableCodemode = loaded.autoEnableCodemode ?? true
        warnedUnreachable = false
        waitedForStartup = false
        startupComplete = false
        sessionCwd = URL(fileURLWithPath: context.cwd, isDirectory: true)
        generation += 1
        sessionActive = true
        let registered = registeredServers()
        overridden = registered.overridden
        servers = [:]
        serverNames = []
        serverMessages = [:]
        for entry in configuredEntries {
            if servers[entry.name] == nil { serverNames.append(entry.name) }
            servers[entry.name] = BuiltinMcpServer(entry: entry)
        }
        for server in registered.servers {
            serverNames.append(server.entry.name)
            servers[server.entry.name] = server
        }
        changed()
        let current = generation
        await ensureDiscoveryActive(context)
        guard generation == current, sessionActive else { return }
        startup = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            await self.connectEnabled(context: context, generation: current)
        }
    }

    private func registeredServers() -> (servers: [BuiltinMcpServer], overridden: [String]) {
        var result: [BuiltinMcpServer] = []
        var notices: [String] = []
        for registered in api.getMcpServers() {
            if let configured = configuredEntries.first(where: { mcpNamespace($0.name) == mcpNamespace(registered.name) }) {
                notices.append("\"\(registered.name)\" registered by \(registered.extensionPath) is overridden by \"\(configured.name)\" in \(configured.source)")
            } else {
                result.append(BuiltinMcpServer(entry: McpServerEntry(name: registered.name, config: registered.config,
                    source: registered.extensionPath, scope: .extension), registeredConfig: registered.config))
            }
        }
        return (result, notices)
    }

    private func makeConnection(_ entry: McpServerEntry) -> McpServerConnection {
        McpServerConnection(entry: entry, cwd: sessionCwd, createTransport: options.createTransport,
            credentials: credentials, log: log, clientMetadataDocumentURL: options.clientMetadataDocumentURL, providerToken: { [registry = modelRegistry] provider in
                await registry?.getApiKeyForProvider(provider)
            }, onTools: { [weak self] connection in
                await self?.registerTools(connection)
            }, onChange: { [weak self] connection in
                await self?.connectionChanged(connection)
            })
    }

    private func changed() {
        for continuation in menuChanges.values { continuation.yield(()) }
    }

    private func stopMenuChanges(_ id: UUID) {
        menuChanges.removeValue(forKey: id)?.finish()
    }

    private func liveMenu(_ ui: any McpUi,
                          build: @escaping @Sendable () async -> McpMenu) async -> String? {
        let id = UUID()
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopMenuChanges(id) }
        }
        menuChanges[id] = continuation
        defer { stopMenuChanges(id) }
        return await ui.menu(build: build, changes: changes)
    }

    private func finishWork(_ id: UUID) { work.removeValue(forKey: id) }

    private func trackAction(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            await operation()
            self.finishWork(id)
        }
        work[id] = .action(task)
        return task
    }

    private func isCurrent(_ name: String, attempt: UUID, generation current: Int) -> Bool {
        sessionActive && generation == current && servers[name]?.attempt == attempt
    }

    private func startConnection(_ name: String) -> Task<Void, Never> {
        let attempt = UUID()
        let current = generation
        let closing = servers[name]?.closing
        servers[name]?.attempt = attempt
        servers[name]?.readyComplete = false
        serverMessages.removeValue(forKey: name)
        let task = trackAction { [weak self] in
            await closing?.value
            await self?.openServer(name, attempt: attempt, generation: current)
        }
        servers[name]?.readyTask = task
        changed()
        return task
    }

    private func openServer(_ name: String, attempt: UUID, generation current: Int) async {
        guard isCurrent(name, attempt: attempt, generation: current),
              let server = servers[name], server.entry.config.isEnabled else { return }
        let connection = makeConnection(server.entry)
        servers[name]?.connection = connection
        servers[name]?.closing = nil
        changed()
        _ = try? await connection.connect()
        connectionReady(connection, attempt: attempt, generation: current)
    }

    private func connectEnabled(context: HookContext, generation current: Int) async {
        guard generation == current, sessionActive else { return }
        let tasks = orderedServers.filter { $0.entry.config.isEnabled }.map { startConnection($0.entry.name) }
        for task in tasks { await task.value }
        guard generation == current, sessionActive else { return }
        startupComplete = true
        await ensureDiscoveryActive(context)
        guard generation == current, sessionActive else { return }
        await reportProblems(context)
    }

    private func connectionReady(_ connection: McpServerConnection, attempt: UUID, generation current: Int) {
        guard isCurrent(connection.name, attempt: attempt, generation: current),
              servers[connection.name]?.connection === connection else { return }
        servers[connection.name]?.readyComplete = true
        changed()
    }

    private func reconnect(_ name: String) -> Task<Void, Never>? {
        guard let server = servers[name], server.entry.config.isEnabled,
              let connection = server.connection else { return nil }
        let previous = server.readyTask
        let attempt = UUID()
        let current = generation
        servers[name]?.attempt = attempt
        servers[name]?.readyComplete = false
        serverMessages.removeValue(forKey: name)
        let task = trackAction { [weak self] in
            await previous?.value
            await self?.reconnectServer(connection, attempt: attempt, generation: current)
        }
        servers[name]?.readyTask = task
        changed()
        return task
    }

    private func reconnectServer(_ connection: McpServerConnection, attempt: UUID, generation current: Int) async {
        guard isCurrent(connection.name, attempt: attempt, generation: current) else { return }
        // Connection state and error report failures, including required sign-ins.
        _ = try? await connection.reconnect()
        guard isCurrent(connection.name, attempt: attempt, generation: current) else { return }
        serverMessages.removeValue(forKey: connection.name)
        connectionReady(connection, attempt: attempt, generation: current)
        await ensureDiscoveryActive()
    }

    private func reconnectFailure(_ connection: McpServerConnection) async -> String? {
        if await connection.state == .needsAuth {
            let command = connection.entry.config.auth.map { "/login \($0.provider)" } ?? "/mcp"
            return "MCP server \"\(connection.name)\" requires sign-in. Run \(command) to sign in."
        }
        if let error = await connection.error {
            return "MCP server \"\(connection.name)\" failed to connect: \(error)"
        }
        return nil
    }

    private func connectionChanged(_ connection: McpServerConnection) async {
        let name = connection.name
        guard sessionActive, let server = servers[name], server.entry.config.isEnabled,
              let current = server.connection, current === connection else { return }
        let state = await connection.state
        let url = await connection.oauthURL
        guard isCurrent(name, attempt: server.attempt, generation: generation),
              servers[name]?.connection === connection else { return }
        if state == .needsAuth, let url, tokensAtSignIn[name] == nil {
            tokensAtSignIn[name] = storedTokens(name: name, url: url)
        } else if state != .needsAuth {
            tokensAtSignIn.removeValue(forKey: name)
        }
        changed()
    }

    private func storedTokens(name: String, url: URL) -> String {
        guard let token = try? credentials.tokens(name: name, url: url),
              let data = try? JSONEncoder().encode(token) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private func registerTools(_ connection: McpServerConnection) async {
        let name = connection.name
        guard sessionActive, let server = servers[name], server.entry.config.isEnabled,
              server.connection === connection else { return }
        let tools = await connection.tools
        let instructions = await connection.instructions
        guard sessionActive, servers[name]?.connection === connection,
              servers[name]?.entry.config.isEnabled == true else { return }
        let description = server.entry.config.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = ToolNamespace(name: mcpNamespace(name),
            description: description?.isEmpty == false ? description : nil, instructions: instructions)
        let plain = Set(tools.map(\.name)).map { createMcpToolName(server: name, tool: $0) }
        let collisions = Dictionary(grouping: plain, by: { $0 }).filter { $0.value.count > 1 }
        let previous = serverTools[name] ?? []
        var current: Set<String> = []
        for tool in tools {
            let owner = "\(name)\u{0}\(tool.name)"
            let toolName = createMcpToolName(server: name, tool: tool.name) { candidate in
                (toolOwners[candidate] != nil && toolOwners[candidate] != owner) || current.contains(candidate) || collisions[candidate] != nil
            }
            toolOwners[toolName] = owner
            current.insert(toolName)
            let definition = createMcpToolDefinition(server: name, tool: tool, name: toolName,
                exposure: getMcpToolExposure(server.entry.config, toolName: tool.name), namespace: namespace,
                timeoutMs: connection.timeoutMs, getClient: { [weak self] in
                    guard let self else { throw McpRuntimeError.connectionFailed("MCP server \"\(name)\" is disabled.") }
                    return try await self.currentConnection(name, tool: tool.name)
                },
                readableResources: { [weak self] in await self?.hasVisibleResources(name) ?? false })
            definitions[toolName] = definition
            _ = api.registerTool(definition)
        }
        serverTools[name] = current
        for withdrawn in previous.subtracting(current) {
            if var definition = definitions[withdrawn] {
                definition.exposure = .hidden
                _ = api.registerTool(definition)
            }
        }
        await syncResourceTools()
        changed()
    }

    private func currentConnection(_ name: String, tool: String) async throws -> McpServerConnection {
        while true {
            guard let server = servers[name], server.entry.config.isEnabled else {
                throw McpRuntimeError.connectionFailed("MCP server \"\(name)\" is disabled.")
            }
            guard let connection = server.connection else {
                throw McpRuntimeError.connectionFailed("MCP server \"\(name)\" is still starting.")
            }
            let state = await connection.state
            let tools = await connection.tools
            guard servers[name]?.attempt == server.attempt,
                  servers[name]?.connection === connection else { continue }
            guard let config = servers[name]?.entry.config else { continue }
            if getMcpToolExposure(config, toolName: tool) == .hidden ||
                (state == .connected && !tools.contains { $0.name == tool }) {
                throw McpRuntimeError.connectionFailed("MCP tool \"\(name)/\(tool)\" is no longer available.")
            }
            return connection
        }
    }

    private func hideTools(_ name: String) async {
        for tool in serverTools[name] ?? [] {
            if var definition = definitions[tool] {
                definition.exposure = .hidden
                _ = api.registerTool(definition)
            }
        }
        serverTools[name] = []
        await syncResourceTools()
    }

    private func hasVisibleResources(_ name: String) async -> Bool {
        guard let server = servers[name], server.entry.config.isEnabled,
              server.entry.config.effectiveExposure != .hidden,
              let connection = server.connection else { return false }
        return await connection.hasResources
    }

    private func resourceServers() async -> [McpServerConnection] {
        var result: [McpServerConnection] = []
        for server in orderedServers {
            if await hasVisibleResources(server.entry.name), let connection = server.connection { result.append(connection) }
        }
        return result
    }

    private func syncResourceTools() async {
        var exposures: Set<McpExposure> = []
        for server in orderedServers where await hasVisibleResources(server.entry.name) {
            exposures.insert(server.entry.config.effectiveExposure)
        }
        let next = [McpExposure.direct, .codemode, .deferred].first(where: exposures.contains) ?? .hidden
        if next == resourceExposure || (resourceExposure == nil && next == .hidden) { return }
        let wasDirect = resourceExposure == .direct
        resourceExposure = next
        let definitions = createMcpResourceToolDefinitions(exposure: next, servers: { [weak self] in
            await self?.resourceServers() ?? []
        })
        for definition in definitions { _ = api.registerTool(definition) }
        if wasDirect {
            let names = Set(definitions.map(\.name))
            api.setActiveTools(api.getActiveTools().filter { !names.contains($0) })
        }
    }

    private func ensureDiscoveryActive(_ context: HookContext? = nil) async {
        var exposure: Set<McpExposure> = []
        for server in orderedServers where server.entry.config.isEnabled {
            exposure.formUnion(configuredMcpExposures(server.entry))
        }
        let needsCodemode = exposure.contains(.codemode)
        let needsSearch = exposure.contains(.deferred)
        guard needsCodemode || needsSearch else { return }
        let all = api.getAllTools()
        let hasCodemode = all.contains(where: isCodemodeTool)
        let hasSearch = all.contains(where: isToolSearchTool)
        var active = api.getActiveTools()
        if needsCodemode && hasCodemode && autoEnableCodemode && !active.contains(CODEMODE_TOOL_NAME) {
            active.append(CODEMODE_TOOL_NAME)
        }
        if needsSearch && hasSearch && !active.contains(TOOL_SEARCH_TOOL_NAME) {
            active.append(TOOL_SEARCH_TOOL_NAME)
        }
        api.setActiveTools(active)
        if !(hasCodemode && active.contains(CODEMODE_TOOL_NAME)) && !(hasSearch && active.contains(TOOL_SEARCH_TOOL_NAME)) && !warnedUnreachable {
            warnedUnreachable = true
            if let context { await context.ui.notify(
                "MCP tools are only reachable from the codemode or tool_search tool, but neither is active\(needsCodemode && hasCodemode && !autoEnableCodemode ? " (autoEnableCodemode is false)" : ""); they cannot be called.", .warning) }
        }
    }

    private func hasPendingServers(names: Set<String>?) -> Bool {
        orderedServers.contains {
            $0.entry.config.isEnabled && !$0.readyComplete && (names == nil || names!.contains($0.entry.name))
        }
    }

    /// Wait until the selected servers finish connection and tool registration.
    /// A failed connection also completes readiness. Cancellation ends only this wait.
    public func waitForServers(names: [String]? = nil, signal: CancellationToken? = nil) async throws {
        let selected = names.map(Set.init)
        let current = generation
        while current == generation && hasPendingServers(names: selected) {
            if signal?.isCancelled == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func waitForFirstPrompt(context: HookContext) async {
        guard startup != nil, !waitedForStartup else { return }
        waitedForStartup = true
        let direct = Set(orderedServers.filter {
            $0.entry.config.isEnabled && configuredMcpExposures($0.entry).contains(.direct)
        }.map { $0.entry.name })
        guard !direct.isEmpty else { return }
        let deadline = ContinuousClock.now + .milliseconds(max(0, options.startupWaitMs))
        while hasPendingServers(names: direct) && ContinuousClock.now < deadline {
            if context.signal?.isCancelled == true || Task.isCancelled { return }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        if hasPendingServers(names: direct) {
            await context.ui.notify("MCP servers are still connecting; their tools become available once connected.", .info)
        }
    }

    public func serversSection() async -> String? {
        var listings: [McpServerListing] = []
        for server in orderedServers {
            listings.append(McpServerListing(entry: server.entry, instructions: await server.connection?.instructions))
        }
        return renderServersSection(listings)
    }

    public func toolCall(event: ToolCallEvent, context: HookContext) async throws {
        if let owner = toolOwners[event.toolName]?.split(separator: "\0").first {
            try await waitForServers(names: [String(owner)], signal: context.signal)
            return
        }
        guard let tool = api.getAllTools().first(where: { $0.name == event.toolName }) else { return }
        let names: [String]
        if isCodemodeTool(tool) {
            let source = event.input["code"]?.value as? String ?? ""
            names = orderedServers.filter { mcpScriptNeedsServer(source, server: $0.entry.name) }.map { $0.entry.name }
        } else if isToolSearchTool(tool) || [LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL].contains(tool.name) {
            names = serverNames
        } else { return }
        try await waitForServers(names: names, signal: context.signal)
    }

    public func turnStart(context: HookContext) async {
        for (name, oldToken) in tokensAtSignIn {
            guard let connection = servers[name]?.connection, let url = await connection.oauthURL,
                  storedTokens(name: name, url: url) != oldToken else { continue }
            tokensAtSignIn.removeValue(forKey: name)
            await reconnect(name)?.value
        }
        await ensureDiscoveryActive(context)
    }

    public func registrationsChanged(context: HookContext) async {
        let current = generation
        guard sessionActive else { return }
        let registered = registeredServers()
        overridden = registered.overridden
        let next = Dictionary(uniqueKeysWithValues: registered.servers.map { ($0.entry.name, $0) })
        let removed = orderedServers.filter { server in
            server.entry.scope == .extension && next[server.entry.name]?.registeredConfig != server.registeredConfig
        }
        for server in removed {
            guard sessionActive, generation == current else { return }
            servers.removeValue(forKey: server.entry.name)
            serverNames.removeAll { $0 == server.entry.name }
            serverMessages.removeValue(forKey: server.entry.name)
            await hideTools(server.entry.name)
            await withTaskGroup(of: Void.self) { group in
                if let connection = server.connection { group.addTask { await connection.close() } }
                if let ready = server.readyTask { group.addTask { await ready.value } }
                if let closing = server.closing { group.addTask { await closing.value } }
            }
        }
        guard sessionActive, generation == current else { return }
        var added: [String] = []
        var tasks: [Task<Void, Never>] = []
        for server in registered.servers where servers[server.entry.name] == nil {
            serverNames.append(server.entry.name)
            servers[server.entry.name] = server
            if server.entry.config.isEnabled {
                added.append(server.entry.name)
                tasks.append(startConnection(server.entry.name))
            }
        }
        changed()
        await ensureDiscoveryActive(context)
        for task in tasks { await task.value }
        guard generation == current, sessionActive else { return }
        await ensureDiscoveryActive(context)
        guard generation == current, sessionActive else { return }
        await reportProblems(context, only: Set(added))
    }

    public func shutdown() async {
        sessionActive = false
        generation += 1
        startupComplete = true
        let starting = startup
        starting?.cancel()
        let pending = Array(work.values)
        for item in pending { item.cancelSignIn() }
        let connections = orderedServers.compactMap(\.connection)
        servers = [:]
        serverNames = []
        serverMessages = [:]
        changed()
        await withTaskGroup(of: Void.self) { group in
            for connection in connections { group.addTask { await connection.close() } }
            for item in pending { group.addTask { await item.wait() } }
        }
        await starting?.value
    }

    private func reportProblems(_ context: HookContext, only: Set<String>? = nil) async {
        let current = generation
        guard sessionActive else { return }
        var lines = only == nil ? configErrors.map { "config: \($0)" } : []
        for server in orderedServers where only == nil || only!.contains(server.entry.name) {
            guard let connection = server.connection else { continue }
            let state = await connection.state
            if state == .needsAuth || state == .failed {
                lines.append("\(server.entry.name): \(await describeState(server))")
            }
        }
        if !lines.isEmpty, generation == current, sessionActive {
            await context.ui.notify("MCP servers need attention:\n\(lines.map { "  \($0)" }.joined(separator: "\n"))\nRun /mcp to fix.", .warning)
        }
    }

    private func describeState(_ server: BuiltinMcpServer, withError: Bool = true) async -> String {
        guard server.entry.config.isEnabled else { return "disabled" }
        guard let connection = server.connection else { return "starting" }
        switch await connection.state {
        case .needsAuth: return "needs sign-in"
        case .failed: return !withError ? "failed" : "failed: \((await connection.error ?? "unknown error").components(separatedBy: "\n").first ?? "unknown error")"
        case .connected:
            let tools = await connection.tools.count
            let resources = await connection.resources.count
            return "connected · \(tools) tool\(tools == 1 ? "" : "s")\(resources > 0 ? " · \(resources) resource\(resources == 1 ? "" : "s")" : "")"
        case .connecting: return "connecting…"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        }
    }

    public func menu() async -> McpMenu {
        var ranked: [(rank: Int, server: BuiltinMcpServer)] = []
        for server in orderedServers {
            let rank: Int
            if !server.entry.config.isEnabled { rank = 5 }
            else {
                switch await server.connection?.state {
                case .needsAuth: rank = 0
                case .failed: rank = 1
                case .disconnected: rank = 2
                case .connected: rank = 4
                default: rank = 3
                }
            }
            ranked.append((rank, server))
        }
        let sorted = ranked.sorted { $0.rank == $1.rank
            ? $0.server.entry.name.compare($1.server.entry.name, locale: .current) == .orderedAscending : $0.rank < $1.rank }.map(\.server)
        var items: [McpMenuItem] = []
        for server in sorted {
            items.append(McpMenuItem(value: server.entry.name, label: server.entry.name,
                detail: "\(await describeState(server)) · \(server.entry.config.effectiveExposure.rawValue) · \(server.entry.override == nil ? server.entry.scope.rawValue : "global, project override")"))
        }
        let notices = configErrors.map { "config: \($0)" } + overridden.map { "overridden: \($0)" }
        return McpMenu(title: "MCP servers", error: notices.isEmpty ? nil : notices.joined(separator: "\n"),
            items: items, empty: "No MCP servers configured. Add them to \(options.agentDir.appendingPathComponent("mcp.json").path) or .pi/mcp.json.",
            confirmLabel: "manage", cancelLabel: "close")
    }

    public func status() async -> String {
        var lines: [String] = []
        for server in orderedServers {
            let name = server.entry.name
            let exposure = server.entry.config.effectiveExposure.rawValue
            let connection = server.connection
            let state = await connection?.state
            if state == .needsAuth {
                lines.append("\(name): needs sign-in, run /mcp login \(name) (\(exposure))")
                continue
            }
            let tools = state == .connected ? ", \(await connection?.tools.count ?? 0) tools" : ""
            let description = !server.entry.config.isEnabled ? "disabled" : state == .disconnected
                ? "disconnected, reconnects on next call" : state?.rawValue ?? "starting"
            let failure = state != .connected ? await connection?.error : nil
            let error = failure.map { "\n    " + $0.components(separatedBy: "\n").joined(separator: "\n    ") } ?? ""
            lines.append("\(name): \(description)\(tools) (\(exposure))\(error)")
        }
        lines += configErrors.map { "config error: \($0)" }
        lines += overridden.map { "overridden: \($0)" }
        if lines.isEmpty {
            return "No MCP servers configured. Add them to \(options.agentDir.appendingPathComponent("mcp.json").path) or .pi/mcp.json."
        }
        return lines.joined(separator: "\n")
    }

    private func choose(_ name: String?, context: HookCommandContext,
                        eligible: (BuiltinMcpServer) -> Bool,
                        preferred: (BuiltinMcpServer) async -> Bool, none: String) async -> BuiltinMcpServer? {
        if let name {
            guard let server = servers[name] else {
                await context.ui.notify("No MCP server named \"\(name)\".", .error)
                return nil
            }
            guard eligible(server) else { await context.ui.notify(none, .error); return nil }
            return server
        }
        let choices = orderedServers.filter(eligible)
        guard !choices.isEmpty else { await context.ui.notify(none, .info); return nil }
        if choices.count == 1 { return choices[0] }
        var favored: [BuiltinMcpServer] = []
        for choice in choices where await preferred(choice) { favored.append(choice) }
        if favored.count == 1 { return favored[0] }
        guard let selected = await context.ui.select("MCP server", choices.map { $0.entry.name }) else { return nil }
        return choices.first { $0.entry.name == selected }
    }

    private func usesOAuth(_ server: BuiltinMcpServer) -> Bool {
        server.connection != nil && server.entry.config.isHTTP && server.entry.config.auth == nil &&
            !(server.entry.config.headers ?? [:]).keys.contains {
                $0.caseInsensitiveCompare("authorization") == .orderedSame
            }
    }

    public func command(_ args: String, context: HookCommandContext) async {
        let current = generation
        let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty, context.mode == .tui, let ui = options.ui {
            await runManager(ui)
            return
        }
        while !startupComplete {
            guard sessionActive, generation == current, !Task.isCancelled else { return }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        guard sessionActive, generation == current, !Task.isCancelled else { return }
        guard parts.count <= 2 else { await context.ui.notify("Usage: /mcp, /mcp login [server], /mcp logout [server], /mcp reconnect [server]", .warning); return }
        guard let action = parts.first else {
            if context.mode == .tui, let ui = options.ui {
                await runManager(ui)
            } else {
                await context.ui.notify(await status(), .info)
            }
            return
        }
        let name = parts.count > 1 ? parts[1] : nil
        switch action {
        case "login":
            guard let server = await choose(name, context: context, eligible: usesOAuth,
                preferred: { await $0.connection?.state == .needsAuth },
                none: "No enabled MCP server uses OAuth. Only HTTP servers without an Authorization header do."),
                let connection = server.connection, await connection.oauthURL != nil else { return }
            guard context.hasUI else {
                await context.ui.notify("Signing in to MCP server \"\(server.entry.name)\" requires interactive mode.", .error)
                return
            }
            let failure = await trackedSignIn(server: server,
                ui: context.mode == .tui ? options.ui : nil, commandContext: context)
            guard sessionActive, generation == current, servers[server.entry.name]?.connection === connection else { return }
            if let failure {
                await context.ui.notify(failure, failure == "Sign-in cancelled." ? .info : .error)
                return
            }
            await ensureDiscoveryActive()
            guard sessionActive, generation == current else { return }
            await context.ui.notify("Signed in to MCP server \"\(server.entry.name)\" (\(await connection.tools.count) tools).", .info)
        case "logout":
            guard let server = await choose(name, context: context, eligible: usesOAuth,
                preferred: { await $0.connection?.state == .needsAuth }, none: "No enabled MCP server uses OAuth."),
                let connection = server.connection, let url = await connection.oauthURL else { return }
            let removed = (try? credentials.remove(name: server.entry.name, url: url)) ?? false
            await connection.signOut()
            guard sessionActive, generation == current else { return }
            await context.ui.notify(removed ? "Signed out of MCP server \"\(server.entry.name)\"." :
                "No stored credentials for MCP server \"\(server.entry.name)\".", .info)
        case "reconnect":
            guard let server = await choose(name, context: context, eligible: { $0.connection != nil },
                preferred: { server in
                    guard let connection = server.connection else { return false }
                    let state = await connection.state
                    return state == .failed || state == .disconnected
                },
                none: "No enabled MCP server to reconnect."), let connection = server.connection else { return }
            do {
                await reconnect(server.entry.name)?.value
                guard sessionActive, generation == current else { return }
                if let error = await reconnectFailure(connection) { throw McpRuntimeError.connectionFailed(error) }
                await ensureDiscoveryActive()
                guard sessionActive, generation == current else { return }
                await context.ui.notify("Reconnected to MCP server \"\(server.entry.name)\" (\(await describeState(server))).", .info)
            } catch {
                guard sessionActive, generation == current else { return }
                await context.ui.notify(error.localizedDescription, .error)
            }
        default:
            await context.ui.notify("Usage: /mcp, /mcp login [server], /mcp logout [server], /mcp reconnect [server]", .warning)
        }
    }

    public func runManager(_ ui: any McpUi) async {
        let current = generation
        while let choice = await liveMenu(ui, build: { await self.menu() }) {
            while let action = await liveMenu(ui, build: { await self.serverMenu(choice) }) {
                guard sessionActive, generation == current, let server = servers[choice] else { break }
                var message: String?
                switch action {
                case "enable", "disable", "enable-project", "disable-project":
                    message = await setEnabled(choice, enabled: action.hasPrefix("enable"), inProject: action.hasSuffix("-project"))
                    if message == nil {
                        await ensureDiscoveryActive()
                        guard sessionActive, generation == current else { return }
                        continue
                    }
                case "reconnect":
                    _ = reconnect(choice)
                    await ensureDiscoveryActive()
                    guard sessionActive, generation == current else { return }
                    continue
                case "signout":
                    if let connection = server.connection, let url = await connection.oauthURL {
                        do { _ = try credentials.remove(name: server.entry.name, url: url); await connection.signOut() }
                        catch { message = error.localizedDescription }
                    }
                case "signin":
                    message = await signInForManager(server: server, ui: ui)
                case "tools":
                    _ = await ui.menu(toolsMenu(server))
                case "exposure":
                    let choice = await ui.menu(exposureMenu(server))
                    if let choice, let exposure = McpExposure(rawValue: choice), exposure != server.entry.config.effectiveExposure {
                        message = await setExposure(server.entry.name, exposure: exposure)
                    }
                default: break
                }
                guard sessionActive, generation == current, let latest = servers[choice],
                      latest.connection === server.connection else { return }
                if let message { serverMessages[server.entry.name] = message }
                else { serverMessages.removeValue(forKey: server.entry.name) }
                await ensureDiscoveryActive()
                changed()
            }
            guard sessionActive, generation == current else { return }
        }
    }

    private func signInForManager(server: BuiltinMcpServer, ui: any McpUi) async -> String? {
        await trackedSignIn(server: server, ui: ui, commandContext: nil)
    }

    private func trackedSignIn(server: BuiltinMcpServer, ui: (any McpUi)?,
                               commandContext: HookCommandContext?) async -> String? {
        guard sessionActive else { return "Sign-in cancelled." }
        let id = UUID()
        let current = generation
        let onCancel: @MainActor @Sendable () -> Void = { [weak self] in
            Task { await self?.cancelSignIn(id) }
        }
        let task = Task {
            let message = await self.performSignIn(server: server, ui: ui, commandContext: commandContext,
                onCancel: onCancel, generation: current)
            self.finishWork(id)
            return message
        }
        work[id] = .signIn(task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func cancelSignIn(_ id: UUID) { work[id]?.cancelSignIn() }

    private func performSignIn(server: BuiltinMcpServer, ui: (any McpUi)?,
                               commandContext: HookCommandContext?,
                               onCancel: @escaping @MainActor @Sendable () -> Void,
                               generation current: Int) async -> String? {
        guard let connection = server.connection, let url = await connection.oauthURL else {
            return "MCP server \"\(server.entry.name)\" does not use OAuth."
        }
        let title = "Sign in to \(server.entry.name)"
        do {
            try Task.checkCancellation()
            guard isCurrent(server.entry.name, attempt: server.attempt, generation: current) else { throw CancellationError() }
            if let ui { await ui.status(title: title, message: "Contacting the authorization server…", onCancel: onCancel) }
            let presenter: any McpSignInPresenter
            if let host = options.presenter {
                if let ui { presenter = McpManagerPresenter(base: host, ui: ui, title: title, onCancel: onCancel) }
                else { presenter = host }
            } else {
                #if os(macOS)
                let activeURL = LockedState<URL?>(nil)
                let loopback = try makeMcpMacOSSignInPresenter(settings: server.entry.config.oauth ?? .init(),
                    pasteRedirectURL: {
                        if let ui {
                            guard let authorizationURL = activeURL.withLock({ $0 }) else { return "" }
                            let value = await ui.redirectURL(title: title, authorizationURL: authorizationURL)
                            try Task.checkCancellation()
                            await ui.status(title: title, message: "Connecting…", onCancel: onCancel)
                            guard let value else { throw CancellationError() }
                            return value.absoluteString
                        }
                        guard let context = commandContext,
                              let value = await context.ui.input("Waiting for sign-in to \"\(server.entry.name)\". If the browser cannot reach this machine, paste the URL it was redirected to.", "http://127.0.0.1:.../callback?code=...") else {
                            throw CancellationError()
                        }
                        return value
                    }, openAuthorizationURL: { authorizationURL in
                        activeURL.withLock { $0 = authorizationURL }
                        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
                        if !opened { throw McpOAuthError.invalidRedirect }
                    })
                if let ui { presenter = McpManagerPresenter(base: loopback, ui: ui, title: title, onCancel: onCancel) }
                else { presenter = loopback }
                #else
                return "MCP sign-in needs a host presenter on iOS."
                #endif
            }
            let prompt: any McpSignInPresenter
            if ui == nil, let context = commandContext {
                prompt = McpCommandPresenter(base: presenter, notify: { [weak self] authorizationURL in
                    guard await self?.isCurrent(server.entry.name, attempt: server.attempt, generation: current) == true else { return }
                    await context.ui.notify("Sign in to MCP server \"\(server.entry.name)\" in your browser:\n\(authorizationURL.absoluteString)", .info)
                })
            } else { prompt = presenter }
            try await signInMcpServer(name: server.entry.name, serverURL: url, credentials: credentials,
                settings: try connection.oauthSettings(), challenge: await connection.challenge,
                presenter: prompt, clientMetadataDocumentURL: options.clientMetadataDocumentURL)
            try Task.checkCancellation()
            guard isCurrent(server.entry.name, attempt: server.attempt, generation: current),
                  servers[server.entry.name]?.connection === connection else { return "Sign-in cancelled." }
            await connection.clearOAuthChallenge()
            let ready = reconnect(server.entry.name)
            let reconnectAttempt = servers[server.entry.name]?.attempt
            await ready?.value
            guard sessionActive, generation == current,
                  servers[server.entry.name]?.attempt == reconnectAttempt,
                  servers[server.entry.name]?.connection === connection else { return "Sign-in cancelled." }
            if let error = await reconnectFailure(connection) { return "Signed in, but \(error)" }
            return nil
        } catch {
            if isMcpSignInCancellation(error) { return "Sign-in cancelled." }
            return "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func serverMenu(_ name: String) async -> McpMenu {
        guard let server = servers[name] else {
            return McpMenu(title: name, items: [], empty: "This server is no longer configured.",
                           confirmLabel: "", cancelLabel: "back")
        }
        let saved = server.entry.scope == .extension ? "for this session" :
            "saved to the \(server.entry.override == nil ? server.entry.scope.rawValue : "project") mcp.json"
        let inProject = server.entry.scope == .global && server.entry.override == nil && projectConfig != nil
        var items: [McpMenuItem] = []
        if server.entry.config.isEnabled {
            let state = await server.connection?.state
            if state == .needsAuth { items.append(McpMenuItem(value: "signin", label: "Sign in", detail: "opens the browser")) }
            if state == .connected {
                items.append(McpMenuItem(value: "tools", label: "Tools", detail: "\(await server.connection?.tools.count ?? 0) offered"))
            }
            if state == .connected || state == .failed || state == .disconnected || state == .needsAuth {
                items.append(McpMenuItem(value: "reconnect", label: "Reconnect"))
            }
            if state == .connected, await server.connection?.oauthURL != nil {
                items.append(McpMenuItem(value: "signout", label: "Sign out", detail: "deletes the stored credentials"))
            }
            items.append(McpMenuItem(value: "exposure", label: "Exposure", detail: server.entry.config.effectiveExposure.rawValue))
            items.append(McpMenuItem(value: "disable", label: "Disable", detail: saved))
            if inProject { items.append(McpMenuItem(value: "disable-project", label: "Disable in this project", detail: "saved to the project mcp.json")) }
        } else {
            items.append(McpMenuItem(value: "enable", label: "Enable", detail: saved))
            if inProject { items.append(McpMenuItem(value: "enable-project", label: "Enable in this project", detail: "saved to the project mcp.json")) }
        }
        let transport = server.entry.config.url ?? ([server.entry.config.command ?? ""] + (server.entry.config.args ?? [])).joined(separator: " ")
        let overrideDetail = server.entry.override.map { "\nproject override: \($0)" } ?? ""
        let details = "\(transport)\n\(server.entry.scope.rawValue): \(server.entry.source)\(overrideDetail)\nState: \(await describeState(server, withError: false))"
        let connectionError = await server.connection?.state == .connected ? nil : await server.connection?.error
        let error = [serverMessages[server.entry.name], connectionError].compactMap { $0 }.joined(separator: "\n")
        return McpMenu(title: "MCP server \(server.entry.name)", details: details,
                       error: error.isEmpty ? nil : error, items: items, selected: items.first?.value,
                       confirmLabel: "select", cancelLabel: "back")
    }

    private func toolsMenu(_ server: BuiltinMcpServer) async -> McpMenu {
        var items: [McpMenuItem] = []
        for tool in await server.connection?.tools ?? [] {
            let exposure = getMcpToolExposure(server.entry.config, toolName: tool.name)
            let summary = tool.description?.components(separatedBy: "\n").first ?? ""
            items.append(McpMenuItem(value: tool.name, label: tool.name,
                detail: exposure == server.entry.config.effectiveExposure ? summary : "[\(exposure.rawValue)] \(summary)"))
        }
        let exposure = server.entry.config.effectiveExposure
        let description = mcpExposureDescriptions.first { $0.0 == exposure }?.1 ?? "unreachable"
        let overrides = (server.entry.config.toolExposure?.isEmpty == false) ? "\nSome tools override it with toolExposure." : ""
        return McpMenu(title: "Tools of \(server.entry.name)", details: "Exposure \(exposure.rawValue): \(description)\(overrides)",
            items: items, empty: "The server offers no tools.", confirmLabel: "back", cancelLabel: "back")
    }

    private func exposureMenu(_ server: BuiltinMcpServer) -> McpMenu {
        let choices = mcpExposureDescriptions
        return McpMenu(title: "Exposure of \(server.entry.name)", details: server.entry.scope == .extension
            ? "Applies to this session; the server is registered by \(server.entry.source)."
            : "Saved to \(server.entry.override ?? server.entry.source).",
            items: choices.map { exposure, description in McpMenuItem(value: exposure.rawValue,
                label: "\(exposure == server.entry.config.effectiveExposure ? "✓ " : "  ")\(exposure.rawValue)", detail: description) },
            selected: server.entry.config.effectiveExposure.rawValue, confirmLabel: "save", cancelLabel: "back")
    }

    private func setEnabled(_ name: String, enabled: Bool, inProject: Bool = false) async -> String? {
        guard var server = servers[name] else { return "No MCP server named \"\(name)\"." }
        let override = inProject ? projectConfig : server.entry.override
        let path = override ?? server.entry.source
        if server.entry.scope != .extension {
            do { try updateMcpServerConfig(path: URL(fileURLWithPath: path), name: name,
                patch: McpServerConfigPatch(enabled: enabled), override: override != nil) }
            catch { return "Could not update \(path): \(error.localizedDescription)" }
        }
        server.entry.override = override
        server.entry.config.enabled = enabled
        serverMessages.removeValue(forKey: name)
        if enabled {
            servers[name] = server
            _ = startConnection(name)
        } else {
            let connection = server.connection
            let previous = server.readyTask
            let oldClosing = server.closing
            let attempt = UUID()
            let current = generation
            server.attempt = attempt
            server.connection = nil
            server.readyComplete = true
            servers[name] = server
            let closing = trackAction { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    if let connection { group.addTask { await connection.close() } }
                    if let previous { group.addTask { await previous.value } }
                    if let oldClosing { group.addTask { await oldClosing.value } }
                }
                await self?.closedServer(name, attempt: attempt, generation: current)
            }
            servers[name]?.closing = closing
            await hideTools(name)
            changed()
        }
        return nil
    }

    private func closedServer(_ name: String, attempt: UUID, generation current: Int) {
        guard isCurrent(name, attempt: attempt, generation: current) else { return }
        servers[name]?.closing = nil
        changed()
    }

    private func setExposure(_ name: String, exposure: McpExposure) async -> String? {
        guard var server = servers[name] else { return "No MCP server named \"\(name)\"." }
        let path = server.entry.override ?? server.entry.source
        if server.entry.scope != .extension {
            do { try updateMcpServerConfig(path: URL(fileURLWithPath: path), name: name,
                patch: McpServerConfigPatch(exposure: exposure), override: server.entry.override != nil) }
            catch { return "Could not update \(path): \(error.localizedDescription)" }
        }
        server.entry.config.exposure = exposure
        servers[name] = server
        changed()
        if let connection = server.connection { await registerTools(connection) }
        await syncResourceTools()
        let indirect = Set(api.getAllTools().filter { $0.exposure != .direct }.map(\.name))
        let names = serverTools[name] ?? []
        api.setActiveTools(api.getActiveTools().filter { !names.contains($0) || !indirect.contains($0) })
        return nil
    }
}

public func createMcpExtension(options: McpExtensionOptions = .init()) -> InlineExtension {
    InlineExtension(name: "mcp", builtin: true, replaceable: true) { api in
        api.registerToolRenderer { name, next in
            if let renderers = next() { return renderers }
            guard name.range(of: #"^mcp__(.+?)__(.+)$"#, options: .regularExpression) != nil else { return nil }
            let suffix = name.dropFirst(5)
            guard let separator = suffix.range(of: "__", range: suffix.index(after: suffix.startIndex)..<suffix.endIndex) else { return nil }
            return CustomToolRenderers(builtIn: .mcp(label: "\(suffix[..<separator.lowerBound])/\(suffix[separator.upperBound...])"))
        }
        let runtime = McpBuiltinRuntime(api: api, options: options)
        api.on("session_start") { (_: SessionStartEvent, context) in
            await runtime.start(context: context)
            return nil
        }
        api.on("before_agent_start") { (_: BeforeAgentStartEvent, context) in
            await runtime.waitForFirstPrompt(context: context)
            return BeforeAgentStartEventResult(sections: [MCP_SERVERS_SECTION: await runtime.serversSection()])
        }
        api.on("tool_call") { (event: ToolCallEvent, context) in
            try await runtime.toolCall(event: event, context: context)
            return nil
        }
        api.on("turn_start") { (_: TurnStartEvent, context) in
            await runtime.turnStart(context: context)
            return nil
        }
        api.on("mcp_servers_change") { (_: McpServersChangeEvent, context) in
            await runtime.registrationsChanged(context: context)
            return nil
        }
        api.on("session_shutdown") { (_: SessionShutdownEvent, _) in
            await runtime.shutdown()
            return nil
        }
        api.registerCommand("mcp", description: "Manage MCP servers: sign in, reconnect, enable or disable, and change exposure",
            sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user", origin: "top-level")) { args, context in
            await runtime.command(args, context: context)
        }
    }
}
