import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

// Port of v1.0.0 suite/agent-session-mcp.test.ts, resume and reload additions.
private actor C3PendingMcpServer {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private let gate: LockedState<Bool>
    private var loop: Task<Void, Never>?

    init(gate: LockedState<Bool>) {
        (client, server) = InMemoryTransport.pair()
        self.gate = gate
    }

    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let incoming = try? JsonRpc.decodeIncoming(data),
                      case .request(let request) = incoming else { continue }
                await self.reply(request)
            }
        }
    }

    private func reply(_ request: JsonRpcRequest) async {
        if request.method == "initialize" {
            while !gate.withLock({ $0 }) {
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
            }
        }
        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "docs", "version": "1"]]
        case "tools/list":
            result = ["tools": [["name": "search", "description": "Search documentation.",
                                  "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]]]]]
        case "tools/call":
            result = ["content": [["type": "text", "text": "documentation result"]]]
        case "resources/list": result = ["resources": []]
        case "resources/templates/list": result = ["resourceTemplates": []]
        default: result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }

    func close() async { loop?.cancel(); await server.close() }
}

private struct C3PendingMcpPool: Sendable {
    let gate: LockedState<Bool>
    let directory: URL
    let servers = LockedState<[C3PendingMcpServer]>([])
    let connected = LockedState<[String]>([])

    init(ready: Bool = true) throws {
        gate = LockedState(ready)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("c3-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func transport(_ entry: McpServerEntry) -> any McpTransport {
        let fixture = C3PendingMcpServer(gate: gate)
        servers.withLock { $0.append(fixture) }
        connected.withLock { $0.append(entry.name) }
        Task { await fixture.start() }
        return fixture.client
    }

    func close() async {
        gate.withLock { $0 = true }
        for fixture in servers.withLock({ $0 }) { await fixture.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func c3PendingEventually(_ check: @Sendable () -> Bool) async throws -> Bool {
    for _ in 0..<600 {
        if check() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return check()
}

private func c3PendingResponse(_ model: Model, tool: String? = nil) -> AssistantMessageEventStream {
    let reason: StopReason = tool == nil ? .stop : .toolUse
    let content: [ContentBlock] = tool.map {
        [.toolCall(ToolCall(id: UUID().uuidString, name: $0, arguments: ["query": AnyCodable("documentation")]))]
    } ?? [.text(TextContent(text: "done"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: reason)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: reason, message: message)); stream.end(message)
    return stream
}

private func c3PendingSession(_ pool: C3PendingMcpPool, manager: SessionManager? = nil,
                              extensions: [InlineExtension] = [], configuredServer: Bool = true,
                              toolNames: [String]? = nil) async throws -> AgentSession {
    let entry = McpServerEntry(name: "docs", config: McpServerConfig(url: "http://127.0.0.1/mcp",
        exposure: .deferred, timeout: 3), source: "test", scope: .extension)
    let mcp = createMcpExtension(options: McpExtensionOptions(agentDir: pool.directory,
        loadConfig: { _ in LoadedMcpConfig(servers: configuredServer ? [entry] : [], autoEnableCodemode: false) },
        createTransport: { entry, _, _ in pool.transport(entry) },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())))
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let tools = ["base", "extra"].map { name in
        CustomToolDefinition(tool: CustomTool(name: name, label: name, description: name,
            execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: name == "base"))
    }
    // C1 U3: SDK tool-list validation now throws.
    let created = try await createAgentSession(CreateAgentSessionOptions(cwd: pool.directory.path,
        agentDir: pool.directory.path, authStorage: auth, model: model, offline: true,
        toolNames: toolNames, noTools: .builtin,
        customTools: tools, resourceLoader: TestResourceLoader(),
        inlineExtensions: extensions + [createToolSearchExtension(), mcp],
        sessionManager: manager ?? .inMemory(pool.directory.path), settingsManager: .inMemory()))
    let session = created.session
    session.agent.streamFn = { model, _, _ in c3PendingResponse(model) }
    let runner = try #require(session.hookRunner)
    _ = await runner.emit(SessionStartEvent())
    return session
}

private func c3PendingLoadDocs(_ session: AgentSession) async throws {
    #expect(try await c3PendingEventually { session.getAllTools().contains { $0.name == "mcp__docs__search" } })
    let turn = LockedState(0)
    session.agent.streamFn = { model, _, _ in
        let index = turn.withLock { $0 += 1; return $0 }
        return c3PendingResponse(model, tool: index == 1 ? TOOL_SEARCH_TOOL_NAME : nil)
    }
    try await session.prompt("load documentation")
    #expect(session.getActiveToolNames().contains("mcp__docs__search"))
    session.agent.streamFn = { model, _, _ in c3PendingResponse(model) }
}

private func c3PendingRemovals(_ session: AgentSession) -> [String] {
    session.sessionManager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
        .flatMap { $0.toolsRemoved?.map(\.name) ?? [] }
}

@Suite("C3 MCP loaded tools after resume and reload")
struct C3McpPendingTests {
    @Test(.timeLimit(.minutes(1)))
    func branchWithoutSystemMessageClearsPreviousPendingNames() async throws {
        let pool = try C3PendingMcpPool(ready: false)
        let manager = SessionManager.inMemory(pool.directory.path)
        manager.appendModelChange("openai", "gpt-4o-mini")
        let root = try #require(manager.getLeafId())
        manager.appendMessage(.system(SystemMessage(content: .text("previous branch"),
            toolsAdded: [AITool(name: "mcp__docs__search", description: "Search documentation.", parameters: [:])])))
        let session = try await c3PendingSession(pool, manager: manager)
        defer { session.dispose() }
        #expect(!session.getAllTools().contains { $0.name == "mcp__docs__search" })
        let navigation = await session.navigateTree(root, summarize: false)
        #expect(!navigation.cancelled)
        #expect(getCurrentSystemMessage(manager.buildSessionProjection().messages) == nil)
        pool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { session.getAllTools().contains { $0.name == "mcp__docs__search" } })
        #expect(!session.getActiveToolNames().contains("mcp__docs__search"))
        _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await pool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitInitialToolNamesPermitDiscoveryAndRestoreLoadedTool() async throws {
        // The non-empty allowlist keeps unnamed MCP tools. tool_search can activate deferred MCP tools.
        let firstPool = try C3PendingMcpPool()
        let first = try await c3PendingSession(firstPool, toolNames: [TOOL_SEARCH_TOOL_NAME])
        defer { first.dispose() }
        #expect(first.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME])
        try await c3PendingLoadDocs(first)
        let secondPool = try C3PendingMcpPool(ready: false)
        let second = try await c3PendingSession(secondPool, manager: first.sessionManager,
            toolNames: [TOOL_SEARCH_TOOL_NAME])
        defer { second.dispose() }
        secondPool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { second.getActiveToolNames().contains("mcp__docs__search") })
        try await second.prompt("use the restored explicit loadout")
        #expect(c3PendingRemovals(second).isEmpty)
        _ = await second.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        _ = await first.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await secondPool.close(); await firstPool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resumedLoadedToolActivatesWhenServerConnects() async throws {
        let firstPool = try C3PendingMcpPool()
        let first = try await c3PendingSession(firstPool)
        defer { first.dispose() }
        try await c3PendingLoadDocs(first)
        let secondPool = try C3PendingMcpPool(ready: false)
        let second = try await c3PendingSession(secondPool, manager: first.sessionManager)
        defer { second.dispose() }
        #expect(!second.getAllTools().contains { $0.name == "mcp__docs__search" })
        secondPool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { second.getActiveToolNames().contains("mcp__docs__search") })
        let turn = LockedState(0)
        second.agent.streamFn = { model, _, _ in
            let index = turn.withLock { $0 += 1; return $0 }
            return c3PendingResponse(model, tool: index == 1 ? "mcp__docs__search" : nil)
        }
        try await second.prompt("use the restored tool")
        #expect(c3PendingRemovals(second).isEmpty)
        let results = second.sessionManager.buildSessionProjection().messages.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message, result.toolName == "mcp__docs__search" { return result }
            return nil
        }
        #expect(results.last?.content.contains { if case .text(let text) = $0 { text.text == "documentation result" } else { false } } == true)
        _ = await second.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        _ = await first.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await secondPool.close(); await firstPool.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func loadoutRemovalClearsPendingButAddOnlyKeepsIt(addOnly: Bool) async throws {
        let firstPool = try C3PendingMcpPool()
        let first = try await c3PendingSession(firstPool)
        defer { first.dispose() }
        try await c3PendingLoadDocs(first)
        let change = InlineExtension(name: "loadout") { api in
            _ = api.on("session_start") { (_: SessionStartEvent, _: HookContext) -> Any? in
                api.setActiveTools(addOnly ? api.getActiveTools() + ["extra"] : ["base"])
                return nil
            }
        }
        let secondPool = try C3PendingMcpPool(ready: false)
        let second = try await c3PendingSession(secondPool, manager: first.sessionManager, extensions: [change])
        defer { second.dispose() }
        secondPool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { second.getAllTools().contains { $0.name == "mcp__docs__search" } })
        #expect(second.getActiveToolNames().contains("mcp__docs__search") == addOnly)
        _ = await second.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        _ = await first.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await secondPool.close(); await firstPool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func registrationAfterPromptDoesNotActivateAndAddsRemovalPatch() async throws {
        let firstPool = try C3PendingMcpPool()
        let first = try await c3PendingSession(firstPool)
        defer { first.dispose() }
        try await c3PendingLoadDocs(first)
        let secondPool = try C3PendingMcpPool(ready: false)
        let second = try await c3PendingSession(secondPool, manager: first.sessionManager)
        defer { second.dispose() }
        try await second.prompt("go before the server connects")
        #expect(c3PendingRemovals(second).contains("mcp__docs__search"))
        secondPool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { second.getAllTools().contains { $0.name == "mcp__docs__search" } })
        #expect(!second.getActiveToolNames().contains("mcp__docs__search"))
        _ = await second.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        _ = await first.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await secondPool.close(); await firstPool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func reloadKeepsToolSearchLoadedDeferredTool() async throws {
        let pool = try C3PendingMcpPool()
        let session = try await c3PendingSession(pool)
        defer { session.dispose() }
        try await c3PendingLoadDocs(session)
        pool.gate.withLock { $0 = false }
        await session.reload()
        let result = await session.reloadExtensions()
        #expect(result.errors.isEmpty)
        #expect(try await c3PendingEventually { pool.connected.withLock { $0 == ["docs", "docs"] } })
        pool.gate.withLock { $0 = true }
        #expect(try await c3PendingEventually { session.getActiveToolNames().contains("mcp__docs__search") })
        try await session.prompt("use tools after reload")
        #expect(c3PendingRemovals(session).isEmpty)
        _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await pool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func oldDashedTranscriptNameDropsAtPromptWithoutMigration() async throws {
        let pool = try C3PendingMcpPool()
        let manager = SessionManager.inMemory(pool.directory.path)
        let oldName = "mcp__my-docs__search"
        manager.appendMessage(.system(SystemMessage(content: .text("old transcript"),
            toolsAdded: [AITool(name: oldName, description: "Search documentation.", parameters: [:])])))
        let original = manager.getEntries().count
        let session = try await c3PendingSession(pool, manager: manager)
        defer { session.dispose() }
        #expect(manager.getEntries().count == original)
        #expect(!session.getActiveToolNames().contains(oldName))
        try await session.prompt("drop unavailable tools")
        #expect(c3PendingRemovals(session).contains(oldName))
        #expect(manager.buildSessionProjection().messages.first?.transcriptSystemMessage?.toolsAdded?.first?.name == oldName)
        _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await pool.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func reloadCanReplaceDashedMcpRegistrationWithUnderscores() async throws {
        let pool = try C3PendingMcpPool()
        let name = LockedState("my-docs")
        let registration = InlineExtension(name: "registered-docs") { api in
            try api.registerMcpServer(name.withLock { $0 }, config: McpServerConfig(
                url: "http://127.0.0.1/mcp", exposure: .deferred, timeout: 3))
        }
        let session = try await c3PendingSession(pool, extensions: [registration], configuredServer: false)
        defer { session.dispose() }
        #expect(session.hookRunner?.getMcpServers().map(\.name) == ["my-docs"])
        name.withLock { $0 = "my_docs" }
        await session.reload()
        let result = await session.reloadExtensions()
        #expect(result.errors.isEmpty)
        #expect(session.hookRunner?.getMcpServers().map(\.name) == ["my_docs"])
        #expect(try await c3PendingEventually { pool.connected.withLock { $0.contains("my_docs") } })
        _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        await pool.close()
    }
}
