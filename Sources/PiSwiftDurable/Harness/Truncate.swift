import Foundation

/// The default maximum retained output line count.
public let defaultMaxLines = 2000
/// The default maximum retained output byte count.
public let defaultMaxBytes = 50 * 1024
/// Identifies the byte or line limit that removed output.
public enum TruncationLimit: String, Sendable, Equatable {
    /// The line limit removed output.
    case lines
    /// The byte limit removed output.
    case bytes
}
/// Byte and line limits applied to retained command output.
public struct TruncationOptions: Sendable {
    /// The maximum number of lines to retain.
    public var maxLines: Int
    /// The maximum UTF-8 byte count to retain.
    public var maxBytes: Int
    /// Sets the byte and line limits for retained command output.
    public init(maxLines: Int = defaultMaxLines, maxBytes: Int = defaultMaxBytes) {
        self.maxLines = maxLines; self.maxBytes = maxBytes
    }
}
/// The full byte and line counts of output available outside a retained prefix.
public struct TruncationTotals: Sendable {
    /// The retained output lines.
    public var lines: Int
    /// The UTF-8 byte count of the retained output.
    public var bytes: Int
    /// Records the full output line and UTF-8 byte counts.
    public init(lines: Int, bytes: Int) { self.lines = lines; self.bytes = bytes }
}
/// Retained command output, full totals, and the limit that removed content.
public struct TruncationResult: Sendable, Equatable {
    /// The text or content blocks supplied by this result.
    public let content: String
    /// Whether a byte or line limit removed output.
    public let truncated: Bool
    /// The first limit that removed output.
    public let truncatedBy: TruncationLimit?
    /// The line count of the complete output before truncation.
    public let totalLines: Int
    /// The UTF-8 byte count of the complete output before truncation.
    public let totalBytes: Int
    /// The line count of the retained output.
    public let outputLines: Int
    /// The UTF-8 byte count of the retained output.
    public let outputBytes: Int
    /// Whether the retained output ends within a line.
    public let lastLinePartial: Bool
    /// Whether the first line alone exceeds the byte limit.
    public let firstLineExceedsLimit: Bool
    /// The maximum number of lines to retain.
    public let maxLines: Int
    /// The maximum UTF-8 byte count to retain.
    public let maxBytes: Int
}
internal func utf8ByteLength(_ content: String) -> Int { content.utf8.count }
/// Formats a byte count using B, KB, or MB units.
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
/// Retains a text prefix within the requested byte and line limits.
public func truncateHead(_ content: String, options: TruncationOptions = .init()) -> TruncationResult {
    truncateHeadOf(content, totals: .init(lines: splitLines(content).count, bytes: utf8ByteLength(content)), options: options)
}
/// Truncates a retained prefix using the full output totals.
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
