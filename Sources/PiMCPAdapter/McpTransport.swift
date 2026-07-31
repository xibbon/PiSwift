import Foundation
import PiSwiftAI

// MARK: - Transport Protocol

public protocol McpTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// Identifies a transport that can prove an active Streamable HTTP session.
/// The manager only retries a 404 when this value was true before the failed
/// operation, as required by the MCP Streamable HTTP specification.
protocol McpSessionAwareTransport: McpTransport {
    func hasSessionIdentifier() async -> Bool
}

// MARK: - Stdio Transport

#if os(macOS)
public actor StdioTransport: McpTransport {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer: Data = Data()
    private var isClosed = false
    private var pendingReceive: CheckedContinuation<Data, any Error>?
    private var receivedChunks: [Data] = []
    private let chunkStore = ChunkStore()

    private let command: String
    private let args: [String]
    private let env: [String: String]?
    private let cwd: String?
    private let debug: Bool

    public init(command: String, args: [String] = [], env: [String: String]? = nil, cwd: String? = nil, debug: Bool = false) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.debug = debug
    }

    public func start() throws {
        let proc = Process()

        if command.contains("/") {
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [command] + args
        }

        if let cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (k, v) in env { environment[k] = v }
        }
        proc.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let store = self.chunkStore
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                store.enqueue(nil) // EOF signal
            } else {
                store.enqueue(data)
            }
        }

        if debug {
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    fputs("[mcp-stdio-stderr] \(text)", Foundation.stderr)
                }
            }
        } else {
            stderr.fileHandleForReading.readabilityHandler = { _ in }
        }

        proc.terminationHandler = { _ in
            store.enqueue(nil) // EOF
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
    }

    public func send(_ data: Data) async throws {
        guard !isClosed, let pipe = stdinPipe else {
            throw McpError.transportClosed
        }
        pipe.fileHandleForWriting.write(data)
    }

    public func receive() async throws -> Data {
        while true {
            // Check buffer for complete line
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                if lineData.isEmpty { continue }
                return Data(lineData)
            }

            // Wait for more data
            guard !isClosed else { throw McpError.transportClosed }
            guard let chunk = await chunkStore.dequeue() else {
                throw McpError.transportClosed
            }
            buffer.append(chunk)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        chunkStore.enqueue(nil)
        stdinPipe?.fileHandleForWriting.closeFile()
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
    }

}

// Thread-safe chunk queue for bridging readabilityHandler → async receive
private final class ChunkStore: Sendable {
    private let state = LockedState(ChunkState())

    struct ChunkState: Sendable {
        var chunks: [Data] = []
        var eof = false
        var waiters: [CheckedContinuation<Data?, Never>] = []
    }

    func enqueue(_ data: Data?) {
        state.withLock { s in
            if let data {
                if let waiter = s.waiters.first {
                    s.waiters.removeFirst()
                    waiter.resume(returning: data)
                } else {
                    s.chunks.append(data)
                }
            } else {
                s.eof = true
                for waiter in s.waiters {
                    waiter.resume(returning: nil)
                }
                s.waiters.removeAll()
            }
        }
    }

    func dequeue() async -> Data? {
        let immediate: Data? = state.withLock { s in
            if !s.chunks.isEmpty {
                return s.chunks.removeFirst()
            }
            if s.eof { return nil }
            return nil
        }

        if immediate != nil { return immediate }
        if state.withLock({ $0.eof }) { return nil }

        return await withCheckedContinuation { continuation in
            state.withLock { s in
                if !s.chunks.isEmpty {
                    let chunk = s.chunks.removeFirst()
                    continuation.resume(returning: chunk)
                } else if s.eof {
                    continuation.resume(returning: nil)
                } else {
                    s.waiters.append(continuation)
                }
            }
        }
    }
}
#else
/// iOS applications can use remote MCP transports. Local process launch is a
/// macOS-only feature, so this type fails clearly when selected on iOS.
public actor StdioTransport: McpTransport {
    public init(command: String, args: [String] = [], env: [String: String]? = nil, cwd: String? = nil, debug: Bool = false) {}

    public func start() throws {
        throw McpError.connectionFailed("Stdio MCP servers are available only on macOS")
    }

    public func send(_ data: Data) async throws {
        throw McpError.transportClosed
    }

    public func receive() async throws -> Data {
        throw McpError.transportClosed
    }

    public func close() async {}
}
#endif

// MARK: - HTTP Transport (Streamable HTTP / legacy SSE fallback)

public actor HttpTransport: McpSessionAwareTransport {
    private let url: URL
    private let headers: [String: String]
    private let debug: Bool
    private let session: URLSession
    private var sessionUrl: URL?
    private var sessionIdentifier: String?
    private var isClosed = false
    private var pendingResponses: [CheckedContinuation<Data, any Error>] = []
    private var receivedMessages: [Data] = []
    private var sseTask: Task<Void, Never>?
    private var legacySSETask: Task<Void, Never>?
    private var legacyMessageURL: URL?
    private var legacyEndpointWaiter: CheckedContinuation<Void, any Error>?

    public init(
        url: URL,
        headers: [String: String] = [:],
        debug: Bool = false,
        session: URLSession = .shared
    ) {
        self.url = url
        self.headers = headers
        self.debug = debug
        self.session = session
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw McpError.transportClosed }

        if legacyMessageURL != nil {
            try await sendLegacySSEMessage(data)
            return
        }

        var request = URLRequest(url: sessionUrl ?? url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionIdentifier {
            request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw McpError.protocolError("Non-HTTP response")
        }
        captureSessionIdentifier(httpResponse)

        if httpResponse.statusCode == 202 {
            openSseStreamIfNeeded()
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // The older MCP SSE transport opens a GET event stream first and
            // supplies a separate POST endpoint in an `endpoint` event. Try
            // it only for the normal method-not-supported responses. This
            // preserves authentication and ordinary HTTP errors as-is.
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                try await establishLegacySSEEndpoint()
                try await sendLegacySSEMessage(data)
                return
            }
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw McpError.protocolError("HTTP \(httpResponse.statusCode): \(body)")
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            parseSSEData(responseData)
        } else {
            enqueueMessage(responseData)
        }
        openSseStreamIfNeeded()
    }

    public func receive() async throws -> Data {
        guard !isClosed else { throw McpError.transportClosed }
        if !receivedMessages.isEmpty {
            return receivedMessages.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses.append(continuation)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        sseTask?.cancel()
        legacySSETask?.cancel()
        legacyEndpointWaiter?.resume(throwing: McpError.transportClosed)
        legacyEndpointWaiter = nil
        for cont in pendingResponses {
            cont.resume(throwing: McpError.transportClosed)
        }
        pendingResponses.removeAll()
    }

    func hasSessionIdentifier() -> Bool {
        sessionIdentifier != nil
    }

    private func enqueueMessage(_ data: Data) {
        if let cont = pendingResponses.first {
            pendingResponses.removeFirst()
            cont.resume(returning: data)
        } else {
            receivedMessages.append(data)
        }
    }

    private func parseSSEData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var eventName: String?
        var eventData = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5)
                eventData += value.first == " " ? String(value.dropFirst()) : String(value)
            } else if line.isEmpty && !eventData.isEmpty {
                handleSSEEvent(name: eventName, data: eventData)
                eventName = nil
                eventData = ""
            }
        }
        if !eventData.isEmpty {
            handleSSEEvent(name: eventName, data: eventData)
        }
    }

    private func captureSessionIdentifier(_ response: HTTPURLResponse) {
        guard let identifier = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !identifier.isEmpty else { return }
        sessionIdentifier = identifier
    }

    /// A Streamable HTTP server can send later messages through its optional
    /// GET event stream. Servers that reject GET are still valid POST-only MCP
    /// servers, so failure here never fails the active request.
    private func openSseStreamIfNeeded() {
        guard sseTask == nil, legacySSETask == nil, !isClosed, let sessionIdentifier else { return }
        var request = URLRequest(url: sessionUrl ?? url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let activeSession = session

        sseTask = Task { [weak self] in
            do {
                let (bytes, response) = try await activeSession.bytes(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { return }
                var eventName: String?
                var eventData = ""
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") {
                        eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let value = line.dropFirst(5)
                        eventData += value.first == " " ? String(value.dropFirst()) : String(value)
                    } else if line.isEmpty, !eventData.isEmpty {
                        await self?.handleSSEEvent(name: eventName, data: eventData)
                        eventName = nil
                        eventData = ""
                    }
                }
                if !eventData.isEmpty {
                    await self?.handleSSEEvent(name: eventName, data: eventData)
                }
            } catch {
                // The POST request path remains usable when the optional
                // stream closes or is unsupported.
            }
        }
    }

    private func establishLegacySSEEndpoint() async throws {
        if legacyMessageURL != nil { return }
        if legacySSETask == nil {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let activeSession = session
            legacySSETask = Task { [weak self] in
                do {
                    let (bytes, response) = try await activeSession.bytes(for: request)
                    guard let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode) else {
                        await self?.failLegacyEndpoint(McpError.protocolError("Legacy MCP SSE endpoint was not available"))
                        return
                    }
                    var eventName: String?
                    var eventData = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let value = line.dropFirst(5)
                            eventData += value.first == " " ? String(value.dropFirst()) : String(value)
                        } else if line.isEmpty, !eventData.isEmpty {
                            await self?.handleSSEEvent(name: eventName, data: eventData)
                            eventName = nil
                            eventData = ""
                        }
                    }
                    if !eventData.isEmpty {
                        await self?.handleSSEEvent(name: eventName, data: eventData)
                    }
                    await self?.failLegacyEndpoint(McpError.transportClosed)
                } catch is CancellationError {
                    // `close()` resumes the waiting request, if any.
                } catch {
                    await self?.failLegacyEndpoint(error)
                }
            }
        }
        try await waitForLegacyEndpoint()
    }

    private func waitForLegacyEndpoint() async throws {
        if legacyMessageURL != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            if legacyMessageURL != nil {
                continuation.resume()
            } else if isClosed {
                continuation.resume(throwing: McpError.transportClosed)
            } else {
                legacyEndpointWaiter = continuation
            }
        }
    }

    private func sendLegacySSEMessage(_ data: Data) async throws {
        guard let legacyMessageURL else { throw McpError.transportClosed }
        var request = URLRequest(url: legacyMessageURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw McpError.protocolError("Non-HTTP response")
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw McpError.protocolError("HTTP \(response.statusCode): \(body)")
        }
        guard !responseData.isEmpty else { return }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            parseSSEData(responseData)
        } else {
            enqueueMessage(responseData)
        }
    }

    private func handleSSEEvent(name: String?, data: String) {
        if name == "endpoint" {
            guard let endpoint = URL(string: data, relativeTo: url)?.absoluteURL else {
                failLegacyEndpoint(McpError.protocolError("Legacy MCP SSE server returned an invalid message endpoint"))
                return
            }
            legacyMessageURL = endpoint
            legacyEndpointWaiter?.resume()
            legacyEndpointWaiter = nil
            return
        }
        if let message = data.data(using: .utf8) {
            enqueueMessage(message)
        }
    }

    private func failLegacyEndpoint(_ error: any Error) {
        guard legacyMessageURL == nil else { return }
        legacyEndpointWaiter?.resume(throwing: error)
        legacyEndpointWaiter = nil
    }
}
