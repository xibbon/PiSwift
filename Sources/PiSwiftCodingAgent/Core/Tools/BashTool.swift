import Foundation
import PiSwiftAI
import PiSwiftAgent

enum BashToolError: LocalizedError, Sendable {
    case operationAborted
    case missingCommand
    case commandTimedOut(seconds: Int, output: String)
    case commandAborted(output: String)
    case commandFailed(exitCode: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .operationAborted:
            return "Operation aborted"
        case .missingCommand:
            return "Missing command"
        case let .commandTimedOut(seconds, output):
            let suffix = output.isEmpty ? "" : "\n\n"
            return "\(output)\(suffix)Command timed out after \(seconds) seconds"
        case let .commandAborted(output):
            let suffix = output.isEmpty ? "" : "\n\n"
            return "\(output)\(suffix)Command aborted"
        case let .commandFailed(exitCode, output):
            let suffix = output.isEmpty ? "" : "\n\n"
            return "\(output)\(suffix)Command exited with code \(exitCode)"
        }
    }
}

public struct BashToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var fullOutputPath: String?
}

/// Generate a unique temp file path for bash output
private func getTempFilePath() -> String {
    let uuid = UUID().uuidString.prefix(16)
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-bash-\(uuid).log")
        .path
}

public protocol BashOperations: Sendable {
    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult
}

public struct DefaultBashOperations: BashOperations {
    public init() {}

    public func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        try await executeBash(command, options: options)
    }
}

public struct BashToolOptions: Sendable {
    public var operations: BashOperations?
    /// Command prefix prepended to every command (e.g., "shopt -s expand_aliases" for alias support)
    public var commandPrefix: String?

    public init(operations: BashOperations? = nil, commandPrefix: String? = nil) {
        self.operations = operations
        self.commandPrefix = commandPrefix
    }
}

public func createBashTool(cwd: String, options: BashToolOptions? = nil) -> PiSwiftAgent.AgentTool {
    let parameters: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "command": ["type": "string", "description": "Bash command to execute"],
            "timeout": ["type": "number", "description": "Timeout in seconds (optional)"],
        ]),
    ]
    @Sendable func execute(
        _ toolCallId: String,
        _ params: [String: AnyCodable],
        _ signal: CancellationToken?,
        _ onUpdate: AgentToolUpdateCallback?
    ) async throws -> AgentToolResult {
        _ = toolCallId
        if signal?.isCancelled == true {
            throw BashToolError.operationAborted
        }
        guard let command = params["command"]?.value as? String else {
            throw BashToolError.missingCommand
        }
        // Apply command prefix if configured (e.g., "shopt -s expand_aliases" for alias support)
        let resolvedCommand: String
        if let prefix = options?.commandPrefix {
            resolvedCommand = "\(prefix)\n\(command)"
        } else {
            resolvedCommand = command
        }
        let timeoutValue: Double? = doubleValue(params["timeout"])
        let operations: BashOperations = options?.operations ?? DefaultBashOperations()

        // Track output for truncation using thread-safe state
        struct TempFileState: Sendable {
            var output: String = ""
            var tempFilePath: String? = nil
            var tempFileHandle: FileHandle? = nil
        }
        let state: LockedState<TempFileState> = LockedState(TempFileState())

        // Always capture output for truncation, even without streaming
        let onChunk: @Sendable (String) -> Void = { chunk in
            let (current, _, tempPath): (String, Int, String?) = state.withLock { s in
                s.output += chunk
                let bytes = s.output.utf8.count

                // Start writing to temp file once we exceed the threshold
                if bytes > DEFAULT_MAX_BYTES && s.tempFilePath == nil {
                    let path = getTempFilePath()
                    FileManager.default.createFile(atPath: path, contents: nil)
                    if let handle = FileHandle(forWritingAtPath: path) {
                        s.tempFilePath = path
                        s.tempFileHandle = handle
                        // Write buffered content to file
                        if let data = s.output.data(using: .utf8) {
                            try? handle.write(contentsOf: data)
                        }
                    }
                } else if let handle = s.tempFileHandle {
                    // Write new chunk to temp file
                    if let data = chunk.data(using: .utf8) {
                        try? handle.write(contentsOf: data)
                    }
                }

                return (s.output, bytes, s.tempFilePath)
            }

            // Stream truncated output to callback if provided
            if let onUpdate {
                let truncation = truncateTail(current)
                let text = truncation.content.isEmpty ? "(no output)" : truncation.content
                let details: AnyCodable? = truncation.truncated ? AnyCodable([
                    "truncation": [
                        "truncated": truncation.truncated,
                        "truncatedBy": truncation.truncatedBy as Any,
                        "totalLines": truncation.totalLines,
                        "totalBytes": truncation.totalBytes,
                        "outputLines": truncation.outputLines,
                        "outputBytes": truncation.outputBytes,
                    ],
                    "fullOutputPath": tempPath as Any,
                ]) : nil
                onUpdate(AgentToolResult(content: [.text(TextContent(text: text))], details: details))
            }
        }

        let result: BashResult = try await operations.execute(
            resolvedCommand,
            options: BashExecutorOptions(onChunk: onChunk, signal: signal, timeoutSeconds: timeoutValue)
        )

        // Get final state and close temp file handle
        let (fullOutput, tempFilePath): (String, String?) = state.withLock { s in
            try? s.tempFileHandle?.close()
            return (s.output, s.tempFilePath)
        }

        let truncation = truncateTail(fullOutput)
        var outputText = truncation.content.isEmpty ? "(no output)" : truncation.content

        // Build details with truncation info
        var details: AnyCodable? = nil
        if truncation.truncated {
            let startLine = truncation.totalLines - truncation.outputLines + 1
            let endLine = truncation.totalLines

            // Build actionable notice
            if truncation.lastLinePartial {
                let lastLineSize = formatSize(fullOutput.split(separator: "\n").last.map { $0.utf8.count } ?? 0)
                outputText += "\n\n[Showing last \(formatSize(truncation.outputBytes)) of line \(endLine) (line is \(lastLineSize)). Full output: \(tempFilePath ?? "unavailable")]"
            } else if truncation.truncatedBy == "lines" {
                outputText += "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines). Full output: \(tempFilePath ?? "unavailable")]"
            } else {
                outputText += "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines) (\(formatSize(DEFAULT_MAX_BYTES)) limit). Full output: \(tempFilePath ?? "unavailable")]"
            }

            details = AnyCodable([
                "truncation": [
                    "truncated": truncation.truncated,
                    "truncatedBy": truncation.truncatedBy as Any,
                    "totalLines": truncation.totalLines,
                    "totalBytes": truncation.totalBytes,
                    "outputLines": truncation.outputLines,
                    "outputBytes": truncation.outputBytes,
                ],
                "fullOutputPath": tempFilePath as Any,
            ])
        }

        if result.cancelled {
            if let timeoutValue {
                throw BashToolError.commandTimedOut(seconds: Int(timeoutValue), output: outputText)
            }
            throw BashToolError.commandAborted(output: outputText)
        }
        if let exitCode = result.exitCode, exitCode != 0 {
            throw BashToolError.commandFailed(exitCode: exitCode, output: outputText)
        }

        return AgentToolResult(content: [.text(TextContent(text: outputText))], details: details)
    }
    return PiSwiftAgent.AgentTool(
        label: "bash",
        name: "bash",
        description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last \(DEFAULT_MAX_LINES) lines or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first). If truncated, full output is saved to a temp file.",
        parameters: parameters,
        execute: execute
    )
}

/// Create a `BashOperations` instance that executes commands locally.
/// Extensions can use this to compose bash behavior without duplicating execution logic.
public func createLocalBashOperations() -> BashOperations {
    DefaultBashOperations()
}
