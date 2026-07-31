import Foundation
import PiSwiftAI

public struct McpTraceSettings: Codable, Sendable {
    public var enabled: Bool?
    public var maxEvents: Int?

    public init(enabled: Bool? = nil, maxEvents: Int? = nil) {
        self.enabled = enabled
        self.maxEvents = maxEvents
    }
}

public struct McpTraceEvent: Sendable {
    public let timestamp: Date
    public let serverName: String
    public let transport: String
    public let direction: String
    public let kind: String
    public let method: String?
    public let byteCount: Int

    public init(timestamp: Date = Date(), serverName: String, transport: String, direction: String, kind: String, method: String?, byteCount: Int) {
        self.timestamp = timestamp
        self.serverName = serverName
        self.transport = transport
        self.direction = direction
        self.kind = kind
        self.method = method
        self.byteCount = byteCount
    }
}

/// Receives metadata-only MCP protocol events. Event values never include
/// parameters, result content, headers, URLs, or authorization values.
public protocol McpTraceSink: Sendable {
    func record(_ event: McpTraceEvent) async
}

actor McpTracingTransport: McpTransport {
    private let base: any McpTransport
    private let serverName: String
    private let transportName: String
    private let sink: any McpTraceSink

    init(base: any McpTransport, serverName: String, transportName: String, sink: any McpTraceSink) {
        self.base = base
        self.serverName = serverName
        self.transportName = transportName
        self.sink = sink
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
        await sink.record(traceEvent(data: data, direction: "outbound"))
    }

    func receive() async throws -> Data {
        let data = try await base.receive()
        await sink.record(traceEvent(data: data, direction: "inbound"))
        return data
    }

    func close() async {
        await base.close()
    }

    private func traceEvent(data: Data, direction: String) -> McpTraceEvent {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let method = object?["method"] as? String
        let kind = method == nil ? "response" : (object?["id"] == nil ? "notification" : "request")
        return McpTraceEvent(
            serverName: redactTraceText(serverName),
            transport: transportName,
            direction: direction,
            kind: kind,
            method: method.map { redactTraceText($0) },
            byteCount: data.count
        )
    }

    /// A server controls method names. Do not let a malformed server use one
    /// as a side channel for credentials or URLs in host trace storage.
    private func redactTraceText(_ value: String, maxLength: Int = 120) -> String {
        let sensitiveTerms = ["token", "secret", "password", "passwd", "api_key", "apikey", "authorization", "cookie"]
        let lower = value.lowercased()
        if sensitiveTerms.contains(where: { lower.contains($0) }) {
            return "[REDACTED]"
        }
        if lower.contains("://") { return "[REDACTED_URL]" }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }
}
