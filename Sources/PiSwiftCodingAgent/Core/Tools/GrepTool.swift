import Foundation
import PiSwiftAI
import PiSwiftAgent

enum GrepToolError: LocalizedError, Sendable {
    case operationAborted
    case missingPattern
    case invalidPattern(description: String)
    case pathNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingPattern:
            return "Missing pattern"
        case let .invalidPattern(description):
            return "Invalid regular expression: \(description)"
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

/// The search uses the local file system. Override `execute` for remote search.
public struct GrepOperations: Sendable {
    public var isDirectory: @Sendable (String) async throws -> Bool
    /// This hook is accepted for compatibility. The search does not call it.
    @available(*, deprecated, message: "Ignored. Context uses streamed local files. Override execute for remote search.")
    public var readFile: (@Sendable (String) async throws -> String)? {
        get { legacyReadFile }
        set { legacyReadFile = newValue }
    }
    private var legacyReadFile: (@Sendable (String) async throws -> String)?

    public init(
        isDirectory: @escaping @Sendable (String) async throws -> Bool,
        readFile: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.isDirectory = isDirectory
        self.legacyReadFile = readFile
    }
}

public struct GrepToolOptions: Sendable {
    public var operations: GrepOperations?

    public init(operations: GrepOperations? = nil) {
        self.operations = operations
    }
}

public func createGrepTool(cwd: String) -> AgentTool {
    createGrepTool(cwd: cwd, options: nil)
}

public func createGrepTool(cwd: String, options: GrepToolOptions?) -> AgentTool {
    var tool = AgentTool(
        label: "grep",
        name: "grep",
        description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first). Long lines are truncated to \(GREP_MAX_LINE_LENGTH) chars.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Search pattern (regex or literal string)"],
                "path": ["type": "string", "description": "Directory or file to search (default: current directory)"],
                "glob": ["type": "string", "description": "Filter files by glob pattern, relative to path, e.g. '*.ts', 'src/**/*.ts' or '**/*.spec.ts'. A pattern without '/' matches file names at any depth"],
                "ignoreCase": ["type": "boolean", "description": "Case-insensitive search (default: false)"],
                "literal": ["type": "boolean", "description": "Treat pattern as literal string instead of regex (default: false)"],
                "context": ["type": "number", "description": "Number of lines to show before and after each match (default: 0)"],
                "limit": ["type": "number", "description": "Maximum number of matches to return (default: 100)"],
            ]),
            "required": AnyCodable(["pattern"]),
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
        let context = grepInteger(params["context"], default: 0, minimum: 0)
        let limit = grepInteger(params["limit"], default: 100, minimum: 1)

        let searchPath = resolveToCwd(searchDir, cwd: cwd)
        let resolvedSearchPath = URL(fileURLWithPath: searchPath).resolvingSymlinksInPath().path
        let isDirectory: Bool
        if let operations = options?.operations {
            do { isDirectory = try await operations.isDirectory(searchPath) }
            catch { throw GrepToolError.pathNotFound(path: searchPath) }
        } else {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: searchPath, isDirectory: &isDir) else {
                throw GrepToolError.pathNotFound(path: searchPath)
            }
            isDirectory = isDir.boolValue
        }

        let regex: NSRegularExpression?
        if literal {
            regex = nil
        } else {
            do {
                regex = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
            } catch {
                throw GrepToolError.invalidPattern(description: error.localizedDescription)
            }
        }
        let checkCancellation = {
            if signal?.isCancelled == true || Task.isCancelled {
                throw GrepToolError.operationAborted
            }
        }
        var outputLines: [String] = []
        var outputBytes = 0
        var outputLineCount = 0
        var matchCount = 0
        var matchLimitReached = false
        var linesTruncated = false

        func appendLine(_ text: String, number: Int, path: String, match: Bool) {
            let truncated = truncateLine(text)
            if truncated.wasTruncated { linesTruncated = true }
            let row = match ? "\(path):\(number): \(truncated.text)" : "\(path)-\(number)- \(truncated.text)"
            // Keep the first row beyond the cap so truncateHead detects an exact boundary.
            if outputBytes - 1 <= DEFAULT_MAX_BYTES { outputLines.append(row) }
            outputBytes += row.utf8.count + 1
            outputLineCount += 1
        }

        let files: AnySequence<URL>
        if isDirectory {
            files = grepFiles(root: resolvedSearchPath, glob: glob)
        } else {
            // A glob does not filter an explicit file path.
            files = AnySequence([URL(fileURLWithPath: searchPath)])
        }
        for file in files {
            try checkCancellation()
            if matchLimitReached { break }
            guard let reader = try? GrepLineReader(file: file) else { continue }
            var contextReader: GrepLineReader?
            var contextPosition = 0
            var lineNumber = 0
            var lastOutputLine = 0
            var trailingContextEnd = 0
            let relativePath = formatPath(for: file, searchPath: resolvedSearchPath, isDirectory: isDirectory)
            while let line = try reader.nextLine(checkCancellation: checkCancellation) {
                try checkCancellation()
                lineNumber += 1
                let matches: Bool
                if literal {
                    matches = line.range(of: pattern, options: ignoreCase ? [.caseInsensitive, .literal] : [.literal]) != nil
                } else {
                    matches = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
                if matches && matchCount < limit {
                    if context > 0 {
                        // A second cursor supplies prior context without a file-sized buffer.
                        // Each cursor reads the file at most once, even for a huge context value.
                        if contextReader == nil { contextReader = try GrepLineReader(file: file) }
                        let start = max(lastOutputLine + 1, lineNumber - min(context, lineNumber - 1))
                        while contextPosition < lineNumber - 1,
                              let prior = try contextReader?.nextLine(checkCancellation: checkCancellation) {
                            contextPosition += 1
                            if contextPosition >= start {
                                appendLine(prior, number: contextPosition, path: relativePath, match: false)
                            }
                        }
                    }
                    appendLine(line, number: lineNumber, path: relativePath, match: true)
                    lastOutputLine = lineNumber
                    matchCount += 1
                    trailingContextEnd = lineNumber + min(context, Int.max - lineNumber)
                } else {
                    if matches && matchCount >= limit { matchLimitReached = true }
                    if lineNumber <= trailingContextEnd {
                        appendLine(line, number: lineNumber, path: relativePath, match: false)
                        lastOutputLine = lineNumber
                    }
                }
                if matchLimitReached && lineNumber >= trailingContextEnd { break }
            }
        }

        if matchCount == 0 {
            return AgentToolResult(content: [.text(TextContent(text: "No matches found"))])
        }

        let rawOutput = outputLines.joined(separator: "\n")
        var truncation = truncateHead(rawOutput, options: TruncationOptions(maxLines: Int.max))
        truncation.totalLines = outputLineCount
        truncation.totalBytes = outputBytes - 1
        var output = truncation.content
        var notices: [String] = []
        var detailsDict: [String: Any] = [:]

        if matchLimitReached {
            notices.append("\(limit) matches limit reached. Use limit=\(limit > Int.max / 2 ? Int.max : limit * 2) for more, or refine pattern")
            detailsDict["matchLimitReached"] = limit
        }

        if truncation.truncated {
            notices.append("\(formatSize(DEFAULT_MAX_BYTES)) limit reached")
            detailsDict["truncation"] = truncationToAnyCodable(truncation).value
        }

        if linesTruncated {
            notices.append("Some lines truncated to \(GREP_MAX_LINE_LENGTH) chars. Use read tool to see full lines")
            detailsDict["linesTruncated"] = true
        }

        if !notices.isEmpty {
            output += "\n\n[\(notices.joined(separator: ". "))]"
        }

        let details = detailsDict.isEmpty ? nil : AnyCodable(detailsDict)
        return AgentToolResult(content: [.text(TextContent(text: output))], details: details)
    }
    tool.executeWithContext = { id, params, signal, onUpdate, context in
        try await createGrepTool(cwd: resolveToolExecutionCwd(context, fallback: cwd), options: options).execute(id, params, signal, onUpdate)
    }
    return tool
}

private func formatPath(for file: URL, searchPath: String, isDirectory: Bool) -> String {
    if isDirectory {
        let basePrefix = searchPath.hasSuffix("/") ? searchPath : searchPath + "/"
        let resolved = file.resolvingSymlinksInPath().path
        let relative = resolved.hasPrefix(basePrefix) ? String(resolved.dropFirst(basePrefix.count)) : file.lastPathComponent
        return relative.replacingOccurrences(of: "\\", with: "/")
    }
    return file.lastPathComponent
}

private func grepInteger(_ value: AnyCodable?, default fallback: Int, minimum: Int) -> Int {
    guard let number = doubleValue(value), !number.isNaN else { return fallback }
    if number <= Double(minimum) { return minimum }
    // Double(Int.max) rounds upward, so test the bound before conversion.
    if number >= Double(Int.max) { return Int.max }
    return max(minimum, Int(number.rounded(.down)))
}

private func grepFiles(root: String, glob: String?) -> AnySequence<URL> {
    let rootURL = URL(fileURLWithPath: root)
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var pattern = glob ?? ""
    let excluded = pattern.hasPrefix("!")
    if excluded { pattern.removeFirst() }
    while pattern.hasPrefix("./") { pattern.removeFirst(2) }
    if pattern.hasPrefix("/") { pattern.removeFirst() }
    let basenameOnly = !pattern.contains("/")
    let regex = pattern.isEmpty ? nil : globToRegex(pattern)
    return AnySequence {
        let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants], errorHandler: nil
        )
        return AnyIterator<URL> {
            while let file = enumerator?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if let regex {
                    let resolved = file.resolvingSymlinksInPath().path
                    let relative = resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : file.lastPathComponent
                    let candidate = basenameOnly ? file.lastPathComponent : relative
                    let matches = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
                    if matches == excluded { continue }
                }
                return file
            }
            return nil
        }
    }
}

/// Read LF-delimited lines. A CR before LF is a terminator; other CRs are content.
/// Memory use is bounded by the block size and the longest line.
private final class GrepLineReader {
    private let handle: FileHandle
    private var bytes: [UInt8]
    private var position = 0
    private var ended = false
    private let unitSize: Int
    private let bigEndian: Bool

    init(file: URL) throws {
        handle = try FileHandle(forReadingFrom: file)
        bytes = Array(try handle.read(upToCount: 64 * 1024) ?? Data())
        if bytes.starts(with: [0xFF, 0xFE]) {
            unitSize = 2
            bigEndian = false
            position = 2
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            unitSize = 2
            bigEndian = true
            position = 2
        } else {
            unitSize = 1
            bigEndian = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
        }
    }

    deinit { try? handle.close() }

    func nextLine(checkCancellation: () throws -> Void) throws -> String? {
        var scan = position
        while true {
            while scan + unitSize <= bytes.count {
                let code = unitSize == 1 ? UInt16(bytes[scan]) :
                    (bigEndian ? UInt16(bytes[scan]) << 8 | UInt16(bytes[scan + 1]) :
                        UInt16(bytes[scan]) | UInt16(bytes[scan + 1]) << 8)
                if code == 10 {
                    let start = position
                    position = scan + unitSize
                    var end = scan
                    if end - start >= unitSize {
                        let previous = unitSize == 1 ? UInt16(bytes[end - 1]) :
                            (bigEndian ? UInt16(bytes[end - 2]) << 8 | UInt16(bytes[end - 1]) :
                                UInt16(bytes[end - 2]) | UInt16(bytes[end - 1]) << 8)
                        if previous == 13 { end -= unitSize }
                    }
                    return decode(bytes[start..<end])
                }
                scan += unitSize
            }
            if ended {
                guard position < bytes.count else { return nil }
                let result = decode(bytes[position...])
                position = bytes.count
                return result
            }
            try checkCancellation()
            if position > 0 {
                bytes.removeFirst(position)
                scan -= position
                position = 0
            }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { ended = true }
            else { bytes.append(contentsOf: chunk) }
        }
    }

    private func decode(_ slice: ArraySlice<UInt8>) -> String {
        if unitSize == 1 { return String(decoding: slice, as: UTF8.self) }
        let data = Array(slice)
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        for index in stride(from: 0, to: data.count - data.count % 2, by: 2) {
            units.append(bigEndian ? UInt16(data[index]) << 8 | UInt16(data[index + 1]) :
                UInt16(data[index]) | UInt16(data[index + 1]) << 8)
        }
        return String(decoding: units, as: UTF16.self)
    }
}
