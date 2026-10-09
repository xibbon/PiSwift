/// Finds line ranges in chunks without storing the complete file.
public struct LineScanner: Sendable {
    private let startLine: Int
    private let endLine: Int?
    private var position: Int64 = 0
    private var newlines = 0
    private var lineStart: Int64 = 0
    private var start: Int64?
    private var end: Int64?
    private var firstLineEnd: Int64?
    private var lastLineStart: Int64?
    private var selectedBytes: Int64 = 0
    private var firstLineBytes: Int64 = 0
    private var selection: RangeDecoder?
    private var firstLine: RangeDecoder?
    private var head: [UInt8]? = []
    private var bom = false

    /// Creates a scan for a nonempty range of line numbers. A nil end selects to EOF.
    public init(startLine: Int, endLine: Int? = nil) throws {
        // Upstream requires JavaScript safe integers.
        let maximum = 9_007_199_254_740_991
        guard startLine >= 0, startLine <= maximum,
              endLine.map({ $0 > startLine && $0 <= maximum }) ?? true else {
            throw FileError(.invalid, message: "Invalid line range")
        }
        self.startLine = startLine
        self.endLine = endLine
        if startLine == 0 { begin(0) }
    }

    /// Adds the next bytes in file order.
    public mutating func push(_ chunk: [UInt8]) {
        if head != nil {
            let take = min(3 - (head?.count ?? 0), chunk.count)
            head?.append(contentsOf: chunk.prefix(take))
            if (head?.count ?? 0) < 3 { return }
            releaseHead()
            process(Array(chunk.dropFirst(take)))
        } else {
            process(chunk)
        }
    }

    /// Finishes the scan and returns byte offsets and decoded byte counts.
    public mutating func finish() -> LineScan {
        if head != nil { releaseHead() }
        let size = position
        guard let start else {
            return LineScan(newlines: newlines, start: size, end: size, firstLineEnd: size,
                            lastLineStart: size, selectedBytes: 0, firstLineBytes: 0)
        }
        if firstLineEnd == nil { endFirstLine(size) }
        if end == nil { endSelection(size) }
        return LineScan(newlines: newlines, start: start, end: end ?? size,
                        firstLineEnd: firstLineEnd ?? size, lastLineStart: lastLineStart ?? lineStart,
                        selectedBytes: selectedBytes, firstLineBytes: firstLineBytes)
    }

    private mutating func releaseHead() {
        let bytes = head ?? []
        head = nil
        bom = startsWithBom(bytes)
        process(bytes)
    }

    private mutating func process(_ chunk: [UInt8]) {
        let base = position
        var from = 0
        for index in chunk.indices where chunk[index] == 0x0a {
            feed(chunk, base: base, from: from, to: index)
            let offset = base + Int64(index)
            if newlines == startLine { endFirstLine(offset) }
            if endLine.map({ newlines == $0 - 1 }) ?? false { endSelection(offset) }
            feed(chunk, base: base, from: index, to: index + 1)
            from = index + 1
            newlines += 1
            lineStart = offset + 1
            if newlines == startLine { begin(lineStart) }
            if endLine.map({ newlines == $0 - 1 }) ?? false { lastLineStart = lineStart }
        }
        feed(chunk, base: base, from: from, to: chunk.count)
        position += Int64(chunk.count)
    }

    private mutating func begin(_ offset: Int64) {
        start = offset
        if endLine.map({ startLine == $0 - 1 }) ?? false { lastLineStart = offset }
        selection = rangeDecoder()
        firstLine = rangeDecoder()
    }

    private mutating func endFirstLine(_ offset: Int64) {
        firstLineEnd = offset
        if var decoder = firstLine { firstLineBytes += Int64(decoder.decode().utf8.count) }
        firstLine = nil
    }

    private mutating func endSelection(_ offset: Int64) {
        end = offset
        if var decoder = selection { selectedBytes += Int64(decoder.decode().utf8.count) }
        selection = nil
    }

    private mutating func feed(_ chunk: [UInt8], base: Int64, from originalFrom: Int, to: Int) {
        var from = originalFrom
        if bom && base + Int64(from) < 3 { from = min(to, Int(3 - base)) }
        guard to > from else { return }
        let bytes = Array(chunk[from..<to])
        if var decoder = selection {
            selectedBytes += Int64(decoder.decode(bytes).utf8.count)
            selection = decoder
        }
        if var decoder = firstLine {
            firstLineBytes += Int64(decoder.decode(bytes).utf8.count)
            firstLine = decoder
        }
    }
}
