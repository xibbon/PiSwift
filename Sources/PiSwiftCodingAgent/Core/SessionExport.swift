import Foundation
import PiSwiftAI

/// Write the current branch and optional export-only records as JSONL.
/// The callback receives the last branch ID and the export timestamp.
@discardableResult
public func exportSessionToJsonl(
    _ sessionManager: SessionManager,
    outputPath: String? = nil,
    createTrailingEntries: ((_ parentId: String?, _ timestamp: String) throws -> [[String: AnyCodable]])? = nil
) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: Date())
    let defaultName = "session-\(timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")).jsonl"
    let path = ((outputPath ?? defaultName) as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: path).standardizedFileURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let header = SessionHeader(
        version: CURRENT_SESSION_VERSION,
        id: sessionManager.getSessionId(),
        timestamp: timestamp,
        cwd: sessionManager.getCwd()
    )
    var lines = [encodeSessionHeader(header)]
    var parentId: String?
    for var entry in sessionManager.getBranch() {
        entry.parentId = parentId
        let data = try JSONSerialization.data(withJSONObject: codingAgentSessionEntryJSONObject(entry))
        lines.append(String(decoding: data, as: UTF8.self))
        parentId = entry.id
    }
    for entry in try createTrailingEntries?(parentId, timestamp) ?? [] {
        let data = try JSONSerialization.data(withJSONObject: entry.mapValues(\.jsonValue))
        lines.append(String(decoding: data, as: UTF8.self))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    return url.path
}
