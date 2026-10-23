import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private actor M1SlowServer {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private var loop: Task<Void, Never>?
    private var calls: [String] = []

    init() { (client, server) = InMemoryTransport.pair() }
    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let incoming = try? JsonRpc.decodeIncoming(data), case .request(let request) = incoming else { continue }
                await self.reply(request)
            }
        }
    }
    private func reply(_ request: JsonRpcRequest) async {
        let result: [String: Any]
        switch request.method {
        case "initialize":
            try? await Task.sleep(for: .milliseconds(40))
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "slow", "version": "1"]]
        case "tools/list":
            result = ["tools": [["name": "search", "description": "Search docs",
                "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]]]]]
        case "tools/call":
            let input = request.params?.value as? [String: Any]
            let arguments = input?["arguments"] as? [String: Any]
            calls.append("\(input?["name"] as? String ?? ""):\(arguments?["query"] as? String ?? "")")
            result = ["content": [["type": "text", "text": "found"]]]
        default: result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
    func called() -> [String] { calls }
    func close() async { loop?.cancel(); await server.close() }
}

private func m1Response(_ model: Model, code: String? = nil) -> AssistantMessageEventStream {
    let content: [ContentBlock] = code.map {
        [.toolCall(ToolCall(id: "m1-code", name: CODEMODE_TOOL_NAME, arguments: ["code": AnyCodable($0)]))]
    } ?? [.text(TextContent(text: "done"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: code == nil ? .stop : .toolUse)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

private func m1Session(_ fixture: M1SlowServer, directory: URL, extensions: [InlineExtension] = []) async throws -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let entry = McpServerEntry(name: "slow-docs", config: .init(command: "fixture", exposure: .codemode),
        source: "test", scope: .extension)
    let mcp = createMcpExtension(options: .init(agentDir: directory,
        loadConfig: { _ in LoadedMcpConfig(servers: [entry]) }, createTransport: { _, _, _ in fixture.client },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())))
    let created = try await createAgentSession(CreateAgentSessionOptions(cwd: directory.path,
        agentDir: directory.path, authStorage: auth, model: model, offline: true, noTools: .builtin,
        resourceLoader: TestResourceLoader(), inlineExtensions: extensions + [createCodemodeExtension(), mcp],
        sessionManager: .inMemory(directory.path), settingsManager: .inMemory()))
    let session = created.session
    session.agent.streamFn = { model, _, _ in m1Response(model) }
    _ = await session.hookRunner?.emit(SessionStartEvent())
    return session
}

// v1.3.0 agent-session-mcp.test.ts:693-728. The replacement's own callback is required.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func m1ReplacementCodemodeRequiresDeclaredReach(_ declaresReach: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m1-replacement-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = M1SlowServer()
    await fixture.start()
    let replacement = InlineExtension(name: "replacement") { api in
        var tool = CustomTool(name: CODEMODE_TOOL_NAME, label: "Code", description: "Replacement",
            parameters: ["type": AnyCodable("object")], execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: false)
        if declaresReach { tool.reachesTools = { _ in .all } }
        _ = api.registerTool(tool)
    }
    let session = try await m1Session(fixture, directory: directory, extensions: [replacement])
    try await session.prompt("start")
    #expect(session.getActiveToolNames() == (declaresReach ? [CODEMODE_TOOL_NAME] : []))
    _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
    session.dispose()
    await fixture.close()
}

// v1.3.0 agent-session-mcp.test.ts:855-875. Keep the array output and one search call.
@Test(.timeLimit(.minutes(1))) func m1DelayedServerResolvesAllFourNamespaceAliases() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m1-aliases-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = M1SlowServer()
    await fixture.start()
    let session = try await m1Session(fixture, directory: directory)
    let turn = LockedState(0)
    session.agent.streamFn = { model, _, _ in
        let first = turn.withLock { $0 += 1; return $0 == 1 }
        return m1Response(model, code: first ? """
        await tools.mcp__slow_docs__search({query:'q'});
        const names=['slow-docs','slow_docs','mcp__slow-docs','mcp__slow_docs'];
        return [...new Set(await Promise.all(names.map(async name=>(await describeNamespace(name))?.name)))];
        """ : nil)
    }
    try await session.prompt("go")
    let result = try #require(session.agent.messages.compactMap { message -> ToolResultMessage? in
        if case .toolResult(let value) = message, value.toolName == CODEMODE_TOOL_NAME { return value }
        return nil
    }.first)
    #expect(!result.isError)
    let output = result.content.compactMap { if case .text(let text) = $0 { return text.text }; return nil }.joined(separator: "\n")
    #expect(output.components(separatedBy: "\n").last == "[\"mcp__slow_docs\"]")
    #expect(await fixture.called() == ["search:q"])
    #expect(session.getAllTools().contains { $0.name == "mcp__slow_docs__search" })
    _ = await session.hookRunner?.emit(SessionShutdownEvent(reason: .quit))
    session.dispose()
    await fixture.close()
}
