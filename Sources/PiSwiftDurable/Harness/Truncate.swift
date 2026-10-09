import Foundation

public let defaultMaxLines = 2000
public let defaultMaxBytes = 50 * 1024
public enum TruncationLimit: String, Sendable, Equatable { case lines, bytes }
public struct TruncationOptions: Sendable {
    public var maxLines: Int
    public var maxBytes: Int
    public init(maxLines: Int = defaultMaxLines, maxBytes: Int = defaultMaxBytes) {
        self.maxLines = maxLines; self.maxBytes = maxBytes
    }
}
public struct TruncationTotals: Sendable {
    public var lines: Int
    public var bytes: Int
    public init(lines: Int, bytes: Int) { self.lines = lines; self.bytes = bytes }
}
public struct TruncationResult: Sendable, Equatable {
    public let content: String
    public let truncated: Bool
    public let truncatedBy: TruncationLimit?
    public let totalLines: Int
    public let totalBytes: Int
    public let outputLines: Int
    public let outputBytes: Int
    public let lastLinePartial: Bool
    public let firstLineExceedsLimit: Bool
    public let maxLines: Int
    public let maxBytes: Int
}
public func utf8ByteLength(_ content: String) -> Int { content.utf8.count }
public func formatSize(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    let divisor = bytes < 1024 * 1024 ? 1024.0 : 1024.0 * 1024
    return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / divisor)
        + (bytes < 1024 * 1024 ? "KB" : "MB")
}
private func splitLines(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines = text.components(separatedBy: "\n")
    if text.hasSuffix("\n") { lines.removeLast() }
    return lines
}
public func truncateHead(_ content: String, options: TruncationOptions = .init()) -> TruncationResult {
    truncateHeadOf(content, totals: .init(lines: splitLines(content).count, bytes: utf8ByteLength(content)), options: options)
}
public func truncateHeadOf(_ prefix: String, totals: TruncationTotals, options: TruncationOptions = .init()) -> TruncationResult {
    let lines = splitLines(prefix)
    func result(_ content: String, _ truncated: Bool, _ by: TruncationLimit?, _ outputLines: Int, _ first: Bool = false) -> TruncationResult {
        .init(content: content, truncated: truncated, truncatedBy: by, totalLines: totals.lines, totalBytes: totals.bytes,
              outputLines: outputLines, outputBytes: truncated ? utf8ByteLength(content) : totals.bytes, lastLinePartial: false,
              firstLineExceedsLimit: first, maxLines: options.maxLines, maxBytes: options.maxBytes)
    }
    if totals.lines <= options.maxLines && totals.bytes <= options.maxBytes { return result(prefix, false, nil, totals.lines) }
    if utf8ByteLength(lines.first ?? "") > options.maxBytes { return result("", true, .bytes, 0, true) }
    var kept: [String] = []; var bytes = 0; var by = TruncationLimit.lines
    for (index, line) in lines.prefix(max(0, options.maxLines)).enumerated() {
        let size = utf8ByteLength(line) + (index > 0 ? 1 : 0)
        if bytes + size > options.maxBytes { by = .bytes; break }
        kept.append(line); bytes += size
    }
    if by != .bytes { by = kept.count < totals.lines ? .lines : .bytes }
    return result(kept.joined(separator: "\n"), true, by, kept.count)
}
