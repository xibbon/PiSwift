import Foundation

/// A program that the host has started. `exited` must settle after `close()`.
/// `write` is asynchronous so a host can apply pipe back-pressure.
public protocol McpPipe: Sendable {
    func write(_ data: Data) async throws
    func closeStdin() async
    func close() async
    var exited: Task<Void, Error> { get }
}

/// Output handlers are installed before the host opens the program.
public struct McpPipeHandlers: Sendable {
    public let onStdout: @Sendable (Data) -> Void
    public let onStderr: @Sendable (Data) -> Void

    public init(onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void) {
        self.onStdout = onStdout
        self.onStderr = onStderr
    }
}

/// MCP stdio framing over a caller-owned program, including remote programs.
public actor PipeTransport: McpTransport {
    public typealias Open = @Sendable (McpPipeHandlers) async throws -> any McpPipe

    private let open: Open
    private let lines: JsonRpcLineReader
    private let closeTimeout: Duration
    private let onError: (@Sendable (Error) -> Void)?
    private let exitWait = PipeExitWait()
    private var pipe: (any McpPipe)?
    private var started = false
    private var closed = false
    private var ended = false
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    public init(
        open: @escaping Open,
        maxMessageBytes: Int = mcpDefaultMaxMessageBytes,
        maxStderrBytes: Int = 64 * 1024,
        onStderr: (@Sendable (String) -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil,
        closeTimeout: Duration = .seconds(2)
    ) {
        self.open = open
        self.lines = JsonRpcLineReader(maxMessageBytes: maxMessageBytes, maxStderrBytes: maxStderrBytes, onStderr: onStderr, onError: onError)
        self.onError = onError
        self.closeTimeout = closeTimeout
    }

    public var stderr: String { get async { await lines.stderr } }

    public func start() async throws {
        if started { throw McpTransportError.invalidResponse("MCP pipe transport already started") }
        if closed { throw McpError.transportClosed }
        started = true
        let (stdout, stdoutSink) = AsyncStream<Data>.makeStream()
        let (stderr, stderrSink) = AsyncStream<Data>.makeStream()
        stdoutContinuation = stdoutSink
        stderrContinuation = stderrSink
        let reader = lines
        stdoutTask = Task {
            for await chunk in stdout { await reader.readStdout(chunk) }
        }
        stderrTask = Task {
            for await chunk in stderr { await reader.readStderr(chunk) }
        }
        let handlers = McpPipeHandlers(
            onStdout: { stdoutSink.yield($0) },
            onStderr: { stderrSink.yield($0) }
        )
        let opened: any McpPipe
        do {
            opened = try await open(handlers)
        } catch {
            stdoutSink.finish()
            stderrSink.finish()
            await lines.end()
            throw error
        }
        if closed {
            stdoutSink.finish()
            stderrSink.finish()
            await opened.close()
            _ = try? await opened.exited.value
            throw McpError.transportClosed
        }
        pipe = opened
        Task { [weak self] in
            do {
                try await opened.exited.value
                await self?.finish(exitError: nil)
            } catch {
                await self?.finish(exitError: error)
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard started, !closed, !ended, let pipe else { throw McpError.transportClosed }
        var framed = data
        if framed.last != UInt8(ascii: "\n") { framed.append(UInt8(ascii: "\n")) }
        try await pipe.write(framed)
    }

    public func receive() async throws -> Data {
        if let message = await lines.next() { return message }
        throw McpTransportError.connectionClosed(stderr: await lines.stderr)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        guard let pipe else {
            stdoutContinuation?.finish()
            stderrContinuation?.finish()
            await lines.end()
            return
        }
        if ended { return }
        await pipe.closeStdin()
        if await exitWait.wait(timeout: closeTimeout) { return }
        await pipe.close()
        _ = try? await pipe.exited.value
    }

    private func finish(exitError: Error?) async {
        guard !ended else { return }
        ended = true
        if let exitError, !closed { onError?(exitError) }
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        await stdoutTask?.value
        await stderrTask?.value
        await lines.end()
        await exitWait.complete()
    }
}

private actor PipeExitWait {
    private var completed = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    func complete() {
        completed = true
        timer?.cancel()
        timer = nil
        waiter?.resume(returning: true)
        waiter = nil
    }

    func wait(timeout: Duration) async -> Bool {
        if completed { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            timer = Task {
                try? await Task.sleep(for: timeout)
                timedOut()
            }
        }
    }

    private func timedOut() {
        guard !completed else { return }
        waiter?.resume(returning: false)
        waiter = nil
        timer = nil
    }
}
