import Foundation
import Testing
@testable import PiMCPAdapter

@Suite("MCP Trace")
struct McpTraceTests {
    @Test("records protocol metadata without recording payload content")
    func recordsMetadataOnly() async throws {
        let secret = "do-not-persist-this-value"
        let base = TraceTransport(received: Data(#"{"jsonrpc":"2.0","id":2,"result":{"token":"\#(secret)"}}"#.utf8))
        let sink = InMemoryTraceSink()
        let transport = McpTracingTransport(
            base: base,
            serverName: "demo",
            transportName: "stdio",
            sink: sink
        )

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"secret":"\#(secret)"}}"#.utf8))
        _ = try await transport.receive()

        let events = await sink.events()
        #expect(events.count == 2)
        #expect(events[0].direction == "outbound")
        #expect(events[0].kind == "request")
        #expect(events[0].method == "tools/call")
        #expect(events[0].serverName == "demo")
        #expect(events[1].direction == "inbound")
        #expect(events[1].kind == "response")
        #expect(events[1].method == nil)
        #expect(!String(describing: events).contains(secret))

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":3,"method":"secret/\#(secret)"}"#.utf8))
        let redacted = try await eventuallyTraceEvent(from: sink, count: 3)
        #expect(redacted[2].method == "[REDACTED]")
    }
}

private func eventuallyTraceEvent(from sink: InMemoryTraceSink, count: Int) async throws -> [McpTraceEvent] {
    for _ in 0..<100 {
        let events = await sink.events()
        if events.count >= count { return events }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw McpError.timeout
}

private actor TraceTransport: McpTransport {
    private let received: Data

    init(received: Data) {
        self.received = received
    }

    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { received }
    func close() async {}
}

private actor InMemoryTraceSink: McpTraceSink {
    private var recorded: [McpTraceEvent] = []

    func record(_ event: McpTraceEvent) async {
        recorded.append(event)
    }

    func events() -> [McpTraceEvent] { recorded }
}
