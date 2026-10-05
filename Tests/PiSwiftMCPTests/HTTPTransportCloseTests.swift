import Foundation
import Network
import Testing
@testable import PiSwiftMCP

private enum CloseFixtureError: Error { case deadline, stopped }

/// Each wait has a deadline. No test depends on a fixed delay.
private actor CloseEvents {
    private var counts: [String: Int] = [:]
    private struct Waiter {
        let key: String
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func mark(_ key: String) {
        counts[key, default: 0] += 1
        let ready = waiters.filter { $0.value.key == key && counts[key, default: 0] >= $0.value.count }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    func count(_ key: String) -> Int { counts[key, default: 0] }

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
        waiter.continuation.resume(throwing: CloseFixtureError.deadline)
    }

    func stop() {
        for waiter in waiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: CloseFixtureError.stopped)
        }
        waiters.removeAll()
    }
}

private actor CloseHTTPServer {
    enum Mode: Sendable { case noHeaders, partialJSON, completeJSON }
    let events = CloseEvents()
    private let listener: NWListener
    private let mode: Mode
    private var connections: [UUID: NWConnection] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(_ mode: Mode) throws {
        self.mode = mode
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [events] state in
            if case .ready = state { Task { await events.mark("ready") } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .global())
        try await events.wait("ready")
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)/mcp"))
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        workers[id] = Task { await self.handle(connection, id: id) }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if error != nil || complete && (data?.isEmpty ?? true) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func send(_ text: String, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func handle(_ connection: NWConnection, id: UUID) async {
        // Cancel the connection even if a test fails before it calls stop().
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
            connections[id] = nil
            workers[id] = nil
        }
        var data = Data()
        while let chunk = await receive(connection) {
            data.append(chunk)
            guard data.count <= 64 * 1024 else { return }
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let length = lines.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            guard data.count >= boundary.upperBound + length else { continue }
            guard head.hasPrefix("POST ") else {
                await send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", to: connection)
                return
            }
            await events.mark("post")
            switch mode {
            case .noHeaders: break
            case .partialJSON:
                await send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 200\r\nConnection: close\r\n\r\n{\"jsonrpc\":", to: connection)
                await events.mark("partial")
            case .completeJSON:
                let body = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
                await send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)", to: connection)
                return
            }
            while await receive(connection) != nil {}
            await events.mark("eof")
            return
        }
    }

    func stop() async {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        for worker in workers.values { worker.cancel() }
        await events.stop()
    }
}

private func closeRequest(_ id: Int) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}".utf8)
}

private actor CloseAuthGate: McpAuthProvider {
    let events = CloseEvents()

    func token() async throws -> String? {
        await events.mark("token")
        try await events.wait("release")
        return nil
    }

    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {}
}

private func closeOperation(
    events: CloseEvents,
    _ operation: @escaping @Sendable () async throws -> Void
) -> Task<McpError?, Never> {
    Task {
        let result: McpError?
        do {
            try await operation()
            Issue.record("Expected a closed transport error")
            result = nil
        } catch let error as McpError {
            result = error
        } catch {
            Issue.record("Unexpected error: \(error)")
            result = nil
        }
        await events.mark("done")
        return result
    }
}

// Z4 / #10249: upstream Streamable HTTP close aborts each active fetch and body read.
@Suite("HTTP transport close")
struct HTTPTransportCloseTests {
    @Test(.timeLimit(.minutes(1)))
    func closeDuringAuthDoesNotStartPost() async throws {
        let server = try CloseHTTPServer(.noHeaders)
        let auth = CloseAuthGate()
        let events = CloseEvents()
        let transport = StreamableHTTPTransport(
            url: try await server.start(), authProvider: auth, openGetStream: false
        )
        let request = closeOperation(events: events) { try await transport.send(closeRequest(1)) }
        do {
            try await auth.events.wait("token")
            await transport.close()
            await auth.events.mark("release")
            try await events.wait("done")
            #expect(await request.value == .transportClosed)
            #expect(await server.events.count("post") == 0)
        } catch {
            await auth.events.mark("release")
            await transport.close()
            await server.stop()
            await events.stop()
            await auth.events.stop()
            throw error
        }
        await server.stop()
        await events.stop()
        await auth.events.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeCancelsTwoPostsBeforeHeaders() async throws {
        let server = try CloseHTTPServer(.noHeaders)
        let events = CloseEvents()
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        let first = closeOperation(events: events) { try await transport.send(closeRequest(1)) }
        let second = closeOperation(events: events) { try await transport.send(closeRequest(2)) }
        do {
            try await server.events.wait("post", count: 2)
            await transport.close()
            try await events.wait("done", count: 2)
            #expect(await first.value == .transportClosed)
            #expect(await second.value == .transportClosed)
            try await server.events.wait("eof", count: 2)
            await #expect(throws: McpError.transportClosed) {
                try await transport.send(closeRequest(3))
            }
        } catch {
            await transport.close()
            await server.stop()
            await events.stop()
            throw error
        }
        await server.stop()
        await events.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeCancelsPartialJSONBody() async throws {
        let server = try CloseHTTPServer(.partialJSON)
        let events = CloseEvents()
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        let request = closeOperation(events: events) { try await transport.send(closeRequest(1)) }
        do {
            try await server.events.wait("partial")
            await transport.close()
            try await events.wait("done")
            #expect(await request.value == .transportClosed)
            try await server.events.wait("eof")
        } catch {
            await transport.close()
            await server.stop()
            await events.stop()
            throw error
        }
        await server.stop()
        await events.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func clientCloseClearsInitializeAndSecondRequest() async throws {
        let server = try CloseHTTPServer(.noHeaders)
        let events = CloseEvents()
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        let client = McpClient()
        let initialize = closeOperation(events: events) { try await client.connect(transport: transport) }
        do {
            try await server.events.wait("post")
            let tools = closeOperation(events: events) { _ = try await client.listTools() }
            try await server.events.wait("post", count: 2)
            await client.close()
            try await events.wait("done", count: 2)
            #expect(await initialize.value == .transportClosed)
            #expect(await tools.value == .transportClosed)
            try await server.events.wait("eof", count: 2)
        } catch {
            await client.close()
            await server.stop()
            await events.stop()
            throw error
        }
        await server.stop()
        await events.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func transportCloseClearsClientRequests() async throws {
        let server = try CloseHTTPServer(.noHeaders)
        let events = CloseEvents()
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        let client = McpClient()
        let initialize = closeOperation(events: events) { try await client.connect(transport: transport) }
        do {
            try await server.events.wait("post")
            let tools = closeOperation(events: events) { _ = try await client.listTools() }
            try await server.events.wait("post", count: 2)
            await transport.close()
            try await events.wait("done", count: 2)
            let initializeError = await initialize.value
            let toolsError = await tools.value
            // The receive loop can close all pending client requests before either send task reports its error.
            #expect(initializeError == .transportClosed || initializeError == .connectionClosed)
            #expect(toolsError == .transportClosed || toolsError == .connectionClosed)
            try await server.events.wait("eof", count: 2)
        } catch {
            await client.close()
            await server.stop()
            await events.stop()
            throw error
        }
        await client.close()
        await server.stop()
        await events.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeKeepsSharedSessionUsable() async throws {
        let blockedServer = try CloseHTTPServer(.noHeaders)
        let replyServer = try CloseHTTPServer(.completeJSON)
        let session = URLSession(configuration: .ephemeral)
        let events = CloseEvents()
        let blocked = StreamableHTTPTransport(url: try await blockedServer.start(), session: session, openGetStream: false)
        let other = StreamableHTTPTransport(url: try await replyServer.start(), session: session, openGetStream: false)
        let request = closeOperation(events: events) { try await blocked.send(closeRequest(1)) }
        do {
            try await blockedServer.events.wait("post")
            await blocked.close()
            try await events.wait("done")
            #expect(await request.value == .transportClosed)
            let completed = Task {
                do {
                    try await other.send(closeRequest(1))
                    let response = try await other.receive()
                    #expect(String(decoding: response, as: UTF8.self).contains("\"result\""))
                } catch { Issue.record("Shared session request failed: \(error)") }
                await events.mark("other")
            }
            try await events.wait("other")
            await completed.value
        } catch {
            await blocked.close()
            await other.close()
            await blockedServer.stop()
            await replyServer.stop()
            await events.stop()
            session.invalidateAndCancel()
            throw error
        }
        await other.close()
        await blockedServer.stop()
        await replyServer.stop()
        await events.stop()
        session.invalidateAndCancel()
    }
}
