import Foundation
import Testing
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("MCP Server Manager")
struct McpServerManagerTests {
    @Test("resolves command secrets only when a connection needs them")
    func resolvesCommandSecrets() async throws {
        #expect(try await resolveCommandSecret("!!literal", context: "test") == "!literal")
        #expect(try await resolveCommandSecret("!printf token", context: "test") == "token")
        await #expect(throws: McpError.self) {
            _ = try await resolveCommandSecret("!printf ''", context: "test")
        }
        await #expect(throws: McpError.self) {
            _ = try await resolveCommandSecret("!yes x | head -c 1048577", context: "test")
        }
    }

    @Test("shares one connection attempt and records an unexpected close")
    func sharesConnectionAttempt() async throws {
        let factory = CountingTransportFactory()
        let manager = McpServerManager(transportFactory: { _, _ in
            await factory.makeTransport()
        })
        let definition = ServerEntry(command: "test-server")

        async let first = manager.connect(name: "demo", definition: definition)
        async let second = manager.connect(name: "demo", definition: definition)
        let connections = try await [first, second]

        #expect(connections[0].client.connectionID == connections[1].client.connectionID)
        #expect(await factory.createdCount() == 1)
        #expect(await manager.isConnected(name: "demo"))

        let transport = try #require(await factory.lastTransport())
        await transport.finish()
        #expect(try await eventuallyNotConnected(manager, name: "demo"))
        await manager.closeAll()
    }

    @Test("retries only a proven terminated HTTP session once")
    func retriesTerminatedHttpSession() async throws {
        let factory = CountingTransportFactory()
        let manager = McpServerManager(transportFactory: { _, _ in
            await factory.makeTransport()
        })
        let definition = ServerEntry(command: "test-server")
        _ = try await manager.connect(name: "demo", definition: definition)
        let operation = RecoveryOperation()

        let value: String = try await manager.withSessionRecovery(name: "demo") { _ in
            try await operation.run()
        }

        #expect(value == "retried")
        #expect(await operation.count() == 2)
        #expect(await factory.createdCount() == 2)
        await manager.closeAll()
    }

    @Test("falls back to the legacy SSE transport for remote servers")
    func fallsBackToLegacySSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacySSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = HttpTransport(
            url: try #require(URL(string: "http://mcp-legacy.test/sse")),
            session: session
        )

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        let response = try await transport.receive()
        let object = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect(object["id"] as? Int == 1)
        #expect((object["result"] as? [String: Any])?["legacy"] as? Bool == true)
        await transport.close()
    }

    @Test("skips optional lists that the server does not advertise")
    func skipsUnadvertisedOptionalLists() async throws {
        let transport = ManagerTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{}}}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.utf8),
        ])
        let manager = McpServerManager(transportFactory: { _, _ in transport })

        let connection = try await manager.connect(name: "tools-only", definition: ServerEntry(command: "test"))
        #expect(connection.resources.isEmpty)
        #expect(connection.prompts.isEmpty)
        #expect(await transport.sentMethods() == ["initialize", "notifications/initialized", "tools/list"])
        await manager.closeAll()
    }

    @Test("keeps prompt-discovery failure separate from an empty prompt list")
    func recordsPromptDiscoveryFailure() async throws {
        let transport = ManagerTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{},"prompts":{}}}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"prompts unavailable"}}"#.utf8),
        ])
        let manager = McpServerManager(transportFactory: { _, _ in transport })

        let connection = try await manager.connect(name: "prompt-failure", definition: ServerEntry(command: "test"))
        #expect(connection.prompts.isEmpty)
        #expect(connection.promptDiscoveryFailed)
        await manager.closeAll()
    }
}

private final class LegacySSEURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mcp-legacy.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let headers: [String: String]
        let body: Data
        switch (request.httpMethod, url.path) {
        case ("POST", "/sse"):
            status = 405
            headers = ["Content-Type": "text/plain"]
            body = Data("Method not allowed".utf8)
        case ("GET", "/sse"):
            status = 200
            headers = ["Content-Type": "text/event-stream"]
            body = Data("event: endpoint\ndata: /message\n\n".utf8)
        case ("POST", "/message"):
            status = 202
            headers = ["Content-Type": "application/json"]
            body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"legacy":true}}"#.utf8)
        default:
            status = 404
            headers = ["Content-Type": "text/plain"]
            body = Data()
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CountingTransportFactory {
    private var created: [ManagerTransport] = []

    func makeTransport() -> ManagerTransport {
        let transport = ManagerTransport(messages: [
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":3,"result":{"resources":[]}}"#.utf8),
            Data(#"{"jsonrpc":"2.0","id":4,"result":{"prompts":[]}}"#.utf8),
        ])
        created.append(transport)
        return transport
    }

    func createdCount() -> Int { created.count }
    func lastTransport() -> ManagerTransport? { created.last }
}

private actor ManagerTransport: McpSessionAwareTransport {
    private var responses: [Int: Data] = [:]
    private var ready: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var methods: [String] = []

    init(messages: [Data]) {
        for message in messages {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            responses[id] = message
        }
    }

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = object["method"] as? String {
            methods.append(method)
        }
        guard let id = object["id"] as? Int,
              let response = responses.removeValue(forKey: id) else { return }
        if let waiter {
            waiter.resume(returning: response)
            self.waiter = nil
        } else {
            ready.append(response)
        }
    }

    func receive() async throws -> Data {
        if !ready.isEmpty { return ready.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func finish() {
        waiter?.resume(throwing: McpError.transportClosed)
        waiter = nil
    }

    func close() async { finish() }
    func hasSessionIdentifier() -> Bool { true }
    func sentMethods() -> [String] { methods }
}

private actor RecoveryOperation {
    private var attempts = 0

    func run() throws -> String {
        attempts += 1
        if attempts == 1 {
            throw McpError.protocolError("HTTP 404: MCP session does not exist")
        }
        return "retried"
    }

    func count() -> Int { attempts }
}

private func eventuallyNotConnected(_ manager: McpServerManager, name: String) async throws -> Bool {
    for _ in 0..<100 {
        if !(await manager.isConnected(name: name)) { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}
