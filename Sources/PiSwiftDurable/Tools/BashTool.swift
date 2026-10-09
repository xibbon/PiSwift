import PiSwiftChord

/// A command and an optional timeout in seconds.
public struct BashToolInput: Codable, Sendable, Equatable {
    /// The command supplied by the model.
    public var command: String
    /// A positive, finite timeout in seconds. Nil gives no timeout.
    public var timeout: Double?
    /// Creates bash arguments.
    public init(command: String, timeout: Double? = nil) { self.command = command; self.timeout = timeout }
}

/// The command, directory, and environment for one tool call.
public struct BashExecution: Sendable, Equatable {
    /// The command with its configured prefix.
    public var command: String
    /// The working directory.
    public var cwd: String
    /// The explicit environment variables.
    public var env: [String: String]
    /// Whether the shell inherits the host environment.
    public var inheritEnv: Bool
    /// Creates one execution value.
    public init(command: String, cwd: String, env: [String: String] = [:], inheritEnv: Bool = true) {
        self.command = command; self.cwd = cwd; self.env = env; self.inheritEnv = inheritEnv
    }
}

/// Returns the prepared command for one call. Each call starts with a separate value.
public typealias BashPrepare = @Sendable (BashExecution, ToolExecutionApi, ChordContext) async throws -> BashExecution

/// Optional command prefix and per-call preparation.
public struct BashToolOptions: Sendable {
    /// Lines placed before each command.
    public var commandPrefix: String?
    /// A callback that changes the command, directory, or explicit environment.
    public var prepare: BashPrepare?
    /// Creates bash options.
    public init(commandPrefix: String? = nil, prepare: BashPrepare? = nil) {
        self.commandPrefix = commandPrefix; self.prepare = prepare
    }
}

internal func bashTimeout(_ timeout: Double?) throws -> Duration? {
    guard let timeout else { return nil }
    guard timeout.isFinite, timeout > 0 else {
        throw DurableToolError(message: "Invalid timeout: must be a finite number of seconds")
    }
    let maximum = 2_147_483_647.0 / 1000
    guard timeout <= maximum else {
        throw DurableToolError(message: "Invalid timeout: maximum is 2147483.647 seconds")
    }
    return .seconds(timeout)
}

/// Creates a tool that streams raw shell output and lets the harness retain its tail.
/// Local shell execution is unavailable on iOS. A mobile host can omit this tool or supply a remote shell.
public func createBashTool(options: BashToolOptions = .init()) throws -> ToolRegistration {
    try defineTool(name: "bash", description: "Execute a bash command in the current working directory. Returns combined stdout and stderr. Output is truncated to last \(defaultMaxLines) lines or \(defaultMaxBytes / 1024)KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        parameters: ["type": "object", "properties": [
            "command": ["type": "string", "description": "Bash command to execute"],
            "timeout": ["type": "number", "description": "Timeout in seconds (optional, no default timeout)"]
        ], "required": ["command"]], args: BashToolInput.self, outputLimits: .init(retain: .tail)) { args, api, context in
            let timeout = try bashTimeout(args.timeout)
            let env = try requireEnv(api)
            let prefix = options.commandPrefix.flatMap { $0.isEmpty ? nil : $0 }
            var execution = BashExecution(command: prefix.map { $0 + "\n" + args.command } ?? args.command, cwd: env.cwd)
            if let prepare = options.prepare { execution = try await prepare(execution, api, context) }
            let result = await env.exec(.shell(execution.command), options: .init(
                cwd: execution.cwd, env: execution.env, inheritEnv: execution.inheritEnv, timeout: timeout,
                onOutput: { text, _, info in try api.output(.text(text), info.skipped) },
                spill: .init(afterBytes: defaultMaxBytes, afterLines: defaultMaxLines), window: api.outputWindow), context: context)
            let spillPath: String?
            switch result {
            case .success(let value): spillPath = value.spillPath
            case .failure(let error): spillPath = error.spillPath
            }
            if let spillPath {
                try api.diagnostic(.init(severity: .info, message: "Full output: \(spillPath)", code: "full_output"))
            }
            switch result {
            case .failure(let error):
                if error.code == .aborted, context.abortSignal?.aborted == true { throw error }
                if error.code == .timeout {
                    let seconds = try args.timeout.map { try JSONValue.number($0).jsonText() } ?? "undefined"
                    throw DurableToolError(message: "Command timed out after \(seconds) seconds")
                }
                if error.code == .aborted { throw DurableToolError(message: "Command aborted") }
                throw error
            case .success(let value):
                if value.exitCode != 0 { throw DurableToolError(message: "Command exited with code \(value.exitCode)") }
            }
            return ToolExecutionResult()
        }
}
