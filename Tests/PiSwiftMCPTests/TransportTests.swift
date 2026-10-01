import Foundation
import Network
import Testing
import PiSwiftAI
@testable import PiSwiftMCP
#if os(macOS)
import Darwin
#endif

@Suite("MCP transports")
struct TransportTests {
    @Test(.timeLimit(.minutes(1)))
    func inMemoryPairDeliversMessagesAndCloses() async throws {
        let (client, server) = InMemoryTransport.pair(maxMessageBytes: 32)
        let request = Data(#"{"jsonrpc":"2.0"}"#.utf8)
        try await client.send(request)
        #expect(try await server.receive() == request)
        do {
            try await client.send(Data(repeating: 0, count: 33))
            Issue.record("Expected message cap")
        } catch McpTransportError.messageTooLarge(let limit) {
            #expect(limit == 32)
        }
        await client.close()
        await #expect(throws: McpError.self) { try await server.receive() }
    }

    #if os(macOS)
    @Test(.timeLimit(.minutes(1)))
    func stdioFramesMessagesAndCapturesStderr() async throws {
        let stderrChunks = LockedState<[String]>([])
        let fixture = try #require(Bundle.module.url(forResource: "stdio-server", withExtension: "sh", subdirectory: "fixtures"))
        let transport = StdioTransport(command: "/bin/sh", args: [fixture.path], onStderr: { chunk in
            stderrChunks.withLock { $0.append(chunk) }
        })
        try await transport.start()
        let message = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
        try await transport.send(message)
        #expect(try await transport.receive() == message)
        #expect(await transport.processID != nil)
        try await Task.sleep(for: .milliseconds(25))
        #expect(await transport.stderr.contains("stdio fixture ready"))
        #expect(stderrChunks.withLock { $0.joined() }.contains("stdio fixture ready"))
        await transport.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func stdioCloseTerminatesStubbornProcessGroup() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "stubborn-server", withExtension: "sh", subdirectory: "fixtures"))
        let transport = StdioTransport(
            command: "/bin/sh",
            args: [fixture.path],
            closeTimeout: .milliseconds(150)
        )
        try await transport.start()
        let pid = try #require(await transport.processID)
        await transport.close()
        #expect(await transport.processID == nil)
        #expect(kill(-pid, 0) == -1)
    }
    #endif

    @Test(.timeLimit(.minutes(1)))
    func httpUsesSessionVersionGetAndDelete() async throws {
        let fixture = HTTPFixture(mode: .normal)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let url = await server.start()
        let transport = StreamableHTTPTransport(url: url, reconnect: .init(initialDelay: .milliseconds(5), maxRetries: 1))
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        _ = try await transport.receive()
        await transport.setProtocolVersion("2025-11-25")
        try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":"tool-id","method":"tools/list"}"#.utf8))
        let response = try await transport.receive()
        #expect(String(decoding: response, as: UTF8.self).contains("tool-id"))
        #expect(await transport.hasSessionIdentifier())
        await transport.close()
        let requests = await fixture.requests
        #expect(requests.contains { $0.method == "GET" })
        #expect(requests.contains { $0.method == "DELETE" })
        let list = try #require(requests.first { $0.body.contains("tools/list") })
        #expect(list.headers["mcp-session-id"] == "session-1")
        #expect(list.headers["mcp-protocol-version"] == "2025-11-25")
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpResumesResponseStreamWithLastEventID() async throws {
        let fixture = HTTPFixture(mode: .resume)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let url = await server.start()
        let transport = StreamableHTTPTransport(url: url, openGetStream: false, reconnect: .init(initialDelay: .milliseconds(5), maxRetries: 2))
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#.utf8))
        let result = try await transport.receive()
        #expect(String(decoding: result, as: UTF8.self).contains("resumed"))
        #expect(await fixture.requests.contains { $0.method == "GET" && $0.headers["last-event-id"] == "1" })
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpRetries401AndInsufficientScope403() async throws {
        let fixture = HTTPFixture(mode: .auth)
        let provider = RotatingAuthProvider()
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let url = await server.start()
        let transport = StreamableHTTPTransport(url: url, authProvider: provider, openGetStream: false)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        _ = try await transport.receive()
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#.utf8))
        _ = try await transport.receive()
        let challenges = await provider.challenges
        #expect(challenges.count == 2)
        #expect(challenges[0].contains("Bearer"))
        #expect(challenges[1].contains("insufficient_scope"))
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpParsesCRLFCommentsAndMultilineSSE() async throws {
        let fixture = HTTPFixture(mode: .multiline)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#.utf8))
        let response = try await transport.receive()
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect((object["id"] as? Int) == 2)
        #expect((object["result"] as? [String: Any])?["message"] as? String == "multiline")
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpRejectsOversizeSSEBeforeBlankLine() async throws {
        let fixture = HTTPFixture(mode: .oversize)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false, maxMessageBytes: 256)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#.utf8))
        let response = try await transport.receive()
        #expect(String(decoding: response, as: UTF8.self).contains("MCP response stream failed"))
        #expect(String(decoding: response, as: UTF8.self).contains("messageTooLarge"))
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func brokenResponseStreamDoesNotFailOtherRequest() async throws {
        let fixture = HTTPFixture(mode: .broken)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call"}"#.utf8))
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":"tool-id","method":"tools/list"}"#.utf8))
        let first = try await transport.receive()
        let second = try await transport.receive()
        let text = [first, second].map { String(decoding: $0, as: UTF8.self) }
        #expect(text.contains { $0.contains("MCP response stream failed") })
        #expect(text.contains { $0.contains("tool-id") })
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func getStreamReconnectsWithLastEventID() async throws {
        let fixture = HTTPFixture(mode: .getReconnect)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), reconnect: .init(initialDelay: .milliseconds(5), maxRetries: 2))
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        _ = try await transport.receive()
        try await transport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let first = try await transport.receive()
        let second = try await transport.receive()
        #expect(String(decoding: first, as: UTF8.self).contains("list_changed"))
        #expect(String(decoding: second, as: UTF8.self).contains("list_changed"))
        #expect(await fixture.requests.contains { $0.method == "GET" && $0.headers["last-event-id"] == "g1" })
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpRejectsAcceptedRequestWithoutResponse() async throws {
        let fixture = HTTPFixture(mode: .accepted)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false)
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call"}"#.utf8))
            Issue.record("Expected 202 request error")
        } catch let error as McpHTTPError {
            #expect(error.status == 202)
            #expect(error.message.contains("without a response"))
        }
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func httpKeepsErrorBody() async throws {
        let fixture = HTTPFixture(mode: .badRequest)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false)
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
            Issue.record("Expected HTTP error")
        } catch let error as McpHTTPError {
            #expect(error.status == 400)
            #expect(error.body == "Invalid Accept header")
            #expect(error.message.contains("Invalid Accept header"))
        }
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func establishedSession404IsExpired() async throws {
        let fixture = HTTPFixture(mode: .expired)
        let server = try LoopbackHTTPServer(handler: { request in await fixture.reply(to: request) })
        let transport = StreamableHTTPTransport(url: await server.start(), openGetStream: false)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        _ = try await transport.receive()
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
            Issue.record("Expected expired session")
        } catch let error as McpSessionExpiredError {
            #expect(error.body == "gone")
        }
        await transport.close()
        await server.stop()
    }
}

private struct FixtureRequest: Sendable {
    let method: String
    let headers: [String: String]
    let body: String
}

private struct FixtureReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: String

    init(_ status: Int, headers: [String: String] = [:], body: String = "") {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

private actor HTTPFixture {
    enum Mode: Sendable { case normal, resume, auth, multiline, oversize, broken, getReconnect, accepted, badRequest, expired }
    private let mode: Mode
    private(set) var requests: [FixtureRequest] = []

    init(mode: Mode) { self.mode = mode }

    func reply(to request: FixtureRequest) -> FixtureReply {
        requests.append(request)
        if request.method == "DELETE" { return FixtureReply(200) }
        if request.method == "GET" {
            if case .resume = mode, request.headers["last-event-id"] == "1" {
                return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: "id: 2\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"message\":\"resumed\"}}\n\n")
            }
            if case .getReconnect = mode {
                let id = request.headers["last-event-id"] == "g1" ? "g2" : "g1"
                return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: "id: \(id)\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n")
            }
            return FixtureReply(405)
        }
        if case .badRequest = mode { return FixtureReply(400, body: "Invalid Accept header") }
        if case .auth = mode {
            let authorization = request.headers["authorization"]
            if authorization == "Bearer old" {
                return FixtureReply(401, headers: ["WWW-Authenticate": "Bearer"], body: "login required")
            }
            if request.body.contains("tools/call"), authorization == "Bearer new" {
                return FixtureReply(403, headers: ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="admin""#])
            }
        }
        if request.body.contains("notifications/initialized") { return FixtureReply(202) }
        if request.body.contains("initialize") {
            return FixtureReply(200, headers: ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"], body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#)
        }
        if case .expired = mode { return FixtureReply(404, body: "gone") }
        if case .resume = mode, request.body.contains("tools/call") {
            return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: "id: 1\nretry: 5\ndata:\n\n")
        }
        if case .multiline = mode, request.body.contains("tools/call") {
            return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: ": keepalive\r\nid: 7\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":2,\"result\":{\"message\":\"multiline\"}}\r\n\r\n")
        }
        if case .oversize = mode, request.body.contains("tools/call") {
            return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: "data: \(String(repeating: "x", count: 300))")
        }
        if case .broken = mode, request.body.contains("tools/call") {
            return FixtureReply(200, headers: ["Content-Type": "text/event-stream"], body: "data: not json\n\n")
        }
        if case .accepted = mode, request.body.contains("tools/call") { return FixtureReply(202) }
        if request.body.contains("tools/list") {
            return FixtureReply(200, headers: ["Content-Type": "application/json"], body: #"{"jsonrpc":"2.0","id":"tool-id","result":{"tools":[]}}"#)
        }
        return FixtureReply(200, headers: ["Content-Type": "application/json"], body: #"{"jsonrpc":"2.0","id":2,"result":{"content":[]}}"#)
    }
}

private actor RotatingAuthProvider: McpAuthProvider {
    private var current = "old"
    private(set) var challenges: [String] = []

    func token() -> String? { current }

    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) {
        challenges.append(challenge ?? "")
        current = current == "old" ? "new" : "admin"
    }
}

private actor LoopbackHTTPServer {
    private let listener: NWListener
    private let handler: @Sendable (FixtureRequest) async -> FixtureReply
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var isReady = false

    init(handler: @escaping @Sendable (FixtureRequest) async -> FixtureReply) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
    }

    func start() async -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.markReady() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener.start(queue: .global())
        if !isReady {
            await withCheckedContinuation { readyWaiter = $0 }
        }
        return URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/mcp")!
    }

    func stop() { listener.cancel() }

    private func markReady() {
        isReady = true
        readyWaiter?.resume()
        readyWaiter = nil
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global())
        guard let request = await readRequest(connection) else { connection.cancel(); return }
        let reply = await handler(request)
        let reason = switch reply.status {
        case 200: "OK"
        case 202: "Accepted"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 405: "Method Not Allowed"
        default: "Error"
        }
        var response = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
        for (key, value) in reply.headers { response += "\(key): \(value)\r\n" }
        response += "\r\n\(reply.body)"
        await withCheckedContinuation { continuation in
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
        connection.cancel()
    }

    private func readRequest(_ connection: NWConnection) async -> FixtureRequest? {
        var data = Data()
        while data.count < 64 * 1024 {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, _, _ in
                    continuation.resume(returning: content)
                }
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            data.append(chunk)
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let method = lines[0].split(separator: " ").first.map(String.init) ?? ""
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if data.count < boundary.upperBound + length { continue }
            let body = String(decoding: data[boundary.upperBound..<boundary.upperBound + length], as: UTF8.self)
            return FixtureRequest(method: method, headers: headers, body: body)
        }
        return nil
    }
}
