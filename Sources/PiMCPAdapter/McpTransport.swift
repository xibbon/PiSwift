import Foundation
import PiSwiftAI
import PiSwiftMCP

/// Adapter-only session awareness for its legacy SSE fallback.
protocol McpSessionAwareTransport: McpTransport {
    func hasSessionIdentifier() async -> Bool
}

/// Uses the shared Streamable HTTP transport, then falls back to the older
/// HTTP+SSE endpoint protocol when the server rejects the initial POST.
public actor HttpTransport: McpSessionAwareTransport {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let streamable: StreamableHTTPTransport
    private var started = false
    private var isClosed = false
    private var usingLegacy = false
    private var receiveError: (any Error)?
    private var pendingResponses: [CheckedContinuation<Data, any Error>] = []
    private var receivedMessages: [Data] = []
    private var forwardTask: Task<Void, Never>?
    private var legacySSETask: Task<Void, Never>?
    private var legacyMessageURL: URL?
    private var legacyEndpointWaiter: CheckedContinuation<Void, any Error>?

    public init(url: URL, headers: [String: String] = [:], debug: Bool = false, session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
        self.streamable = StreamableHTTPTransport(url: url, headers: headers, debug: debug, session: session)
    }

    public func start() async throws {
        guard !isClosed else { throw McpError.transportClosed }
        guard !started else { return }
        started = true
        try await streamable.start()
        forwardTask = Task { [weak self] in await self?.forwardSharedMessages() }
    }

    public func setProtocolVersion(_ version: String) async {
        await streamable.setProtocolVersion(version)
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw McpError.transportClosed }
        if !started { try await start() }
        if usingLegacy {
            try await sendLegacySSEMessage(data)
            return
        }
        do {
            try await streamable.send(data)
        } catch let error as McpHTTPError {
            guard (error.status == 404 || error.status == 405),
                  !(await streamable.hasSessionIdentifier()) else { throw error }
            usingLegacy = true
            await streamable.close()
            try await establishLegacySSEEndpoint()
            try await sendLegacySSEMessage(data)
        }
    }

    public func receive() async throws -> Data {
        if !receivedMessages.isEmpty { return receivedMessages.removeFirst() }
        if let receiveError { throw receiveError }
        guard !isClosed else { throw McpError.transportClosed }
        return try await withCheckedThrowingContinuation { pendingResponses.append($0) }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await streamable.close()
        forwardTask?.cancel()
        legacySSETask?.cancel()
        legacyEndpointWaiter?.resume(throwing: McpError.transportClosed)
        legacyEndpointWaiter = nil
        failPending(McpError.transportClosed)
    }

    func hasSessionIdentifier() async -> Bool {
        await streamable.hasSessionIdentifier()
    }

    private func forwardSharedMessages() async {
        do {
            while !Task.isCancelled {
                let message = try await streamable.receive()
                enqueueMessage(message)
            }
        } catch {
            if !usingLegacy && !isClosed {
                receiveError = error
                failPending(error)
            }
        }
    }

    private func failPending(_ error: any Error) {
        for waiter in pendingResponses { waiter.resume(throwing: error) }
        pendingResponses.removeAll()
    }

    private func enqueueMessage(_ data: Data) {
        if let waiter = pendingResponses.first {
            pendingResponses.removeFirst()
            waiter.resume(returning: data)
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
