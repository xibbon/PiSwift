import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
import PiSwiftCodingAgent

private actor C2CloseGate {
    private var released = false
    private(set) var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}

private actor C2Transport: McpTransport {
    let base: InMemoryTransport
    private let closeGate: C2CloseGate?
    private(set) var closeCompleted = false

    init(_ base: InMemoryTransport, closeGate: C2CloseGate? = nil) {
        self.base = base
        self.closeGate = closeGate
    }

    func start() async throws { try await base.start() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() async throws -> Data { try await base.receive() }
    func setProtocolVersion(_ version: String) async { await base.setProtocolVersion(version) }
    func close() async {
        await closeGate?.wait()
        await base.close()
        closeCompleted = true
    }
}

private actor C2Server {
    nonisolated let client: C2Transport
    private let server: InMemoryTransport
    private let text: String
    private var initializeAllowed: Bool
    private var pendingInitialize: JsonRpcRequest?
    private var tools = ["echo"]
    private var loop: Task<Void, Never>?
    private(set) var initializeReceived = false
    private(set) var callCount = 0

    init(text: String = "echo", initializeAllowed: Bool = true, closeGate: C2CloseGate? = nil) {
        let pair = InMemoryTransport.pair()
        client = C2Transport(pair.0, closeGate: closeGate)
        server = pair.1
        self.text = text
        self.initializeAllowed = initializeAllowed
    }

    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }

    func allowInitialize() async {
        initializeAllowed = true
        if let request = pendingInitialize {
            pendingInitialize = nil
            await reply(request)
        }
    }

    func removeTools() async throws {
        tools = []
        try await server.send(JsonRpc.encodeNotificationToLine(
            JsonRpcNotification(method: "notifications/tools/list_changed")))
    }

    func close() async {
        loop?.cancel()
        await server.close()
    }

    private func reply(_ request: JsonRpcRequest) async {
        let result: [String: Any]
        switch request.method {
        case "initialize":
            initializeReceived = true
            guard initializeAllowed else { pendingInitialize = request; return }
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "c2", "version": "1"]]
        case "tools/list":
            result = ["tools": tools.map { ["name": $0, "inputSchema": ["type": "object"]] }]
        case "tools/call":
            callCount += 1
            result = ["content": [["type": "text", "text": text]]]
        default: result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

@MainActor private final class C2LiveUi: McpUi {
    struct Update: Sendable { let visit: Int; let menu: McpMenu }
    private(set) var visits = 0
    private(set) var updates: [Update] = []
    private(set) var statuses: [String] = []
    private var selection: CheckedContinuation<String?, Never>?

    var latest: McpMenu? { updates.last?.menu }

    func menu(_ menu: McpMenu) async -> String? {
        Issue.record("Use the live manager menu.")
        return nil
    }

    func menu(build: @escaping @Sendable () async -> McpMenu, changes: AsyncStream<Void>?) async -> String? {
        let initial = await build()
        visits += 1
        let visit = visits
        updates.append(Update(visit: visit, menu: initial))
        let collector = Task {
            if let changes {
                for await _ in changes {
                    if Task.isCancelled { break }
                    let menu = await build()
                    if Task.isCancelled { break }
                    updates.append(Update(visit: visit, menu: menu))
                }
            }
        }
        defer { collector.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { selection = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.select(nil) }
        }
    }

    func select(_ value: String?) {
        let current = selection
        selection = nil
        current?.resume(returning: value)
    }
    func status(title: String, message: String) { statuses.append(message) }
    func redirectURL(title: String, authorizationURL: URL) async -> URL? { nil }
}

private func c2Eventually(_ check: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await check()
}

private func c2Root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-mcp-c2-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func c2Context() -> HookContext {
    HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
}

private func c2CommandContext() -> HookCommandContext {
    var context = HookRunner([], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:"))).createCommandContext()
    context.mode = .tui
    return context
}

private func c2ToolContext() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
                      isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
}

private func c2Runtime(root: URL, servers: [C2Server], enabled: Bool = true, ui: (any McpUi)? = nil)
    -> (runtime: McpBuiltinRuntime, api: HookAPI, supplied: LockedState<Int>) {
    let supplied = LockedState(0)
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    api.setGetAllToolsHandler {
        [ToolInfo(name: "mcp__docs__echo", description: "Echo",
                  sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user"), exposure: .direct)]
    }
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture", exposure: .direct,
        enabled: enabled, timeout: 30), source: "fixture", scope: .extension)
    let runtime = McpBuiltinRuntime(api: api, options: .init(agentDir: root,
        loadConfig: { _ in .init(servers: [entry]) }, createTransport: { _, _, _ in
            let index = supplied.withLock { count in
                let current = count
                count += 1
                return current
            }
            guard servers.indices.contains(index) else { throw McpRuntimeError.connectionFailed("No transport remains.") }
            return servers[index].client
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), ui: ui))
    return (runtime, api, supplied)
}

private func c2ExecuteError(_ tool: CustomTool) async -> String? {
    do {
        _ = try await tool.execute("error", [:], nil, c2ToolContext(), nil)
        Issue.record("The saved tool must return an error.")
        return nil
    } catch { return error.localizedDescription }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c2McpCommandOpensManagerWhileInitializeIsPending() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = C2Server(initializeAllowed: false)
    await server.start()
    let ui = C2LiveUi()
    let (runtime, _, _) = c2Runtime(root: root, servers: [server], ui: ui)
    await runtime.start(context: c2Context())
    #expect(await c2Eventually { await server.initializeReceived })
    let command = Task { await runtime.command("", context: c2CommandContext()) }
    #expect(await c2Eventually { await ui.visits == 1 })
    #expect(ui.latest?.items.first?.detail?.contains("connecting") == true)
    await server.allowInitialize()
    #expect(await c2Eventually { await ui.latest?.items.first?.detail?.contains("connected · 1 tool") == true })
    command.cancel()
    await command.value
    await runtime.shutdown()
    await server.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c2McpEnableReturnsToLiveMenuBeforeInitializeEnds() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = C2Server(initializeAllowed: false)
    await server.start()
    let (runtime, _, _) = c2Runtime(root: root, servers: [server], enabled: false)
    await runtime.start(context: c2Context())
    let ui = C2LiveUi()
    let manager = Task { await runtime.runManager(ui) }
    #expect(await c2Eventually { await ui.visits == 1 })
    ui.select("docs")
    #expect(await c2Eventually { await ui.visits == 2 })
    ui.select("enable")
    #expect(await c2Eventually { await ui.visits == 3 })
    #expect(await c2Eventually { await server.initializeReceived })
    #expect(await c2Eventually { await ui.latest?.details?.contains("State: connecting") == true })
    #expect(ui.latest?.items.contains { $0.id == "disable" } == true)
    #expect(ui.latest?.items.contains { $0.id == "tools" } == false)
    await server.allowInitialize()
    #expect(await c2Eventually { await ui.latest?.items.first(where: { $0.id == "tools" })?.detail == "1 offered" })
    #expect(ui.visits == 3)
    manager.cancel()
    await manager.value
    await runtime.shutdown()
    await server.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c2McpDisableThenEnableWaitsForOldCloseAndUsesNewClient() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = C2CloseGate()
    let first = C2Server(text: "first", closeGate: gate)
    let second = C2Server(text: "second")
    await first.start()
    await second.start()
    let (runtime, api, supplied) = c2Runtime(root: root, servers: [first, second])
    await runtime.start(context: c2Context())
    try await runtime.waitForServers()
    let saved = try #require(api.tools["mcp__docs__echo"])
    let ui = C2LiveUi()
    let manager = Task { await runtime.runManager(ui) }
    #expect(await c2Eventually { await ui.visits == 1 })
    ui.select("docs")
    #expect(await c2Eventually { await ui.visits == 2 })
    ui.select("disable")
    #expect(await c2Eventually { await gate.entered })
    #expect(await c2Eventually { await ui.visits == 3 })
    #expect(ui.latest?.items.map(\.id) == ["enable"])
    #expect(await c2ExecuteError(saved) == "MCP server \"docs\" is disabled.")
    ui.select("enable")
    #expect(await c2Eventually { await ui.visits == 4 })
    #expect(ui.latest?.details?.contains("State: starting") == true)
    #expect(await c2ExecuteError(saved) == "MCP server \"docs\" is still starting.")
    #expect(supplied.withLock { $0 } == 1)
    #expect(await second.initializeReceived == false)
    await gate.release()
    #expect(await c2Eventually { await second.initializeReceived })
    #expect(await c2Eventually { await ui.latest?.items.first(where: { $0.id == "tools" })?.detail == "1 offered" })
    #expect(await first.client.closeCompleted)
    #expect(supplied.withLock { $0 } == 2)
    let result = try await saved.execute("saved", [:], nil, c2ToolContext(), nil)
    if case .text(let text) = result.content.first { #expect(text.text == "second") }
    else { Issue.record("The new client must return text.") }
    #expect(await first.callCount == 0)
    #expect(await second.callCount == 1)
    manager.cancel()
    await manager.value
    await runtime.shutdown()
    await first.close()
    await second.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c2McpReconnectReturnsToMenuAndDirectCallWaitsForOldClose() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = C2CloseGate()
    let first = C2Server(closeGate: gate)
    let second = C2Server(initializeAllowed: false)
    await first.start()
    await second.start()
    let (runtime, _, supplied) = c2Runtime(root: root, servers: [first, second])
    await runtime.start(context: c2Context())
    try await runtime.waitForServers()
    let ui = C2LiveUi()
    let manager = Task { await runtime.runManager(ui) }
    #expect(await c2Eventually { await ui.visits == 1 })
    ui.select("docs")
    #expect(await c2Eventually { await ui.visits == 2 })
    ui.select("reconnect")
    #expect(await c2Eventually { await gate.entered })
    #expect(await c2Eventually { await ui.visits == 3 })
    let finished = LockedState(false)
    let call = Task {
        try await runtime.toolCall(event: .init(toolName: "mcp__docs__echo", toolCallId: "direct", input: [:]), context: c2Context())
        finished.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!finished.withLock { $0 })
    #expect(supplied.withLock { $0 } == 1)
    await gate.release()
    #expect(await c2Eventually { await second.initializeReceived })
    #expect(!finished.withLock { $0 })
    #expect(await c2Eventually { await ui.latest?.details?.contains("State: connecting") == true })
    await second.allowInitialize()
    #expect(await c2Eventually { finished.withLock { $0 } })
    try await call.value
    #expect(await c2Eventually { await ui.latest?.items.first(where: { $0.id == "tools" })?.detail == "1 offered" })
    #expect(ui.visits == 3)
    manager.cancel()
    await manager.value
    await runtime.shutdown()
    await first.close()
    await second.close()
}

@Test(.timeLimit(.minutes(1)))
func c2McpSavedToolRejectsRemovedTool() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = C2Server()
    await server.start()
    let (runtime, api, _) = c2Runtime(root: root, servers: [server])
    await runtime.start(context: c2Context())
    try await runtime.waitForServers()
    let saved = try #require(api.tools["mcp__docs__echo"])
    try await server.removeTools()
    #expect(await c2Eventually { api.tools["mcp__docs__echo"]?.exposure == .hidden })
    #expect(await c2ExecuteError(saved) == "MCP tool \"docs/echo\" is no longer available.")
    #expect(await server.callCount == 0)
    await runtime.shutdown()
    await server.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["login docs", "logout docs", "reconnect docs"])
func c2McpCancelledSubcommandStopsStartupWait(_ args: String) async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = C2Server(initializeAllowed: false)
    await server.start()
    let (runtime, _, _) = c2Runtime(root: root, servers: [server])
    await runtime.start(context: c2Context())
    #expect(await c2Eventually { await server.initializeReceived })
    let completed = LockedState(false)
    let command = Task {
        await runtime.command(args, context: c2CommandContext())
        completed.withLock { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!completed.withLock { $0 })
    let started = ContinuousClock.now
    command.cancel()
    #expect(await c2Eventually { completed.withLock { $0 } })
    #expect(started.duration(to: .now) < .milliseconds(500))
    // Release initialize after the cancellation check so a failed test can end.
    await server.allowInitialize()
    await command.value
    await runtime.shutdown()
    await server.close()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func c2McpShutdownWaitsForOverlappingReconnectDisableAndEnable() async throws {
    let root = try c2Root()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = C2CloseGate()
    let first = C2Server(closeGate: gate)
    let second = C2Server()
    await first.start()
    await second.start()
    let (runtime, api, supplied) = c2Runtime(root: root, servers: [first, second])
    await runtime.start(context: c2Context())
    try await runtime.waitForServers()
    let saved = try #require(api.tools["mcp__docs__echo"])
    let ui = C2LiveUi()
    let manager = Task { await runtime.runManager(ui) }
    #expect(await c2Eventually { await ui.visits == 1 })
    ui.select("docs")
    #expect(await c2Eventually { await ui.visits == 2 })
    ui.select("reconnect")
    #expect(await c2Eventually { await gate.entered })
    #expect(await c2Eventually { await ui.visits == 3 })
    ui.select("disable")
    #expect(await c2Eventually { await ui.visits == 4 })
    #expect(ui.latest?.items.map(\.id) == ["enable"])
    #expect(api.tools["mcp__docs__echo"]?.exposure == .hidden)
    ui.select("enable")
    #expect(await c2Eventually { await ui.visits == 5 })
    #expect(ui.latest?.details?.contains("State: starting") == true)
    #expect(supplied.withLock { $0 } == 1)
    #expect(await second.initializeReceived == false)

    let stopped = LockedState(false)
    let shutdown = Task {
        await runtime.shutdown()
        stopped.withLock { $0 = true }
    }
    #expect(await c2Eventually { await ui.latest?.empty == "This server is no longer configured." })
    #expect(ui.latest?.items.isEmpty == true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!stopped.withLock { $0 })
    #expect(await c2ExecuteError(saved) == "MCP server \"docs\" is disabled.")
    await gate.release()
    await shutdown.value
    #expect(stopped.withLock { $0 })
    #expect(await first.client.closeCompleted)
    #expect(supplied.withLock { $0 } == 1)
    #expect(await second.initializeReceived == false)
    #expect(api.tools["mcp__docs__echo"]?.exposure == .hidden)
    #expect(await runtime.menu().items.isEmpty)
    #expect(ui.visits == 5)
    manager.cancel()
    await manager.value
    await first.close()
    await second.close()
}
