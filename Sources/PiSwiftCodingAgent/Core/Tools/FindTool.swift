import Foundation
import PiSwiftAI
import PiSwiftAgent

enum FindToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPattern
    case pathNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingPattern:
            return "Missing pattern"
        case let .pathNotFound(path):
            return "Path not found: \(path)"
        }
    }
}

public struct FindToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var resultLimitReached: Int?
}

public func createFindTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "find",
        name: "find",
        description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Glob pattern to match files"],
                "path": ["type": "string", "description": "Directory to search in (default: current directory)"],
                "limit": ["type": "number", "description": "Maximum number of results (default: 1000)"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw FindToolError.operationAborted
        }
        guard let pattern = params["pattern"]?.value as? String else {
            throw FindToolError.missingPattern
        }
        let searchDir = params["path"]?.value as? String ?? "."
        let limit = intValue(params["limit"]) ?? 1000

        let searchPath = resolveToCwd(searchDir, cwd: cwd)
        let baseURL = URL(fileURLWithPath: searchPath).resolvingSymlinksInPath()
        let basePath = baseURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir), isDir.boolValue else {
            throw FindToolError.pathNotFound(path: searchPath)
        }

        let ignorePatterns = loadGitignorePatterns(root: searchPath)
        let patternRegex = globToRegex(pattern)

        var matches: [String] = []
        var resultLimitReached = false

        if let enumerator = FileManager.default.enumerator(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants], errorHandler: nil) {
            while let item = enumerator.nextObject() {
                if signal?.isCancelled == true {
                    throw FindToolError.operationAborted
                }
                guard let url = item as? URL else { continue }
                let resolvedURL = url.resolvingSymlinksInPath()
                let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
                let relative = resolvedURL.path.replacingOccurrences(of: basePrefix, with: "")
                let normalized = relative.replacingOccurrences(of: "\\", with: "/")

                if isIgnored(path: normalized, patterns: ignorePatterns) {
                    continue
                }

                let isDirValue = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirValue {
                    continue
                }

                if let patternRegex, patternRegex.firstMatch(in: normalized, options: [], range: NSRange(location: 0, length: normalized.utf16.count)) == nil {
                    continue
                }

                matches.append(normalized)
                if matches.count >= limit {
                    resultLimitReached = true
                    break
                }
            }
        }

        if matches.isEmpty {
            return AgentToolResult(content: [.text(TextContent(text: "No files found matching pattern"))])
        }

        let rawOutput = matches.joined(separator: "\n")
        let truncation = truncateHead(rawOutput, options: TruncationOptions(maxLines: Int.max))
        var output = truncation.content
        var notices: [String] = []
        var detailsDict: [String: Any] = [:]

        if resultLimitReached {
            notices.append("\(limit) results limit reached. Use limit=\(limit * 2) for more, or refine pattern")
            detailsDict["resultLimitReached"] = limit
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

private func loadGitignorePatterns(root: String) -> [String] {
    let gitignorePath = URL(fileURLWithPath: root).appendingPathComponent(".gitignore").path
    guard let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
        return []
    }
    return content
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

private func isIgnored(path: String, patterns: [String]) -> Bool {
    for pattern in patterns {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if matchesGlob(path, trimmed) { return true }
        if path.hasSuffix(trimmed) { return true }
    }
    return false
}
