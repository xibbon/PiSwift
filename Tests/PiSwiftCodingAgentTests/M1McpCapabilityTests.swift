import Foundation
import Testing
import PiSwiftAI
import PiSwiftMCP
@testable import PiSwiftCodingAgent

private actor M1ResourceServer {
    nonisolated let client: InMemoryTransport
    private let server: InMemoryTransport
    private var loop: Task<Void, Never>?
    private var methods: [String] = []

    init() { (client, server) = InMemoryTransport.pair() }
    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.server.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }
    func received() -> [String] { methods }
    func notify() async throws {
        for method in ["notifications/resources/list_changed", "notifications/resources/templates/list_changed"] {
            try await server.send(JsonRpc.encodeNotificationToLine(JsonRpcNotification(method: method)))
        }
    }
    func close() async { loop?.cancel(); await server.close() }
    private func reply(_ request: JsonRpcRequest) async {
        methods.append(request.method)
        let result: [String: Any]
        switch request.method {
        case "initialize":
            result = ["protocolVersion": LATEST_PROTOCOL_VERSION,
                "capabilities": ["tools": [:], "resources": [:]], "serverInfo": ["name": "m1", "version": "1"]]
        case "tools/list": result = ["tools": []]
        case "resources/list":
            let cursor = (request.params?.value as? [String: Any])?["cursor"] as? String
            result = cursor == nil
                ? ["resources": [["uri": "docs://one", "name": "one"]], "nextCursor": "page2"]
                : ["resources": [["uri": "docs://two", "name": "two"]]]
        case "resources/templates/list": result = ["resourceTemplates": []]
        default: result = ["content": []]
        }
        try? await server.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: AnyCodable(result), error: nil)))
    }
}

// v1.3.0 coding-agent/test/mcp-extension.test.ts:791, plus explicit pagination.
@Test(.timeLimit(.minutes(1))) func m1ConnectUsesResourceCapabilityWithoutListing() async throws {
    let server = M1ResourceServer()
    await server.start()
    let entry = McpServerEntry(name: "docs", config: .init(command: "fixture"), source: "test", scope: .extension)
    let connection = McpServerConnection(entry: entry, cwd: FileManager.default.temporaryDirectory,
        createTransport: { _, _, _ in server.client },
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
    try await connection.connect()
    #expect(await connection.state == .connected)
    #expect(await connection.hasResources)
    #expect(await server.received() == ["initialize", "tools/list"])
    try await server.notify()
    _ = try await connection.callTool(name: "barrier", arguments: [:])
    try await Task.sleep(for: .milliseconds(20))
    #expect(await server.received() == ["initialize", "tools/list", "tools/call"])
    #expect(try await connection.allResources().map(\.uri) == ["docs://one", "docs://two"])
    #expect(await server.received().suffix(2) == ["resources/list", "resources/list"])
    await connection.close()
    await server.close()
}

private func m1ReportData(_ fields: String) -> Data {
    Data("""
    {"name":"docs","source":"test","scope":"extension","enabled":true,"exposure":"codemode","transport":"fixture","state":"connected","tools":[]\(fields)}
    """.utf8)
}

@Test(arguments: ["", ",\"resources\":false", ",\"resources\":0,\"resourceTemplates\":0"])
func m1ReportOmitsUnconfirmedResourceCapability(_ fields: String) throws {
    let report = try JSONDecoder().decode(McpServerListReport.self, from: m1ReportData(fields))
    #expect(!report.hasResources)
    let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(value["resources"] == nil)
    #expect(value["resourceTemplates"] == nil)
}

@Test(arguments: [",\"resources\":true", ",\"resources\":3,\"resourceTemplates\":0", ",\"resources\":0,\"resourceTemplates\":2"])
func m1ReportReadsLegacyCountsAndWritesOnlyCapability(_ fields: String) throws {
    let report = try JSONDecoder().decode(McpServerListReport.self, from: m1ReportData(fields))
    #expect(report.hasResources)
    let data = try JSONEncoder().encode(report)
    let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(value["resources"] as? Bool == true)
    #expect(value["resourceTemplates"] == nil)
    #expect(try JSONDecoder().decode(McpServerListReport.self, from: data).hasResources)
}

@Test func m1ReachMatchesServerNamesOwnersAndDeclaredAliases() {
    let tools = [ToolInfo(name: "custom-doc-search", description: "Docs",
        namespace: ToolNamespace(name: "docs-api", aliases: ["reference-guide"]))]
    #expect(mcpReachNeedsServer(.all, server: "slow-docs"))
    for word in ["slow-docs", "slow_docs", "mcp__slow-docs", "mcp__slow_docs", "mcp__slow_docs__search"] {
        #expect(mcpReachNeedsServer(.words([word]), server: "slow-docs"))
    }
    for word in ["custom-doc-search", "custom_doc_search", "docs-api", "docs_api", "reference-guide", "reference_guide"] {
        #expect(mcpReachNeedsServer(.words([word]), server: "slow-docs", tools: tools))
    }
    #expect(!mcpReachNeedsServer(.words([]), server: "slow-docs", tools: tools))
    #expect(!mcpReachNeedsServer(.words(["unrelated"]), server: "slow-docs", tools: tools))
}

@Test func m1LegacyReportAccessorsKeepSuppliedCounts() throws {
    var report = try JSONDecoder().decode(McpServerListReport.self,
        from: m1ReportData(",\"resources\":3,\"resourceTemplates\":2"))
    #expect(report.resources == 3)
    #expect(report.resourceTemplates == 2)
    report.resources = 4
    report.resourceTemplates = 5
    #expect(report.resources == 4)
    #expect(report.resourceTemplates == 5)
    #expect(report.hasResources)
    let value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(value["resources"] as? Bool == true)
    #expect(value["resourceTemplates"] == nil)
    #expect(value["hasResources"] == nil)
}
