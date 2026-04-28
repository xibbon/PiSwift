import Foundation
import PiSwiftAI
import PiSwiftAgent

enum GrepToolError: LocalizedError, Sendable {
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

public struct GrepToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var matchLimitReached: Int?
    public var linesTruncated: Bool?
}

public func createGrepTool(cwd: String) -> AgentTool {
    AgentTool(
        label: "grep",
        name: "grep",
        description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Search pattern (regex or literal string)"],
                "path": ["type": "string", "description": "Directory or file to search (default: current directory)"],
                "glob": ["type": "string", "description": "Filter files by glob pattern"],
                "ignoreCase": ["type": "boolean", "description": "Case-insensitive search"],
                "literal": ["type": "boolean", "description": "Treat pattern as literal string"],
                "context": ["type": "number", "description": "Number of lines before/after each match"],
                "limit": ["type": "number", "description": "Maximum number of matches to return"],
            ]),
        ]
    ) { _, params, signal, _ in
        if signal?.isCancelled == true {
            throw GrepToolError.operationAborted
        }
        guard let pattern = params["pattern"]?.value as? String else {
            throw GrepToolError.missingPattern
        }
        let searchDir = params["path"]?.value as? String ?? "."
        let glob = params["glob"]?.value as? String
        let ignoreCase = (params["ignoreCase"]?.value as? Bool) ?? false
        let literal = (params["literal"]?.value as? Bool) ?? false
        let context = intValue(params["context"]) ?? 0
        let limit = intValue(params["limit"]) ?? 100

        let searchPath = resolveToCwd(searchDir, cwd: cwd)
        let resolvedSearchPath = URL(fileURLWithPath: searchPath).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir) else {
            throw GrepToolError.pathNotFound(path: searchPath)
        }

        let files: [URL]
        if isDir.boolValue {
            files = collectFiles(root: resolvedSearchPath, glob: glob)
        } else {
            files = [URL(fileURLWithPath: searchPath)]
        }

        var outputLines: [String] = []
        var matchCount = 0
        var matchLimitReached = false
        var linesTruncated = false

        let regex: NSRegularExpression? = {
            if literal { return nil }
            let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
            return try? NSRegularExpression(pattern: pattern, options: options)
        }()

        for file in files {
            if matchCount >= limit { break }
            if signal?.isCancelled == true {
                throw GrepToolError.operationAborted
            }
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

            for (index, line) in lines.enumerated() {
                if matchCount >= limit { break }
                // v0.70.5: long files (multi-MB minified, generated, etc.) can hold the inner
                // loop for many ms — poll the cancellation signal periodically so an aborted
                // search stops promptly instead of waiting on the next file boundary.
                if index % 1024 == 0, signal?.isCancelled == true {
                    throw GrepToolError.operationAborted
                }
                let lineNumber = index + 1
                let matches: Bool
                if literal {
                    if ignoreCase {
                        matches = line.range(of: pattern, options: .caseInsensitive) != nil
                    } else {
                        matches = line.contains(pattern)
                    }
                } else if let regex {
                    let range = NSRange(location: 0, length: line.utf16.count)
                    matches = regex.firstMatch(in: line, options: [], range: range) != nil
                } else {
                    matches = false
                }

                if matches {
                    matchCount += 1
                    let rangeStart = max(1, lineNumber - max(0, context))
                    let rangeEnd = min(lines.count, lineNumber + max(0, context))
                    let relativePath = formatPath(for: file, searchPath: resolvedSearchPath, isDirectory: isDir.boolValue)

                    for current in rangeStart...rangeEnd {
                        let lineText = lines[current - 1]
                        let truncated = truncateLine(lineText)
                        if truncated.wasTruncated {
                            linesTruncated = true
                        }
                        if current == lineNumber {
                            outputLines.append("\(relativePath):\(current): \(truncated.text)")
                        } else {
                            outputLines.append("\(relativePath)-\(current)- \(truncated.text)")
                        }
                    }

                    if matchCount >= limit {
                        matchLimitReached = true
                        break
                    }
                }
            }
        }

        if matchCount == 0 {
            return AgentToolResult(content: [.text(TextContent(text: "No matches found"))])
        }

        let rawOutput = outputLines.joined(separator: "\n")
        let truncation = truncateHead(rawOutput, options: TruncationOptions(maxLines: Int.max))
        var output = truncation.content
        var notices: [String] = []
        var detailsDict: [String: Any] = [:]

        if matchLimitReached {
            notices.append("\(limit) matches limit reached. Use limit=\(limit * 2) for more, or refine pattern")
            detailsDict["matchLimitReached"] = limit
        }

        if truncation.truncated {
            notices.append("\(formatSize(DEFAULT_MAX_BYTES)) limit reached")
            detailsDict["truncation"] = truncationToAnyCodable(truncation).value
        }

        if linesTruncated {
            detailsDict["linesTruncated"] = true
        }

        if !notices.isEmpty {
            output += "\n\n[\(notices.joined(separator: ". "))]"
        }

        let details = detailsDict.isEmpty ? nil : AnyCodable(detailsDict)
        return AgentToolResult(content: [.text(TextContent(text: output))], details: details)
    }
}

private func formatPath(for file: URL, searchPath: String, isDirectory: Bool) -> String {
    if isDirectory {
        let basePrefix = searchPath.hasSuffix("/") ? searchPath : searchPath + "/"
        let relative = file.path.replacingOccurrences(of: basePrefix, with: "")
        return relative.replacingOccurrences(of: "\\", with: "/")
    }
    return file.lastPathComponent
}

private func collectFiles(root: String, glob: String?) -> [URL] {
    let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
    let rootPath = rootURL.path
    var results: [URL] = []
    let patternRegex = glob.flatMap { globToRegex($0) }

    if let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants], errorHandler: nil) {
        for case let url as URL in enumerator {
            let resolvedURL = url.resolvingSymlinksInPath()
            let isDirValue = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirValue { continue }
            if let patternRegex {
                let basePrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                let relative = resolvedURL.path.replacingOccurrences(of: basePrefix, with: "").replacingOccurrences(of: "\\", with: "/")
                if patternRegex.firstMatch(in: relative, options: [], range: NSRange(location: 0, length: relative.utf16.count)) == nil {
                    continue
                }
            }
            results.append(resolvedURL)
        }
    }
    return results
}
