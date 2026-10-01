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
    public var startupWaitMs: Int

    public init(agentDir: URL = URL(fileURLWithPath: getAgentDir()),
                loadConfig: (@Sendable (HookContext) -> LoadedMcpConfig)? = nil,
                createTransport: @escaping McpTransportFactory = createDefaultMcpTransport,
                credentials: McpOAuthCredentialStore? = nil, logPath: URL? = nil,
                presenter: (any McpSignInPresenter)? = nil, ui: (any McpUi)? = nil,
                startupWaitMs: Int = 10_000) {
        self.agentDir = agentDir; self.loadConfig = loadConfig; self.createTransport = createTransport
        self.credentials = credentials; self.logPath = logPath; self.presenter = presenter; self.ui = ui
        self.startupWaitMs = startupWaitMs
    }
}

private let mcpExposureDescriptions: [(McpExposure, String)] = [
    (.codemode, "called from codemode scripts, listed in the codemode description"),
    (.codemodeDeferred, "called from codemode scripts, not listed; scripts find them with searchTools()"),
    (.deferred, "not declared until tool_search loads them, then called directly; no codemode needed"),
    (.direct, "declared to the model like built-in tools"),
]

private struct McpManagerPresenter: McpSignInPresenter {
    let base: any McpSignInPresenter
    let ui: any McpUi
    let title: String

    func redirectURL(for state: String) async throws -> URL { try await base.redirectURL(for: state) }

    func present(authorizationURL: URL, state: String) async throws -> URL {
        do {
            let result = try await base.present(authorizationURL: authorizationURL, state: state)
            await ui.status(title: title, message: "Connecting…")
            return result
        } catch is CancellationError {
            await ui.status(title: title, message: "Connecting…")
            throw CancellationError()
        }
    }

    func cancel() async { await base.cancel() }
}

private struct BuiltinMcpServer: Sendable {
    var entry: McpServerEntry
    var connection: McpServerConnection?
    var registeredConfig: McpServerConfig?
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
    private var overridden: [String] = []
    private var startup: Task<Void, Never>?
    private var startupComplete = true
    private var waitedForStartup = false
    private var sessionActive = false
    private var generation = 0
    private var sessionCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    private var autoEnableCodemode = true
    private var warnedUnreachable = false
    private var serverTools: [String: Set<String>] = [:]
    private var toolOwners: [String: String] = [:]
    private var definitions: [String: CustomTool] = [:]
    private var resourceExposure: McpExposure?
    private var tokensAtSignIn: [String: String] = [:]
    private var serverMessages: [String: String] = [:]
    private var menuChanges: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(api: HookAPI, options: McpExtensionOptions) {
        self.api = api; self.options = options
        self.credentials = options.credentials ?? McpOAuthCredentialStore(agentDir: options.agentDir)
        self.log = McpServerLog(path: options.logPath ?? options.agentDir.appendingPathComponent("mcp.log"))
    }

    public func start(context: HookContext) {
        let loaded = options.loadConfig?(context) ?? loadMcpConfig(
            agentDir: options.agentDir, cwd: URL(fileURLWithPath: context.cwd, isDirectory: true),
            projectTrusted: context.isProjectTrusted())
        configErrors = loaded.errors
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
            if let configured = configuredEntries.first(where: { $0.name == registered.name }) {
                notices.append("\"\(registered.name)\" registered by \(registered.extensionPath) is overridden by \(configured.source)")
            } else {
                result.append(BuiltinMcpServer(entry: McpServerEntry(name: registered.name, config: registered.config,
                    source: registered.extensionPath, scope: .extension), registeredConfig: registered.config))
            }
        }
        return (result, notices)
    }

    private func makeConnection(_ entry: McpServerEntry) -> McpServerConnection {
        McpServerConnection(entry: entry, cwd: sessionCwd, createTransport: options.createTransport,
            credentials: credentials, log: log, onTools: { [weak self] connection in
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

    private func connectEnabled(context: HookContext, generation current: Int) async {
        let names = orderedServers.filter { $0.entry.config.isEnabled }.map { $0.entry.name }
        let connections = names.compactMap { name -> McpServerConnection? in
            guard let server = servers[name] else { return nil }
            let connection = makeConnection(server.entry)
            servers[name]?.connection = connection
            changed()
            return connection
        }
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { _ = try? await connection.connect() }
            }
        }
        guard generation == current else { return }
        startupComplete = true
        await ensureDiscoveryActive(context)
        await reportProblems(context)
    }

    private func connectionChanged(_ connection: McpServerConnection) async {
        let name = connection.name
        guard let current = servers[name]?.connection, current === connection else { return }
        if await connection.state == .needsAuth, let url = await connection.oauthURL,
           tokensAtSignIn[name] == nil {
            tokensAtSignIn[name] = storedTokens(url)
        } else if await connection.state != .needsAuth {
            tokensAtSignIn.removeValue(forKey: name)
        }
        changed()
    }

    private func storedTokens(_ url: URL) -> String {
        guard let token = try? credentials.tokens(for: url),
              let data = try? JSONEncoder().encode(token) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private func registerTools(_ connection: McpServerConnection) async {
        let name = connection.name
        guard let server = servers[name], server.connection === connection else { return }
        let tools = await connection.tools
        let instructions = await connection.instructions
        let namespaceName = "mcp__\(name)"
        let namespace = ToolNamespace(name: namespaceName,
            description: instructions ?? "Tools in the \(namespaceName) namespace.")
        let previous = serverTools[name] ?? []
        var current: Set<String> = []
        for tool in tools {
            let owner = "\(name)\u{0}\(tool.name)"
            let toolName = createMcpToolName(server: name, tool: tool.name) { candidate in
                (toolOwners[candidate] != nil && toolOwners[candidate] != owner) || current.contains(candidate)
            }
            toolOwners[toolName] = owner
            current.insert(toolName)
            let definition = createMcpToolDefinition(server: name, tool: tool, name: toolName,
                exposure: getMcpToolExposure(server.entry.config, toolName: tool.name), namespace: namespace,
                timeoutMs: connection.timeoutMs, getClient: { connection },
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
        let next = [McpExposure.direct, .codemode, .codemodeDeferred, .deferred].first(where: exposures.contains) ?? .hidden
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
            guard let connection = server.connection, await connection.state == .connected else { continue }
            for toolName in serverTools[server.entry.name] ?? [] {
                if let owner = toolOwners[toolName], let rawName = owner.split(separator: "\u{0}").last {
                    exposure.insert(getMcpToolExposure(server.entry.config, toolName: String(rawName)))
                }
            }
            if await connection.hasResources { exposure.insert(server.entry.config.effectiveExposure) }
        }
        let needsCodemode = exposure.contains(.codemode) || exposure.contains(.codemodeDeferred)
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
        if !active.contains(CODEMODE_TOOL_NAME) && !active.contains(TOOL_SEARCH_TOOL_NAME) && !warnedUnreachable {
            warnedUnreachable = true
            if let context { await context.ui.notify(
                "MCP tools are only reachable from the codemode or tool_search tool, but neither is active; they cannot be called.", .warning) }
        }
    }

    public func waitForFirstPrompt(context: HookContext) async {
        guard startup != nil, !waitedForStartup else { return }
        waitedForStartup = true
        let deadline = ContinuousClock.now + .milliseconds(max(0, options.startupWaitMs))
        while !startupComplete && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if !startupComplete {
            await context.ui.notify("MCP servers are still connecting; their tools become available once connected.", .info)
        }
    }

    public func turnStart(context: HookContext) async {
        for (name, oldToken) in tokensAtSignIn {
            guard let connection = servers[name]?.connection, let url = await connection.oauthURL,
                  storedTokens(url) != oldToken else { continue }
            tokensAtSignIn.removeValue(forKey: name)
            _ = try? await connection.reconnect()
        }
        await ensureDiscoveryActive(context)
    }

    public func registrationsChanged(context: HookContext) async {
        guard sessionActive else { return }
        let registered = registeredServers()
        overridden = registered.overridden
        let next = Dictionary(uniqueKeysWithValues: registered.servers.map { ($0.entry.name, $0) })
        let removed = orderedServers.filter { server in
            server.entry.scope == .extension && next[server.entry.name]?.registeredConfig != server.registeredConfig
        }
        for server in removed {
            servers.removeValue(forKey: server.entry.name)
            serverNames.removeAll { $0 == server.entry.name }
            serverMessages.removeValue(forKey: server.entry.name)
            await hideTools(server.entry.name)
            await server.connection?.close()
        }
        var added: [McpServerConnection] = []
        for server in registered.servers where servers[server.entry.name] == nil {
            serverNames.append(server.entry.name)
            servers[server.entry.name] = server
            if server.entry.config.isEnabled {
                let connection = makeConnection(server.entry)
                servers[server.entry.name]?.connection = connection
                added.append(connection)
            }
        }
        changed()
        await withTaskGroup(of: Void.self) { group in
            for connection in added { group.addTask { _ = try? await connection.connect() } }
        }
        await ensureDiscoveryActive(context)
        await reportProblems(context, only: Set(added.map(\.name)))
    }

    public func shutdown() async {
        sessionActive = false
        generation += 1
        let connections = orderedServers.compactMap(\.connection)
        servers = [:]
        serverNames = []
        serverMessages = [:]
        changed()
        for connection in connections { await connection.close() }
    }

    private func reportProblems(_ context: HookContext, only: Set<String>? = nil) async {
        var lines = only == nil ? configErrors.map { "config: \($0)" } : []
        for server in orderedServers where only == nil || only!.contains(server.entry.name) {
            guard let connection = server.connection else { continue }
            let state = await connection.state
            if state == .needsAuth || state == .failed {
                lines.append("\(server.entry.name): \(await describeState(server))")
            }
        }
        if !lines.isEmpty {
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
                detail: "\(await describeState(server)) · \(server.entry.config.effectiveExposure.rawValue) · \(server.entry.scope.rawValue)"))
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
        server.connection != nil && server.entry.config.isHTTP &&
            !(server.entry.config.headers ?? [:]).keys.contains {
                $0.caseInsensitiveCompare("authorization") == .orderedSame
            }
    }

    public func command(_ args: String, context: HookCommandContext) async {
        while !startupComplete { try? await Task.sleep(for: .milliseconds(25)) }
        let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
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
                let connection = server.connection, let url = await connection.oauthURL else { return }
            guard context.hasUI else {
                await context.ui.notify("Signing in to MCP server \"\(server.entry.name)\" requires interactive mode.", .error)
                return
            }
            do {
                #if os(macOS)
                let presenter: any McpSignInPresenter
                if let host = options.presenter { presenter = host }
                else { presenter = try makeMcpMacOSSignInPresenter(settings: server.entry.config.oauth ?? .init(),
                    pasteRedirectURL: { [ui = context.ui] in
                        guard let value = await ui.input("Waiting for sign-in to \"\(server.entry.name)\". If the browser cannot reach this machine, paste the URL it was redirected to.", "http://127.0.0.1:.../callback?code=...") else { throw CancellationError() }
                        return value
                    }) }
                #else
                guard let presenter = options.presenter else { throw McpRuntimeError.invalidConfig("MCP sign-in needs a host presenter on iOS") }
                #endif
                try await signInMcpServer(serverURL: url, credentials: credentials,
                    settings: try connection.oauthSettings(),
                    challenge: await connection.challenge, presenter: presenter)
                await connection.clearOAuthChallenge()
                do { try await connection.reconnect() }
                catch {
                    await context.ui.notify("Signed in, but \(error.localizedDescription)", .error)
                    return
                }
                await ensureDiscoveryActive()
                await context.ui.notify("Signed in to MCP server \"\(server.entry.name)\" (\(await connection.tools.count) tools).", .info)
            } catch is CancellationError { await context.ui.notify("Sign-in cancelled.", .info) }
            catch { await context.ui.notify("Sign-in failed: \(error.localizedDescription)", .error) }
        case "logout":
            guard let server = await choose(name, context: context, eligible: usesOAuth,
                preferred: { await $0.connection?.state == .needsAuth }, none: "No enabled MCP server uses OAuth."),
                let connection = server.connection, let url = await connection.oauthURL else { return }
            let removed = (try? credentials.remove(url)) ?? false
            await connection.signOut()
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
                try await connection.reconnect()
                await ensureDiscoveryActive()
                await context.ui.notify("Reconnected to MCP server \"\(server.entry.name)\" (\(await describeState(server))).", .info)
            } catch { await context.ui.notify(error.localizedDescription, .error) }
        default:
            await context.ui.notify("Usage: /mcp, /mcp login [server], /mcp logout [server], /mcp reconnect [server]", .warning)
        }
    }

    public func runManager(_ ui: any McpUi) async {
        while let choice = await liveMenu(ui, build: { await self.menu() }) {
            while let action = await liveMenu(ui, build: { await self.serverMenu(choice) }) {
                guard let server = servers[choice] else { break }
                var message: String?
                switch action {
                case "enable", "disable":
                    await ui.status(title: "MCP server \(choice)", message: action == "enable" ? "Connecting…" : "Disconnecting…")
                    message = await setEnabled(choice, enabled: action == "enable")
                case "reconnect":
                    await ui.status(title: "MCP server \(choice)", message: "Reconnecting…")
                    if let connection = server.connection {
                        do { try await connection.reconnect() }
                        catch {}
                    }
                case "signout":
                    if let connection = server.connection, let url = await connection.oauthURL {
                        do { _ = try credentials.remove(url); await connection.signOut() }
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
                if let message { serverMessages[server.entry.name] = message }
                else { serverMessages.removeValue(forKey: server.entry.name) }
                await ensureDiscoveryActive()
                changed()
            }
        }
    }

    private func signInForManager(server: BuiltinMcpServer, ui: any McpUi) async -> String? {
        guard let connection = server.connection, let url = await connection.oauthURL else { return "MCP server \"\(server.entry.name)\" does not use OAuth." }
        let title = "Sign in to \(server.entry.name)"
        await ui.status(title: title, message: "Contacting the authorization server…")
        do {
            #if os(macOS)
            let activeURL = LockedState<URL?>(nil)
            let presenter: any McpSignInPresenter
            if let host = options.presenter { presenter = McpManagerPresenter(base: host, ui: ui, title: title) }
            else { presenter = try makeMcpMacOSSignInPresenter(settings: server.entry.config.oauth ?? .init(),
                pasteRedirectURL: {
                    guard let authorizationURL = activeURL.withLock({ $0 }) else { return "" }
                    let value = await ui.redirectURL(title: title, authorizationURL: authorizationURL)
                    await ui.status(title: title, message: "Connecting…")
                    guard let value else { throw CancellationError() }
                    return value.absoluteString
                }, openAuthorizationURL: { authorizationURL in
                    activeURL.withLock { $0 = authorizationURL }
                    let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
                    if !opened { throw McpOAuthError.invalidRedirect }
                }) }
            #else
            guard let host = options.presenter else { return "MCP sign-in needs a host presenter on iOS." }
            let presenter = McpManagerPresenter(base: host, ui: ui, title: title)
            #endif
            try await signInMcpServer(serverURL: url, credentials: credentials,
                settings: try connection.oauthSettings(),
                challenge: await connection.challenge, presenter: presenter)
            await connection.clearOAuthChallenge()
            do { try await connection.reconnect() }
            catch { return "Signed in, but \(error.localizedDescription)" }
            return nil
        } catch is CancellationError { return "Sign-in cancelled." }
        catch { return "Sign-in failed: \(error.localizedDescription)" }
    }

    private func serverMenu(_ name: String) async -> McpMenu {
        guard let server = servers[name] else {
            return McpMenu(title: name, items: [], empty: "This server is no longer configured.",
                           confirmLabel: "", cancelLabel: "back")
        }
        let saved = server.entry.scope == .extension ? "for this session" : "saved to the \(server.entry.scope.rawValue) mcp.json"
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
        } else { items.append(McpMenuItem(value: "enable", label: "Enable", detail: saved)) }
        let transport = server.entry.config.url ?? ([server.entry.config.command ?? ""] + (server.entry.config.args ?? [])).joined(separator: " ")
        let details = "\(transport)\n\(server.entry.scope.rawValue): \(server.entry.source)\nState: \(await describeState(server, withError: false))"
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
            : "Saved to \(server.entry.source).",
            items: choices.map { exposure, description in McpMenuItem(value: exposure.rawValue,
                label: "\(exposure == server.entry.config.effectiveExposure ? "✓ " : "  ")\(exposure.rawValue)", detail: description) },
            selected: server.entry.config.effectiveExposure.rawValue, confirmLabel: "save", cancelLabel: "back")
    }

    private func setEnabled(_ name: String, enabled: Bool) async -> String? {
        guard var server = servers[name] else { return "No MCP server named \"\(name)\"." }
        if server.entry.scope != .extension {
            do { try updateMcpServerConfig(path: URL(fileURLWithPath: server.entry.source), name: name,
                patch: McpServerConfigPatch(enabled: enabled)) }
            catch { return "Could not update \(server.entry.source): \(error.localizedDescription)" }
        }
        server.entry.config.enabled = enabled
        if enabled {
            let connection = makeConnection(server.entry)
            server.connection = connection
            servers[name] = server
            changed()
            _ = try? await connection.connect()
        } else {
            servers[name] = server
            await hideTools(name)
            await server.connection?.close()
            servers[name]?.connection = nil
            changed()
        }
        return nil
    }

    private func setExposure(_ name: String, exposure: McpExposure) async -> String? {
        guard var server = servers[name] else { return "No MCP server named \"\(name)\"." }
        if server.entry.scope != .extension {
            do { try updateMcpServerConfig(path: URL(fileURLWithPath: server.entry.source), name: name,
                patch: McpServerConfigPatch(exposure: exposure)) }
            catch { return "Could not update \(server.entry.source): \(error.localizedDescription)" }
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
        let runtime = McpBuiltinRuntime(api: api, options: options)
        api.on("session_start") { (_: SessionStartEvent, context) in
            await runtime.start(context: context)
            return nil
        }
        api.on("before_agent_start") { (_: BeforeAgentStartEvent, context) in
            await runtime.waitForFirstPrompt(context: context)
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
