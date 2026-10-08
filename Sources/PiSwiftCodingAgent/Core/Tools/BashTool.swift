import Foundation
import PiSwiftAI
import PiSwiftAgent

enum BashToolError: LocalizedError, Sendable {
    case operationAborted
    case missingCommand
    case commandTimedOut(seconds: Int, output: String)
    case commandAborted(output: String)
    case noExitCode(output: String)

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
        case let .noExitCode(output):
            let suffix = output.isEmpty ? "" : "\n\n"
            return "\(output)\(suffix)Command terminated without an exit code"
        }
    }
}

public struct BashToolDetails: Sendable {
    public var truncation: TruncationResult?
    public var fullOutputPath: String?
}

private let structuredOutputMaxBytes = 1024 * 1024

/// Read the complete output when it fits. Otherwise, keep the first and last 512 KiB.
/// The temp file is the source when output is large, as in the upstream accumulator.
func structuredBashOutput(_ output: String, tempFilePath: String?) throws -> (content: String, truncated: Bool) {
    let bytes = Data(output.utf8)
    guard bytes.count > structuredOutputMaxBytes else {
        return (output, false)
    }
    let path = try tempFilePath ?? writeOutputFile(prefix: "pi-bash", extension: ".log", data: bytes)
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let size = try file.seekToEnd()
    let headSize = structuredOutputMaxBytes / 2
    let tailSize = structuredOutputMaxBytes - headSize
    try file.seek(toOffset: 0)
    let head = try file.read(upToCount: headSize) ?? Data()
    try file.seek(toOffset: size - UInt64(tailSize))
    let tail = try file.read(upToCount: tailSize) ?? Data()

    // Remove an incomplete final character from the head and continuation bytes from the tail.
    var headEnd = head.count
    let headBytes = Array(head)
    let tailBytes = Array(tail)
    let fullBytes = Array(bytes)
    while headEnd > 0 && headEnd < fullBytes.count && (fullBytes[headEnd] & 0xC0) == 0x80 {
        headEnd -= 1
    }
    var tailStart = 0
    while tailStart < tailBytes.count && (tailBytes[tailStart] & 0xC0) == 0x80 {
        tailStart += 1
    }
    let headText = String(decoding: headBytes[..<headEnd], as: UTF8.self)
    let tailText = String(decoding: tailBytes[tailStart...], as: UTF8.self)
    let omitted = Int(size) - headSize - tailSize
    return ("\(headText)\n\n[... \(omitted) bytes omitted ...]\n\n\(tailText)", true)
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
    /// Supplies current session metadata at execution time. Default tools expose it.
    public var sessionEnvironment: (@Sendable () -> [String: String])?
    public var exposeSessionEnvironment: Bool

    public init(
        operations: BashOperations? = nil,
        commandPrefix: String? = nil,
        sessionEnvironment: (@Sendable () -> [String: String])? = nil,
        exposeSessionEnvironment: Bool = true
    ) {
        self.operations = operations
        self.commandPrefix = commandPrefix
        self.sessionEnvironment = sessionEnvironment
        self.exposeSessionEnvironment = exposeSessionEnvironment
    }
}

public let piSessionEnvironmentVariableNames = [
    "PI_SESSION_ID",
    "PI_SESSION_FILE",
    "PI_PROVIDER",
    "PI_MODEL",
    "PI_REASONING_LEVEL",
]

public func makePiSessionEnvironment(
    sessionId: String,
    sessionFile: String?,
    provider: String?,
    model: String?,
    reasoningLevel: String?
) -> [String: String] {
    [
        "PI_SESSION_ID": sessionId,
        "PI_SESSION_FILE": sessionFile ?? "",
        "PI_PROVIDER": provider ?? "",
        "PI_MODEL": model ?? "",
        "PI_REASONING_LEVEL": reasoningLevel ?? "",
    ]
}

public func createBashTool(cwd: String, options: BashToolOptions? = nil) -> PiSwiftAgent.AgentTool {
    let parameters: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "command": ["type": "string", "description": "Shell command to execute"],
            "timeout": ["type": "number", "description": "Timeout in seconds (optional)"],
        ]),
    ]
    let outputSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "output": [
                "type": "string",
                "description": "Combined stdout and stderr, possibly truncated",
            ],
            "truncated": ["type": "boolean"],
            "full_output_path": ["type": "string", "description": "Full output, when truncated"],
            "exit_code": ["type": "number"],
            "wall_time_seconds": ["type": "number"],
        ]),
        "required": AnyCodable(["output", "truncated", "exit_code", "wall_time_seconds"]),
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
        _ = try validatedShellTimeout(timeoutValue)
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
                    if let file = try? createOutputFileStream(prefix: "pi-bash", extension: ".log") {
                        s.tempFilePath = file.path
                        s.tempFileHandle = file.stream
                        // Write buffered content to file
                        if let data = s.output.data(using: .utf8) {
                            try? file.stream.write(contentsOf: data)
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

        let startedAt = ContinuousClock.now
        let result: BashResult = try await executeBashWithOperations(
            resolvedCommand,
            operations: operations,
            options: BashExecutorOptions(
                onChunk: onChunk,
                signal: signal,
                timeoutSeconds: timeoutValue,
                environment: options?.exposeSessionEnvironment == false ? nil : options?.sessionEnvironment?(),
                cwd: cwd
            )
        )

        // Get final state and close temp file handle
        let (fullOutput, initialTempFilePath): (String, String?) = state.withLock { s in
            try? s.tempFileHandle?.close()
            return (s.output, s.tempFilePath)
        }

        let truncation = truncateTail(fullOutput)
        var tempFilePath = initialTempFilePath
        if truncation.truncated && tempFilePath == nil {
            tempFilePath = try writeOutputFile(prefix: "pi-bash", extension: ".log", data: Data(fullOutput.utf8))
        }
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
        guard let exitCode = result.exitCode else {
            throw BashToolError.noExitCode(output: outputText)
        }
        let structuredOutput = try structuredBashOutput(fullOutput, tempFilePath: tempFilePath)
        let wallTime = ContinuousClock.now - startedAt
        let wallTimeSeconds = Double(wallTime.components.seconds) + Double(wallTime.components.attoseconds) / 1e18
        let structuredContent: [String: Any] = [
            "output": structuredOutput.content,
            "truncated": structuredOutput.truncated,
            "exit_code": exitCode,
            "wall_time_seconds": (wallTimeSeconds * 10).rounded() / 10,
        ]
        var structured = structuredContent
        if structuredOutput.truncated, let tempFilePath {
            structured["full_output_path"] = tempFilePath
        }
        if exitCode != 0 {
            outputText += "\n\nCommand exited with code \(exitCode)"
        }
        return AgentToolResult(
            content: [.text(TextContent(text: outputText))],
            details: details,
            structuredContent: AnyCodable(structured),
            isError: exitCode != 0 ? true : nil
        )
    }
    return PiSwiftAgent.AgentTool(
        label: "bash",
        name: "bash",
        description: "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last \(DEFAULT_MAX_LINES) lines or \(DEFAULT_MAX_BYTES / 1024)KB (whichever is hit first). If truncated, full output is saved to a temp file.",
        parameters: parameters,
        execute: execute,
        executeWithContext: { id, params, signal, onUpdate, context in
            try await createBashTool(cwd: resolveToolExecutionCwd(context, fallback: cwd), options: options)
                .execute(id, params, signal, onUpdate)
        },
        constrainedSampling: .jsonSchema(strict: .prefer),
        outputSchema: outputSchema
    )
}

/// Create a `BashOperations` instance that executes commands locally.
/// Extensions can use this to compose bash behavior without duplicating execution logic.
public func createLocalBashOperations() -> BashOperations {
    DefaultBashOperations()
}
