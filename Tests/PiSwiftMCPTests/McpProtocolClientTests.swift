import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftMCP

private extension ContentBlock {
    var textContent: TextContent? {
        if case .text(let text) = self { return text }
        return nil
    }
}

private actor TestServer {
    typealias Handler = @Sendable (JsonRpcRequest) async throws -> AnyCodable
    let transport: InMemoryTransport
    private var handlers: [String: Handler] = [:]
    private var messages: [JsonRpcIncomingMessage] = []
    private var loop: Task<Void, Never>?

    init(transport: InMemoryTransport) { self.transport = transport }

    func setHandler(_ method: String, _ handler: @escaping Handler) { handlers[method] = handler }

    func start() {
        loop = Task { [weak self] in
            while let data = try? await self?.transport.receive() {
                guard let self, let message = try? JsonRpc.decodeIncoming(data) else { continue }
                await self.record(message)
                if case .request(let request) = message {
                    Task { await self.respond(request) }
                }
            }
        }
    }

    func close() async { loop?.cancel(); await transport.close() }
    func receivedMethods() -> [String] {
        messages.compactMap { message in
            switch message {
            case .request(let request): request.method
            case .notification(let notification): notification.method
            case .response: nil
            }
        }
    }
    func firstRequest(_ method: String) -> JsonRpcRequest? {
        for message in messages {
            if case .request(let request) = message, request.method == method { return request }
        }
        return nil
    }
    func firstResponse(_ id: JsonRpcId) -> JsonRpcResponse? {
        for message in messages {
            if case .response(let response) = message, response.id == id { return response }
        }
        return nil
    }

    private func record(_ message: JsonRpcIncomingMessage) { messages.append(message) }
    private func respond(_ request: JsonRpcRequest) async {
        guard let handler = handlers[request.method] else { return }
        do {
            let result = try await handler(request)
            let response = JsonRpcServerResponse(id: request.id, result: result, error: nil)
            try await transport.send(JsonRpc.encodeServerResponseToLine(response))
        } catch let error as McpError {
            let rpc: JsonRpcError
            if case .rpcError(let code, let message) = error {
                rpc = JsonRpcError(code: code, message: message)
            } else {
                rpc = JsonRpcError(code: -32603, message: String(describing: error))
            }
            let response = JsonRpcServerResponse(id: request.id, result: nil, error: rpc)
            try? await transport.send(JsonRpc.encodeServerResponseToLine(response))
        } catch {
            let response = JsonRpcServerResponse(id: request.id, result: nil, error: JsonRpcError(code: -32603, message: String(describing: error)))
            try? await transport.send(JsonRpc.encodeServerResponseToLine(response))
        }
    }
}

private func connectedServer(version: String = LATEST_PROTOCOL_VERSION) async throws -> (McpClient, TestServer) {
    let (clientTransport, serverTransport) = InMemoryTransport.pair()
    let server = TestServer(transport: serverTransport)
    await server.setHandler("initialize") { _ in
        AnyCodable(["protocolVersion": version, "capabilities": ["tools": [:]], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
    }
    await server.start()
    let client = McpClient(requestTimeoutMs: 1_000)
    try await client.connect(transport: clientTransport)
    return (client, server)
}

@Suite("MCP protocol and client") struct McpProtocolClientTests {
    @Test("JSON-RPC accepts string and number IDs and rejects malformed messages")
    func jsonRpcIDs() throws {
        let string = try JsonRpc.decodeIncoming(Data(#"{"jsonrpc":"2.0","id":"roots","method":"roots/list"}"#.utf8))
        guard case .request(let request) = string else { Issue.record("Expected request"); return }
        #expect(request.id == .string("roots"))
        let number = try JsonRpc.decodeIncoming(Data(#"{"jsonrpc":"2.0","id":1.5,"result":{}}"#.utf8))
        guard case .response(let response) = number else { Issue.record("Expected response"); return }
        #expect(response.id == .number(1.5))
        #expect(throws: (any Error).self) {
            try JsonRpc.decodeIncoming(Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8))
        }
    }

    @Test("Negotiates the current and oldest supported versions", .timeLimit(.minutes(1)))
    func versions() async throws {
        let (client, server) = try await connectedServer(version: "2024-11-05")
        #expect(await client.negotiatedProtocolVersion() == "2024-11-05")
        let initRequest = await server.firstRequest("initialize")
        let params = initRequest?.params?.value as? [String: Any]
        #expect(params?["protocolVersion"] as? String == LATEST_PROTOCOL_VERSION)
        await client.close(); await server.close()

        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let unsupported = TestServer(transport: serverTransport)
        await unsupported.setHandler("initialize") { _ in
            AnyCodable(["protocolVersion": "1999-01-01", "capabilities": [:], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
        }
        await unsupported.start()
        let rejected = McpClient(requestTimeoutMs: 1_000)
        await #expect(throws: (any Error).self) { try await rejected.connect(transport: clientTransport) }
        await unsupported.close()
    }

    @Test("Preserves tool metadata and lists resource templates", .timeLimit(.minutes(1)))
    func toolsAndTemplates() async throws {
        let (client, server) = try await connectedServer()
        await server.setHandler("tools/list") { _ in
            AnyCodable(["tools": [["name": "search", "inputSchema": ["type": "object"], "outputSchema": ["type": "object"], "annotations": ["readOnlyHint": true], "execution": ["taskSupport": "optional"]]]] as [String: Any])
        }
        await server.setHandler("resources/templates/list") { _ in
            AnyCodable(["resourceTemplates": [["uriTemplate": "repo://{owner}/{repo}"]]] as [String: Any])
        }
        let tools = try await client.listAllTools()
        #expect(tools.first?.annotations?.readOnlyHint == true)
        #expect(tools.first?.execution?.taskSupport == "optional")
        let templates = try await client.listAllResourceTemplates()
        #expect(templates.first?.name == "repo://{owner}/{repo}")
        await client.close(); await server.close()
    }

    @Test("Replies to roots/list with a string request ID", .timeLimit(.minutes(1)))
    func roots() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let server = TestServer(transport: serverTransport)
        await server.setHandler("initialize") { _ in
            AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": [:], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
        }
        await server.start()
        let client = McpClient(requestTimeoutMs: 1_000, roots: [McpRoot(uri: "file:///workspace", name: "workspace")])
        try await client.connect(transport: clientTransport)
        try await serverTransport.send(JsonRpc.encodeToLine(JsonRpcRequest(id: .string("roots"), method: "roots/list")))
        try await Task.sleep(for: .milliseconds(30))
        guard let decoded = await server.firstResponse(.string("roots")) else {
            Issue.record("Expected roots/list response"); await client.close(); await server.close(); return
        }
        #expect(decoded.id == .string("roots"))
        let object = decoded.result?.value as? [String: Any]
        let roots = object?["roots"] as? [[String: Any]]
        #expect(roots?.first?["uri"] as? String == "file:///workspace")
        await client.close(); await server.close()
    }
}

private actor ProgressRecorder {
    var updates: [Double] = []
    func record(_ progress: McpProgressNotification) { updates.append(progress.progress) }
}

private actor RootStore {
    private var roots = [McpRoot(uri: "file:///first")]
    func value() -> [McpRoot] { roots }
    func update() { roots = [McpRoot(uri: "file:///second")] }
}

@Suite("MCP progress and content") struct McpProgressContentTests {
    @Test("Progress renews the request timeout and cancellation notifies the server", .timeLimit(.minutes(1)))
    func progressAndCancellation() async throws {
        let (client, server) = try await connectedServer()
        await server.setHandler("tools/call") { request in
            let params = request.params?.value as? [String: Any]
            let name = params?["name"] as? String
            if name == "wait" {
                try await Task.sleep(for: .seconds(2))
                return AnyCodable(["content": []] as [String: Any])
            }
            let meta = params?["_meta"] as? [String: Any]
            let token = meta?["progressToken"] as? Int ?? -1
            try await Task.sleep(for: .milliseconds(200))
            let update = JsonRpcNotification(method: "notifications/progress", params: AnyCodable(["progressToken": token, "progress": 1, "total": 2]))
            try await server.transport.send(JsonRpc.encodeNotificationToLine(update))
            try await Task.sleep(for: .milliseconds(200))
            return AnyCodable(["content": [["type": "text", "text": "done"]]] as [String: Any])
        }
        // Each step (200 ms) is shorter than the timeout (300 ms), the call (400 ms) is longer, so it
        // succeeds only if progress renews the timeout. Wider than the first 35/50 ms values, which flaked.
        let recorder = ProgressRecorder()
        let result = try await client.callTool(name: "slow", timeoutMs: 300, onProgress: { update in
            await recorder.record(update)
        })
        #expect(result.content.first?.text == "done")
        #expect(await recorder.updates == [1])

        let signal = CancellationToken()
        let pending = Task { try await client.callTool(name: "wait", signal: signal) }
        try await Task.sleep(for: .milliseconds(30))
        signal.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await server.receivedMethods().contains("notifications/cancelled"))
        await client.close(); await server.close()
    }

    @Test("Converts content blocks and falls back to structured content")
    func content() throws {
        let result = McpToolResult(content: [
            McpContent(type: "text", text: "hello"),
            McpContent(type: "image", data: "aW1n", mimeType: "image/png"),
            McpContent(type: "audio", data: "YXVk", mimeType: "audio/wav"),
            McpContent(type: "resource_link", uri: "file:///a.txt", name: "a.txt"),
            McpContent(type: "resource", resource: McpResourceContent(uri: "file:///b.txt", text: "inline")),
            McpContent(type: "resource", resource: McpResourceContent(uri: "file:///c.png", blob: "Yw==", mimeType: "image/png")),
            McpContent(type: "resource", resource: McpResourceContent(uri: "file:///d.bin", blob: "ZA==")),
        ])
        let content = toLlmContent(result)
        #expect(content.count == 7)
        #expect(content[0].textContent?.text == "hello")
        #expect(content[2].textContent?.text == "[audio audio/wav omitted]")
        #expect(content[3].textContent?.text == "a.txt: file:///a.txt")
        #expect(content[4].textContent?.text == "inline")
        #expect(content[6].textContent?.text == "[binary resource file:///d.bin (unknown type) omitted]")
        let fallback = toLlmContent(McpToolResult(content: [], structuredContent: AnyCodable(["n": 1])))
        #expect(fallback.first?.textContent?.text == "{\n  \"n\" : 1\n}")
    }
}

private actor EventRecorder {
    var count = 0
    var methods: [String] = []
    func closed() { count += 1 }
    func received(_ method: String) { methods.append(method) }
}

@Suite("MCP upstream client cases") struct McpUpstreamClientTests {
    @Test("Requests a supported older version and loads roots for each request", .timeLimit(.minutes(1)))
    func requestedVersionAndDynamicRoots() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let server = TestServer(transport: serverTransport)
        await server.setHandler("initialize") { _ in
            AnyCodable(["protocolVersion": "2025-03-26", "capabilities": [:], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
        }
        await server.start()
        let store = RootStore()
        let client = McpClient(
            requestTimeoutMs: 1_000,
            protocolVersion: .v2025_03_26,
            rootsProvider: { await store.value() }
        )
        try await client.connect(transport: clientTransport)
        let params = await server.firstRequest("initialize")?.params?.value as? [String: Any]
        #expect(params?["protocolVersion"] as? String == "2025-03-26")
        #expect((params?["capabilities"] as? [String: Any])?["roots"] != nil)

        try await serverTransport.send(JsonRpc.encodeToLine(JsonRpcRequest(id: .string("first"), method: "roots/list")))
        try await Task.sleep(for: .milliseconds(20))
        let first = await server.firstResponse(.string("first"))?.result?.value as? [String: Any]
        #expect((first?["roots"] as? [[String: Any]])?.first?["uri"] as? String == "file:///first")

        await store.update()
        try await serverTransport.send(JsonRpc.encodeToLine(JsonRpcRequest(id: .string("second"), method: "roots/list")))
        try await Task.sleep(for: .milliseconds(20))
        let second = await server.firstResponse(.string("second"))?.result?.value as? [String: Any]
        #expect((second?["roots"] as? [[String: Any]])?.first?["uri"] as? String == "file:///second")
        await client.close(); await server.close()
    }

    @Test("Paginates resources, fills missing names, and validates resource reads", .timeLimit(.minutes(1)))
    func resources() async throws {
        let (client, server) = try await connectedServer()
        await server.setHandler("resources/list") { request in
            let cursor = (request.params?.value as? [String: Any])?["cursor"] as? String
            if cursor == nil {
                return AnyCodable(["resources": [["uri": "file:///a", "name": "a"]], "nextCursor": "2"] as [String: Any])
            }
            return AnyCodable(["resources": [["uri": "file:///b"]]] as [String: Any])
        }
        await server.setHandler("resources/read") { _ in
            AnyCodable(["contents": [["uri": "file:///a", "text": "hello"]]] as [String: Any])
        }
        let resources = try await client.listAllResources()
        #expect(resources.map(\.name) == ["a", "file:///b"])
        let contents = try await client.readResource(uri: "file:///a")
        #expect(contents.first?.text == "hello")
        await server.setHandler("resources/read") { _ in
            AnyCodable(["contents": [["uri": "file:///a"]]] as [String: Any])
        }
        await #expect(throws: (any Error).self) { _ = try await client.readResource(uri: "file:///a") }
        await client.close(); await server.close()
    }

    @Test("Keeps structured-only tool results and rejects malformed content", .timeLimit(.minutes(1)))
    func structuredOnly() async throws {
        let (client, server) = try await connectedServer()
        await server.setHandler("tools/call") { _ in
            AnyCodable(["structuredContent": ["ok": true], "_meta": ["source": "fixture"]] as [String: Any])
        }
        let result = try await client.callTool(name: "structured")
        #expect(result.content.isEmpty)
        #expect((result.structuredContent?.value as? [String: Bool])?["ok"] == true)
        #expect((result.meta?.value as? [String: String])?["source"] == "fixture")
        await server.setHandler("tools/call") { _ in
            AnyCodable(["content": "not a list"] as [String: Any])
        }
        await #expect(throws: (any Error).self) { _ = try await client.callTool(name: "broken") }
        await client.close(); await server.close()
    }

    @Test("Times out initialize without sending cancellation", .timeLimit(.minutes(1)))
    func initializeTimeout() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let server = TestServer(transport: serverTransport)
        await server.setHandler("initialize") { _ in
            try await Task.sleep(for: .seconds(2))
            return AnyCodable([String: Any]())
        }
        await server.start()
        let client = McpClient(requestTimeoutMs: 20)
        await #expect(throws: McpError.self) { try await client.connect(transport: clientTransport) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await server.receivedMethods().contains("notifications/cancelled") == false)
        await server.close()
    }

    @Test("Closes once and rejects pending requests when transport drops", .timeLimit(.minutes(1)))
    func closeOnce() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let server = TestServer(transport: serverTransport)
        await server.setHandler("initialize") { _ in
            AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": [:], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
        }
        await server.setHandler("tools/call") { _ in
            try await Task.sleep(for: .seconds(2))
            return AnyCodable(["content": []] as [String: Any])
        }
        await server.start()
        let recorder = EventRecorder()
        let client = McpClient(requestTimeoutMs: 1_000, connectionClosedHandler: { await recorder.closed() })
        try await client.connect(transport: clientTransport)
        let pending = Task { try await client.callTool(name: "wait") }
        try await Task.sleep(for: .milliseconds(20))
        await server.close()
        await #expect(throws: McpError.self) { _ = try await pending.value }
        await client.close()
        #expect(await recorder.count == 1)
    }

    @Test("Dispatches server notifications", .timeLimit(.minutes(1)))
    func notifications() async throws {
        let (clientTransport, serverTransport) = InMemoryTransport.pair()
        let server = TestServer(transport: serverTransport)
        await server.setHandler("initialize") { _ in
            AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": [:], "serverInfo": ["name": "server", "version": "1"]] as [String: Any])
        }
        await server.start()
        let recorder = EventRecorder()
        let client = McpClient(requestTimeoutMs: 1_000, serverNotificationHandler: { method, _ in await recorder.received(method) })
        try await client.connect(transport: clientTransport)
        try await serverTransport.send(JsonRpc.encodeNotificationToLine(JsonRpcNotification(method: "notifications/tools/list_changed")))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorder.methods == ["notifications/tools/list_changed"])
        await client.close(); await server.close()
    }
}

// Users see `localizedDescription` (for example in `pi mcp list`); it must carry the upstream texts.
@Test func mcpErrorsHaveReadableDescriptions() {
    #expect(McpError.connectionClosed.localizedDescription == "MCP connection closed")
    #expect(McpError.requestTimeout(500).localizedDescription == "MCP request timed out after 500ms")
    #expect(McpError.aborted.localizedDescription == "MCP request aborted")
    #expect(McpError.connectionFailed("spawn failed").localizedDescription == "spawn failed")
}

@Test func mcpTransportErrorsHaveReadableDescriptions() {
    #expect(McpTransportError.connectionClosed(stderr: "").localizedDescription == "Connection closed")
    #expect(McpTransportError.connectionClosed(stderr: "boom\n").localizedDescription == "Connection closed\nboom")
    #expect(McpTransportError.messageTooLarge(limit: 16).localizedDescription == "MCP message exceeds 16 bytes")
    #expect(McpHTTPError(status: 404, body: "", message: "MCP session expired").localizedDescription == "MCP session expired")
}
