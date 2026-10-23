import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private let m1ContentDeclaration = #"content: Array<{ data?: string; mimeType?: string; text?: string; type: "text" | "image" | "audio" | "resource_link" | "resource"; [key: string]: unknown; }>; isError?: boolean;"#

// v1.3.0 packages/coding-agent/test/mcp-extension.test.ts:282.
@Test func m1McpResultDeclaresCompletePlainSchema() throws {
    let schema = mcpResultSchema(nil)
    #expect(renderToolOutputType(AnyCodable(schema.mapValues(\.value))) ==
        "{ \(m1ContentDeclaration) structuredContent?: unknown; [key: string]: unknown; }")
    let properties = try #require(schema["properties"]?.value as? [String: Any])
    #expect(properties["_meta"] == nil)
    #expect(AnyCodable(try #require(properties["structuredContent"])) == AnyCodable([String: Any]()))
    #expect(schema["required"] == AnyCodable(["content"]))
    #expect(schema["additionalProperties"] == AnyCodable(true))
}

@Test func m1McpResultRelocatesSchemaReferences() throws {
    let hit: [String: Any] = ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
    var definition = hit
    definition["default"] = ["$ref": "#/stays"]
    let schema = mcpResultSchema(AnyCodable([
        "type": "object",
        "properties": [
            "hits": ["type": "array", "items": ["$ref": "#/$defs/Hit~1v1"]],
            "again": ["$ref": "#/properties/hits"],
            "children": ["type": "array", "items": ["$ref": "#"]],
            "default": ["$ref": "#/definitions/Hit"],
            "remote": ["$ref": "https://example.com/schema.json"],
        ],
        "required": ["hits"], "$defs": ["Hit/v1": definition], "definitions": ["Hit": hit],
    ] as [String: Any]))
    let expected = "{ \(m1ContentDeclaration) structuredContent?: { again?: Array<{ id: string; }>; children?: Array<{ again?: Array<{ id: string; }>; children?: Array<unknown>; default?: { id: string; }; hits: Array<{ id: string; }>; remote?: unknown; }>; default?: { id: string; }; hits: Array<{ id: string; }>; remote?: unknown; }; [key: string]: unknown; }"
    #expect(renderToolOutputType(AnyCodable(schema.mapValues(\.value))) == expected)
    let properties = try #require(schema["properties"]?.value as? [String: Any])
    let structured = try #require(properties["structuredContent"] as? [String: Any])
    let definitions = try #require(structured["$defs"] as? [String: Any])
    let relocatedHit = try #require(definitions["Hit/v1"] as? [String: Any])
    #expect(AnyCodable(try #require(relocatedHit["default"])) == AnyCodable(["$ref": "#/stays"]))
}

@Test func m1McpResultRelocationKeepsDataAndSchemaMapNames() throws {
    let data: [String: Any] = ["$ref": "#/data"]
    var input: [String: Any] = ["$ref": "#", "const": data, "enum": [data], "default": data, "examples": [data],
        "allOf": [["$ref": "#/definitions/a~1b~0c"]], "items": ["$ref": "https://example.com/#/remote"],
        "contains": ["$ref": "#anchor"]]
    let mapKeywords = ["properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"]
    for keyword in mapKeywords { input[keyword] = ["default": ["$ref": "#/definitions/a~1b~0c"]] }
    let result = mcpResultSchema(AnyCodable(input))
    let properties = try #require(result["properties"]?.value as? [String: Any])
    let structured = try #require(properties["structuredContent"] as? [String: Any])
    #expect(structured["$ref"] as? String == "#/properties/structuredContent")
    for keyword in ["const", "enum", "default", "examples"] {
        #expect(AnyCodable(try #require(structured[keyword])) == AnyCodable(try #require(input[keyword])))
    }
    for keyword in mapKeywords {
        let map = try #require(structured[keyword] as? [String: Any])
        #expect(AnyCodable(try #require(map["default"])) ==
            AnyCodable(["$ref": "#/properties/structuredContent/definitions/a~1b~0c"]))
    }
    #expect(AnyCodable(try #require(structured["allOf"])) ==
        AnyCodable([["$ref": "#/properties/structuredContent/definitions/a~1b~0c"]]))
    #expect(AnyCodable(try #require(structured["items"])) == AnyCodable(["$ref": "https://example.com/#/remote"]))
    #expect(AnyCodable(try #require(structured["contains"])) == AnyCodable(["$ref": "#anchor"]))
}

// v1.3.0 packages/coding-agent/test/mcp-extension.test.ts:337-344.
@Test(arguments: [AnyCodable([["id": 1]]), AnyCodable(NSNull()), AnyCodable("text"), AnyCodable(3), AnyCodable(false)])
func m1McpConversionKeepsAnyStructuredJSON(_ value: AnyCodable) async throws {
    let raw = AnyCodable(["content": [], "structuredContent": value.value, "_meta": ["trace": "x"], "future": "kept"])
    let result = await convertMcpResult(server: "docs", tool: "search", result:
        McpToolResult(content: [], structuredContent: value, rawResult: raw))
    let scriptResult = try #require(result.structuredContent?.value as? [String: Any])
    #expect(AnyCodable(try #require(scriptResult["structuredContent"])) == value)
    #expect(scriptResult["_meta"] == nil)
    #expect(scriptResult["future"] as? String == "kept")
    #expect((scriptResult["content"] as? [Any])?.isEmpty == true)
    let text = try #require(result.content.first)
    guard case .text(let text) = text else { Issue.record("Expected JSON text"); return }
    #expect(try JSONDecoder().decode(AnyCodable.self, from: Data(text.text.utf8)) == value)
    let fallback = await convertMcpResult(server: "docs", tool: "search", result:
        McpToolResult(content: [], isError: true, structuredContent: value))
    let fallbackResult = try #require(fallback.structuredContent?.value as? [String: Any])
    #expect(AnyCodable(try #require(fallbackResult["structuredContent"])) == value)
    #expect(fallbackResult["isError"] as? Bool == true)
    #expect(fallback.isError == true)
}

private actor M1DeclarationServer {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private var loop: Task<Void, Never>?

    init() { (client, server) = InMemoryTransport.pair() }
    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }
    private func reply(_ request: JsonRpcRequest) async {
        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "declarations", "version": "1"]]
        case "tools/list":
            result = ["tools": [
                ["name": "search", "description": "Search docs.", "inputSchema": ["type": "object"],
                    "outputSchema": ["type": "object", "properties": ["hits": ["type": "array", "items": ["type": "string"]]], "required": ["hits"]]],
                ["name": "fail", "description": "Fail.", "inputSchema": ["type": "object"]],
            ]]
        default: result = [:]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(JsonRpcServerResponse(id: request.id,
            result: AnyCodable(result), error: nil)))
    }
    func close() async { loop?.cancel(); await server.close() }
}

private func m1DeclarationContext() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
}

// v1.3.0 packages/coding-agent/test/suite/agent-session-mcp.test.ts:680.
@Test(.timeLimit(.minutes(1))) func m1SessionDescribesDirectMcpResults() async throws {
    let fixture = M1DeclarationServer()
    await fixture.start()
    let manager = SessionManager.inMemory()
    let bus = createEventBus()
    let entry = McpServerEntry(name: "docs", config: .init(url: "http://127.0.0.1/mcp", exposure: .direct, timeout: 3), source: "test", scope: .extension)
    let extensions = [createCodemodeExtension(), createMcpExtension(options: .init(
        agentDir: FileManager.default.temporaryDirectory, loadConfig: { _ in .init(servers: [entry]) },
        createTransport: { _, _, _ in fixture.client },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())))]
    let hooks = try extensions.map { try #require(ExtensionLoader.load($0, cwd: manager.getCwd(), eventBus: bus).hook) }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let registry = ModelRegistry(auth)
    let runner = HookRunner(hooks, manager.getCwd(), manager, registry)
    let definitions = runner.getExtensionTools()
    let tools = definitions.map { wrapToolWithHooks(wrapCustomTool($0) { m1DeclarationContext() }, runner) }
    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: { model, _, _ in
        let stream = AssistantMessageEventStream()
        let message = AssistantMessage(content: [.text(TextContent(text: "ready"))], api: model.api, provider: model.provider,
            model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }, getApiKey: { _ in "test" }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        systemPromptOptions: BuildSystemPromptOptions(cwd: manager.getCwd(), contextFiles: [], skills: []),
        hookRunner: runner, modelRegistry: registry,
        toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
        toolDefinitions: Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) }),
        wrapExtensionTools: { tools in tools.map { wrapToolWithHooks(wrapCustomTool($0) { m1DeclarationContext() }, runner) } }))
    defer { session.dispose() }
    _ = await runner.emit(SessionStartEvent())
    try await session.prompt("start")
    session.setActiveToolsByName(session.getActiveToolNames() + [CODEMODE_TOOL_NAME])
    let declared = session.agent.state.tools
    #expect(declared.first { $0.name == "mcp__docs__search" }?.description ==
        "Search docs.\n\nCodemode: `tools.mcp__docs__search(args)` resolves to `{ content, isError?, structuredContent?: { hits } }`.")
    #expect(declared.first { $0.name == "mcp__docs__fail" }?.description ==
        "Fail.\n\nCodemode: `tools.mcp__docs__fail(args)` resolves to `{ content, isError?, structuredContent? }`.")
    _ = await runner.emit(SessionShutdownEvent(reason: .quit))
    await fixture.close()
}
