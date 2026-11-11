import Foundation

/// MCP's newline-delimited stdio framing and bounded stderr tail.
/// Incomplete lines are kept as chunks and joined only after a newline.
actor JsonRpcLineReader {
    private let maxMessageBytes: Int
    private let maxStderrBytes: Int
    private let onStderr: (@Sendable (String) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var stderrData = Data()
    private var messages: [Data] = []
    private var messageHead = 0
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var ended = false

    init(maxMessageBytes: Int, maxStderrBytes: Int, onStderr: (@Sendable (String) -> Void)? = nil, onError: (@Sendable (Error) -> Void)? = nil) {
        self.maxMessageBytes = maxMessageBytes
        self.maxStderrBytes = maxStderrBytes
        self.onStderr = onStderr
        self.onError = onError
    }

    var stderr: String { String(decoding: stderrData, as: UTF8.self) }

    func readStdout(_ chunk: Data) {
        guard !ended else { return }
        var start = chunk.startIndex
        while start < chunk.endIndex {
            if let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let part = chunk[start..<newline]
                let length = pendingBytes + part.count
                if length > maxMessageBytes {
                    report(McpTransportError.stdioMessageTooLarge(limit: maxMessageBytes))
                } else {
                    var line = Data()
                    line.reserveCapacity(length)
                    for bytes in pending { line.append(bytes) }
                    line.append(contentsOf: part)
                    handleLine(line)
                }
                pending.removeAll(keepingCapacity: true)
                pendingBytes = 0
                start = chunk.index(after: newline)
            } else {
                let part = Data(chunk[start...])
                pending.append(part)
                pendingBytes += part.count
                if pendingBytes > maxMessageBytes {
                    pending.removeAll(keepingCapacity: true)
                    pendingBytes = 0
                    report(McpTransportError.stdioMessageTooLarge(limit: maxMessageBytes))
                }
                break
            }
        }
    }

    private func handleLine(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        let normalized = text.hasSuffix("\r") ? String(text.dropLast()) : text
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let bytes = Data(normalized.utf8)
        do {
            _ = try JsonRpc.decodeIncoming(bytes)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: bytes) }
            else { messages.append(bytes) }
        } catch {
            report(error)
        }
    }

    func readStderr(_ chunk: Data) {
        stderrData.append(chunk)
        if stderrData.count > maxStderrBytes {
            stderrData.removeFirst(stderrData.count - maxStderrBytes)
        }
        onStderr?(String(decoding: chunk, as: UTF8.self))
    }

    func end() {
        guard !ended else { return }
        if !String(decoding: pending.joined(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report(McpTransportError.invalidResponse("MCP stdio server closed with an incomplete JSON-RPC message"))
        }
        pending.removeAll()
        pendingBytes = 0
        ended = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }

    func takeReady() -> Data? {
        guard messageHead < messages.count else { return nil }
        let message = messages[messageHead]
        messageHead += 1
        if messageHead > 1024 && messageHead * 2 >= messages.count {
            messages.removeFirst(messageHead)
            messageHead = 0
        }
        return message
    }

    func next() async -> Data? {
        if let message = takeReady() { return message }
        if ended { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func report(_ error: Error) { onError?(error) }
}
