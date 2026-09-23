import Foundation
import PiSwiftAI

/// Serialize the current branch and optional export-only records as JSONL.
/// The callback receives the last branch ID and the export timestamp.
public func serializeSessionBranch(
    _ sessionManager: SessionManager,
    createTrailingEntries: ((_ parentId: String?, _ timestamp: String) throws -> [[String: AnyCodable]])? = nil
) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: Date())
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
        lines.append(encodeSessionEntry(entry))
        parentId = entry.id
    }
    for entry in try createTrailingEntries?(parentId, timestamp) ?? [] {
        let data = try JSONSerialization.data(withJSONObject: entry.mapValues(\.jsonValue))
        lines.append(String(decoding: data, as: UTF8.self))
    }
    return lines.joined(separator: "\n") + "\n"
}

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
    try serializeSessionBranch(sessionManager, createTrailingEntries: createTrailingEntries)
        .write(to: url, atomically: false, encoding: .utf8)
    return url.path
}
