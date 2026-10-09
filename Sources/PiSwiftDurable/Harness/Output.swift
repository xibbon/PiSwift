import Foundation
import Synchronization

public enum OutputRetention: String, Sendable, Equatable { case head, tail }
public struct OutputLimits: Sendable, Equatable {
    public var maxBytes: Int
    public var maxLines: Int
    public var retain: OutputRetention
    public init(maxBytes: Int, maxLines: Int, retain: OutputRetention) {
        precondition(maxBytes >= 0 && maxLines >= 0)
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.retain = retain
    }
}
public struct BoundedOutput: Sendable, Equatable {
    public let text: String
    public let droppedBytes: Int
    public let droppedLines: Int
    public init(text: String, droppedBytes: Int, droppedLines: Int) {
        self.text = text; self.droppedBytes = droppedBytes; self.droppedLines = droppedLines
    }
}
public struct OutputSlice: Sendable, Equatable {
    public let text: String
    public let bytes: Int
    public let droppedBytes: Int
    public let droppedLines: Int
}
public func sanitizeOutput(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter {
        !((0...8).contains($0.value) || (11...31).contains($0.value) || (0xfff9...0xfffb).contains($0.value))
    }))
}
public func characterEnd(_ bytes: [UInt8], at index: Int) -> Int {
    var end = index
    while end > 0 && end < bytes.count && bytes[end] & 0xc0 == 0x80 { end -= 1 }
    return end
}
private func characterStart(_ bytes: [UInt8], at index: Int) -> Int {
    var start = index
    while start < bytes.count && bytes[start] & 0xc0 == 0x80 { start += 1 }
    return start
}
private func lineCount(_ bytes: ArraySlice<UInt8>) -> Int {
    bytes.isEmpty ? 0 : bytes.filter { $0 == 10 }.count + (bytes.last == 10 ? 0 : 1)
}
public func boundOutput(_ text: String, limits: OutputLimits) -> OutputSlice {
    let bytes = Array(text.utf8)
    var from = 0; var to = bytes.count
    if limits.maxBytes == 0 || limits.maxLines == 0 { to = 0 }
    else if limits.retain == .head {
        var lines = 0
        for index in bytes.indices where bytes[index] == 10 {
            lines += 1
            if lines == limits.maxLines { to = index + 1; break }
        }
        if to > limits.maxBytes {
            to = bytes.prefix(limits.maxBytes).lastIndex(of: 10).map { $0 + 1 }
                ?? characterEnd(bytes, at: limits.maxBytes)
        }
    } else {
        let last = bytes.last == 10 ? bytes.count - 2 : bytes.count - 1
        var lines = 1
        if last >= 0 {
            for index in stride(from: last, through: 0, by: -1) where bytes[index] == 10 {
                if lines == limits.maxLines { from = index + 1; break }
                lines += 1
            }
        }
        if bytes.count - from > limits.maxBytes {
            let start = bytes.count - limits.maxBytes
            if let newline = bytes.indices.dropFirst(max(0, start - 1)).first(where: { bytes[$0] == 10 }), newline + 1 < bytes.count {
                from = newline + 1
            } else { from = characterStart(bytes, at: start) }
        }
    }
    let kept = bytes[from..<to]
    return .init(text: kept.count == bytes.count ? text : String(decoding: kept, as: UTF8.self),
                 bytes: kept.count, droppedBytes: bytes.count - kept.count,
                 droppedLines: lineCount(bytes[...]) - lineCount(kept))
}

/// Output state is protected by a mutex. Snapshots preserve the margin needed to locate a later tail line.
public final class OutputBuffer: Sendable {
    private struct Chunk: Sendable { let text: String; let bytes: Int; let newlines: Int }
    private struct State: Sendable {
        var chunks: [Chunk] = []
        var pending: [UInt8] = []
        var started = false
        var storedBytes = 0
        var storedNewlines = 0
        var full = false
        var totalBytes = 0
        var totalNewlines = 0
        var endsWithNewline = true
    }
    private let limits: OutputLimits
    private let state = Mutex(State())
    public init(_ limits: OutputLimits) { self.limits = limits }
    public var storedBytes: Int { state.withLock { $0.storedBytes } }
    @discardableResult public func push(_ text: String, skipped: ShellOutputSkip? = nil) throws -> Bool {
        try state.withLock { state in
            let pending = String(decoding: state.pending, as: UTF8.self)
            state.pending = []
            return try pushDecoded(pending: pending, text: text, bytes: false, skipped: skipped, state: &state)
        }
    }
    @discardableResult public func push(_ bytes: Data, skipped: ShellOutputSkip? = nil) throws -> Bool {
        try push(Array(bytes), skipped: skipped)
    }
    @discardableResult public func push(_ bytes: [UInt8], skipped: ShellOutputSkip? = nil) throws -> Bool {
        try state.withLock { state in
            var pending = ""
            if skipped != nil { pending = String(decoding: state.pending, as: UTF8.self); state.pending = [] }
            let combined = state.pending + bytes
            let end = completeUTF8End(combined)
            let text = String(decoding: combined[..<end], as: UTF8.self)
            state.pending = Array(combined[end...])
            return try pushDecoded(pending: pending, text: text, bytes: true, skipped: skipped, state: &state)
        }
    }
    private func pushDecoded(pending: String, text: String, bytes: Bool, skipped: ShellOutputSkip?, state: inout State) throws -> Bool {
        let first = !state.started && pending.isEmpty && skipped == nil
        var text = text
        if !pending.isEmpty || !text.isEmpty || skipped != nil { state.started = true }
        if first && bytes && text.unicodeScalars.first?.value == 0xfeff { text.removeFirst() }
        guard let skipped else { return accept(pending + text, state: &state) }
        guard limits.retain == .tail else { throw OutputBufferError.skippedOutputRequiresTailRetention }
        _ = accept(pending, state: &state)
        if skipped.bytes != 0 {
            state.totalBytes += skipped.bytes; state.totalNewlines += skipped.newlines
            state.endsWithNewline = skipped.endsWithNewline
            state.chunks = []; state.storedBytes = 0; state.storedNewlines = 0
        }
        _ = accept(text, state: &state)
        return true
    }
    public func end() {
        state.withLock { state in
            _ = accept(String(decoding: state.pending, as: UTF8.self), state: &state)
            state.pending = []
        }
    }
    private func accept(_ text: String, state: inout State) -> Bool {
        if text.isEmpty { return false }
        let bytes = utf8ByteLength(text); let newlines = text.utf8.filter { $0 == 10 }.count
        state.totalBytes += bytes; state.totalNewlines += newlines; state.endsWithNewline = text.hasSuffix("\n")
        if state.full { return true }
        state.chunks.append(.init(text: text, bytes: bytes, newlines: newlines))
        state.storedBytes += bytes; state.storedNewlines += newlines
        if limits.retain == .head {
            state.full = state.storedBytes > limits.maxBytes || state.storedNewlines >= limits.maxLines
        } else {
            while state.chunks.count > 1 {
                let first = state.chunks[0]
                let bytesAfter = state.storedBytes - first.bytes
                let newlinesAfter = state.storedNewlines - first.newlines
                if bytesAfter <= limits.maxBytes + 1 && newlinesAfter <= limits.maxLines + 1 { break }
                state.chunks.removeFirst(); state.storedBytes = bytesAfter; state.storedNewlines = newlinesAfter
            }
        }
        return true
    }
    public func snapshot() -> BoundedOutput {
        state.withLock { state in
            let stored = state.chunks.map(\.text).joined()
            let kept = boundOutput(stored, limits: limits)
            let storedLines = state.storedNewlines + (stored.isEmpty || stored.hasSuffix("\n") ? 0 : 1)
            let keptLines = storedLines - kept.droppedLines
            if limits.retain == .tail || state.chunks.count > 1 {
                let text = limits.retain == .tail ? tailMargin(stored, limits: limits) : stored
                let bytes = utf8ByteLength(text); let newlines = text.utf8.filter { $0 == 10 }.count
                state.chunks = text.isEmpty ? [] : [.init(text: text, bytes: bytes, newlines: newlines)]
                state.storedBytes = bytes; state.storedNewlines = newlines
            }
            return .init(text: sanitizeOutput(kept.text), droppedBytes: state.totalBytes - kept.bytes,
                         droppedLines: state.totalNewlines + (state.endsWithNewline ? 0 : 1) - keptLines)
        }
    }
}
public enum OutputBufferError: Error, Sendable { case skippedOutputRequiresTailRetention }
private func tailMargin(_ text: String, limits: OutputLimits) -> String {
    let bytes = Array(text.utf8)
    let byteStart = bytes.count > limits.maxBytes ? characterEnd(bytes, at: bytes.count - limits.maxBytes - 1) : 0
    var lineStart = 0; var newlines = 0
    for index in bytes.indices.reversed() where bytes[index] == 10 {
        newlines += 1
        if newlines > limits.maxLines { lineStart = index; break }
    }
    return String(decoding: bytes[max(byteStart, lineStart)...], as: UTF8.self)
}
/// Keep only an incomplete, valid UTF-8 suffix. Invalid input is decoded now as replacement text.
private func completeUTF8End(_ bytes: [UInt8]) -> Int {
    guard !bytes.isEmpty else { return 0 }
    var start = bytes.count - 1
    while start > 0 && bytes[start] & 0xc0 == 0x80 { start -= 1 }
    let lead = bytes[start]
    let expected = lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf4 ? 4 : 1
    let count = bytes.count - start
    if expected <= count { return bytes.count }
    if count >= 2 {
        let second = bytes[start + 1]
        if second & 0xc0 != 0x80 || (lead == 0xe0 && second < 0xa0) || (lead == 0xed && second >= 0xa0)
            || (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second >= 0x90) { return bytes.count }
    }
    return start
}
