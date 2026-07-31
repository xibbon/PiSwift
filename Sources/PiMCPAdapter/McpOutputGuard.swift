import Foundation
import PiSwiftAI

public let defaultMcpOutputMaxBytes = 50 * 1024
public let defaultMcpOutputMaxLines = 2_000
public let defaultMcpDetailsMaxBytes = 16 * 1024

/// Describes output that was shortened before it entered model context.
public struct McpOutputGuardDetails: Sendable {
    public let originalBytes: Int
    public let returnedBytes: Int
    public let originalLines: Int
    public let returnedLines: Int
    public let fullOutputReference: String?

    public init(
        originalBytes: Int,
        returnedBytes: Int,
        originalLines: Int,
        returnedLines: Int,
        fullOutputReference: String? = nil
    ) {
        self.originalBytes = originalBytes
        self.returnedBytes = returnedBytes
        self.originalLines = originalLines
        self.returnedLines = returnedLines
        self.fullOutputReference = fullOutputReference
    }

    var detailsValue: AnyCodable {
        AnyCodable([
            "outputGuard": [
                "truncated": true,
                "originalBytes": originalBytes,
                "returnedBytes": returnedBytes,
                "originalLines": originalLines,
                "returnedLines": returnedLines,
                "fullOutputReference": fullOutputReference as Any,
            ] as [String: Any],
        ])
    }
}

public struct McpGuardedOutput: Sendable {
    public let content: [ContentBlock]
    public let details: McpOutputGuardDetails?
    public let rawMcpResult: AnyCodable?

    var detailsValue: AnyCodable? {
        var value: [String: Any] = [:]
        if let rawMcpResult { value["mcpResult"] = rawMcpResult.value }
        if let details { value["outputGuard"] = details.detailsValue.value }
        return value.isEmpty ? nil : AnyCodable(value)
    }
}

/// Stores a complete MCP result when the inline result exceeds the guard.
/// Implement this in the host when artifact retention has product-specific
/// requirements. The return value is a host-safe reference, not raw content.
public protocol McpOutputStore: Sendable {
    func save(serverName: String, content: String) async -> String?
}

/// Default artifact store for guarded output. It uses the application cache
/// directory and does not access project or home MCP configuration paths.
public actor FileMcpOutputStore: McpOutputStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.directory = caches.appendingPathComponent("PiSwift/mcp-output", isDirectory: true)
        } else {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiSwift-mcp-output", isDirectory: true)
        }
    }

    public func save(serverName: String, content: String) -> String? {
        let safeName = serverName.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let file = directory.appendingPathComponent("\(safeName)-\(UUID().uuidString).txt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }
}

func guardMcpOutput(
    _ content: [ContentBlock],
    serverName: String,
    settings: McpSettings?,
    outputStore: (any McpOutputStore)?,
    rawMcpResult: AnyCodable? = nil
) async -> McpGuardedOutput {
    let resolved = resolvedOutputGuard(settings?.outputGuard)
    guard resolved.enabled else {
        return McpGuardedOutput(content: content, details: nil, rawMcpResult: rawMcpResult)
    }

    let text = content.compactMap { block -> String? in
        guard case .text(let value) = block else { return nil }
        return value.text
    }.joined(separator: "\n")
    let originalBytes = text.lengthOfBytes(using: .utf8)
    let originalLines = lineCount(text)
    guard originalBytes > resolved.maxBytes || originalLines > resolved.maxLines else {
        return McpGuardedOutput(
            content: content,
            details: nil,
            rawMcpResult: await boundMcpResult(rawMcpResult, serverName: serverName, limit: resolved.detailsMaxBytes, outputStore: outputStore)
        )
    }

    let reference = await outputStore?.save(serverName: serverName, content: text)
    let notice = outputNotice(
        originalBytes: originalBytes,
        originalLines: originalLines,
        reference: reference
    )
    let textBudget = max(0, resolved.maxBytes - notice.lengthOfBytes(using: .utf8) - 2)
    let lineBudget = max(0, resolved.maxLines - lineCount(notice) - 1)
    let preview = truncatedText(text, maxBytes: textBudget, maxLines: lineBudget)
    let returned = preview.isEmpty ? notice : "\(preview)\n\n\(notice)"
    let images = content.filter { if case .image = $0 { return true }; return false }
    let details = McpOutputGuardDetails(
        originalBytes: originalBytes,
        returnedBytes: returned.lengthOfBytes(using: .utf8),
        originalLines: originalLines,
        returnedLines: lineCount(returned),
        fullOutputReference: reference
    )
    return McpGuardedOutput(
        content: [.text(TextContent(text: returned))] + images,
        details: details,
        rawMcpResult: await boundMcpResult(rawMcpResult, serverName: serverName, limit: resolved.detailsMaxBytes, outputStore: outputStore)
    )
}

private func resolvedOutputGuard(_ configuration: OutputGuardConfig?) -> (enabled: Bool, maxBytes: Int, maxLines: Int, detailsMaxBytes: Int) {
    switch configuration {
    case .enabled(false):
        return (false, defaultMcpOutputMaxBytes, defaultMcpOutputMaxLines, defaultMcpDetailsMaxBytes)
    case .limits(let limits):
        return (
            true,
            positive(limits.maxBytes) ?? defaultMcpOutputMaxBytes,
            positive(limits.maxLines) ?? defaultMcpOutputMaxLines,
            positive(limits.detailsMaxBytes) ?? defaultMcpDetailsMaxBytes
        )
    case .enabled(true), .none:
        return (true, defaultMcpOutputMaxBytes, defaultMcpOutputMaxLines, defaultMcpDetailsMaxBytes)
    }
}

private func boundMcpResult(
    _ result: AnyCodable?,
    serverName: String,
    limit: Int,
    outputStore: (any McpOutputStore)?
) async -> AnyCodable? {
    guard let result else { return nil }
    guard let data = try? JSONEncoder().encode(result), data.count > limit else { return result }
    let reference = await outputStore?.save(
        serverName: "\(serverName)-result",
        content: String(data: data, encoding: .utf8) ?? ""
    )
    return AnyCodable([
        "omitted": true,
        "reason": "Raw MCP result exceeded the details size limit.",
        "rawResultBytes": data.count,
        "fullResultReference": reference as Any,
    ] as [String: Any])
}

private func positive(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return value
}

private func lineCount(_ text: String) -> Int {
    text.isEmpty ? 0 : text.reduce(into: 1) { count, character in
        if character == "\n" { count += 1 }
    }
}

private func outputNotice(originalBytes: Int, originalLines: Int, reference: String?) -> String {
    if let reference {
        return "[MCP output truncated: \(originalLines) lines / \(originalBytes) bytes. Full output: \(reference)]"
    }
    return "[MCP output truncated: \(originalLines) lines / \(originalBytes) bytes. Full output was not saved.]"
}

private func truncatedText(_ text: String, maxBytes: Int, maxLines: Int) -> String {
    guard maxBytes > 0, maxLines > 0 else { return "" }
    let limitedLines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).joined(separator: "\n")
    let data = Data(limitedLines.utf8)
    guard data.count > maxBytes else { return limitedLines }
    var end = maxBytes
    while end > 0 && (data[end] & 0b1100_0000) == 0b1000_0000 {
        end -= 1
    }
    return String(data: data.prefix(end), encoding: .utf8) ?? ""
}
