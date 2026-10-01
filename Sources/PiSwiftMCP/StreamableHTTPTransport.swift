import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct McpHTTPReconnectOptions: Sendable {
    public var initialDelay: Duration
    public var maxDelay: Duration
    public var maxRetries: Int

    public init(initialDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30), maxRetries: Int = 5) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
    }
}

/// MCP Streamable HTTP with optional GET notifications and event-ID resume.
public actor StreamableHTTPTransport: McpSessionAwareTransport {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let authProvider: (any McpAuthProvider)?
    private let maxMessageBytes: Int
    private let openGetStream: Bool
    private let reconnect: McpHTTPReconnectOptions
    private var protocolVersion: String?
    private var sessionIdentifier: String?
    private var closed = false
    private var messages: [Data] = []
    private var waiters: [CheckedContinuation<Data, any Error>] = []
    private var getTask: Task<Void, Never>?
    private var responseTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        url: URL,
        headers: [String: String] = [:],
        debug: Bool = false,
        session: URLSession = .shared,
        authProvider: (any McpAuthProvider)? = nil,
        openGetStream: Bool = true,
        maxMessageBytes: Int = mcpDefaultMaxMessageBytes,
        reconnect: McpHTTPReconnectOptions = .init()
    ) {
        self.url = url
        self.headers = headers
        self.session = session
        self.authProvider = authProvider
        self.openGetStream = openGetStream
        self.maxMessageBytes = maxMessageBytes
        self.reconnect = reconnect
        _ = debug
    }

    public var sessionID: String? { sessionIdentifier }
    public func hasSessionIdentifier() -> Bool { sessionIdentifier != nil }
    public func setProtocolVersion(_ version: String) async { protocolVersion = version }

    public func send(_ data: Data) async throws {
        guard !closed else { throw McpError.transportClosed }
        guard data.count <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
        let info = try Self.messageInfo(data)
        let (bytes, response) = try await authorizedRequest(method: "POST", accept: "application/json, text/event-stream", body: data)
        try await check(response: response, bytes: bytes)
        captureSession(response)

        if info.id == nil {
            // Notifications and client responses have no reply. The server may
            // acknowledge them with an empty 202 body.
            if info.method == "notifications/initialized" { startGetStreamIfNeeded() }
            return
        }
        if response.statusCode == 202 || response.statusCode == 204 {
            throw McpHTTPError(status: response.statusCode, body: "", message: "MCP server accepted request \(info.method ?? "") without a response")
        }
        let type = Self.contentType(response)
        if type == "application/json" {
            let body = try await readBody(bytes)
            try enqueueJSON(body)
            return
        }
        if type == "text/event-stream" {
            let taskID = UUID()
            let requestID = info.id
            responseTasks[taskID] = Task { [weak self] in
                await self?.consumeResponseStream(bytes, requestID: requestID)
                await self?.removeResponseTask(taskID)
            }
            return
        }
        throw McpTransportError.invalidResponse("Unsupported MCP response content type: \(type ?? "missing")")
    }

    public func receive() async throws -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        guard !closed else { throw McpError.transportClosed }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        getTask?.cancel()
        for task in responseTasks.values { task.cancel() }
        responseTasks.removeAll()
        for waiter in waiters { waiter.resume(throwing: McpError.transportClosed) }
        waiters.removeAll()
        guard sessionIdentifier != nil else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 1
        do {
            _ = try await applyHeaders(to: &request)
            _ = try await session.data(for: request)
        } catch {
            // Session expiry on the server is sufficient when DELETE fails.
        }
    }

    private func removeResponseTask(_ id: UUID) { responseTasks[id] = nil }

    private func enqueue(_ data: Data) {
        if waiters.isEmpty { messages.append(data) }
        else { waiters.removeFirst().resume(returning: data) }
    }

    private func enqueueJSON(_ data: Data) throws {
        guard data.count <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [Any] {
            for item in array {
                let itemData = try JSONSerialization.data(withJSONObject: item)
                enqueue(itemData)
            }
        } else {
            enqueue(data)
        }
    }

    private func applyHeaders(to request: inout URLRequest, accept: String? = nil, lastEventID: String? = nil) async throws -> String? {
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let sessionIdentifier { request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let token = try await authProvider?.token()
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return token
    }

    private func authorizedRequest(method: String, accept: String, body: Data? = nil, lastEventID: String? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let token = try await applyHeaders(to: &request, accept: accept, lastEventID: lastEventID)
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw McpTransportError.invalidResponse("Non-HTTP response") }
            let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")
            let needsAuth = response.statusCode == 401 || (response.statusCode == 403 && challenge?.range(of: "insufficient_scope", options: .caseInsensitive) != nil)
            if attempt == 0, needsAuth, let authProvider {
                try await authProvider.onUnauthorized(challenge: challenge, serverURL: url, rejectedToken: token)
                continue
            }
            return (bytes, response)
        }
        throw McpTransportError.invalidResponse("Authorization retry did not return a response")
    }

    private func check(response: HTTPURLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let data = (try? await readErrorBody(bytes)) ?? Data()
        let body = String(decoding: data, as: UTF8.self)
        if response.statusCode == 401 {
            throw McpAuthRequiredError(status: 401, body: body, wwwAuthenticate: response.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        if response.statusCode == 404, sessionIdentifier != nil { throw McpSessionExpiredError(body: body) }
        let snippet = String(body.prefix(500))
        let message = "MCP HTTP request failed with status \(response.statusCode)\(snippet.isEmpty ? "" : ": \(snippet)")"
        throw McpHTTPError(status: response.statusCode, body: body, message: message)
    }

    private func captureSession(_ response: HTTPURLResponse) {
        if let identifier = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !identifier.isEmpty {
            sessionIdentifier = identifier
        }
    }

    private func readBody(_ bytes: URLSession.AsyncBytes, limit: Int? = nil) async throws -> Data {
        let byteLimit = limit ?? maxMessageBytes
        var body = Data()
        for try await byte in bytes {
            guard body.count < byteLimit else { throw McpTransportError.messageTooLarge(limit: byteLimit) }
            body.append(byte)
        }
        return body
    }

    private func readErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            if body.count == 8 * 1024 { break }
            body.append(byte)
        }
        return body
    }

    private func startGetStreamIfNeeded() {
        guard openGetStream, getTask == nil, !closed else { return }
        getTask = Task { [weak self] in await self?.runGetStream() }
    }

    private func runGetStream() async {
        var cursor = SSECursor()
        var attempts = 0
        while !closed, !Task.isCancelled {
            do {
                let (bytes, response) = try await authorizedRequest(method: "GET", accept: "text/event-stream", lastEventID: cursor.lastEventID)
                if response.statusCode == 405 { return }
                try await check(response: response, bytes: bytes)
                guard Self.contentType(response) == "text/event-stream" else {
                    throw McpTransportError.invalidResponse("Unsupported MCP GET response content type")
                }
                captureSession(response)
                let started = ContinuousClock.now
                _ = try await consumeSSE(bytes, cursor: &cursor, responseID: nil)
                if cursor.received || ContinuousClock.now - started > reconnect.maxDelay { attempts = 0 }
            } catch {
                if closed || Task.isCancelled { return }
                guard Self.isRetryable(error) else { return }
            }
            cursor.received = false
            guard attempts < reconnect.maxRetries else { return }
            let delay = reconnectDelay(attempt: attempts, serverDelay: cursor.retry)
            attempts += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func consumeResponseStream(_ initialBytes: URLSession.AsyncBytes, requestID: String?) async {
        var cursor = SSECursor()
        var bytes: URLSession.AsyncBytes? = initialBytes
        var attempts = 0
        var failure: (any Error)?
        while !closed, !Task.isCancelled {
            if let current = bytes {
                do {
                    let answered = try await consumeSSE(current, cursor: &cursor, responseID: requestID)
                    if answered { return }
                    failure = nil
                } catch {
                    failure = error
                    if !Self.isRetryable(error) { break }
                }
            }
            guard let lastID = cursor.lastEventID, attempts < reconnect.maxRetries else { break }
            if cursor.received { attempts = 0 }
            cursor.received = false
            let delay = reconnectDelay(attempt: attempts, serverDelay: cursor.retry)
            attempts += 1
            do {
                try await Task.sleep(for: delay)
                let (next, response) = try await authorizedRequest(method: "GET", accept: "text/event-stream", lastEventID: lastID)
                if response.statusCode == 405 { break }
                try await check(response: response, bytes: next)
                bytes = next
            } catch {
                failure = error
                guard Self.isRetryable(error) else { break }
                bytes = nil
            }
        }
        guard !closed, !Task.isCancelled, let requestID else { return }
        let reason = failure.map { String(describing: $0) } ?? "stream ended without a response"
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": Self.jsonID(requestID),
            "error": ["code": -32603, "message": "MCP response stream failed: \(reason)"]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: message) { enqueue(data) }
    }

    private func consumeSSE(_ bytes: URLSession.AsyncBytes, cursor: inout SSECursor, responseID: String?) async throws -> Bool {
        var event = SSEEvent()
        var eventBytes = 0
        var rawLine = Data()
        func processLine(_ rawLine: Data) throws -> Bool {
            if closed || Task.isCancelled { return false }
            let text = String(decoding: rawLine, as: UTF8.self)
            let line = text.hasSuffix("\r") ? String(text.dropLast()) : text
            if line.isEmpty {
                if try dispatch(event, cursor: &cursor, responseID: responseID) { return true }
                event = SSEEvent()
                eventBytes = 0
                return false
            }
            if line.hasPrefix(":") { return false }
            let split = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(split[0])
            var value = split.count > 1 ? String(split[1]) : ""
            if value.first == " " { value.removeFirst() }
            switch field {
            case "data":
                eventBytes += value.utf8.count + (event.dataLines.isEmpty ? 0 : 1)
                guard eventBytes <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
                event.dataLines.append(value)
            case "event": event.name = value
            case "id" where !value.contains("\0"):
                event.id = value
                cursor.lastEventID = value
            case "retry":
                if let milliseconds = UInt64(value) { cursor.retry = .milliseconds(milliseconds) }
            default: break
            }
            return false
        }
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if try processLine(rawLine) { return true }
                rawLine.removeAll(keepingCapacity: true)
            } else {
                rawLine.append(byte)
                guard rawLine.count <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
            }
        }
        if !rawLine.isEmpty, try processLine(rawLine) { return true }
        return try dispatch(event, cursor: &cursor, responseID: responseID)
    }

    private func dispatch(_ event: SSEEvent, cursor: inout SSECursor, responseID: String?) throws -> Bool {
        guard !event.dataLines.isEmpty else { return false }
        cursor.received = true
        let payload = event.dataLines.joined(separator: "\n")
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.name == nil || event.name == "message" else { return false }
        guard let data = payload.data(using: .utf8) else { return false }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return false }
        enqueue(data)
        if let responseID, let id = dictionary["id"] { return Self.idString(id) == responseID }
        return false
    }

    private func reconnectDelay(attempt: Int, serverDelay: Duration?) -> Duration {
        if let serverDelay { return serverDelay }
        let multiplier = 1 << min(attempt, 20)
        return min(reconnect.initialDelay * multiplier, reconnect.maxDelay)
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if let http = error as? McpHTTPError { return http.status == 408 || http.status == 429 || http.status >= 500 }
        if error is McpAuthRequiredError || error is McpSessionExpiredError || error is McpTransportError { return false }
        return error is URLError
    }

    private static func contentType(_ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func messageInfo(_ data: Data) throws -> (id: String?, method: String?) {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw McpTransportError.invalidResponse("JSON-RPC message is not an object") }
        return (dictionary["id"].map(idString), dictionary["method"] as? String)
    }

    private static func idString(_ value: Any) -> String {
        if let string = value as? String { return "s:\(string)" }
        return "n:\(value)"
    }

    private static func jsonID(_ value: String) -> Any {
        if value.hasPrefix("s:") { return String(value.dropFirst(2)) }
        return Int(value.dropFirst(2)) ?? String(value.dropFirst(2))
    }
}

private struct SSECursor {
    var lastEventID: String?
    var retry: Duration?
    var received = false
}

private struct SSEEvent {
    var name: String?
    var id: String?
    var dataLines: [String] = []
}
