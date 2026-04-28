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
                var buffer = Data()
                var state = SseDecoderState()
                for try await byte in bytes {
                    if signal?.isCancelled == true {
                        throw CancellationError()
                    }
                    buffer.append(byte)
                    while let consumed = consumeSseLine(buffer: buffer) {
                        buffer = consumed.rest
                        if let event = decodeSseLine(consumed.line, state: &state) {
                            continuation.yield(event)
                        }
                    }
                }
                while let consumed = consumeSseLine(buffer: buffer) {
                    buffer = consumed.rest
                    if let event = decodeSseLine(consumed.line, state: &state) {
                        continuation.yield(event)
                    }
                }
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    if let event = decodeSseLine(line, state: &state) {
                        continuation.yield(event)
                    }
                }
                if let trailing = flushSseEvent(state: &state) {
                    continuation.yield(trailing)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private struct SseDecoderState {
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

private func consumeSseLine(buffer: Data) -> (line: String, rest: Data)? {
    let cr: UInt8 = 13
    let lf: UInt8 = 10
    var crIndex: Int? = nil
    var lfIndex: Int? = nil
    for (idx, byte) in buffer.enumerated() {
        if byte == cr, crIndex == nil { crIndex = idx }
        if byte == lf, lfIndex == nil { lfIndex = idx }
        if crIndex != nil && lfIndex != nil { break }
    }
    let breakIndex: Int
    switch (crIndex, lfIndex) {
    case (nil, nil): return nil
    case (let cr?, nil): breakIndex = cr
    case (nil, let lf?): breakIndex = lf
    case (let cr?, let lf?): breakIndex = min(cr, lf)
    }
    let lineData = buffer.prefix(breakIndex)
    var nextIndex = breakIndex + 1
    if breakIndex < buffer.count, buffer[buffer.startIndex + breakIndex] == cr,
       nextIndex < buffer.count, buffer[buffer.startIndex + nextIndex] == lf {
        nextIndex += 1
    }
    let rest = nextIndex >= buffer.count ? Data() : buffer.suffix(from: buffer.startIndex + nextIndex)
    let line = String(data: Data(lineData), encoding: .utf8) ?? ""
    return (line, Data(rest))
}
