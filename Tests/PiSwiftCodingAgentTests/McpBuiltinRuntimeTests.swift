import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private actor BuiltinFixture {
    let transport: InMemoryTransport
    private var loop: Task<Void, Never>?
    private var called: [String] = []
    private var offeredTools = ["read", "search"]

    init(_ transport: InMemoryTransport) { self.transport = transport }

    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.transport.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }

    func methods() -> [String] { called }
    func setTools(_ names: [String]) async throws {
        offeredTools = names
        try await transport.send(JsonRpc.encodeNotificationToLine(
            JsonRpcNotification(method: "notifications/tools/list_changed")))
    }
    func close() async { loop?.cancel(); await transport.close() }

    private func reply(_ request: JsonRpcRequest) async {
        called.append(request.method)
        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                      "capabilities": ["tools": [:], "resources": [:]],
                      "serverInfo": ["name": "fixture", "version": "1"]]
        case "tools/list":
            result = ["tools": offeredTools.map { ["name": $0, "description": "Use \($0)", "inputSchema": ["type": "object"]] }]
        case "resources/list":
            result = ["resources": []]
        case "resources/templates/list":
            result = ["resourceTemplates": []]
        case "tools/call":
            result = ["content": [["type": "text", "text": "done"]]]
        default: result = [:]
        }
        try? await transport.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

private actor RetryResourceTransport: McpTransport {
    let base: InMemoryTransport
    private var failNextResource = false
    private var resourceAttempts = 0

    init(_ base: InMemoryTransport) { self.base = base }
    func failOnce() { failNextResource = true }
    func attempts() -> Int { resourceAttempts }
    func start() async throws { try await base.start() }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
    func setProtocolVersion(_ version: String) async { await base.setProtocolVersion(version) }
    func send(_ data: Data) async throws {
        if let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message,
           request.method == "resources/list" {
            resourceAttempts += 1
            if failNextResource {
                failNextResource = false
                throw McpHTTPError(status: 503, body: "busy", message: "busy")
            }
        }
        try await base.send(data)
    }
}

@Test(.timeLimit(.minutes(1))) func mcpToolNamesExposureAndOutputGuard() async throws {
    #expect(createMcpToolName(server: "alpha", tool: "search") == "mcp__alpha__search")
    #expect(createMcpToolName(server: "alpha", tool: "a.b") == "mcp__alpha__a_b")
    #expect(createMcpToolName(server: "alpha", tool: "😀") == "mcp__alpha____")
    #expect(createMcpToolName(server: "alpha", tool: "search", isTaken: { _ in true }) == "mcp__alpha__search_0ab588c2")
    let long = createMcpToolName(server: "alpha", tool: String(repeating: "x", count: 80))
    #expect(long.count == 64)
    #expect(long.hasPrefix("mcp__alpha__"))
    #expect(mcpToolExposure(.codemodeDeferred) == .deferred)
    #expect(mcpToolExposure(.codemode) == .codemode)
    let saved = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-output-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: saved) }
    let content: [ContentBlock] = [.text(TextContent(text: String(repeating: "x", count: MCP_OUTPUT_MAX_BYTES + 100)))]
    let limited = await limitMcpContent(content, saveOutput: { data, _ in
        try data.write(to: saved)
        return saved
    })
    #expect(limited.fullOutputPath == saved.path)
    #expect(try Data(contentsOf: saved).count == MCP_OUTPUT_MAX_BYTES + 100)
    guard case .text(let text) = limited.content.first else { Issue.record("Expected text"); return }
    #expect(text.text.contains("Warning: truncated output"))
    #expect(text.text.contains("[Full output: "))

    let tool = McpTool(name: "read", title: "Read title", inputSchema: AnyCodable(["type": "object"]),
        outputSchema: AnyCodable(["type": "object", "properties": ["ok": ["type": "boolean"]]]),
        annotations: McpToolAnnotations(readOnlyHint: true))
    let definition = createMcpToolDefinition(server: "docs", tool: tool, name: "mcp__docs__read",
        exposure: .direct, namespace: ToolNamespace(name: "mcp__docs"), timeoutMs: 1000,
        getClient: { throw McpRuntimeError.connectionFailed("unused") })
    #expect(definition.label == "docs/read")
    #expect(definition.description == "Read title")
    #expect(definition.annotations?.readOnlyHint == true)
    #expect(definition.outputSchema?["properties"] != nil)
    #expect(definition.defaultActive == true)

    let errorResult = McpToolResult(content: [], isError: true,
        structuredContent: AnyCodable(["ok": false]))
    let converted = await convertMcpResult(server: "docs", tool: "read", result: errorResult)
    #expect(converted.isError == true)
    #expect((converted.structuredContent?.value as? [String: Any])?["isError"] as? Bool == true)
    #expect(converted.content.contains { if case .text(let text) = $0 { return !text.text.isEmpty }; return false })
}

@Test func mcpSecretTemplateMatchesUpstreamEscapes() throws {
    let entry = McpServerEntry(name: "auth", config: McpServerConfig(
        url: "https://example.invalid/mcp",
        oauth: McpOAuthConfig(clientSecret: "$HOME/$$/$!/${HOME}")),
        source: "fixture", scope: .extension)
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    #expect(try resolvedMcpOAuthSettings(entry).clientSecret == "\(home)/$/!/\(home)")
    var missing = entry
    missing.config.oauth?.clientSecret = "${PI_MCP_MISSING_TEST_SECRET}"
    #expect(throws: McpRuntimeError.self) { try resolvedMcpOAuthSettings(missing) }
}

@Test(.timeLimit(.minutes(1))) func mcpRuntimeRetriesConnectAndCallsTool() async throws {
    let (clientTransport, serverTransport) = InMemoryTransport.pair()
    let fixture = BuiltinFixture(serverTransport)
    await fixture.start()
    defer { Task { await fixture.close() } }
    let attempts = LockedState(0)
    // The client can connect with OAuth configured before a lazy client secret is resolved.
    let entry = McpServerEntry(name: "docs", config: McpServerConfig(url: "http://127.0.0.1/mcp",
        oauth: McpOAuthConfig(clientSecret: "${PI_MCP_MISSING_TEST_SECRET}"), timeout: 1),
                               source: "fixture", scope: .extension)
    let connection = McpServerConnection(entry: entry, cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, _ in
            let count = attempts.withLock { value in value += 1; return value }
            if count == 1 { throw URLError(.timedOut) }
            return clientTransport
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
    try await connection.connect()
    #expect(attempts.withLock { $0 } == 2)
    #expect(await connection.state == .connected)
    #expect(await connection.tools.map(\.name) == ["read", "search"])
    let result = try await connection.callTool(name: "read", arguments: [:])
    #expect(result.content.first?.text == "done")
    #expect(await fixture.methods().contains("tools/call"))
    await connection.close()
}

@Test(.timeLimit(.minutes(1))) func mcpRuntimeRetriesReadOnlyAndReconnectsLazily() async throws {
    let (firstClient, firstServer) = InMemoryTransport.pair()
    let (secondClient, secondServer) = InMemoryTransport.pair()
    let fixture1 = BuiltinFixture(firstServer)
    let fixture2 = BuiltinFixture(secondServer)
    await fixture1.start(); await fixture2.start()
    defer { Task { await fixture1.close(); await fixture2.close() } }
    let retryTransport = RetryResourceTransport(firstClient)
    let supplied = LockedState(0)
    let entry = McpServerEntry(name: "docs", config: McpServerConfig(
        url: "http://127.0.0.1/mcp", headers: ["Authorization": "fixture"], timeout: 1),
        source: "fixture", scope: .extension)
    let connection = McpServerConnection(entry: entry, cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, _ in
            let index = supplied.withLock { value in defer { value += 1 }; return value }
            return index == 0 ? retryTransport : secondClient
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
    try await connection.connect()
    let before = await retryTransport.attempts()
    await retryTransport.failOnce()
    let page = try await connection.resourcesPage()
    #expect(page.resources.isEmpty)
    #expect(await retryTransport.attempts() == before + 2)
    await fixture1.close()
    for _ in 0..<30 where await connection.state != .disconnected {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await connection.state == .disconnected)
    let result = try await connection.callTool(name: "read", arguments: [:])
    #expect(result.content.first?.text == "done")
    #expect(supplied.withLock { $0 } == 2)
    await connection.close()
}

@Test(.timeLimit(.minutes(1))) func mcpBuiltinActivatesDiscoveryAndHidesWithdrawnTools() async throws {
    let directory = FileManager.default.temporaryDirectory
    let (clientTransport, serverTransport) = InMemoryTransport.pair()
    let fixture = BuiltinFixture(serverTransport)
    await fixture.start()
    defer { Task { await fixture.close() } }
    let config = McpServerConfig(url: "http://127.0.0.1/mcp", headers: ["Authorization": "fixture"],
        toolExposure: ["search": .deferred], timeout: 1)
    let loaded = LoadedMcpConfig(servers: [McpServerEntry(name: "docs", config: config,
        source: "fixture", scope: .extension)])
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    let active = LockedState<[String]>([])
    api.setGetActiveToolsHandler { active.withLock { $0 } }
    api.setSetActiveToolsHandler { names in active.withLock { $0 = names } }
    api.setGetAllToolsHandler {
        [ToolInfo(name: CODEMODE_TOOL_NAME, description: "Codemode",
            sourceInfo: SourceInfo(path: "builtin:codemode", source: "builtin", scope: "user")),
         ToolInfo(name: TOOL_SEARCH_TOOL_NAME, description: "Search",
            sourceInfo: SourceInfo(path: "builtin:tool-search", source: "builtin", scope: "user"))]
    }
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(agentDir: directory,
        loadConfig: { _ in loaded }, createTransport: { _, _, _ in clientTransport }))
    let context = HookContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    await runtime.start(context: context)
    await runtime.waitForFirstPrompt(context: context)
    #expect(Set(active.withLock { $0 }) == [CODEMODE_TOOL_NAME, TOOL_SEARCH_TOOL_NAME])
    #expect(api.tools["mcp__docs__read"]?.exposure == .codemode)
    #expect(api.tools["mcp__docs__search"]?.exposure == .deferred)
    #expect(api.tools["mcp__docs__read"]?.namespace?.name == "mcp__docs")
    try await fixture.setTools(["search"])
    for _ in 0..<30 where api.tools["mcp__docs__read"]?.exposure != .hidden {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(api.tools["mcp__docs__read"]?.exposure == .hidden)
    await runtime.shutdown()
}

@Test(.timeLimit(.minutes(1))) func mcpBuiltinSourceAndFirstPromptWait() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-builtin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let loaded = ExtensionLoader.load(createMcpExtension(options: McpExtensionOptions(agentDir: directory)),
                                      cwd: directory.path, eventBus: createEventBus())
    let hook = try #require(loaded.hook)
    let command = try #require(hook.commands["mcp"])
    #expect(command.sourceInfo?.path == "builtin:mcp")
    #expect(hook.path == "builtin:mcp" && hook.hidden && hook.replaceable)
    #expect(builtInExtensions.map(\.name).suffix(3) == ["codemode", "tool-search", "mcp"])

    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    let config = LoadedMcpConfig(servers: [McpServerEntry(name: "slow", config: McpServerConfig(
        command: "slow", timeout: 0.2), source: "fixture", scope: .extension)])
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(agentDir: directory,
        loadConfig: { _ in config }, createTransport: { _, _, _ in throw URLError(.timedOut) }, startupWaitMs: 10))
    let context = HookContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    await runtime.start(context: context)
    let clock = ContinuousClock()
    let started = clock.now
    await runtime.waitForFirstPrompt(context: context)
    #expect(started.duration(to: clock.now) < .milliseconds(200))
    await runtime.shutdown()
}
