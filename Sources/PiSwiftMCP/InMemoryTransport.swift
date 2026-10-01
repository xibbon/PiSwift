import Foundation

/// A transport pair for tests and embedded MCP servers.
public actor InMemoryTransport: McpTransport {
    private let channel: InMemoryChannel
    private let side: Int

    private init(channel: InMemoryChannel, side: Int) {
        self.channel = channel
        self.side = side
    }

    public static func pair(maxMessageBytes: Int = mcpDefaultMaxMessageBytes) -> (InMemoryTransport, InMemoryTransport) {
        let channel = InMemoryChannel(maxMessageBytes: maxMessageBytes)
        return (InMemoryTransport(channel: channel, side: 0), InMemoryTransport(channel: channel, side: 1))
    }

    public func send(_ data: Data) async throws {
        try await channel.send(data, from: side)
    }

    public func receive() async throws -> Data {
        try await channel.receive(for: side)
    }

    public func close() async {
        await channel.close(side: side)
    }
}

private actor InMemoryChannel {
    private let maxMessageBytes: Int
    private var queues: [[Data]] = [[], []]
    private var waiters: [[CheckedContinuation<Data, any Error>]] = [[], []]
    private var closed = [false, false]

    init(maxMessageBytes: Int) { self.maxMessageBytes = maxMessageBytes }

    func send(_ data: Data, from side: Int) throws {
        guard !closed[side], !closed[1 - side] else { throw McpError.transportClosed }
        guard data.count <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
        let destination = 1 - side
        if waiters[destination].isEmpty {
            queues[destination].append(data)
        } else {
            waiters[destination].removeFirst().resume(returning: data)
        }
    }

    func receive(for side: Int) async throws -> Data {
        if !queues[side].isEmpty { return queues[side].removeFirst() }
        guard !closed[side], !closed[1 - side] else { throw McpError.transportClosed }
        return try await withCheckedThrowingContinuation { waiters[side].append($0) }
    }

    func close(side: Int) {
        guard !closed[side] else { return }
        closed[side] = true
        for index in 0...1 {
            for waiter in waiters[index] { waiter.resume(throwing: McpError.transportClosed) }
            waiters[index].removeAll()
        }
    }
}
