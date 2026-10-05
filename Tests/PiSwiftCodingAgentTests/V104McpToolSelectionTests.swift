import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

// Port of v1.0.4 suite/agent-session-mcp.test.ts:231-323.
private actor V104SelectionServer {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private let resources: Bool
    private var loop: Task<Void, Never>?

    init(resources: Bool) {
        (client, server) = InMemoryTransport.pair()
        self.resources = resources
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
        let result: [String: Any]
        switch request.method {
        case "initialize":
            var capabilities: [String: Any] = ["tools": [:]]
            if resources { capabilities["resources"] = [String: Any]() }
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": capabilities,
                      "serverInfo": ["name": "docs", "version": "1.0.0"]]
        case "tools/list":
            result = ["tools": [
                ["name": "search", "description": "Search the docs.",
                 "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]]],
                ["name": "fail", "description": "Always fails.",
                 "inputSchema": ["type": "object", "properties": [:]]],
                ["name": "shot", "description": "Returns an image.",
                 "inputSchema": ["type": "object", "properties": [:]]]
            ]]
        case "resources/list":
            result = ["resources": [["uri": "docs://intro", "name": "intro", "mimeType": "text/markdown"]]]
        case "resources/templates/list":
            result = ["resourceTemplates": [["uriTemplate": "docs://pages/{slug}", "name": "page"]]]
        case "resources/read":
            result = ["contents": [["uri": "docs://intro", "mimeType": "text/markdown", "text": "# Intro"]]]
        case "tools/call":
            result = ["content": [["type": "text", "text": "documentation result"]]]
        default:
            result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }

    func close() async {
        loop?.cancel()
        await server.close()
        await loop?.value
        loop = nil
    }
}

private struct V104SelectionPool: Sendable {
    let directory: URL
    let servers = LockedState<[V104SelectionServer]>([])
    let startups = LockedState<[Task<Void, Never>]>([])

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("v104-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func transport(resources: Bool) -> any McpTransport {
        let fixture = V104SelectionServer(resources: resources)
        servers.withLock { $0.append(fixture) }
        let startup = Task { await fixture.start() }
        startups.withLock { $0.append(startup) }
        return fixture.client
    }

    func close() async {
        for startup in startups.withLock({ $0 }) { await startup.value }
        for fixture in servers.withLock({ $0 }) { await fixture.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func v104SelectionEventually(_ check: @Sendable () -> Bool) async throws -> Bool {
    for _ in 0..<600 {
        if check() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return check()
}

private func v104SelectionResponse(_ model: Model, search: Bool = false) -> AssistantMessageEventStream {
    let reason: StopReason = search ? .toolUse : .stop
    let content: [ContentBlock] = search
        ? [.toolCall(ToolCall(id: UUID().uuidString, name: TOOL_SEARCH_TOOL_NAME,
                             arguments: ["query": AnyCodable("search the docs"), "limit": AnyCodable(1)]))]
        : [.text(TextContent(text: "done"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: reason)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: reason, message: message))
    stream.end(message)
    return stream
}

private func v104WithMcpSession(
    exposure: McpExposure,
    toolNames: [String]? = nil,
    excludeTools: [String]? = nil,
    noTools: NoToolsMode? = nil,
    resources: Bool = false,
    toolExposure: [String: McpExposure] = [:],
    manager: SessionManager? = nil,
    waitForTools: Bool = true,
    extensions: [InlineExtension] = [],
    body: (AgentSession, V104SelectionPool) async throws -> Void
) async throws {
    let pool = try V104SelectionPool()
    let entry = McpServerEntry(name: "docs", config: McpServerConfig(url: "http://unused.invalid/mcp",
        exposure: exposure, toolExposure: toolExposure, timeout: 3), source: "test", scope: .extension)
    let mcp = createMcpExtension(options: McpExtensionOptions(agentDir: pool.directory,
        loadConfig: { _ in LoadedMcpConfig(servers: [entry]) },
        createTransport: { _, _, _ in pool.transport(resources: resources) },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())))
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let created = await createAgentSession(CreateAgentSessionOptions(cwd: pool.directory.path,
        agentDir: pool.directory.path, authStorage: auth, model: model, offline: true,
        toolNames: toolNames, excludeTools: excludeTools, noTools: noTools,
        resourceLoader: TestResourceLoader(), hooks: [],
        inlineExtensions: extensions + [createCodemodeExtension(), createToolSearchExtension(), mcp],
        sessionManager: manager ?? .inMemory(pool.directory.path), settingsManager: .inMemory()))
    let session = created.session
    session.agent.streamFn = { model, _, _ in v104SelectionResponse(model) }
    do {
        let runner = try #require(session.hookRunner)
        _ = await runner.emit(SessionStartEvent())
        if waitForTools {
            let registered = try await v104SelectionEventually { session.getAllToolNames().contains("mcp__docs__search") }
            #expect(registered)
        }
        try await body(session, pool)
    } catch {
        _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
        session.dispose()
        await pool.close()
        throw error
    }
    _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
    session.dispose()
    await pool.close()
}

private func v104SelectionTool(_ name: String, defaultActive: Bool = true,
                                exposure: ToolExposure = .direct) -> CustomTool {
    CustomTool(name: name, label: name, description: name, parameters: [:],
        execute: { _, _, _, _, _ in AgentToolResult(content: []) },
        exposure: exposure, defaultActive: defaultActive)
}

private func v104SelectionSession(extensions: [InlineExtension], toolNames: [String],
                                   excludeTools: [String] = [],
                                   customTools: [CustomToolDefinition] = []) async -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let created = await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, toolNames: toolNames, excludeTools: excludeTools, customTools: customTools,
        resourceLoader: TestResourceLoader(), hooks: [], inlineExtensions: extensions,
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    return created.session
}

@Suite("v1.0.4 MCP tool selection")
struct V104McpToolSelectionTests {
    @Test(.timeLimit(.minutes(1)))
    func keepsMcpToolsWhenAllowlistNamesNoMcpTool() async throws {
        for exposure in [McpExposure.codemode, .deferred] {
            try await v104WithMcpSession(exposure: exposure, toolNames: ["read", "codemode"], resources: true) { session, _ in
                #expect(session.getActiveToolNames() == ["read", "codemode"])
                let callable = try await v104SelectionEventually {
                    Set(session.getCallableTools().map(\.name)).isSuperset(of:
                        ["mcp__docs__search", "mcp__docs__fail", LIST_MCP_RESOURCES_TOOL, READ_MCP_RESOURCE_TOOL])
                }
                #expect(callable)
                #expect(!session.getAllToolNames().contains("bash"))
                #expect(!session.getAllToolNames().contains(TOOL_SEARCH_TOOL_NAME))
            }
        }
        try await v104WithMcpSession(exposure: .codemode, toolNames: ["codemode"],
                                    toolExposure: ["fail": .direct]) { session, _ in
            let registered = try await v104SelectionEventually { session.getAllToolNames().contains("mcp__docs__fail") }
            #expect(registered)
            #expect(session.getActiveToolNames() == ["codemode"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func removesMcpToolsWithNoTools() async throws {
        try await v104WithMcpSession(exposure: .direct, noTools: .all, waitForTools: false) { session, pool in
            try await session.prompt("go")
            #expect(pool.servers.withLock { $0.count } == 1)
            #expect(session.getAllTools().isEmpty)
            #expect(session.getActiveToolNames().isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func doesNotDeclareUnnamedMcpToolsRestoredFromTranscript() async throws {
        // Upstream's first harness starts with no built-in tools.
        try await v104WithMcpSession(exposure: .direct, noTools: .builtin) { first, _ in
            try await first.prompt("first")
            try await first.prompt("second")
            let declared = first.sessionManager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
                .flatMap { $0.toolsAdded?.map(\.name) ?? [] }
            #expect(declared.contains("mcp__docs__search"))
            try await v104WithMcpSession(exposure: .direct, toolNames: ["read", "codemode"],
                                        manager: first.sessionManager) { second, _ in
                let assistant = try #require(second.sessionManager.getBranch().first {
                    if case .message(let entry) = $0, case .assistant = entry.message { return true }
                    return false
                })
                let navigation = await second.navigateTree(assistant.id, summarize: false)
                #expect(!navigation.cancelled)
                #expect(second.getActiveToolNames().isEmpty)
                #expect(second.getAllToolNames().contains("mcp__docs__search"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func toolSearchDeclaresUnnamedMcpToolsWhenAllowlistNamesIt() async throws {
        try await v104WithMcpSession(exposure: .deferred, toolNames: [TOOL_SEARCH_TOOL_NAME]) { session, _ in
            let turn = LockedState(0)
            session.agent.streamFn = { model, _, _ in
                let index = turn.withLock { $0 += 1; return $0 }
                return v104SelectionResponse(model, search: index == 1)
            }
            try await session.prompt("load")
            #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mcpAllowlistEntriesFilterRegisteredToolsAndResources() async throws {
        try await v104WithMcpSession(exposure: .codemode, toolNames: ["codemode", "mcp__docs__s*"],
                                    resources: true, toolExposure: ["shot": .direct]) { session, _ in
            let active = try await v104SelectionEventually { session.getActiveToolNames() == ["codemode", "mcp__docs__shot"] }
            #expect(active)
            let registered = Set(session.getAllToolNames())
            #expect(registered.isSuperset(of: ["mcp__docs__search", "mcp__docs__shot"]))
            #expect(!registered.contains("mcp__docs__fail"))
            #expect(!registered.contains(LIST_MCP_RESOURCES_TOOL))
            #expect(!registered.contains(LIST_MCP_RESOURCE_TEMPLATES_TOOL))
            #expect(!registered.contains(READ_MCP_RESOURCE_TOOL))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func excludesMcpToolsWithPatterns() async throws {
        try await v104WithMcpSession(exposure: .codemode, toolNames: ["codemode"],
                                    excludeTools: ["mcp__docs__f*"]) { session, _ in
            #expect(session.getAllToolNames().contains("mcp__docs__search"))
            #expect(!session.getAllToolNames().contains("mcp__docs__fail"))
        }
    }

    @Test
    func matchesAllowlistAndDenylistPatterns() async throws {
        // Port of regressions/5109-exclude-tools.test.ts:82-98.
        let extensionFactory = InlineExtension(name: "dynamic") { api in
            _ = api.on("session_start") { (_: SessionStartEvent, _: HookContext) -> Any? in
                _ = api.registerTool(v104SelectionTool("ask_question"))
                _ = api.registerTool(v104SelectionTool("dynamic_tool"))
                return nil
            }
        }
        let session = await v104SelectionSession(extensions: [extensionFactory],
            toolNames: ["*_tool", "ask_*", "re*"], excludeTools: ["ask*"])
        defer { session.dispose() }
        _ = await session.hookRunner?.emit(SessionStartEvent())
        #expect(session.getAllToolNames().sorted() == ["dynamic_tool", "read"])
        #expect(session.getActiveToolNames().sorted() == ["dynamic_tool", "read"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        ["*_tool"], ["static_tool", "live_tool", "custom_tool", "blocked_tool", "denied_tool"]
    ])
    func matchingNamesActivateNonDefaultToolsAtStartupRegistrationAndReload(toolNames: [String]) async {
        let extensionFactory = InlineExtension(name: "inactive") { api in
            _ = api.registerTool(v104SelectionTool("static_tool", defaultActive: false))
            _ = api.registerTool(v104SelectionTool("blocked_tool", defaultActive: false))
            _ = api.on("session_start") { (_: SessionStartEvent, _: HookContext) -> Any? in
                _ = api.registerTool(v104SelectionTool("live_tool", defaultActive: false))
                return nil
            }
        }
        let session = await v104SelectionSession(extensions: [extensionFactory], toolNames: toolNames,
            excludeTools: ["blocked*", "denied*"], customTools: [
                CustomToolDefinition(tool: v104SelectionTool("custom_tool", defaultActive: false)),
                CustomToolDefinition(tool: v104SelectionTool("denied_tool", defaultActive: false))
            ])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["custom_tool", "static_tool"])
        _ = await session.hookRunner?.emit(SessionStartEvent())
        #expect(session.getActiveToolNames().sorted() == ["custom_tool", "live_tool", "static_tool"])
        session.setActiveToolsByName([])
        let reloaded = await session.reloadExtensions()
        #expect(reloaded.errors.isEmpty)
        // A reload matches the allowlist again, even for a tool that was already registered.
        #expect(session.getActiveToolNames().sorted() == ["custom_tool", "live_tool", "static_tool"])
        #expect(!session.getAllToolNames().contains("blocked_tool"))
        #expect(!session.getAllToolNames().contains("denied_tool"))
    }

    @Test(.timeLimit(.minutes(1)))
    func extensionLoadoutCannotDeclareUnnamedDirectMcpTool() async throws {
        let capture = LockedState<HookAPI?>(nil)
        let extensionFactory = InlineExtension(name: "loadout") { api in capture.withLock { $0 = api } }
        try await v104WithMcpSession(exposure: .direct, toolNames: ["read"],
                                    extensions: [extensionFactory]) { session, _ in
            let api = try #require(capture.withLock { $0 })
            api.setActiveTools(["read", "mcp__docs__search"])
            #expect(session.getActiveToolNames() == ["read"])
            #expect(session.getAllToolNames().contains("mcp__docs__search"))
        }
    }
}
