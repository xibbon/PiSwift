import Foundation
import Testing
import PiSwiftAI
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private actor ResourceFixture {
    let transport: InMemoryTransport
    private var task: Task<Void, Never>?

    init(_ transport: InMemoryTransport) { self.transport = transport }

    func start() {
        task = Task { [weak self] in
            while let self, let data = try? await self.transport.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(to: request)
            }
        }
    }

    func close() async { task?.cancel(); await transport.close() }

    private func reply(to request: JsonRpcRequest) async {
        let cursor = (request.params?.value as? [String: Any])?["cursor"] as? String
        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                      "capabilities": ["resources": ["listChanged": true]],
                      "serverInfo": ["name": "fixture", "version": "1"]]
        case "resources/list":
            if cursor == "next" {
                result = ["resources": [["uri": "file:///second", "name": "second"]]]
            } else {
                result = ["resources": [["uri": "file:///first", "name": "first"],
                                        ["uri": "ui://panel", "name": "app"]], "nextCursor": "next"]
            }
        case "resources/templates/list":
            result = ["resourceTemplates": [["uriTemplate": "file:///{name}", "name": "files"],
                                            ["uriTemplate": "ui://{name}", "name": "app"]]]
        case "resources/read":
            result = ["contents": [["uri": "file:///first", "text": "one"],
                                   ["uri": "file:///second", "text": "two"]]]
        default:
            result = [:]
        }
        try? await transport.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

private func mcpResourceContext() -> CustomToolContext {
    CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
}

@Test func mcpAppResourceFilterCoversUrisAndProfiles() {
    #expect(isMcpAppResource(uri: "ui://panel", mimeType: nil))
    #expect(isMcpAppResource(uri: "file:///a", mimeType: "text/html; profile=mcp-app"))
    #expect(isMcpAppResource(uri: "file:///a", mimeType: "text/html; PROFILE=\"mcp-app\""))
    #expect(!isMcpAppResource(uri: "file:///a", mimeType: "text/html"))
}

@Test(.timeLimit(.minutes(1))) func mcpResourceToolsPageFilterAndRead() async throws {
    let (client, serverTransport) = InMemoryTransport.pair()
    let fixture = ResourceFixture(serverTransport)
    await fixture.start()
    defer { Task { await fixture.close() } }
    let entry = McpServerEntry(name: "docs",
        config: McpServerConfig(url: "http://127.0.0.1/mcp", headers: ["Authorization": "fixture"]),
        source: "fixture", scope: .extension)
    let connection = McpServerConnection(entry: entry, cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, _ in client },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
    try await connection.connect()
    defer { Task { await connection.close() } }
    let tools = createMcpResourceToolDefinitions(exposure: .direct, servers: { [connection] })
    #expect(tools.map(\.name) == [LIST_MCP_RESOURCES_TOOL, LIST_MCP_RESOURCE_TEMPLATES_TOOL, READ_MCP_RESOURCE_TOOL])
    #expect(tools.allSatisfy { $0.annotations?.readOnlyHint == true && $0.outputSchema != nil })

    let context = mcpResourceContext()
    let first = try await tools[0].execute("list", ["server": AnyCodable("docs")], nil, context, nil)
    let firstPayload = try #require(first.structuredContent?.value as? [String: Any])
    #expect(firstPayload["nextCursor"] as? String == "next")
    let firstItems = try #require(firstPayload["resources"] as? [[String: Any]])
    #expect(firstItems.map { $0["uri"] as? String } == ["file:///first"])
    let second = try await tools[0].execute("page", ["server": AnyCodable("docs"), "cursor": AnyCodable("next")], nil, context, nil)
    let secondPayload = try #require(second.structuredContent?.value as? [String: Any])
    let secondItems = try #require(secondPayload["resources"] as? [[String: Any]])
    #expect(secondItems.map { $0["uri"] as? String } == ["file:///second"])
    await #expect(throws: McpResourceToolError.self) {
        try await tools[0].execute("bad", ["cursor": AnyCodable("next")], nil, context, nil)
    }
    let all = try await tools[0].execute("all", [:], nil, context, nil)
    let allPayload = try #require(all.structuredContent?.value as? [String: Any])
    let allItems = try #require(allPayload["resources"] as? [[String: Any]])
    #expect(allItems.count == 2)

    let templates = try await tools[1].execute("templates", ["server": AnyCodable("docs")], nil, context, nil)
    let templatesPayload = try #require(templates.structuredContent?.value as? [String: Any])
    #expect((templatesPayload["resourceTemplates"] as? [[String: Any]])?.count == 1)

    let read = try await tools[2].execute("read", ["server": AnyCodable("docs"), "uri": AnyCodable("file:///first")], nil, context, nil)
    let readPayload = try #require(read.structuredContent?.value as? [String: Any])
    #expect((readPayload["contents"] as? [[String: Any]])?.count == 2)
    let modelText = read.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
    #expect(modelText.contains("file:///first:"))
    #expect(modelText.contains("one"))
}
