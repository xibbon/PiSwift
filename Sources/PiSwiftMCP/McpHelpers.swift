import Foundation
import CryptoKit
import PiSwiftAI

/// The maximum number of UTF-8 bytes retained from MCP text output.
public let MCP_OUTPUT_MAX_BYTES = 20 * 1024

/// Build a model-facing name from an MCP server and tool.
public func createMcpToolName(server: String, tool: String, isTaken: (String) -> Bool = { _ in false }) -> String {
    let source = "mcp__\(server)__\(tool)"
    // The upstream regular expression operates on UTF-16 code units.
    let name = String(source.utf16.map { unit -> Character in
        if (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || unit == 95 {
            return Character(UnicodeScalar(unit)!)
        }
        return "_"
    })
    if name.count <= 64 && !isTaken(name) { return name }
    let digest = SHA256.hash(data: Data("\(server)\u{0}\(tool)".utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "\(name.prefix(55))_\(suffix)"
}

/// Namespaces use the server name with hyphens replaced by underscores.
public func mcpNamespace(_ server: String) -> String {
    "mcp__" + server.replacingOccurrences(of: "-", with: "_")
}

/// Supply the object keywords required by model tool APIs and keep all other keywords.
public func normalizeMcpInputSchema(_ schema: [String: Any]) -> [String: Any] {
    var normalized = schema
    if normalized["type"] == nil || normalized["type"] is NSNull { normalized["type"] = "object" }
    if normalized["properties"] == nil { normalized["properties"] = [String: Any]() }
    return normalized
}

public typealias McpOutputSaver = @Sendable (Data, String) async throws -> URL

/// Cut long model-facing text in the middle. A host may save the complete text.
public func limitMcpContent(
    _ content: [ContentBlock], saveOutput: McpOutputSaver? = nil
) async -> (content: [ContentBlock], fullOutputPath: String?) {
    let combined = content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
    }.joined(separator: "\n")
    let bytes = Array(combined.utf8)
    guard bytes.count > MCP_OUTPUT_MAX_BYTES else { return (content, nil) }
    let half = MCP_OUTPUT_MAX_BYTES / 2
    var headEnd = half
    while headEnd > 0 && (bytes[headEnd] & 0xc0) == 0x80 { headEnd -= 1 }
    var tailStart = bytes.count - half
    while tailStart < bytes.count && (bytes[tailStart] & 0xc0) == 0x80 { tailStart += 1 }
    let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
    let tail = String(decoding: bytes[tailStart...], as: UTF8.self)
    let removed = String(decoding: bytes[headEnd..<tailStart], as: UTF8.self).unicodeScalars.count
    let totalLines = combined.split(separator: "\n", omittingEmptySubsequences: false).count - (combined.hasSuffix("\n") ? 1 : 0)
    var notice = ""
    var path: String?
    if let saveOutput {
        do {
            let url = try await saveOutput(Data(bytes), ".txt")
            path = url.path
            notice = "\n\n[Full output: \(url.path) (read it with offset/limit)]"
        } catch {
            notice = "\n\n[Could not save the full output: \(error.localizedDescription)]"
        }
    }
    let tokens = (bytes.count + 3) / 4
    let text = "Warning: truncated output (original token count: \(tokens))\nTotal output lines: \(totalLines)\n\n\(head)…\(removed) chars truncated…\(tail)\(notice)"
    let images = content.filter { if case .image = $0 { return true }; return false }
    return ([.text(TextContent(text: text))] + images, path)
}
