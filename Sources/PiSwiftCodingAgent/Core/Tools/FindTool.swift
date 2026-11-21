import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftIgnore

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
    createFindTool(cwd: cwd, environment: ProcessInfo.processInfo.environment)
}

func createFindTool(cwd: String, environment: [String: String]) -> AgentTool {
    var tool = AgentTool(
        label: "find",
        name: "find",
        description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first).",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Glob pattern relative to the search directory, e.g. 'src/**/*.ts'. Without '/', e.g. '*.ts', it matches file names at any depth"],
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir), isDir.boolValue else {
            throw FindToolError.pathNotFound(path: searchPath)
        }

        #if os(Windows)
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        #else
        let normalizedPattern = pattern
        #endif
        var effectivePattern = normalizedPattern
        while effectivePattern.hasPrefix("./") { effectivePattern.removeFirst(2) }
        let patternRegex = findGlobRegex(effectivePattern)
        let matchBasename = !effectivePattern.contains("/")
        let matchAbsolute = effectivePattern.hasPrefix("/")

        var matches: [String] = []
        var resultLimitReached = false
        var resultCount = 0
        var outputBytes = 0

        if signal?.isCancelled == true {
            throw FindToolError.operationAborted
        }

        var walker = try NativeIgnoreWalker(root: baseURL.path, tool: .find, environment: environment,
                                            processDirectory: FileManager.default.currentDirectoryPath, check: {
            if signal?.isCancelled == true || Task.isCancelled {
                throw FindToolError.operationAborted
            }
        })
        while let item = try walker.next() {
            if signal?.isCancelled == true || Task.isCancelled {
                throw FindToolError.operationAborted
            }
            let url = item.url
            let normalized = item.relative.replacingOccurrences(of: "\\", with: "/")
            if item.isDirectory { continue }

            let absoluteRoot = URL(fileURLWithPath: searchPath).standardizedFileURL.path
            let absoluteCandidate = absoluteRoot.hasSuffix("/") ? absoluteRoot + normalized : absoluteRoot + "/" + normalized
            let candidate = matchBasename ? url.lastPathComponent : (matchAbsolute ? absoluteCandidate : normalized)
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
        try await createFindTool(cwd: resolveToolExecutionCwd(context, fallback: cwd), environment: environment).execute(id, params, signal, onUpdate)
    }
    return tool
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
