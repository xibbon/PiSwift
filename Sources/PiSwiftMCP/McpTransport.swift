import Foundation
import PiSwiftAI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Darwin
#endif

/// The largest JSON-RPC message accepted by the upstream MCP transports.
public let mcpDefaultMaxMessageBytes = 16 * 1024 * 1024

public struct McpTransportSendOptions: Sendable {
    /// Cancel this token when the sender stops waiting for a reply. A transport
    /// must then prevent a later dispatch or retry. This does not stop work for
    /// a message that was already sent.
    public var signal: CancellationToken?

    public init(signal: CancellationToken? = nil) {
        self.signal = signal
    }
}

/// A pull-based transport. Framing is transport-specific: stdio uses newline
/// delimiters; HTTP sends a single JSON value in each request body.
public protocol McpTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func send(_ data: Data, options: McpTransportSendOptions) async throws
    func receive() async throws -> Data
    func close() async
    func setProtocolVersion(_ version: String) async
}

public extension McpTransport {
    func start() async throws {}
    func setProtocolVersion(_ version: String) async {}

    /// A transport that waits before dispatch must also check the token after
    /// that wait. Implement this overload to check each authorization retry.
    func send(_ data: Data, options: McpTransportSendOptions) async throws {
        guard options.signal?.isCancelled != true else { throw McpError.aborted }
        try await send(data)
    }
}

public protocol McpSessionAwareTransport: McpTransport {
    func hasSessionIdentifier() async -> Bool
}

public enum McpTransportError: Error, Sendable, Equatable {
    case messageTooLarge(limit: Int)
    case stdioMessageTooLarge(limit: Int)
    case stdioUnavailable
    case connectionClosed(stderr: String)
    case invalidResponse(String)
    case responseStreamFailed(String)
}

public struct McpHTTPError: Error, Sendable, Equatable {
    public let status: Int
    public let body: String
    public let message: String

    public init(status: Int, body: String, message: String) {
        self.status = status
        self.body = body
        self.message = message
    }
}

public struct McpAuthRequiredError: Error, Sendable, Equatable {
    public let status: Int
    public let body: String
    public let wwwAuthenticate: String?

    public init(status: Int, body: String, wwwAuthenticate: String?) {
        self.status = status
        self.body = body
        self.wwwAuthenticate = wwwAuthenticate
    }
}

public struct McpSessionExpiredError: Error, Sendable, Equatable {
    public let body: String

    public init(body: String) { self.body = body }
}

#if os(macOS)
private let liveStdioProcessGroups = LockedState<Set<pid_t>>([])
private let stdioExitHook: Void = {
    atexit {
        for pid in liveStdioProcessGroups.withLock({ $0 }) {
            _ = kill(-pid, SIGTERM)
        }
    }
}()

// Node reports spawn failures with the POSIX error name, not strerror text.
private func stdioSpawnError(_ code: Int32, command: String) -> McpError {
    let name: String
    switch code {
    case ENOENT: name = "ENOENT"
    case EACCES: name = "EACCES"
    case ENOTDIR: name = "ENOTDIR"
    case ELOOP: name = "ELOOP"
    case ENOEXEC: name = "ENOEXEC"
    case ETXTBSY: name = "ETXTBSY"
    case E2BIG: name = "E2BIG"
    case ENOMEM: name = "ENOMEM"
    case EMFILE: name = "EMFILE"
    case ENFILE: name = "ENFILE"
    case EIO: name = "EIO"
    case EINVAL: name = "EINVAL"
    case EAGAIN: name = "EAGAIN"
    case EPERM: name = "EPERM"
    default: name = "UNKNOWN"
    }
    return .connectionFailed("spawn \(command) \(name)")
}

/// A local MCP server with its own process group. `close()` shuts stdin,
/// waits briefly, then signals the entire group, including wrapper children.
public actor StdioTransport: McpTransport {
    private let command: String
    private let args: [String]
    private let env: [String: String]?
    private let inheritEnv: Bool
    private let cwd: String?
    private let debug: Bool
    private let onStderr: (@Sendable (String) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?
    private let maxMessageBytes: Int
    private let maxStderrBytes: Int
    private let closeTimeout: Duration
    private let lines: JsonRpcLineReader
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pid: pid_t?
    private var closed = false
    private var exited = false

    public init(
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        inheritEnv: Bool = true,
        cwd: String? = nil,
        debug: Bool = false,
        onStderr: (@Sendable (String) -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil,
        maxMessageBytes: Int = mcpDefaultMaxMessageBytes,
        maxStderrBytes: Int = 64 * 1024,
        closeTimeout: Duration = .seconds(2)
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.inheritEnv = inheritEnv
        self.cwd = cwd
        self.debug = debug
        self.onStderr = onStderr
        self.onError = onError
        self.maxMessageBytes = maxMessageBytes
        self.maxStderrBytes = maxStderrBytes
        self.closeTimeout = closeTimeout
        self.lines = JsonRpcLineReader(maxMessageBytes: maxMessageBytes, maxStderrBytes: maxStderrBytes, onStderr: onStderr, onError: onError)
    }

    public var processID: Int32? { pid }
    public var stderr: String { get async { await lines.stderr } }

    public static func create(
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: String? = nil,
        debug: Bool = false
    ) throws -> StdioTransport {
        StdioTransport(command: command, args: args, env: env, cwd: cwd, debug: debug)
    }

    public func start() async throws {
        guard !closed else { throw McpError.transportClosed }
        guard pid == nil else { return }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdin.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, stdout.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, stderr.fileHandleForReading.fileDescriptor)
        if let cwd {
            let directory = NSString(string: cwd).expandingTildeInPath
            let code = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
            guard code == 0 else { throw stdioSpawnError(code, command: command) }
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = inheritEnv ? ProcessInfo.processInfo.environment : [:]
        for (key, value) in env ?? [:] { environment[key] = value }
        let executable = NSString(string: command).expandingTildeInPath
        var argv = ([executable] + args).map { strdup($0) }
        argv.append(nil)
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawnp(&child, executable, &actions, &attributes, argBuffer.baseAddress, envBuffer.baseAddress)
            }
        }
        guard result == 0 else {
            throw stdioSpawnError(result, command: command)
        }
        _ = stdioExitHook
        liveStdioProcessGroups.withLock { $0.insert(child) }

        stdin.fileHandleForReading.closeFile()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr
        pid = child
        let lineReader = lines
        let (stdoutBytes, stdoutSink) = AsyncStream<Data>.makeStream()
        let (stderrBytes, stderrSink) = AsyncStream<Data>.makeStream()
        stdoutContinuation = stdoutSink
        stderrContinuation = stderrSink
        stdoutTask = Task {
            for await data in stdoutBytes { await lineReader.readStdout(data) }
            await lineReader.end()
        }
        stderrTask = Task {
            for await data in stderrBytes { await lineReader.readStderr(data) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { stdoutSink.finish() }
            else { stdoutSink.yield(data) }
        }
        let showStderr = debug
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { stderrSink.finish() }
            else {
                stderrSink.yield(data)
                if showStderr { fputs("[mcp-stdio-stderr] \(String(decoding: data, as: UTF8.self))", Foundation.stderr) }
            }
        }
        Task.detached { [weak self] in
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
            await self?.markExited()
        }
    }

    private func markExited() async {
        exited = true
        if let pid, kill(-pid, 0) == -1 {
            liveStdioProcessGroups.withLock { $0.remove(pid) }
        }
    }

    public func send(_ data: Data) async throws {
        guard !closed, let stdinPipe else { throw McpError.transportClosed }
        guard data.count <= maxMessageBytes else { throw McpTransportError.messageTooLarge(limit: maxMessageBytes) }
        var framed = data
        if framed.last != UInt8(ascii: "\n") { framed.append(UInt8(ascii: "\n")) }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: framed)
        } catch {
            throw McpTransportError.connectionClosed(stderr: await lines.stderr)
        }
    }

    public func receive() async throws -> Data {
        if let line = await lines.next() { return line }
        await stderrTask?.value
        throw McpTransportError.connectionClosed(stderr: await lines.stderr)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        stdinPipe?.fileHandleForWriting.closeFile()
        guard let pid else {
            stdoutContinuation?.finish()
            stderrContinuation?.finish()
            return
        }
        let grace = min(closeTimeout, .milliseconds(500))
        let graceDeadline = ContinuousClock.now + grace
        while !exited && ContinuousClock.now < graceDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The parent can exit while a child in its process group keeps
        // running. Check the group itself before deciding it is gone.
        if kill(-pid, 0) == 0 { _ = kill(-pid, SIGTERM) }
        let deadline = ContinuousClock.now + closeTimeout
        while kill(-pid, 0) == 0 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if kill(-pid, 0) == 0 {
            _ = kill(-pid, SIGKILL)
            let killDeadline = ContinuousClock.now + .seconds(1)
            while kill(-pid, 0) == 0 && ContinuousClock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        stdoutPipe?.fileHandleForReading.closeFile()
        stderrPipe?.fileHandleForReading.closeFile()
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        liveStdioProcessGroups.withLock { $0.remove(pid) }
        self.pid = nil
    }
}

#else
public actor StdioTransport: McpTransport {
    public init(command: String, args: [String] = [], env: [String: String]? = nil, inheritEnv: Bool = true, cwd: String? = nil, debug: Bool = false, onStderr: (@Sendable (String) -> Void)? = nil, onError: (@Sendable (Error) -> Void)? = nil, maxMessageBytes: Int = mcpDefaultMaxMessageBytes, maxStderrBytes: Int = 64 * 1024, closeTimeout: Duration = .seconds(2)) {}
    public static func create(command: String, args: [String] = [], env: [String: String]? = nil, cwd: String? = nil, debug: Bool = false) throws -> StdioTransport { throw McpTransportError.stdioUnavailable }
    public func start() async throws { throw McpTransportError.stdioUnavailable }
    public func send(_ data: Data) async throws { throw McpTransportError.stdioUnavailable }
    public func receive() async throws -> Data { throw McpTransportError.stdioUnavailable }
    public func close() async {}
}
#endif

// Readable texts for `localizedDescription` (shown by `pi mcp list` and `/mcp`); upstream wording.
extension McpTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .messageTooLarge(let limit):
            return "MCP message exceeds \(limit) bytes"
        case .stdioMessageTooLarge(let limit):
            return "MCP stdio message exceeds \(limit) bytes"
        case .stdioUnavailable:
            return "MCP stdio servers are not available on this platform"
        case .connectionClosed(let stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? "Connection closed" : "Connection closed\n\(String(tail.suffix(2_000)))"
        case .invalidResponse(let message), .responseStreamFailed(let message):
            return message
        }
    }
}

extension McpHTTPError: LocalizedError {
    public var errorDescription: String? { message }
}
