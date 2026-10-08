import Foundation
import Network
import Testing
@testable import PiSwiftMCP

@Suite("HTTP close v1.1.0")
struct TransportCloseV110Tests {
    @Test(.timeLimit(.minutes(1)))
    func deleteUsesLatestTokenAndFixedHeaders() async throws {
        let server = try V110CloseServer()
        let provider = V110TokenProvider(tokens: ["token-1", "token-2"])
        let transport = StreamableHTTPTransport(
            url: try await server.start(),
            headers: ["X-Custom": "fixed", "Mcp-Session-Id": "old-session", "MCP-Protocol-Version": "old-version"],
            authProvider: provider, openGetStream: false
        )
        do {
            try await transport.send(v110Request(1))
            await transport.setProtocolVersion("2025-11-25")
            try await transport.send(v110Request(2))
            await transport.close()
            await transport.close()
            let requests = await server.requests
            #expect(requests.filter { $0.method == "DELETE" }.count == 1)
            let deletion = try #require(requests.last)
            #expect(deletion.method == "DELETE")
            #expect(deletion.headers["authorization"] == "Bearer token-2")
            #expect(deletion.headers["mcp-session-id"] == "session-1")
            #expect(deletion.headers["mcp-protocol-version"] == "2025-11-25")
            #expect(deletion.headers["x-custom"] == "fixed")
            #expect(await provider.calls == 2)
        } catch {
            await transport.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func deleteWorksWithoutAuthProvider() async throws {
        let server = try V110CloseServer()
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        do {
            try await transport.send(v110Request(1))
            await transport.close()
            let deletion = try #require(await server.requests.last)
            #expect(deletion.method == "DELETE")
            #expect(deletion.headers["authorization"] == nil)
            #expect(deletion.headers["mcp-session-id"] == "session-1")
        } catch {
            await transport.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [String?.none, ""])
    func latestMissingTokenClearsStoredToken(token: String?) async throws {
        let server = try V110CloseServer()
        let provider = V110TokenProvider(tokens: ["token-1", token])
        let transport = StreamableHTTPTransport(
            url: try await server.start(), authProvider: provider, openGetStream: false
        )
        do {
            try await transport.send(v110Request(1))
            try await transport.send(v110Request(2))
            await transport.close()
            let deletion = try #require(await server.requests.last)
            #expect(deletion.method == "DELETE")
            #expect(deletion.headers["authorization"] == nil)
            #expect(await provider.calls == 2)
        } catch {
            await transport.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func closeDoesNotWaitForTokenRefresh() async throws {
        let server = try V110CloseServer()
        let provider = V110TokenProvider(tokens: ["token-1"])
        let transport = StreamableHTTPTransport(
            url: try await server.start(), authProvider: provider, openGetStream: false
        )
        let events = V110CloseEvents()
        try await transport.send(v110Request(1))
        await provider.arm()
        let closing = Task {
            await transport.close()
            await events.mark("closed")
        }
        do {
            // The provider waits for release if close calls token() again.
            try await events.wait("closed", timeout: .seconds(2))
            #expect(await provider.calls == 1)
            let deletion = try #require(await server.requests.last)
            #expect(deletion.method == "DELETE")
            #expect(deletion.headers["authorization"] == "Bearer token-1")
        } catch {
            await provider.release()
            await closing.value
            await server.stop()
            throw error
        }
        await provider.release()
        await closing.value
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [V110CloseServer.DeleteMode.failure, .disconnect])
    private func deleteFailureDoesNotFailClose(mode: V110CloseServer.DeleteMode) async throws {
        let server = try V110CloseServer(deleteMode: mode)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        do {
            try await transport.send(v110Request(1))
            await transport.close()
            #expect(await server.requests.contains { $0.method == "DELETE" })
            await #expect(throws: McpError.transportClosed) {
                try await transport.send(v110Request(2))
            }
        } catch {
            await transport.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [V110CloseServer.DeleteMode.stall, .slowBody])
    private func stalledDeleteHasOneSecondTimeout(mode: V110CloseServer.DeleteMode) async throws {
        let server = try V110CloseServer(deleteMode: mode)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        do {
            try await transport.send(v110Request(1))
            let started = ContinuousClock.now
            await transport.close()
            let elapsed = ContinuousClock.now - started
            #expect(elapsed >= .milliseconds(750))
            #expect(elapsed < .seconds(3))
            #expect(await server.requests.filter { $0.method == "DELETE" }.count == 1)
        } catch {
            await transport.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }
}

private func v110Request(_ id: Int) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}".utf8)
}

private enum V110CloseError: Error { case deadline }

private actor V110CloseEvents {
    private var completed: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, any Error>] = [:]

    func mark(_ key: String) {
        completed.insert(key)
        waiters.removeValue(forKey: key)?.resume()
    }

    func wait(_ key: String, timeout: Duration = .seconds(5)) async throws {
        if completed.contains(key) { return }
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self.expire(key)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { waiters[key] = $0 }
    }

    private func expire(_ key: String) {
        waiters.removeValue(forKey: key)?.resume(throwing: V110CloseError.deadline)
    }
}

private actor V110TokenProvider: McpAuthProvider {
    private let tokens: [String?]
    private var armed = false
    private let events = V110CloseEvents()
    private(set) var calls = 0

    init(tokens: [String?]) { self.tokens = tokens }
    func arm() { armed = true }
    func release() async { await events.mark("release") }

    func token() async throws -> String? {
        calls += 1
        if armed { try await events.wait("release") }
        return tokens[min(calls - 1, tokens.count - 1)]
    }

    func onUnauthorized(challenge: String?, serverURL: URL, rejectedToken: String?) async throws {}
}

private struct V110CloseRequest: Sendable {
    let method: String
    let headers: [String: String]
}

private actor V110CloseServer {
    enum DeleteMode: Sendable { case normal, failure, disconnect, stall, slowBody }
    private let listener: NWListener
    private let deleteMode: DeleteMode
    private let events = V110CloseEvents()
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private(set) var requests: [V110CloseRequest] = []

    init(deleteMode: DeleteMode = .normal) throws {
        self.deleteMode = deleteMode
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

    func stop() {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func handle(_ connection: NWConnection) async {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
            connections[id] = nil
        }
        var data = Data()
        while let chunk = await receive(connection), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 64 * 1024 else { return }
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let lines = String(decoding: data[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard data.count >= boundary.upperBound + length else { continue }
            let method = lines[0].split(separator: " ").first.map(String.init) ?? ""
            requests.append(V110CloseRequest(method: method, headers: headers))
            if method == "DELETE" {
                switch deleteMode {
                case .disconnect: return
                case .stall:
                    while let chunk = await receive(connection), !chunk.isEmpty {}
                    return
                case .slowBody:
                    // Bytes renew an idle timeout, but must not extend the total deadline.
                    await sendRaw("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx", to: connection)
                    for _ in 0..<12 {
                        do { try await Task.sleep(for: .milliseconds(250)) }
                        catch { return }
                        guard !stopped else { return }
                        await sendRaw("x", to: connection)
                    }
                case .failure:
                    await send(status: "503 Service Unavailable", to: connection)
                case .normal:
                    await send(status: "200 OK", to: connection)
                }
            } else {
                await send(
                    status: "200 OK",
                    headers: "Content-Type: application/json\r\nMcp-Session-Id: session-1\r\n",
                    body: #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                    to: connection
                )
            }
            return
        }
    }

    private func send(status: String, headers: String = "", body: String = "", to connection: NWConnection) async {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\(headers)\r\n\(body)"
        await sendRaw(response, to: connection)
    }

    private func sendRaw(_ text: String, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
