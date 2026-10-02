import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent
#if os(macOS)
import Network
#endif

// Port of v1.0.0 mcp-extension.test.ts and suite/agent-session-mcp.test.ts.
private actor C1McpFixture {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private let gate: LockedState<Bool>?
    private let instructions: String?
    private let toolNames: [String]
    private var loop: Task<Void, Never>?
    private var received: [String] = []
    private var calls: [String] = []

    init(tools: [String] = ["search"], instructions: String? = nil, gate: LockedState<Bool>? = nil) {
        (client, server) = InMemoryTransport.pair()
        toolNames = tools; self.instructions = instructions; self.gate = gate
    }
    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }
    func methods() -> [String] { received }
    func calledTools() -> [String] { calls }
    func close() async { loop?.cancel(); await server.close() }
    private func reply(_ request: JsonRpcRequest) async {
        received.append(request.method)
        if request.method == "initialize", let gate {
            while !gate.withLock({ $0 }) {
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
            }
        }
        var result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:], "resources": [:]],
                      "serverInfo": ["name": "fixture", "version": "1"]]
            if let instructions { result["instructions"] = instructions }
        case "tools/list":
            result = ["tools": toolNames.map { ["name": $0, "description": $0 == "read-file" ? "dashed" : $0 == "read_file" ? "underscored" : "Search the docs.", "inputSchema": ["type": "object"]] }]
        case "resources/list": result = ["resources": []]
        case "resources/templates/list": result = ["resourceTemplates": []]
        case "tools/call":
            let name = (request.params?.value as? [String: Any])?["name"] as? String ?? ""
            calls.append(name)
            result = ["content": [["type": "text", "text": name]]]
        default: result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

private func c1Eventually(_ check: @Sendable () async -> Bool) async throws -> Bool {
    for _ in 0..<300 {
        if await check() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return await check()
}

private func c1Entry(_ name: String, exposure: McpExposure = .codemode, description: String? = nil,
                     toolExposure: [String: McpExposure]? = nil, enabled: Bool = true) -> McpServerEntry {
    McpServerEntry(name: name, config: McpServerConfig(url: "http://127.0.0.1/mcp", headers: ["Authorization": "fixture"],
        description: description, exposure: exposure, toolExposure: toolExposure, enabled: enabled, timeout: 3), source: "test", scope: .extension)
}

private func c1Context(signal: CancellationToken? = nil) -> HookContext {
    var context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil, hasUI: false)
    context.signal = signal
    return context
}

private func c1ToolContext() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
                      isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
}

private func c1Runtime(_ entries: [McpServerEntry], fixtures: [String: C1McpFixture], startupWaitMs: Int = 10_000)
    -> (McpBuiltinRuntime, HookAPI, LockedState<[String]>) {
    let active = LockedState<[String]>([])
    let api = HookAPI(events: createEventBus(), hookPath: "builtin:mcp")
    api.setGetActiveToolsHandler { active.withLock { $0 } }
    api.setSetActiveToolsHandler { names in active.withLock { $0 = names } }
    api.setGetAllToolsHandler {
        [ToolInfo(name: CODEMODE_TOOL_NAME, description: "Codemode", sourceInfo: SourceInfo(path: "builtin:codemode", source: "builtin", scope: "user")),
         ToolInfo(name: TOOL_SEARCH_TOOL_NAME, description: "Search", sourceInfo: SourceInfo(path: "builtin:tool-search", source: "builtin", scope: "user"))]
        // A registered resource tool can wait for other servers still connecting.
        + [LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL].map {
            ToolInfo(name: $0, description: "Resources", sourceInfo: SourceInfo(path: "builtin:mcp", source: "builtin", scope: "user"))
        }
    }
    let runtime = McpBuiltinRuntime(api: api, options: McpExtensionOptions(agentDir: FileManager.default.temporaryDirectory,
        loadConfig: { _ in LoadedMcpConfig(servers: entries) }, createTransport: { entry, _, _ in
            guard let fixture = fixtures[entry.name] else { throw McpRuntimeError.connectionFailed("Missing fixture") }
            return fixture.client
        }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), startupWaitMs: startupWaitMs))
    return (runtime, api, active)
}

@Test func c1McpServersSectionListsReachAndFirstLine() {
    let section = renderServersSection([
        McpServerListing(entry: c1Entry("docs", description: "Docs search.\nMore.")),
        McpServerListing(entry: c1Entry("later", exposure: .deferred)),
        McpServerListing(entry: c1Entry("direct", exposure: .direct, description: "Declared.")),
        McpServerListing(entry: c1Entry("plain"), instructions: "From instructions."),
    ])
    #expect(section?.components(separatedBy: "\n") == [
        "MCP servers whose tools are not declared to you. Call the tools of `codemode` servers from codemode scripts. Load the tools of `tool_search` servers with `tool_search`.",
        "- mcp__docs (codemode): Docs search.", "- mcp__later (tool_search)", "- mcp__plain (codemode): From instructions.",
    ])
    #expect(renderServersSection([McpServerListing(entry: c1Entry("direct", exposure: .direct))]) == nil)
    #expect(renderServersSection([McpServerListing(entry: c1Entry("off", enabled: false))]) == nil)
    #expect(renderServersSection([McpServerListing(entry: c1Entry("my-server"))])?.contains("- mcp__my_server (codemode)") == true)
}

@Test func c1McpServersSectionShrinksDescriptionsToFit() {
    let servers = (0..<40).map { McpServerListing(entry: c1Entry("server\($0)", description: String(repeating: "x", count: 400))) }
    let section = renderServersSection(servers) ?? ""
    #expect(section.utf16.count <= MAX_SERVERS_SECTION_CHARS)
    #expect(section.components(separatedBy: "\n").count == 41)
    #expect(section.contains("- mcp__server39 (codemode): x"))
}

@Test func c1McpServersSectionCountsOmittedServers() throws {
    let servers = (0..<200).map { McpServerListing(entry: c1Entry("server-with-a-long-name-\($0)", description: "desc")) }
    let section = renderServersSection(servers) ?? ""
    #expect(section.utf16.count <= MAX_SERVERS_SECTION_CHARS)
    let lines = section.components(separatedBy: "\n")
    let final = try #require(lines.last)
    #expect(final.hasPrefix("- … "))
    #expect(final.hasSuffix(" more servers; find their tools with searchTools()"))
    let omitted = try #require(Int(final.split(separator: " ")[2]))
    #expect(lines.count - 2 + omitted == 200)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1McpCollidingToolNamesRouteIndependently(_ reverse: Bool) async throws {
    let fixture = C1McpFixture(tools: reverse ? ["read_file", "read-file"] : ["read-file", "read_file"])
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("docs")], fixtures: ["docs": fixture])
    await runtime.start(context: c1Context())
    try await runtime.waitForServers()
    let tools = api.tools.values.filter { $0.namespace?.name == "mcp__docs" }
    #expect(tools.count == 2)
    #expect(tools.allSatisfy { $0.name.hasPrefix("mcp__docs__read_file_") && $0.name.count == "mcp__docs__read_file_".count + 8 })
    #expect(Set(tools.map(\.name)) == Set(["read-file", "read_file"].map { createMcpToolName(server: "docs", tool: $0, isTaken: { _ in true }) }))
    for description in ["dashed", "underscored"] {
        let tool = try #require(tools.first { $0.description == description })
        let result = try await tool.execute("collision", [:], nil, c1ToolContext(), nil)
        guard case .text(let text) = result.content.first else { Issue.record("Expected text"); continue }
        #expect(text.text == (description == "dashed" ? "read-file" : "read_file"))
    }
    #expect(await fixture.calledTools() == ["read-file", "read_file"])
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpNamespaceHasSeparateDescriptionAndInstructions() async throws {
    let fixture = C1McpFixture(instructions: "Always search before reading.")
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("dev-radius", description: "Search the product docs")], fixtures: ["dev-radius": fixture])
    await runtime.start(context: c1Context())
    try await runtime.waitForServers()
    let namespace = try #require(api.tools["mcp__dev_radius__search"]?.namespace)
    #expect(namespace.name == "mcp__dev_radius")
    #expect(namespace.description == "Search the product docs")
    #expect(namespace.instructions == "Always search before reading.")
    #expect(await runtime.serversSection()?.contains("- mcp__dev_radius (codemode): Search the product docs") == true)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [McpExposure.codemode, .deferred])
func c1McpFirstPromptStartsDiscoveryBeforeBackgroundConnect(_ exposure: McpExposure) async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(gate: gate)
    await fixture.start()
    let (runtime, api, active) = c1Runtime([c1Entry("slow", exposure: exposure)], fixtures: ["slow": fixture])
    await runtime.start(context: c1Context())
    await runtime.waitForFirstPrompt(context: c1Context())
    #expect(active.withLock { $0 } == [exposure == .codemode ? CODEMODE_TOOL_NAME : TOOL_SEARCH_TOOL_NAME])
    #expect(api.tools["mcp__slow__search"] == nil)
    #expect(await runtime.serversSection()?.contains("- mcp__slow (\(exposure == .codemode ? "codemode" : "tool_search"))") == true)
    gate.withLock { $0 = true }
    try await runtime.waitForServers()
    #expect(api.tools["mcp__slow__search"] != nil)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1McpFirstPromptWaitsForConfiguredDirectTools(_ override: Bool) async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(gate: gate)
    await fixture.start()
    let entry = c1Entry("slow", exposure: override ? .codemode : .direct, toolExposure: override ? ["search": .direct] : nil)
    let (runtime, api, _) = c1Runtime([entry], fixtures: ["slow": fixture])
    await runtime.start(context: c1Context())
    let finished = LockedState(false)
    let wait = Task { await runtime.waitForFirstPrompt(context: c1Context()); finished.withLock { $0 = true } }
    #expect(try await c1Eventually { await fixture.methods().contains("initialize") })
    #expect(!finished.withLock { $0 })
    gate.withLock { $0 = true }
    await wait.value
    #expect(api.tools["mcp__slow__search"]?.exposure == .direct)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpDirectStartupWaitIsBounded() async throws {
    let fixture = C1McpFixture(gate: LockedState(false))
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("slow", exposure: .direct)], fixtures: ["slow": fixture], startupWaitMs: 20)
    await runtime.start(context: c1Context())
    await runtime.waitForFirstPrompt(context: c1Context())
    #expect(api.tools["mcp__slow__search"] == nil)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["tools.mcp__slow_docs__search({})", "searchTools('docs')", "describeNamespace('slow-docs')", "describeTool('x')", "ALL_TOOLS"])
func c1McpCodemodeWaitsForServersUsedByScript(_ code: String) async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(gate: gate)
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("slow-docs")], fixtures: ["slow-docs": fixture])
    await runtime.start(context: c1Context())
    let finished = LockedState(false), entered = LockedState(false)
    let wait = Task {
        entered.withLock { $0 = true }
        try await runtime.toolCall(event: ToolCallEvent(toolName: CODEMODE_TOOL_NAME, toolCallId: "wait", input: ["code": AnyCodable(code)]), context: c1Context())
        finished.withLock { $0 = true }
    }
    #expect(try await c1Eventually { await fixture.methods().contains("initialize") })
    #expect(try await c1Eventually { entered.withLock { $0 } })
    #expect(!finished.withLock { $0 })
    gate.withLock { $0 = true }
    try await wait.value
    #expect(api.tools["mcp__slow_docs__search"] != nil)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpCodemodeWaitsOnlyForNamedServer() async throws {
    let firstGate = LockedState(false), secondGate = LockedState(false)
    let first = C1McpFixture(gate: firstGate), second = C1McpFixture(gate: secondGate)
    await first.start(); await second.start()
    let (runtime, api, _) = c1Runtime([c1Entry("first"), c1Entry("second")], fixtures: ["first": first, "second": second])
    await runtime.start(context: c1Context())
    let wait = Task { try await runtime.toolCall(event: ToolCallEvent(toolName: CODEMODE_TOOL_NAME, toolCallId: "one", input: ["code": AnyCodable("tools.mcp__first__search({})")]), context: c1Context()) }
    #expect(try await c1Eventually {
        let firstStarted = await first.methods().contains("initialize")
        let secondStarted = await second.methods().contains("initialize")
        return firstStarted && secondStarted
    })
    firstGate.withLock { $0 = true }
    try await wait.value
    #expect(api.tools["mcp__first__search"] != nil)
    #expect(api.tools["mcp__second__search"] == nil)
    secondGate.withLock { $0 = true }
    try await runtime.waitForServers()
    await runtime.shutdown(); await first.close(); await second.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [TOOL_SEARCH_TOOL_NAME, LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL])
func c1McpSearchAndResourceCallsWaitForAllServers(_ name: String) async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(gate: gate)
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("slow", exposure: .deferred)], fixtures: ["slow": fixture])
    await runtime.start(context: c1Context())
    let finished = LockedState(false), entered = LockedState(false)
    let wait = Task {
        entered.withLock { $0 = true }
        try await runtime.toolCall(event: ToolCallEvent(toolName: name, toolCallId: "search", input: [:]), context: c1Context())
        finished.withLock { $0 = true }
    }
    #expect(try await c1Eventually { await fixture.methods().contains("initialize") })
    #expect(try await c1Eventually { entered.withLock { $0 } })
    #expect(!finished.withLock { $0 })
    gate.withLock { $0 = true }
    try await wait.value
    #expect(api.tools["mcp__slow__search"] != nil)
    await runtime.shutdown(); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpReadinessWaitStopsOnAbort() async throws {
    let fixture = C1McpFixture(gate: LockedState(false))
    await fixture.start()
    let (runtime, _, _) = c1Runtime([c1Entry("slow")], fixtures: ["slow": fixture])
    await runtime.start(context: c1Context())
    let signal = CancellationToken()
    let wait = Task { try await runtime.waitForServers(signal: signal) }
    #expect(try await c1Eventually { await fixture.methods().contains("initialize") })
    signal.cancel()
    try await wait.value
    await runtime.shutdown(); await fixture.close()
}

private func c1PromptResponse(_ model: Model) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: [.text(TextContent(text: "ready"))], api: model.api, provider: model.provider,
        model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
    stream.push(.done(reason: .stop, message: message)); stream.end(message)
    return stream
}

private func c1PromptSession(entry: McpServerEntry, fixture: C1McpFixture, startupWaitMs: Int = 10_000,
                             mcpOptions: McpExtensionOptions? = nil) throws
    -> (AgentSession, HookRunner) {
    let manager = SessionManager.inMemory()
    let bus = createEventBus()
    let extensions = [createCodemodeExtension(), createToolSearchExtension(), createMcpExtension(options: mcpOptions ?? .init(
        agentDir: FileManager.default.temporaryDirectory, loadConfig: { _ in .init(servers: [entry]) },
        createTransport: { _, _, _ in fixture.client }, credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), startupWaitMs: startupWaitMs))]
    let hooks = try extensions.map { try #require(ExtensionLoader.load($0, cwd: manager.getCwd(), eventBus: bus).hook) }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let registry = ModelRegistry(auth)
    let runner = HookRunner(hooks, manager.getCwd(), manager, registry)
    let definitions = runner.getExtensionTools()
    let tools = definitions.map { wrapToolWithHooks(wrapCustomTool($0) { c1ToolContext() }, runner) }
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "old", model: model, tools: []),
        streamFn: { model, _, _ in c1PromptResponse(model) }, getApiKey: { _ in "test" }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        systemPromptOptions: BuildSystemPromptOptions(cwd: manager.getCwd(), contextFiles: [], skills: []),
        hookRunner: runner, modelRegistry: registry,
        toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
        toolDefinitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) }),
        wrapExtensionTools: { tools in tools.map { wrapToolWithHooks(wrapCustomTool($0) { c1ToolContext() }, runner) } }))
    return (session, runner)
}

private func c1SystemMessages(_ session: AgentSession) -> [SystemMessage] {
    session.sessionManager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
}

@Test(.timeLimit(.minutes(1))) func c1McpServerSectionAppendsSummaryAtNextPrompt() async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(instructions: "Slow docs.\nMore.", gate: gate)
    await fixture.start()
    let (session, runner) = try c1PromptSession(entry: c1Entry("slow"), fixture: fixture)
    defer { session.dispose() }
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("first")
    let initial = c1SystemMessages(session)
    #expect(initial.count == 1)
    #expect(initial.first?.sections?[MCP_SERVERS_SECTION]?.contains("- mcp__slow (codemode)\n") == true)
    gate.withLock { $0 = true }
    #expect(try await c1Eventually { session.getAllTools().contains { $0.name == "mcp__slow__search" } })
    try await session.prompt("second")
    let messages = session.sessionManager.buildSessionProjection().messages
    let systems = c1SystemMessages(session)
    #expect(systems.count == 2)
    #expect(systems[1].sections?.entries.map(\.name) == [MCP_SERVERS_SECTION])
    #expect(systems[1].sections?[MCP_SERVERS_SECTION]?.contains("- mcp__slow (codemode): Slow docs.") == true)
    #expect(systems[1].sections?[MCP_SERVERS_SECTION]?.contains("More.") == false)
    let patchIndex = try #require(messages.lastIndex { $0.transcriptSystemMessage != nil })
    let firstAssistant = try #require(messages.firstIndex { $0.role == "assistant" })
    #expect(patchIndex > firstAssistant)
    _ = await runner.emit(SessionShutdownEvent(reason: .quit)); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpDirectWaitFinishesBeforeServerSectionIsBuilt() async throws {
    let gate = LockedState(false)
    let fixture = C1McpFixture(instructions: "Slow docs.", gate: gate)
    await fixture.start()
    let (session, runner) = try c1PromptSession(entry: c1Entry("slow", exposure: .direct, toolExposure: ["shot": .codemode]), fixture: fixture)
    defer { session.dispose() }
    _ = await runner.emit(SessionStartEvent())
    let prompt = Task { try await session.prompt("first") }
    #expect(try await c1Eventually { await fixture.methods().contains("initialize") })
    gate.withLock { $0 = true }
    try await prompt.value
    #expect(c1SystemMessages(session).first?.sections?[MCP_SERVERS_SECTION]?.contains("- mcp__slow (codemode): Slow docs.") == true)
    _ = await runner.emit(SessionShutdownEvent(reason: .quit)); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpOnlyDirectServersHaveNoServerSection() async throws {
    let fixture = C1McpFixture()
    await fixture.start()
    let (session, runner) = try c1PromptSession(entry: c1Entry("docs", exposure: .direct), fixture: fixture)
    defer { session.dispose() }
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("first")
    #expect(c1SystemMessages(session).allSatisfy { $0.sections?[MCP_SERVERS_SECTION] == nil })
    #expect(session.getActiveToolNames().contains("mcp__docs__search"))
    _ = await runner.emit(SessionShutdownEvent(reason: .quit)); await fixture.close()
}

@Test(.timeLimit(.minutes(1))) func c1McpDeferredSectionUsesFirstInstructionLine() async throws {
    let fixture = C1McpFixture(instructions: "Docs search.\nLong guidance.")
    await fixture.start()
    let (session, runner) = try c1PromptSession(entry: c1Entry("docs", exposure: .deferred), fixture: fixture)
    defer { session.dispose() }
    _ = await runner.emit(SessionStartEvent())
    #expect(try await c1Eventually { session.getAllTools().contains { $0.name == "mcp__docs__search" } })
    try await session.prompt("first")
    let section = c1SystemMessages(session).first?.sections?[MCP_SERVERS_SECTION]
    #expect(section?.contains("- mcp__docs (tool_search): Docs search.\n") == true)
    #expect(section?.contains("Long guidance") == false)
    #expect(session.agent.state.tools.first { $0.name == TOOL_SEARCH_TOOL_NAME }?.description == TOOL_SEARCH_DESCRIPTION)
    _ = await runner.emit(SessionShutdownEvent(reason: .quit)); await fixture.close()
}

#if os(macOS)
private actor C1McpProviderHttpServer {
    private let listener: NWListener
    private let rejects: Bool
    private var ready = false
    private var waiter: CheckedContinuation<Void, Error>?
    private var connections: [NWConnection] = []
    private var authorizations: [String?] = []
    private var registrationNames: [String] = []

    init(rejects: Bool) throws {
        self.rejects = rejects
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.respond(connection) } }
        listener.start(queue: .global())
        if !ready { try await withCheckedThrowingContinuation { waiter = $0 } }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/mcp")!
    }
    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready: ready = true; waiter?.resume(); waiter = nil
        case .failed(let error): waiter?.resume(throwing: error); waiter = nil
        default: break
        }
    }
    private func read(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
    private func respond(_ connection: NWConnection) async {
        connections.append(connection)
        connection.start(queue: .global())
        var request = Data()
        var headerRange: Range<Data.Index>?
        var bodyLength = 0
        while let data = await read(connection), !data.isEmpty {
            request.append(data)
            if let range = request.range(of: Data("\r\n\r\n".utf8)) {
                headerRange = range
                let headers = String(decoding: request[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                bodyLength = headers.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count >= range.upperBound + bodyLength { break }
            }
        }
        guard let headerRange else { connection.cancel(); return }
        let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
        let isPost = lines.first?.hasPrefix("POST ") == true
        if isPost { authorizations.append(authorization) }
        let status: String
        let body: Data
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init)
        if path == "/register" {
            let input = request.subdata(in: headerRange.upperBound..<(headerRange.upperBound + bodyLength))
            if let registration = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
               let name = registration["client_name"] as? String { registrationNames.append(name) }
            status = "200 OK"; body = Data(#"{"client_id":"registered-client"}"#.utf8)
        } else if path == "/token" {
            status = "200 OK"; body = Data(#"{"access_token":"fixture-oauth-token","token_type":"Bearer","expires_in":3600}"#.utf8)
        } else if rejects {
            status = "401 Unauthorized"; body = Data()
        } else if !isPost {
            status = "405 Method Not Allowed"; body = Data()
        } else {
            let input = request.subdata(in: headerRange.upperBound..<(headerRange.upperBound + bodyLength))
            if let message = try? JsonRpc.decodeIncoming(input), case .request(let rpc) = message {
                let result: [String: Any]
                switch rpc.method {
                case "initialize": result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]], "serverInfo": ["name": "http", "version": "1"]]
                case "tools/list": result = ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]]
                default: result = ["content": [["type": "text", "text": "ok"]]]
                }
                status = "200 OK"
                body = (try? JsonRpc.encodeServerResponseToLine(JsonRpcServerResponse(id: rpc.id, result: AnyCodable(result), error: nil))) ?? Data()
            } else { status = "202 Accepted"; body = Data() }
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        await withCheckedContinuation { continuation in
            connection.send(content: response, completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }
    func tokens() -> [String?] { authorizations }
    func registeredNames() -> [String] { registrationNames }
    func stop() {
        listener.cancel(); connections.forEach { $0.cancel() }
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }
}

@Test(.timeLimit(.minutes(1))) func c1McpProviderToken401RequiresProviderLogin() async throws {
    let server = try C1McpProviderHttpServer(rejects: true)
    let url = try await server.start()
    let providers = LockedState<[String]>([])
    let connection = McpServerConnection(entry: McpServerEntry(name: "work", config: .init(url: url.absoluteString,
        auth: .init(provider: "company")), source: "test", scope: .global), cwd: FileManager.default.temporaryDirectory,
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), providerToken: { provider in
            providers.withLock { $0.append(provider) }; return provider == "company" ? "tok" : nil
        })
    #expect(await connection.oauthURL == nil)
    do {
        try await connection.connect()
        Issue.record("Expected a provider sign-in error")
    } catch {
        #expect(error.localizedDescription == "MCP server \"work\" requires sign-in. Run /login company to sign in.")
    }
    #expect(await connection.state == .needsAuth)
    #expect(await server.tokens() == ["Bearer tok"])
    #expect(providers.withLock { $0 } == ["company"])
    await connection.close(); await server.stop()
}

@Test(.timeLimit(.minutes(1))) func c1McpProviderReadsCurrentTokenOnEveryRequest() async throws {
    let server = try C1McpProviderHttpServer(rejects: false)
    let url = try await server.start()
    let token = LockedState<String?>("old")
    let connection = McpServerConnection(entry: McpServerEntry(name: "work", config: .init(url: url.absoluteString,
        auth: .init(provider: "company")), source: "test", scope: .global), cwd: FileManager.default.temporaryDirectory,
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()), providerToken: { _ in token.withLock { $0 } })
    try await connection.connect()
    #expect(await server.tokens().allSatisfy { $0 == "Bearer old" })
    token.withLock { $0 = "new" }
    _ = try await connection.callTool(name: "echo", arguments: [:])
    #expect(await server.tokens().last == "Bearer new")
    token.withLock { $0 = nil }
    _ = try await connection.callTool(name: "echo", arguments: [:])
    #expect(await server.tokens().last == .some(nil))
    #expect(await connection.oauthURL == nil)
    await connection.close(); await server.stop()
}
#endif

@Test(.timeLimit(.minutes(1))) func c1McpConfiguredServerOverridesRegisteredNamespaceAlias() async throws {
    let fixture = C1McpFixture()
    await fixture.start()
    let (runtime, api, _) = c1Runtime([c1Entry("dev-docs")], fixtures: ["dev-docs": fixture])
    try api.registerMcpServer("dev_docs", config: McpServerConfig(url: "https://unused.invalid/mcp"))
    await runtime.start(context: c1Context())
    try await runtime.waitForServers()
    #expect(await runtime.menu().items.map(\.value) == ["dev-docs"])
    #expect(await runtime.status().contains("overridden: \"dev_docs\" registered by builtin:mcp is overridden by \"dev-docs\" in test"))
    #expect(api.tools["mcp__dev_docs__search"] != nil)
    await runtime.shutdown(); await fixture.close()
}

#if os(macOS)
private struct C1McpOAuthPresenter: McpSignInPresenter {
    let issuer: String
    func redirectURL(for state: String) async throws -> URL { URL(string: "http://127.0.0.1:6000/callback")! }
    func present(authorizationURL: URL, state: String) async throws -> URL {
        var callback = URLComponents(string: "http://127.0.0.1:6000/callback")!
        callback.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state), .init(name: "iss", value: issuer)]
        return callback.url!
    }
}

// Upstream suite/agent-session-mcp-oauth.test.ts: client_name registration through /mcp login.
@Test(.timeLimit(.minutes(1)), arguments: ["Claude Code", "pi"])
func c1McpSessionLoginRegistersConfiguredOrDefaultClientName(_ clientName: String) async throws {
    let server = try C1McpProviderHttpServer(rejects: false)
    let url = try await server.start()
    var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    origin.path = ""
    let issuer = origin.url!.absoluteString
    let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
    var state = McpOAuthState(serverURL: url.absoluteString)
    state.discovery = .init(authorizationServerURL: issuer,
        authorizationServerMetadata: .init(issuer: issuer, authorizationEndpoint: issuer + "/authorize",
            tokenEndpoint: issuer + "/token", registrationEndpoint: issuer + "/register",
            tokenEndpointAuthMethodsSupported: ["none"], codeChallengeMethodsSupported: ["S256"]))
    try await credentials.forServer(name: "docs", url: url).save(state)
    let entry = McpServerEntry(name: "docs", config: McpServerConfig(url: url.absoluteString,
        oauth: McpOAuthConfig(clientName: clientName == "pi" ? nil : clientName), exposure: .direct), source: "test", scope: .extension)
    let options = McpExtensionOptions(agentDir: FileManager.default.temporaryDirectory, loadConfig: { _ in .init(servers: [entry]) },
        credentials: credentials, presenter: C1McpOAuthPresenter(issuer: issuer))
    let (session, runner) = try c1PromptSession(entry: entry, fixture: C1McpFixture(), mcpOptions: options)
    defer { session.dispose() }
    runner.attachUI(NoOpHookUIContext(), hasUI: true)
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("/mcp login docs")
    #expect(await server.registeredNames() == [clientName])
    #expect(try credentials.tokens(name: "docs", url: url)?.accessToken == "fixture-oauth-token")
    #expect(session.getAllTools().contains { $0.name == "mcp__docs__echo" })
    _ = await runner.emit(SessionShutdownEvent(reason: .quit)); await server.stop()
}
#endif
