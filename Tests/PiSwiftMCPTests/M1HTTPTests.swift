import Foundation
import Network
import Testing
@testable import PiSwiftMCP

@Suite("MCP v1.5.2 Streamable HTTP")
struct M1HTTPTests {
    private let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

    @Test("recognizes CR, LF, and CRLF line endings, including CRLF split across chunks", .timeLimit(.minutes(1)), arguments: ["\n", "\r\n", "\r"])
    func lineEndings(_ separator: String) async throws {
        let response = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#
        let lines = ["id: 1", "data: \(response)", "", ""].joined(separator: separator)
        let server = try M1HTTPServer(status: 200, contentType: "text/event-stream", body: Data(lines.utf8), chunkSize: 1)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        try await transport.send(request)
        let message = try await transport.receive()
        #expect(String(decoding: message, as: UTF8.self).contains("tools"))
        await transport.close()
        await server.stop()
    }

    @Test("dispatches CR-terminated events while the stream stays open", .timeLimit(.minutes(1)))
    func dispatchesCRWhileOpen() async throws {
        let body = Data(#"data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8) + Data("\r\r".utf8)
        let server = try M1HTTPServer(status: 200, contentType: "text/event-stream", body: body, keepOpen: true)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        try await transport.send(request)
        let message = try await transport.receive()
        #expect(String(decoding: message, as: UTF8.self).contains("tools"))
        await transport.close()
        await server.stop()
    }

    @Test("cancels the stream when an event exceeds the limit", .timeLimit(.minutes(1)))
    func oversizedSSECancels() async throws {
        let server = try M1HTTPServer(status: 200, contentType: "text/event-stream", body: Data(("data: " + String(repeating: "x", count: 512) + "\n\n").utf8), keepOpen: true)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false, maxMessageBytes: 128)
        try await transport.send(request)
        let message = try await transport.receive()
        #expect(String(decoding: message, as: UTF8.self).contains("MCP SSE event exceeds 128 bytes"))
        #expect(try await server.waitForPeerClose())
        await transport.close()
        await server.stop()
    }

    @Test("applies maxMessageBytes to JSON responses", .timeLimit(.minutes(1)), arguments: [32, 2048])
    func boundsJSON(_ descriptionBytes: Int) async throws {
        let body = Data((#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":""# + String(repeating: "x", count: descriptionBytes) + #"","inputSchema":{}}]}}"#).utf8)
        let server = try M1HTTPServer(status: 200, contentType: "application/json", body: body, keepOpen: descriptionBytes > 512)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false, maxMessageBytes: 512)
        if descriptionBytes <= 512 {
            try await transport.send(request)
            #expect(String(decoding: try await transport.receive(), as: UTF8.self).contains("echo"))
        } else {
            do {
                try await transport.send(request)
                Issue.record("Expected JSON size error")
            } catch {
                #expect(error.localizedDescription == "MCP JSON response exceeds 512 bytes")
            }
            #expect(try await server.waitForPeerClose())
        }
        await transport.close()
        await server.stop()
    }

    @Test("decodes JSON responses split inside a BOM and a multi-byte character", .timeLimit(.minutes(1)))
    func splitBOMAndUnicode() async throws {
        let body = Data(("\u{FEFF}" + #"{"jsonrpc":"2.0","id":1,"result":{"text":"é€"}}"#).utf8)
        let server = try M1HTTPServer(status: 200, contentType: "application/json", body: body, chunkSize: 1)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        try await transport.send(request)
        let message = try await transport.receive()
        #expect(String(decoding: message, as: UTF8.self).contains("é€"))
        await transport.close()
        await server.stop()
    }

    @Test("reads only an excerpt of HTTP error bodies and cancels the rest", .timeLimit(.minutes(1)))
    func boundedErrorBodyCancels() async throws {
        let server = try M1HTTPServer(status: 500, contentType: "text/plain", body: Data(repeating: UInt8(ascii: "x"), count: 16 * 1024), keepOpen: true)
        let transport = StreamableHTTPTransport(url: try await server.start(), openGetStream: false)
        do {
            try await transport.send(request)
            Issue.record("Expected HTTP error")
        } catch let error as McpHTTPError {
            #expect(error.body.utf8.count == 8 * 1024)
        }
        #expect(try await server.waitForPeerClose())
        await transport.close()
        await server.stop()
    }
}

private actor M1HTTPServer {
    private let listener: NWListener
    private let status: Int
    private let contentType: String
    private let body: Data
    private let chunkSize: Int
    private let keepOpen: Bool
    private var ready: CheckedContinuation<Void, Never>?
    private var isReady = false
    private var connections: [NWConnection] = []
    private var peerClosed = false

    init(status: Int, contentType: String, body: Data, chunkSize: Int = 16 * 1024, keepOpen: Bool = false) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.status = status
        self.contentType = contentType
        self.body = body
        self.chunkSize = chunkSize
        self.keepOpen = keepOpen
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.markReady() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener.start(queue: .global())
        if !isReady { await withCheckedContinuation { ready = $0 } }
        return try #require(URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/mcp"))
    }

    private func markReady() {
        isReady = true
        ready?.resume()
        ready = nil
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                continuation.resume(returning: error == nil && !(done && (data?.isEmpty ?? true)) ? data : nil)
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func handle(_ connection: NWConnection) async {
        connections.append(connection)
        connection.start(queue: .global())
        defer { connection.cancel() }
        var request = Data()
        while let chunk = await receive(connection) {
            request.append(chunk)
            guard let boundary = request.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let header = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            guard request.count >= boundary.upperBound + length else { continue }
            let headerData = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(keepOpen ? body.count + 1_000_000 : body.count)\r\nConnection: close\r\n\r\n".utf8)
            await send(headerData, to: connection)
            for start in stride(from: 0, to: body.count, by: chunkSize) {
                await send(body[start..<min(start + chunkSize, body.count)], to: connection)
            }
            if keepOpen {
                while await receive(connection) != nil {}
                peerClosed = true
            }
            return
        }
    }

    func waitForPeerClose() async throws -> Bool {
        for _ in 0..<100 where !peerClosed { try await Task.sleep(for: .milliseconds(10)) }
        return peerClosed
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
    }
}
