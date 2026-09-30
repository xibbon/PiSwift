import Foundation

public let DEFAULT_MAX_LINES = 2000
public let DEFAULT_MAX_BYTES = 50 * 1024
public let GREP_MAX_LINE_LENGTH = 500

public struct TruncationResult: Sendable {
    public var content: String
    public var truncated: Bool
    public var truncatedBy: String?
    public var totalLines: Int
    public var totalBytes: Int
    public var outputLines: Int
    public var outputBytes: Int
    public var lastLinePartial: Bool
    public var firstLineExceedsLimit: Bool
    public var maxLines: Int
    public var maxBytes: Int
}

public struct TruncationOptions: Sendable {
    public var maxLines: Int?
    public var maxBytes: Int?

    public init(maxLines: Int? = nil, maxBytes: Int? = nil) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }
}

public func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes)B"
    }
    if bytes < 1024 * 1024 {
        return String(format: "%.1fKB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
}

public func truncateHead(_ content: String, options: TruncationOptions = TruncationOptions()) -> TruncationResult {
    let maxLines = options.maxLines ?? DEFAULT_MAX_LINES
    let maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    let totalLines = lines.count
    let totalBytes = content.utf8.count

    if totalLines <= maxLines && totalBytes <= maxBytes {
        return TruncationResult(
            content: content,
            truncated: false,
            truncatedBy: nil,
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: totalLines,
            outputBytes: totalBytes,
            lastLinePartial: false,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    let firstLineBytes = lines.first?.utf8.count ?? 0
    if firstLineBytes > maxBytes {
        return TruncationResult(
            content: "",
            truncated: true,
            truncatedBy: "bytes",
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: 0,
            outputBytes: 0,
            lastLinePartial: false,
            firstLineExceedsLimit: true,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    var outputLinesArr: [String] = []
    var outputBytesCount = 0
    var truncatedBy = "lines"

    for i in 0..<lines.count where i < maxLines {
        let line = lines[i]
        let lineBytes = line.utf8.count + (i > 0 ? 1 : 0)
        if outputBytesCount + lineBytes > maxBytes {
            truncatedBy = "bytes"
            break
        }
        outputLinesArr.append(line)
        outputBytesCount += lineBytes
    }

    if outputLinesArr.count >= maxLines && outputBytesCount <= maxBytes {
        truncatedBy = "lines"
    }

    let outputContent = outputLinesArr.joined(separator: "\n")
    let finalOutputBytes = outputContent.utf8.count

    return TruncationResult(
        content: outputContent,
        truncated: true,
        truncatedBy: truncatedBy,
        totalLines: totalLines,
        totalBytes: totalBytes,
        outputLines: outputLinesArr.count,
        outputBytes: finalOutputBytes,
        lastLinePartial: false,
        firstLineExceedsLimit: false,
        maxLines: maxLines,
        maxBytes: maxBytes
    )
}

public func truncateTail(_ content: String, options: TruncationOptions = TruncationOptions()) -> TruncationResult {
    let maxLines = options.maxLines ?? DEFAULT_MAX_LINES
    let maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    let totalLines = lines.count
    let totalBytes = content.utf8.count

    if totalLines <= maxLines && totalBytes <= maxBytes {
        return TruncationResult(
            content: content,
            truncated: false,
            truncatedBy: nil,
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: totalLines,
            outputBytes: totalBytes,
            lastLinePartial: false,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    var outputLinesArr: [String] = []
    var outputBytesCount = 0
    var truncatedBy = "lines"
    var lastLinePartial = false

    for i in stride(from: lines.count - 1, through: 0, by: -1) {
        if outputLinesArr.count >= maxLines { break }
        let line = lines[i]
        let lineBytes = line.utf8.count + (outputLinesArr.isEmpty ? 0 : 1)

        if outputBytesCount + lineBytes > maxBytes {
            truncatedBy = "bytes"
            if outputLinesArr.isEmpty {
                let truncatedLine = truncateStringToBytesFromEnd(line, maxBytes: maxBytes)
                outputLinesArr.insert(truncatedLine, at: 0)
                outputBytesCount = truncatedLine.utf8.count
                lastLinePartial = true
            }
            break
        }

        outputLinesArr.insert(line, at: 0)
        outputBytesCount += lineBytes
    }

    if outputLinesArr.count >= maxLines && outputBytesCount <= maxBytes {
        truncatedBy = "lines"
    }

    let outputContent = outputLinesArr.joined(separator: "\n")
    let finalOutputBytes = outputContent.utf8.count

    return TruncationResult(
        content: outputContent,
        truncated: true,
        truncatedBy: truncatedBy,
        totalLines: totalLines,
        totalBytes: totalBytes,
        outputLines: outputLinesArr.count,
        outputBytes: finalOutputBytes,
        lastLinePartial: lastLinePartial,
        firstLineExceedsLimit: false,
        maxLines: maxLines,
        maxBytes: maxBytes
    )
}

public func truncateLine(_ line: String, maxChars: Int = GREP_MAX_LINE_LENGTH) -> (text: String, wasTruncated: Bool) {
    if line.count <= maxChars {
        return (line, false)
    }
    let prefix = String(line.prefix(maxChars))
    return ("\(prefix)... [truncated]", true)
}

private func truncateStringToBytesFromEnd(_ str: String, maxBytes: Int) -> String {
    let data = Array(str.utf8)
    if data.count <= maxBytes {
        return str
    }

    var start = data.count - maxBytes
    while start < data.count && (data[start] & 0xC0) == 0x80 {
        start += 1
    }

    let slice = data[start..<data.count]
    return String(decoding: slice, as: UTF8.self)
}

public struct MiddleTruncationResult: Sendable {
    public var content: String
    public var truncated: Bool
    public var removedChars: Int
    public var totalBytes: Int
    public var totalLines: Int
}

/// Keep the start and end within the byte limit. Cut only at UTF-8 boundaries.
public func truncateMiddle(_ content: String, maxBytes: Int) -> MiddleTruncationResult {
    let bytes = Array(content.utf8)
    let totalLines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
        - (content.hasSuffix("\n") ? 1 : 0)
    if bytes.count <= maxBytes {
        return MiddleTruncationResult(content: content, truncated: false, removedChars: 0,
                                      totalBytes: bytes.count, totalLines: totalLines)
    }

    let headSize = max(0, maxBytes / 2)
    let tailSize = max(0, maxBytes - headSize)
    var headEnd = min(headSize, bytes.count)
    while headEnd > 0 && (bytes[headEnd] & 0xC0) == 0x80 { headEnd -= 1 }
    var tailStart = max(0, bytes.count - tailSize)
    while tailStart < bytes.count && (bytes[tailStart] & 0xC0) == 0x80 { tailStart += 1 }

    let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
    let tail = String(decoding: bytes[tailStart...], as: UTF8.self)
    let removedChars = String(decoding: bytes[headEnd..<tailStart], as: UTF8.self).unicodeScalars.count
    return MiddleTruncationResult(
        content: "\(head)…\(removedChars) chars truncated…\(tail)",
        truncated: true,
        removedChars: removedChars,
        totalBytes: bytes.count,
        totalLines: totalLines
    )
}
