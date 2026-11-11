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
    var tool = AgentTool(
        label: "find",
        name: "find",
        description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'"],
                "path": ["type": "string", "description": "Directory to search in (default: current directory)"],
                "limit": ["type": "number", "description": "Maximum number of results (default: 1000)"],
            ]),
            "required": AnyCodable(["pattern"]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw FindToolError.operationAborted
        }
        guard let pattern = params["pattern"]?.value as? String else {
            throw FindToolError.missingPattern
        }
        let searchDir = params["path"]?.value as? String ?? "."
        let limit = max(1, intValue(params["limit"]) ?? 1000)

        let searchPath = resolveToCwd(searchDir, cwd: cwd)
        let baseURL = URL(fileURLWithPath: searchPath).resolvingSymlinksInPath()
        let basePath = baseURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir), isDir.boolValue else {
            throw FindToolError.pathNotFound(path: searchPath)
        }

        let ignorePatterns = loadGitignorePatterns(root: searchPath)
        #if os(Windows)
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        #else
        let normalizedPattern = pattern
        #endif
        let patternRegex = findGlobRegex(normalizedPattern)
        let matchBasename = !normalizedPattern.contains("/")

        var matches: [String] = []
        var resultLimitReached = false
        var resultCount = 0
        var outputBytes = 0

        if signal?.isCancelled == true {
            throw FindToolError.operationAborted
        }

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

                let candidate = matchBasename ? url.lastPathComponent : normalized
                if let patternRegex, patternRegex.firstMatch(in: candidate, options: [], range: NSRange(location: 0, length: candidate.utf16.count)) == nil {
                    continue
                }

                // Read one extra result to detect a limit that excludes more files.
                if resultCount == limit {
                    resultLimitReached = true
                    break
                }
                resultCount += 1
                // Keep one line past the byte cap so truncateHead makes the same decision.
                if outputBytes - 1 <= DEFAULT_MAX_BYTES {
                    matches.append(normalized)
                }
                outputBytes += normalized.utf8.count + 1
            }
        }

        if matches.isEmpty {
            return AgentToolResult(content: [.text(TextContent(text: "No files found matching pattern"))])
        }

        let rawOutput = matches.joined(separator: "\n")
        var truncation = truncateHead(rawOutput, options: TruncationOptions(maxLines: Int.max))
        truncation.totalLines = resultCount
        truncation.totalBytes = outputBytes - 1
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
    tool.executeWithContext = { id, params, signal, onUpdate, context in
        try await createFindTool(cwd: resolveToolExecutionCwd(context, fallback: cwd)).execute(id, params, signal, onUpdate)
    }
    return tool
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

// Match fd's glob syntax without a platform-specific external tool.
private func findGlobRegex(_ pattern: String) -> NSRegularExpression? {
    var parser = FindGlobParser(characters: Array(pattern))
    let expression = "^" + parser.parse() + "$"
    let options: NSRegularExpression.Options = pattern == pattern.lowercased() ? [.caseInsensitive] : []
    return try? NSRegularExpression(pattern: expression, options: options)
}

private struct FindGlobParser {
    let characters: [Character]
    var index = 0

    mutating func parse(stoppingAt stops: Set<Character> = []) -> String {
        var result = ""
        while index < characters.count {
            let character = characters[index]
            if stops.contains(character) { break }
            index += 1
            switch character {
            case "\\":
                if index < characters.count {
                    result += NSRegularExpression.escapedPattern(for: String(characters[index]))
                    index += 1
                } else {
                    result += "\\\\"
                }
            case "*":
                if index < characters.count && characters[index] == "*" {
                    index += 1
                    if index < characters.count && characters[index] == "/" {
                        index += 1
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case "[":
                if let end = characters[index...].firstIndex(of: "]"), end > index {
                    var contents = String(characters[index..<end])
                    if contents.hasPrefix("!") {
                        contents = "^" + contents.dropFirst()
                    } else if contents.hasPrefix("^") {
                        contents = "\\" + contents
                    }
                    result += "[" + contents + "]"
                    index = end + 1
                } else {
                    result += "\\["
                }
            case "{":
                if characters[index...].contains("}") {
                    var alternatives: [String] = []
                    repeat {
                        alternatives.append(parse(stoppingAt: [",", "}"]))
                        if index >= characters.count || characters[index] == "}" { break }
                        index += 1
                    } while index < characters.count
                    if index < characters.count { index += 1 }
                    result += "(?:" + alternatives.joined(separator: "|") + ")"
                } else {
                    result += "\\{"
                }
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return result
    }
}
