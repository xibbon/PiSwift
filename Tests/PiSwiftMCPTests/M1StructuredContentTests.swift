import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftMCP

private actor M1StructuredServer {
    let transport: InMemoryTransport
    private var loop: Task<Void, Never>?
    private var result: AnyCodable
    private let schema: AnyCodable?

    init(_ transport: InMemoryTransport, result: AnyCodable, schema: AnyCodable?) {
        self.transport = transport
        self.result = result
        self.schema = schema
    }

    func setResult(_ result: AnyCodable) { self.result = result }

    func start() {
        loop = Task { [weak self] in
            while let self, let data = try? await self.transport.receive() {
                guard let message = try? JsonRpc.decodeIncoming(data), case .request(let request) = message else { continue }
                await self.reply(request)
            }
        }
    }

    private func reply(_ request: JsonRpcRequest) async {
        let response: AnyCodable
        switch request.method {
        case "initialize":
            response = AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "structured", "version": "1"]] as [String: Any])
        case "tools/list":
            var tool: [String: Any] = ["name": "structured", "inputSchema": ["type": "object"]]
            if let schema { tool["outputSchema"] = schema.value }
            response = AnyCodable(["tools": [tool]])
        default:
            response = result
        }
        try? await transport.send(JsonRpc.encodeServerResponseToLine(
            JsonRpcServerResponse(id: request.id, result: response, error: nil)))
    }

    func close() async { loop?.cancel(); await transport.close() }
}

private func m1StructuredClient(_ result: AnyCodable, schema: AnyCodable? = nil) async throws -> (McpClient, M1StructuredServer) {
    let (clientTransport, serverTransport) = InMemoryTransport.pair()
    let server = M1StructuredServer(serverTransport, result: result, schema: schema)
    await server.start()
    let client = McpClient(requestTimeoutMs: 2_000)
    try await client.connect(transport: clientTransport)
    return (client, server)
}

private func m1StructuredTexts(_ content: [ContentBlock]) -> [String] {
    content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }
}

// v1.3.0 packages/mcp/test/client.test.ts:284.
@Test(.timeLimit(.minutes(1)), arguments: [AnyCodable([["id": 1], ["id": 2]]), AnyCodable(NSNull()),
    AnyCodable("text"), AnyCodable(3), AnyCodable(false)])
func m1ClientAcceptsAnyStructuredJSON(_ value: AnyCodable) async throws {
    let (client, server) = try await m1StructuredClient(AnyCodable(["content": [], "structuredContent": value.value]))
    let result = try await client.callTool(name: "structured")
    #expect(result.content.isEmpty)
    #expect(result.structuredContent == value)
    #expect(result.rawResult == AnyCodable(["content": [], "structuredContent": value.value]))
    await client.close()
    await server.close()
}

@Test(.timeLimit(.minutes(1))) func m1ClientKeepsNullSeparateFromAbsentStructuredContent() async throws {
    let (client, server) = try await m1StructuredClient(AnyCodable(["structuredContent": NSNull()]))
    let explicitNull = try await client.callTool(name: "structured")
    #expect(explicitNull.structuredContent == AnyCodable(NSNull()))
    #expect(explicitNull.content.isEmpty)
    let encoded = try JSONEncoder().encode(try #require(explicitNull.rawResult))
    let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
    #expect((decoded.value as? [String: Any])?["structuredContent"] is NSNull)
    await server.setResult(AnyCodable(["content": []]))
    let absent = try await client.callTool(name: "structured")
    #expect(absent.structuredContent == nil)
    #expect((absent.rawResult?.value as? [String: Any])?["structuredContent"] == nil)
    await client.close()
    await server.close()
}

@Test(.timeLimit(.minutes(1))) func m1ClientRetainsContentAndOutputSchemaValidation() async throws {
    let schema = AnyCodable(["type": "array", "items": ["type": "integer"]] as [String: Any])
    let (client, server) = try await m1StructuredClient(AnyCodable(["content": [], "structuredContent": [1, 2]]), schema: schema)
    _ = try await client.listAllTools()
    #expect(try await client.callTool(name: "structured").structuredContent == AnyCodable([1, 2]))
    await server.setResult(AnyCodable(["content": [], "structuredContent": ["invalid"]]))
    await #expect(throws: McpError.self) { _ = try await client.callTool(name: "structured") }
    await server.setResult(AnyCodable(["content": "invalid", "structuredContent": [1]]))
    await #expect(throws: McpError.self) { _ = try await client.callTool(name: "structured") }
    await server.setResult(AnyCodable(["content": [["text": "missing type"]], "structuredContent": [1]]))
    await #expect(throws: DecodingError.self) { _ = try await client.callTool(name: "structured") }
    await client.close()
    await server.close()
}

// v1.3.0 packages/mcp/test/content.test.ts:26-33, plus Swift JSON fragments.
@Test(arguments: [(AnyCodable([1, 2]), "[\n  1,\n  2\n]"), (AnyCodable(NSNull()), "null"),
    (AnyCodable("text"), "\"text\""), (AnyCodable(3), "3"), (AnyCodable(false), "false"),
    (AnyCodable(["n": 1]), "{\n  \"n\" : 1\n}")])
func m1StructuredFallbackUsesJSON(_ value: AnyCodable, expected: String) {
    let result = McpToolResult(content: [], structuredContent: value)
    #expect(m1StructuredTexts(toLlmContent(result)) == [expected])
    #expect(m1StructuredTexts(resolveMcpResultContent(result)) == [expected])
    let withText = McpToolResult(content: [McpContent(type: "text", text: "original")], structuredContent: value)
    #expect(m1StructuredTexts(toLlmContent(withText)) == ["original"])
    #expect(m1StructuredTexts(resolveMcpResultContent(withText)) == ["original"])
}
