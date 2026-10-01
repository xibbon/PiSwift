import Foundation
import Testing
import PiSwiftAI
import PiSwiftMCP
import PiSwiftCodingAgent

private func c4cDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-c4c-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func c4cEventually(_ check: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

private actor C4cServer {
    let transport: InMemoryTransport
    private var loop: Task<Void, Never>?
    private var tools = ["read"]
    private var initializationAllowed: Bool
    private var initialization: JsonRpcRequest?
    private let logMessage: String?

    init(_ transport: InMemoryTransport, initializationAllowed: Bool = true, logMessage: String? = nil) {
        self.transport = transport
        self.initializationAllowed = initializationAllowed
        self.logMessage = logMessage
    }

    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.transport.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }

    func allowInitialization() async {
        initializationAllowed = true
        if let request = initialization {
            initialization = nil
            await reply(request)
        }
    }

    func setTools(_ names: [String]) async throws {
        tools = names
        try await transport.send(JsonRpc.encodeNotificationToLine(
            JsonRpcNotification(method: "notifications/tools/list_changed")))
    }

    func close() async { loop?.cancel(); await transport.close() }

    private func reply(_ request: JsonRpcRequest) async {
        let result: [String: Any]
        switch request.method {
        case "initialize":
            guard initializationAllowed else { initialization = request; return }
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "c4c", "version": "1"]]
        case "tools/list":
            if let logMessage {
                try? await transport.send(JsonRpc.encodeNotificationToLine(JsonRpcNotification(
                    method: "notifications/message", params: AnyCodable(["level": "info", "data": logMessage]))))
            }
            result = ["tools": tools.map { ["name": $0, "inputSchema": ["type": "object"]] }]
        default: result = [:]
        }
        try? await transport.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

/// The collector deliberately stays active after selection. The runtime must finish its stream.
@MainActor private final class C4cLiveUi: McpUi {
    struct Update: Sendable { var visit: Int; var menu: McpMenu }
    var updates: [Update] = []
    var finishedVisits: Set<Int> = []
    var visits = 0
    private var selection: CheckedContinuation<String?, Never>?

    func menu(_ menu: McpMenu) async -> String? {
        Issue.record("The manager must use the live menu API")
        return nil
    }

    func menu(build: @escaping @Sendable () async -> McpMenu, changes: AsyncStream<Void>?) async -> String? {
        visits += 1
        let visit = visits
        updates.append(Update(visit: visit, menu: await build()))
        if let changes {
            Task {
                for await _ in changes { updates.append(Update(visit: visit, menu: await build())) }
                finishedVisits.insert(visit)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { selection = $0 }
        } onCancel: {
            Task { @MainActor in self.select(nil) }
        }
    }

    func select(_ value: String?) { selection?.resume(returning: value); selection = nil }
    func status(title: String, message: String) {}
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c4cLiveMenusDeliverStateToolsConfigRegistrationsAndShutdown() async throws {
    let root = try c4cDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("mcp.json")
    let config = McpServerConfig(url: "http://127.0.0.1/mcp", headers: ["Authorization": "fixture"], timeout: 5)
    try addMcpServerConfig(path: path, name: "docs", config: config)
    let entry = McpServerEntry(name: "docs", config: config, source: path.path, scope: .global)
    let (client, server) = InMemoryTransport.pair()
    let fixture = C4cServer(server, initializationAllowed: false)
    await fixture.start()
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(agentDir: root,
        loadConfig: { _ in LoadedMcpConfig(servers: [entry]) }, createTransport: { _, _, _ in client }))
    let context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
                              model: nil, hasUI: false)
    let observer = C4cLiveUi()
    let observerTask = Task { await runtime.runManager(observer) }
    #expect(await c4cEventually { await observer.updates.count == 1 })
    await runtime.start(context: context)
    #expect(await c4cEventually {
        await observer.updates.contains { $0.menu.items.first?.detail?.contains("connecting") == true }
    })
    await fixture.allowInitialization()
    #expect(await c4cEventually {
        await observer.updates.last?.menu.items.first?.detail?.contains("connected · 1 tool") == true
    })
    try await fixture.setTools(["read", "search"])
    #expect(await c4cEventually {
        await observer.updates.last?.menu.items.first?.detail?.contains("connected · 2 tools") == true
    })
    #expect(observer.updates.filter { !$0.menu.items.isEmpty }.allSatisfy { $0.menu.items[0].id == "docs" })

    let manager = C4cLiveUi()
    let managerTask = Task { await runtime.runManager(manager) }
    #expect(await c4cEventually { await manager.updates.count == 1 })
    manager.select("docs")
    #expect(await c4cEventually { await manager.updates.last?.visit == 2 })
    try await fixture.setTools(["read", "search", "write"])
    #expect(await c4cEventually {
        await manager.updates.last?.menu.items.first(where: { $0.id == "tools" })?.detail == "3 offered"
    })
    manager.select("disable")
    #expect(await c4cEventually {
        await observer.updates.last?.menu.items.first?.detail?.contains("disabled") == true
    })
    #expect(loadMcpConfig(agentDir: root, cwd: root, projectTrusted: false).servers.first?.config.isEnabled == false)
    #expect(await c4cEventually { await manager.updates.last?.visit == 3 })
    #expect(manager.updates.last?.menu.items.map(\.id) == ["enable"])
    manager.select(nil)
    #expect(await c4cEventually { await manager.updates.last?.visit == 4 })
    manager.select(nil)
    await managerTask.value
    #expect(await c4cEventually { await manager.finishedVisits == [1, 2, 3, 4] })
    let stoppedCount = manager.updates.count

    try api.registerMcpServer("late", config: .init(command: "fixture", enabled: false))
    await runtime.registrationsChanged(context: context)
    #expect(await c4cEventually { await observer.updates.last?.menu.items.contains { $0.id == "late" } == true })
    api.unregisterMcpServer("late")
    await runtime.registrationsChanged(context: context)
    #expect(await c4cEventually { await observer.updates.last?.menu.items.map(\.id) == ["docs"] })
    await runtime.shutdown()
    #expect(await c4cEventually { await observer.updates.last?.menu.items.isEmpty == true })
    #expect(manager.updates.count == stoppedCount)
    observer.select(nil)
    await observerTask.value
    #expect(await c4cEventually { await observer.finishedVisits == [1] })
    await fixture.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c4cCancelledManagerStopsMenuUpdates() async throws {
    let root = try c4cDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = McpBuiltinRuntime(api: HookAPI(events: createEventBus(), hookPath: "builtin:mcp"),
        options: McpExtensionOptions(agentDir: root, loadConfig: { _ in LoadedMcpConfig() }))
    let ui = C4cLiveUi()
    let task = Task { await runtime.runManager(ui) }
    #expect(await c4cEventually { await ui.updates.count == 1 })
    task.cancel()
    await task.value
    #expect(await c4cEventually { await ui.finishedVisits == [1] })
    let context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
                              model: nil, hasUI: false)
    await runtime.start(context: context)
    await runtime.shutdown()
    #expect(ui.updates.count == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c4cServerMenuRebuildsWhenItsRegistrationIsRemoved() async throws {
    let root = try c4cDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    try api.registerMcpServer("gone", config: .init(command: "fixture", enabled: false))
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(agentDir: root,
        loadConfig: { _ in LoadedMcpConfig() }))
    let context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
                              model: nil, hasUI: false)
    await runtime.start(context: context)
    let ui = C4cLiveUi()
    let task = Task { await runtime.runManager(ui) }
    #expect(await c4cEventually { await ui.updates.count == 1 })
    ui.select("gone")
    #expect(await c4cEventually { await ui.updates.last?.visit == 2 })
    #expect(ui.updates.last?.menu.items.map(\.id) == ["enable"])
    api.unregisterMcpServer("gone")
    await runtime.registrationsChanged(context: context)
    #expect(await c4cEventually {
        await ui.updates.last?.menu.empty == "This server is no longer configured."
    })
    #expect(ui.updates.last?.menu.items.isEmpty == true)
    ui.select("enable")
    #expect(await c4cEventually { await ui.updates.last?.visit == 3 })
    #expect(ui.updates.last?.menu.items.isEmpty == true)
    ui.select(nil)
    await task.value
    #expect(await c4cEventually { await ui.finishedVisits == [1, 2, 3] })
    await runtime.shutdown()
}

@MainActor private final class C4cSnapshotUi: McpUi {
    var received: McpMenu?
    func menu(_ menu: McpMenu) async -> String? { received = menu; return "kept" }
    func status(title: String, message: String) {}
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

@Test(.timeLimit(.minutes(1))) @MainActor func c4cLiveMenuDefaultKeepsSnapshotHosts() async {
    let host: any McpUi = C4cSnapshotUi()
    let expected = McpMenu(title: "Snapshot", items: [], confirmLabel: "select", cancelLabel: "back")
    #expect(await host.menu(build: { expected }) == "kept")
    #expect((host as? C4cSnapshotUi)?.received == expected)
}

private func c4cConnection(secret: String?, name: String = "secret") -> McpServerConnection {
    McpServerConnection(entry: McpServerEntry(name: name, config: .init(url: "https://example.invalid/mcp",
        oauth: McpOAuthConfig(clientId: "client", clientSecret: secret, scope: "read")), source: "fixture", scope: .global),
        cwd: FileManager.default.temporaryDirectory, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
}

@Test func c4cPublicOAuthSettingsExpandSecretsAndKeepErrors() throws {
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    let settings = try c4cConnection(secret: "${HOME}/$HOME/$$/$!/${INVALID-NAME}").oauthSettings()
    #expect(settings.clientSecret == "\(home)/\(home)/$/!/${INVALID-NAME}")
    #expect(settings.clientId == "client")
    #expect(settings.scope == "read")
    #expect(try c4cConnection(secret: nil).oauthSettings().clientSecret == nil)
    do {
        _ = try c4cConnection(secret: "${PI_MCP_C4C_MISSING_SECRET}").oauthSettings()
        Issue.record("A missing environment variable must fail")
    } catch McpRuntimeError.invalidConfig(let text) {
        #expect(text == "MCP server \"secret\" oauth.clientSecret: environment variable PI_MCP_C4C_MISSING_SECRET is not set")
    }
}

@Test func c4cPublicOAuthSettingsCacheCommandSuccessAndFailure() throws {
    let root = try c4cDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let success = root.appendingPathComponent("success")
    let command = "!printf 'run\\n' >> \(quote(success.path)); printf 'resolved\\n'"
    #expect(try c4cConnection(secret: command).oauthSettings().clientSecret == "resolved")
    #expect(try c4cConnection(secret: command, name: "other").oauthSettings().clientSecret == "resolved")
    #expect(try String(contentsOf: success, encoding: .utf8) == "run\n")
    let failure = root.appendingPathComponent("failure")
    let failedCommand = "!printf 'run\\n' >> \(quote(failure.path)); exit 1"
    for _ in 0..<2 {
        do {
            _ = try c4cConnection(secret: failedCommand).oauthSettings()
            Issue.record("A command with no value must fail")
        } catch McpRuntimeError.invalidConfig(let text) {
            #expect(text == "MCP server \"secret\" oauth.clientSecret: command returned no value")
        }
    }
    #expect(try String(contentsOf: failure, encoding: .utf8) == "run\n")
}

@Test(.timeLimit(.minutes(1))) func c4cListReportConnectionsWriteServerLog() async throws {
    let root = try c4cDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (firstClient, firstServer) = InMemoryTransport.pair()
    let (secondClient, secondServer) = InMemoryTransport.pair()
    let first = C4cServer(firstServer, logMessage: "first log event")
    let second = C4cServer(secondServer, logMessage: "second log event")
    await first.start(); await second.start()
    let entries = ["first", "second", "disabled"].map { name in
        McpServerEntry(name: name, config: .init(command: "fixture", enabled: name != "disabled"),
                       source: "fixture", scope: .global)
    }
    let requests = LockedState<[String]>([])
    let path = root.appendingPathComponent("mcp.log")
    let report = await inspectMcpServers(LoadedMcpConfig(servers: entries), cwd: root,
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), log: McpServerLog(path: path),
        createTransport: { entry, _, _ in
            requests.withLock { $0.append(entry.name) }
            return entry.name == "first" ? firstClient : secondClient
        })
    #expect(!report.failed)
    #expect(report.servers.map(\.state) == ["connected", "connected", "disabled"])
    #expect(Set(requests.withLock { $0 }) == ["first", "second"])
    let text = try String(contentsOf: path, encoding: .utf8)
    #expect(text.contains("[first] info first log event"))
    #expect(text.contains("[second] info second log event"))
    await first.close(); await second.close()
}

private actor C4cChallengeTransport: McpTransport {
    let auth: any McpAuthProvider
    let url: URL
    init(auth: any McpAuthProvider, url: URL) { self.auth = auth; self.url = url }
    func start() async throws {
        try await auth.onUnauthorized(challenge: "Bearer error=\"insufficient_scope\", scope=\"read write\"",
                                      serverURL: url, rejectedToken: nil)
    }
    func send(_ data: Data) async throws { throw McpError.transportClosed }
    func receive() async throws -> Data { throw McpError.transportClosed }
    func close() async {}
}

@Test(.timeLimit(.minutes(1))) func c4cConnectionClearsOAuthChallengeBeforeReconnect() async throws {
    let url = URL(string: "https://example.invalid/mcp")!
    let changes = LockedState(0)
    let connection = McpServerConnection(entry: McpServerEntry(name: "auth", config: .init(url: url.absoluteString),
        source: "fixture", scope: .global), cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, auth in
            guard let auth else { throw McpRuntimeError.invalidConfig("Missing auth provider") }
            return C4cChallengeTransport(auth: auth, url: url)
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()),
        onChange: { _ in changes.withLock { $0 += 1 } })
    try? await connection.connect()
    #expect(await connection.state == .needsAuth)
    #expect(await connection.challenge?.scope == "read write")
    let previous = changes.withLock { $0 }
    await connection.clearOAuthChallenge()
    #expect(await connection.challenge == nil)
    #expect(changes.withLock { $0 } == previous + 1)
    // A new authorization failure must be able to supply a new challenge.
    try? await connection.reconnect()
    #expect(await connection.challenge?.scope == "read write")
    await connection.close()
}
