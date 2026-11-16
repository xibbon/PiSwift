import Foundation

/// Parsed Server-Sent Events frame. Mirrors upstream `pi-mono`'s `ServerSentEvent` shape so
/// providers that fetch via raw HTTP and parse SSE in-process (instead of relying on a vendor
/// SDK) have a consistent typed surface to work against.
public struct ServerSentEvent: Sendable {
    /// `event:` line value (e.g., `"message_start"` for Anthropic). May be `nil` for
    /// generic data-only frames.
    public let event: String?
    /// `data:` lines joined by newline. SSE spec allows multiple `data:` lines per event.
    public let data: String
    /// Original line forms received before joining. Useful for diagnostics when a JSON
    /// payload fails to parse.
    public let raw: [String]
}

/// Parses a streaming HTTP body's bytes into SSE frames. Supports CR, LF, and CRLF line
/// endings, multi-line `data:` fields, comment lines (lines starting with `:`), and the
/// `event:` field. Behaves like `iterateSseMessages` in upstream pi-mono — accumulates lines
/// in a state machine and flushes when an empty line is seen.
public func iterateSseEvents(
    bytes: URLSession.AsyncBytes,
    signal: CancellationToken? = nil
) -> AsyncThrowingStream<ServerSentEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                var lines = SseLineBuffer()
                var state = SseDecoderState()
                for try await byte in bytes {
                    if signal?.isCancelled == true {
                        throw CancellationError()
                    }
                    lines.append(byte)
                    lines.drain(state: &state, final: false) { continuation.yield($0) }
                }
                lines.finish(state: &state) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Parses provider-client body chunks into SSE frames.
public func iterateSseEvents(
    body: AsyncThrowingStream<Data, Error>,
    signal: CancellationToken? = nil
) -> AsyncThrowingStream<ServerSentEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                var lines = SseLineBuffer()
                var state = SseDecoderState()
                for try await chunk in body {
                    if signal?.isCancelled == true {
                        throw CancellationError()
                    }
                    lines.append(chunk)
                    lines.drain(state: &state, final: false) { continuation.yield($0) }
                }
                lines.finish(state: &state) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Accumulates body bytes and splits them into lines. Each byte is examined
/// once, so a long line (for example, a base64 image) costs linear time.
struct SseLineBuffer {
    private var bytes: [UInt8] = []
    /// The first byte of the current line.
    private var start = 0
    /// The next byte to examine.
    private var scan = 0

    mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// The next complete line, without its terminator. A CR at the end of the
    /// buffer can be the first half of CRLF, so it waits for more bytes
    /// unless `final` is true.
    mutating func nextLine(final: Bool) -> String? {
        while scan < bytes.count {
            let byte = bytes[scan]
            guard byte == 10 || byte == 13 else {
                scan += 1
                continue
            }
            var next = scan + 1
            if byte == 13 {
                if next == bytes.count && !final { return nil }
                if next < bytes.count && bytes[next] == 10 { next += 1 }
            }
            let line = String(bytes: bytes[start..<scan], encoding: .utf8) ?? ""
            start = next
            scan = next
            compact()
            return line
        }
        return nil
    }

    /// Bytes after the last line terminator.
    var remainder: String? {
        start < bytes.count ? String(bytes: bytes[start...], encoding: .utf8) : nil
    }

    private mutating func compact() {
        guard start > 0 else { return }
        if start == bytes.count {
            bytes.removeAll(keepingCapacity: true)
        } else if start >= 64 * 1024 && start * 2 >= bytes.count {
            bytes.removeFirst(start)
        } else {
            return
        }
        scan -= start
        start = 0
    }

    fileprivate mutating func drain(state: inout SseDecoderState, final: Bool, _ yield: (ServerSentEvent) -> Void) {
        while let line = nextLine(final: final) {
            if let event = decodeSseLine(line, state: &state) {
                yield(event)
            }
        }
    }

    fileprivate mutating func finish(state: inout SseDecoderState, _ yield: (ServerSentEvent) -> Void) {
        drain(state: &state, final: true, yield)
        if let line = remainder, let event = decodeSseLine(line, state: &state) {
            yield(event)
        }
        if let trailing = flushSseEvent(state: &state) {
            yield(trailing)
        }
    }
}

fileprivate struct SseDecoderState {
    var event: String?
    var data: [String] = []
    var raw: [String] = []
}

private func flushSseEvent(state: inout SseDecoderState) -> ServerSentEvent? {
    if state.event == nil && state.data.isEmpty {
        return nil
    }
    let event = ServerSentEvent(
        event: state.event,
        data: state.data.joined(separator: "\n"),
        raw: state.raw
    )
    state.event = nil
    state.data = []
    state.raw = []
    return event
}

private func decodeSseLine(_ line: String, state: inout SseDecoderState) -> ServerSentEvent? {
    if line.isEmpty {
        return flushSseEvent(state: &state)
    }
    state.raw.append(line)
    if line.hasPrefix(":") {
        return nil
    }
    let delimiter = line.firstIndex(of: ":")
    let fieldName: String
    var value: String
    if let delimiter {
        fieldName = String(line[..<delimiter])
        value = String(line[line.index(after: delimiter)...])
    } else {
        fieldName = line
        value = ""
    }
    if value.hasPrefix(" ") {
        value.removeFirst()
    }
    if fieldName == "event" {
        state.event = value
    } else if fieldName == "data" {
        state.data.append(value)
    }
    return nil
}
