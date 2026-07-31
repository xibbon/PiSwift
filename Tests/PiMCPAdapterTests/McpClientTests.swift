import Foundation
import Testing
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("MCP Client")
struct McpClientTests {
    @Test("answers server initiated requests through the host handler")
    func answersServerRequest() async throws {
        let transport = ScriptedTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":99,"method":"sampling/createMessage","params":{"prompt":"hello"}}"#.utf8),
        ])
        let client = McpClient(serverRequestHandler: { method, parameters in
            #expect(method == "sampling/createMessage")
            #expect((parameters?.value as? [String: Any])?["prompt"] as? String == "hello")
            return AnyCodable(["accepted": true] as [String: Any])
        }, capabilities: McpClientCapabilities(sampling: true))

        try await client.connect(transport: transport)
        let messages = try await eventually { await transport.sentMessages() }
        let initialize = try #require(messages.first)
        let initializeObject = try #require(try JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        let initializeParameters = try #require(initializeObject["params"] as? [String: Any])
        #expect((initializeParameters["capabilities"] as? [String: Any])?["sampling"] != nil)
        let response = try #require(messages.first { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (object["id"] as? Int) == 99
        })
        let object = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect((object["result"] as? [String: Any])?["accepted"] as? Bool == true)
        await client.close()
    }

    @Test("applies configured MCP request timeouts")
    func appliesRequestTimeout() async {
        let client = McpClient(requestTimeoutMs: 10)
        do {
            try await client.connect(transport: HangingTransport())
            Issue.record("Expected MCP initialization to time out")
        } catch let error as McpError {
            if case .timeout = error {
                // Expected.
            } else {
                Issue.record("Expected timeout, received \(error)")
            }
        } catch {
            Issue.record("Expected McpError.timeout, received \(error)")
        }
        await client.close()
    }

    @Test("keeps server instructions from initialization")
    func keepsServerInstructions() async throws {
        let transport = ScriptedTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"instructions":"Use the catalog first."}}"#.utf8),
        ])
        let client = McpClient()
        try await client.connect(transport: transport)
        #expect(await client.serverInstructions() == "Use the catalog first.")
        await client.close()
    }

    @Test("rejects structured content that violates a tool output schema")
    func validatesStructuredContentAgainstOutputSchema() async throws {
        let transport = ScriptedTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"tuple","inputSchema":{"type":"object"},"outputSchema":{"type":"object","properties":{"values":{"type":"array","prefixItems":[{"type":"string"},{"type":"number"}],"items":false}},"required":["values"]}}]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":[],"structuredContent":{"values":["ok",1,true]}}}"#.utf8),
        ])
        let client = McpClient()
        try await client.connect(transport: transport)
        _ = try await client.listAllTools()
        await #expect(throws: McpError.self) {
            _ = try await client.callTool(name: "tuple")
        }
        await client.close()
    }

    @Test("stops waiting when the host cancellation token is cancelled")
    func cancelsRequestWithHostToken() async throws {
        let transport = ScriptedTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8),
        ])
        let client = McpClient()
        try await client.connect(transport: transport)
        let signal = CancellationToken()
        let request = Task {
            try await client.callTool(name: "never", signal: signal)
        }
        try await Task.sleep(for: .milliseconds(10))
        signal.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }
        await client.close()
    }
}

private actor ScriptedTransport: McpTransport {
    private var responses: [Int: Data] = [:]
    private var notifications: [Data] = []
    private var ready: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var sent: [Data] = []

    init(messages: [Data]) {
        for message in messages {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { continue }
            if object["method"] as? String != nil {
                notifications.append(message)
            } else if let id = object["id"] as? Int {
                responses[id] = message
            }
        }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"] as? Int, let response = responses.removeValue(forKey: id) {
            enqueue(response)
        }
        if object["method"] as? String == "notifications/initialized" {
            for notification in notifications { enqueue(notification) }
            notifications.removeAll()
        }
    }

    func receive() async throws -> Data {
        if !ready.isEmpty { return ready.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        waiter?.resume(throwing: McpError.transportClosed)
        waiter = nil
    }

    func sentMessages() -> [Data] { sent }

    private func enqueue(_ data: Data) {
        if let waiter {
            waiter.resume(returning: data)
            self.waiter = nil
        } else {
            ready.append(data)
        }
    }
}

private actor HangingTransport: McpTransport {
    private var waiter: CheckedContinuation<Data, any Error>?

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        waiter?.resume(throwing: McpError.transportClosed)
        waiter = nil
    }
}

private func eventually(
    _ operation: @escaping @Sendable () async -> [Data]
) async throws -> [Data] {
    for _ in 0..<100 {
        let messages = await operation()
        if messages.count >= 3 { return messages }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw McpError.timeout
}
