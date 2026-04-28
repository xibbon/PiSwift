import Foundation
import PiSwiftAI
import PiSwiftAgent

enum LsToolError: LocalizedError, Sendable {
    case operationAborted
    case pathNotFound(path: String)
    case notDirectory(path: String)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case let .pathNotFound(path):
            return "Path not found: \(path)"
        case let .notDirectory(path):
            return "Not a directory: \(path)"
        }
    }
}

public struct LsToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var entryLimitReached: Int?
}

public func createLsTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "ls",
        name: "ls",
        description: "List directory contents. Includes dotfiles.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string", "description": "Directory to list (default: current directory)"],
                "limit": ["type": "number", "description": "Maximum number of entries to return (default: 500)"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw LsToolError.operationAborted
        }
        let path = params["path"]?.value as? String ?? "."
        let limit = intValue(params["limit"]) ?? 500

        let dirPath = resolveToCwd(path, cwd: cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir) else {
            throw LsToolError.pathNotFound(path: dirPath)
        }
        guard isDir.boolValue else {
            throw LsToolError.notDirectory(path: dirPath)
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: dirPath)
        let sorted = entries.sorted { $0.lowercased() < $1.lowercased() }

        var results: [String] = []
        var entryLimitReached = false
        for entry in sorted {
            if results.count >= limit {
                entryLimitReached = true
                break
            }
            let fullPath = URL(fileURLWithPath: dirPath).appendingPathComponent(entry).path
            var isEntryDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: fullPath, isDirectory: &isEntryDir)
            let suffix = isEntryDir.boolValue ? "/" : ""
            results.append(entry + suffix)
        }

        if results.isEmpty {
            return AgentToolResult(content: [.text(TextContent(text: "(empty directory)"))])
        }

        let rawOutput = results.joined(separator: "\n")
        let truncation = truncateHead(rawOutput, options: TruncationOptions(maxLines: Int.max))

        var output = truncation.content
        var detailsDict: [String: Any] = [:]
        var notices: [String] = []

        if entryLimitReached {
            notices.append("\(limit) entries limit reached. Use limit=\(limit * 2) for more")
            detailsDict["entryLimitReached"] = limit
        }

        if truncation.truncated {
            notices.append("\(formatSize(DEFAULT_MAX_BYTES)) limit reached")
            detailsDict["truncation"] = truncationToAnyCodable(truncation).value
        }

        if !notices.isEmpty {
            output += "\n\n[\(notices.joined(separator: ". "))]"
        }

        let details = detailsDict.isEmpty ? nil : AnyCodable(detailsDict)
        return AgentToolResult(content: [.text(TextContent(text: output))], details: details)
    }
}
