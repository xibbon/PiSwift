import Foundation
import Network
import PiSwiftAI
import Testing
@testable import PiSwiftMCP

private enum M1DispatchError: Error { case deadline, sendFailed }

private actor M1Events {
    private struct Waiter {
        let key: String
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }
    private var counts: [String: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]

    func mark(_ key: String) {
        counts[key, default: 0] += 1
        for (id, waiter) in waiters where waiter.key == key && counts[key, default: 0] >= waiter.count {
            waiters[id] = nil
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    func wait(_ key: String, count: Int = 1) async throws {
        if counts[key, default: 0] >= count { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                self.expire(id)
            }
            waiters[id] = Waiter(key: key, count: count, continuation: continuation, timer: timer)
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: M1DispatchError.deadline)
    }
}

private actor M1ProbeTransport: McpTransport {
    let events = M1Events()
    private let local: InMemoryTransport
    private let peer: InMemoryTransport
    private var signals: [String: CancellationToken] = [:]
    private(set) var notificationHadSignal = false
    private(set) var sendWasCancelled = false
    private(set) var signalsWereCancelledAtClose = false

    init() { (local, peer) = InMemoryTransport.pair() }
    func receive() async throws -> Data { try await local.receive() }
    func close() async {
        signalsWereCancelledAtClose = signals.values.allSatisfy(\.isCancelled)
        await local.close()
    }
    func signal(_ name: String) -> CancellationToken? { signals[name] }
    func send(_ data: Data) async throws { try await send(data, options: .init()) }

    func send(_ data: Data, options: McpTransportSendOptions) async throws {
        let message = try JsonRpc.decodeIncoming(data)
        guard case .request(let request) = message else {
            notificationHadSignal = notificationHadSignal || options.signal != nil
            if case .notification(let notification) = message { await events.mark(notification.method) }
            return
        }
        let name = request.method == "initialize" ? "initialize" :
            (request.params?.value as? [String: Any])?["name"] as? String ?? "unknown"
        signals[name] = options.signal
        await events.mark(name)
        if name == "send-failure" { throw M1DispatchError.sendFailed }
        let result: AnyCodable
        if name == "initialize" {
            result = AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": [:],
                                 "serverInfo": ["name": "fixture", "version": "1"]] as [String: Any])
        } else if name == "response" || name == "rpc-error" {
            result = AnyCodable(["content": []] as [String: Any])
        } else { return }
        let response = JsonRpcServerResponse(id: request.id, result: name == "rpc-error" ? nil : result,
                                            error: name == "rpc-error" ? JsonRpcError(code: -32603, message: "failed") : nil)
        try await peer.send(JsonRpc.encodeServerResponseToLine(response))
        if name == "response" {
            // A settled dispatch token must not cancel work for the active send.
            try await events.wait("release-send")
            sendWasCancelled = Task.isCancelled
            await events.mark("send-finished")
        }
    }
}

/// This conformer deliberately implements only the original send method.
private actor M1LegacyTransport: McpTransport {
    private(set) var sends = 0
    func send(_ data: Data) { sends += 1 }
    func receive() throws -> Data { throw McpError.transportClosed }
    func close() {}
}

private actor M1AuthProvider: McpAuthProvider {
    enum Mode: Sendable { case refresh, token }
    let events = M1Events()
    private let mode: Mode
    private var current = "old"
    private var refresh: Task<Void, any Error>?
    private(set) var refreshes = 0
    private(set) var saves = 0
    private(set) var recoveryWasCancelled = false

    init(_ mode: Mode = .refresh) { self.mode = mode }

    func token() async throws -> String? {
        if mode == .token {
            await events.mark("token")
            try await events.wait("release")
        }
        return current
    }

    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {
        if refresh == nil {
            refreshes += 1
            refresh = Task {
                try await self.events.wait("release")
                try Task.checkCancellation()
                self.current = "new"
                self.saves += 1
            }
        }
        await events.mark("waiting")
        try await refresh?.value
        recoveryWasCancelled = recoveryWasCancelled || Task.isCancelled
    }
}

private struct M1HTTPRequest: Sendable {
    let method: String
    let authorization: String?
    let body: Data
}

private actor M1HTTPServer {
    enum Mode: Sendable { case refresh, holdBody }
    let events = M1Events()
    private let listener: NWListener
    private let mode: Mode
    private var connections: [UUID: NWConnection] = [:]
    private(set) var executed: [String] = []
    private(set) var posts = 0

    init(_ mode: Mode = .refresh) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [events] state in
            if case .ready = state { Task { await events.mark("ready") } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener.start(queue: .global())
        try await events.wait("ready")
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/mcp"))
    }

    func stop() async {
        listener.cancel()
        await events.mark("release-body")
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func read(_ connection: NWConnection) async -> M1HTTPRequest? {
        var data = Data()
        while data.count < 64 * 1024 {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            data.append(chunk)
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let count = Int(headers["content-length"] ?? "0") ?? 0
            guard data.count >= boundary.upperBound + count else { continue }
            return M1HTTPRequest(method: String(lines[0].split(separator: " ").first ?? ""),
                                 authorization: headers["authorization"],
                                 body: Data(data[boundary.upperBound..<boundary.upperBound + count]))
        }
        return nil
    }

    private func send(_ data: Data, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func reply(_ status: Int, body: Data = Data(), to connection: NWConnection) async {
        let headers = "HTTP/1.1 \(status) Reply\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nWWW-Authenticate: Bearer\r\nConnection: close\r\n\r\n"
        await send(Data(headers.utf8) + body, to: connection)
    }

    private func handle(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel(); connections[id] = nil }
        guard let request = await read(connection) else { return }
        guard request.method == "POST" else { await reply(200, to: connection); return }
        posts += 1
        guard let message = try? JsonRpc.decodeIncoming(request.body), case .request(let rpc) = message else {
            await reply(202, to: connection)
            return
        }
        let result: AnyCodable
        if rpc.method == "initialize" {
            result = AnyCodable(["protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": [:],
                                 "serverInfo": ["name": "fixture", "version": "1"]] as [String: Any])
        } else {
            if mode == .refresh, request.authorization == "Bearer old" {
                await reply(401, to: connection)
                return
            }
            let name = (rpc.params?.value as? [String: Any])?["name"] as? String ?? "unknown"
            executed.append(name)
            result = AnyCodable(["content": [["type": "text", "text": "hello"]]] as [String: Any])
        }
        guard let body = try? JsonRpc.encodeServerResponseToLine(JsonRpcServerResponse(id: rpc.id, result: result, error: nil)) else { return }
        if mode == .holdBody {
            let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
            await send(Data(headers.utf8) + body.prefix(10), to: connection)
            await events.mark("body")
            try? await events.wait("release-body")
            await send(Data(body.dropFirst(10)), to: connection)
        } else { await reply(200, body: body, to: connection) }
    }
}

private actor M1ObservedTransport: McpTransport {
    let events = M1Events()
    let transport: StreamableHTTPTransport
    init(_ transport: StreamableHTTPTransport) { self.transport = transport }
    func receive() async throws -> Data { try await transport.receive() }
    func close() async { await transport.close() }
    func setProtocolVersion(_ version: String) async { await transport.setProtocolVersion(version) }
    func send(_ data: Data) async throws { try await send(data, options: .init()) }
    func send(_ data: Data, options: McpTransportSendOptions) async throws {
        let name: String
        if case .request(let request) = try JsonRpc.decodeIncoming(data) {
            name = (request.params?.value as? [String: Any])?["name"] as? String ?? request.method
        } else { name = "notification" }
        do {
            try await transport.send(data, options: options)
            await events.mark(name)
        } catch {
            await events.mark(name)
            throw error
        }
    }
}

@Suite("M1 request-owned dispatch")
struct M1DispatchTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["response", "rpc-error", "timeout", "token-cancel", "task-cancel", "send-failure", "close"])
    func settlementCancelsDispatch(name: String) async throws {
        let transport = M1ProbeTransport()
        let client = McpClient(requestTimeoutMs: 5_000)
        try await client.connect(transport: transport)
        #expect(await transport.signal("initialize")?.isCancelled == true)
        let signal = CancellationToken()
        let call = Task {
            try await client.callTool(name: name, signal: signal, timeoutMs: name == "timeout" ? 100 : 5_000)
        }
        try await transport.events.wait(name)
        if name == "token-cancel" { signal.cancel() }
        if name == "task-cancel" { call.cancel() }
        if name == "close" { await client.close() }
        switch await call.result {
        case .success: #expect(name == "response")
        case .failure(let error):
            switch name {
            case "rpc-error": #expect(error as? McpError == .rpcError(code: -32603, message: "failed"))
            case "timeout": #expect(error as? McpError == .requestTimeout(100))
            case "token-cancel": #expect(error is CancellationError)
            case "task-cancel": #expect(error as? McpError == .aborted)
            case "send-failure": #expect(error is M1DispatchError)
            case "close": #expect(error as? McpError == .transportClosed)
            default: Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(await transport.signal(name)?.isCancelled == true)
        if ["timeout", "token-cancel", "task-cancel"].contains(name) {
            try await transport.events.wait("notifications/cancelled")
        }
        #expect(await transport.notificationHadSignal == false)
        if name == "response" {
            await transport.events.mark("release-send")
            try await transport.events.wait("send-finished")
            #expect(await transport.sendWasCancelled == false)
        }
        await client.close()
        #expect(await transport.signalsWereCancelledAtClose)
    }

    @Test func originalTransportConformanceUsesDefaultOverload() async throws {
        let legacy = M1LegacyTransport()
        let transport: any McpTransport = legacy
        let signal = CancellationToken()
        signal.cancel()
        await #expect(throws: McpError.aborted) {
            try await transport.send(Data(), options: .init(signal: signal))
        }
        #expect(await legacy.sends == 0)
        try await transport.send(Data(), options: .init())
        #expect(await legacy.sends == 1)
    }

    // v1.3.0 packages/mcp/test/streamable-http.test.ts:346, #10598.
    @Test(.timeLimit(.minutes(1)))
    func settledRequestsDoNotRetryAfterSharedRefresh() async throws {
        let server = try M1HTTPServer()
        let auth = M1AuthProvider()
        let transport = M1ObservedTransport(StreamableHTTPTransport(
            url: try await server.start(), authProvider: auth, openGetStream: false
        ))
        let client = McpClient(requestTimeoutMs: 5_000)
        do {
            try await client.connect(transport: transport)
            let signal = CancellationToken()
            let aborted = Task { try await client.callTool(name: "aborted", signal: signal) }
            let timedOut = Task { try await client.callTool(name: "timed-out", timeoutMs: 1_000) }
            let kept = Task { try await client.callTool(name: "kept") }
            try await auth.events.wait("waiting", count: 3)
            signal.cancel()
            await #expect(throws: CancellationError.self) { _ = try await aborted.value }
            await #expect(throws: McpError.requestTimeout(1_000)) { _ = try await timedOut.value }
            #expect(await auth.saves == 0)
            await auth.events.mark("release")
            #expect(try await kept.value.content.first?.text == "hello")
            // Wait for all three sends, including the two settled calls.
            for name in ["aborted", "timed-out", "kept"] { try await transport.events.wait(name) }
            #expect(await server.executed == ["kept"])
            #expect(await auth.refreshes == 1)
            #expect(await auth.saves == 1)
            #expect(await auth.recoveryWasCancelled == false)
        } catch {
            await auth.events.mark("release")
            await client.close()
            await server.stop()
            throw error
        }
        await client.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func settledRequestDoesNotDispatchAfterTokenLookup() async throws {
        let server = try M1HTTPServer()
        let auth = M1AuthProvider(.token)
        let transport = StreamableHTTPTransport(url: try await server.start(), authProvider: auth, openGetStream: false)
        let signal = CancellationToken()
        let send = Task {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), options: .init(signal: signal))
        }
        do {
            try await auth.events.wait("token")
            signal.cancel()
            await auth.events.mark("release")
            await #expect(throws: McpError.aborted) { try await send.value }
            #expect(await server.posts == 0)
        } catch {
            await auth.events.mark("release")
            await transport.close()
            await server.stop()
            throw error
        }
        await transport.close()
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func settlementDoesNotAbortAnActiveResponseBody() async throws {
        let server = try M1HTTPServer(.holdBody)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        let signal = CancellationToken()
        let send = Task {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), options: .init(signal: signal))
        }
        do {
            try await server.events.wait("body")
            signal.cancel()
            await server.events.mark("release-body")
            try await send.value
            guard case .response(let response) = try JsonRpc.decodeIncoming(try await transport.receive()) else {
                Issue.record("Expected a complete response")
                await transport.close(); await server.stop()
                return
            }
            #expect(response.id == .integer(1))
        } catch {
            await server.events.mark("release-body")
            await transport.close()
            await server.stop()
            throw error
        }
        await transport.close()
        await server.stop()
    }
}
