import Foundation
import PiSwiftAI

public struct ExecOptions: Sendable {
    public var signal: CancellationToken?
    public var timeout: TimeInterval?
    public var cwd: String?
    /// Stop the child process when captured stdout exceeds this byte count.
    public var maxOutputBytes: Int?
    /// Discard stderr instead of retaining it in memory.
    public var captureStderr: Bool

    public init(
        signal: CancellationToken? = nil,
        timeout: TimeInterval? = nil,
        cwd: String? = nil,
        maxOutputBytes: Int? = nil,
        captureStderr: Bool = true
    ) {
        self.signal = signal
        self.timeout = timeout
        self.cwd = cwd
        self.maxOutputBytes = maxOutputBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.captureStderr = captureStderr
    }
}

public struct ExecResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int
    public var killed: Bool
    public var outputExceeded: Bool

    public init(stdout: String, stderr: String, code: Int, killed: Bool, outputExceeded: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
        self.killed = killed
        self.outputExceeded = outputExceeded
    }
}

public enum ShellExecutionError: LocalizedError, Sendable {
    case invalidTimeout
    case timeoutExceedsMaximum

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "Invalid timeout: must be a finite number of seconds"
        case .timeoutExceedsMaximum:
            return "Invalid timeout: maximum is \(maximumShellTimeoutSeconds) seconds"
        }
    }
}

public let maximumShellTimeoutMilliseconds: Double = 2_147_483_647
public let maximumShellTimeoutSeconds = maximumShellTimeoutMilliseconds / 1_000

func validatedShellTimeout(_ timeout: TimeInterval?) throws -> TimeInterval? {
    guard let timeout else { return nil }
    guard timeout.isFinite, timeout > 0 else {
        throw ShellExecutionError.invalidTimeout
    }
    guard timeout * 1_000 <= maximumShellTimeoutMilliseconds else {
        throw ShellExecutionError.timeoutExceedsMaximum
    }
    return timeout
}

#if !canImport(UIKit)
public func execCommand(_ command: String, _ args: [String], _ cwd: String, _ options: ExecOptions? = nil) async throws -> ExecResult {
    let timeout = try validatedShellTimeout(options?.timeout)
    let process = Process()

    #if os(Windows)
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    #else
    if command.contains("/") || command.contains("\\") {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
    }
    #endif

    let directory = options?.cwd ?? cwd
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    let stdoutPipe = Pipe()
    let stderrPipe = options?.captureStderr == false ? nil : Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe ?? FileHandle.nullDevice

    let stdoutBuffer = OutputBuffer(limit: options?.maxOutputBytes)
    let stderrBuffer = OutputBuffer()
    let outputExceeded = ManagedAtomic(false)
    let killedFlag = ManagedAtomic(false)

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        if !stdoutBuffer.append(handle.availableData) {
            outputExceeded.store(true)
            killedFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
        }
    }
    stderrPipe?.fileHandleForReading.readabilityHandler = { handle in
        _ = stderrBuffer.append(handle.availableData)
    }

    let cancellationTimer = DispatchSource.makeTimerSource()
    cancellationTimer.schedule(deadline: .now(), repeating: .milliseconds(50))
    cancellationTimer.setEventHandler {
        if options?.signal?.isCancelled == true {
            killedFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            cancellationTimer.cancel()
        }
    }
    cancellationTimer.resume()

    var timeoutTimer: DispatchSourceTimer?
    if let timeout {
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            killedFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            timer.cancel()
        }
        timer.resume()
        timeoutTimer = timer
    }

    do {
        try process.run()
    } catch {
        cancellationTimer.cancel()
        timeoutTimer?.cancel()
        return ExecResult(stdout: "", stderr: error.localizedDescription, code: 1, killed: true)
    }

    let timeoutTimerRef = timeoutTimer
    return await withCheckedContinuation { continuation in
        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrRemainder = stderrPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            _ = stdoutBuffer.append(stdoutRemainder)
            _ = stderrBuffer.append(stderrRemainder)
            cancellationTimer.cancel()
            timeoutTimerRef?.cancel()

            let stdoutText = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
            let stderrText = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)

            let killed = killedFlag.load()
            let code = Int(proc.terminationStatus) + (proc.terminationReason == .uncaughtSignal ? 128 : 0)

            continuation.resume(returning: ExecResult(
                stdout: stdoutText,
                stderr: stderrText,
                code: code,
                killed: killed,
                outputExceeded: outputExceeded.load()
            ))
        }
    }
}

private final class ManagedAtomic: Sendable {
    private let state: LockedState<Bool>

    init(_ initial: Bool) {
        state = LockedState(initial)
    }

    func store(_ newValue: Bool) {
        state.withLock { $0 = newValue }
    }

    func load() -> Bool {
        state.withLock { $0 }
    }
}

private final class OutputBuffer: Sendable {
    private let state = LockedState(Data())
    private let limit: Int?

    init(limit: Int? = nil) {
        self.limit = limit
    }

    /// Returns false when a configured size limit was exceeded.
    func append(_ chunk: Data) -> Bool {
        guard !chunk.isEmpty else { return true }
        return state.withLock { data in
            guard let limit else {
                data.append(chunk)
                return true
            }
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            return chunk.count <= remaining
        }
    }

    func snapshot() -> Data {
        state.withLock { $0 }
    }
}
#endif
