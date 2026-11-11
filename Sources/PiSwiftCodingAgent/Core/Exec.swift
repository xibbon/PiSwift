import Foundation
import PiSwiftAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ExecOptions: Sendable {
    public var signal: CancellationToken?
    public var timeout: TimeInterval?
    public var cwd: String?
    /// Stop the child process when captured stdout exceeds this byte count.
    public var maxOutputBytes: Int?
    /// Combined stdout and stderr cap. Defaults to 256 MiB.
    public var maxBuffer: Int? {
        get { maxOutputBytes }
        set { maxOutputBytes = newValue }
    }
    /// Discard stderr instead of retaining it in memory.
    public var captureStderr: Bool
    /// Delay before forcing a child that ignores SIGTERM to exit.
    public var terminationGracePeriod: TimeInterval

    public init(
        signal: CancellationToken? = nil,
        timeout: TimeInterval? = nil,
        cwd: String? = nil,
        maxOutputBytes: Int? = nil,
        maxBuffer: Int? = nil,
        captureStderr: Bool = true,
        terminationGracePeriod: TimeInterval = 5
    ) {
        self.signal = signal
        self.timeout = timeout
        self.cwd = cwd
        self.maxOutputBytes = maxBuffer ?? maxOutputBytes
        self.captureStderr = captureStderr
        self.terminationGracePeriod = terminationGracePeriod
    }
}

public struct ExecResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int
    public var killed: Bool
    public var outputExceeded: Bool
    public var truncated: Bool { outputExceeded }

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
    case invalidMaxBuffer
    case invalidTerminationGracePeriod

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "Invalid timeout: must be a finite number of seconds"
        case .timeoutExceedsMaximum:
            return "Invalid timeout: maximum is \(maximumShellTimeoutSeconds) seconds"
        case .invalidMaxBuffer:
            return "maxBuffer must be an integer between 0 and \(Int.max) bytes"
        case .invalidTerminationGracePeriod:
            return "terminationGracePeriod must be a finite, nonnegative number of seconds"
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
    let maxBuffer = options?.maxOutputBytes ?? 256 * 1_024 * 1_024
    guard maxBuffer >= 0 else { throw ShellExecutionError.invalidMaxBuffer }
    let terminationGracePeriod = options?.terminationGracePeriod ?? 5
    guard terminationGracePeriod.isFinite, terminationGracePeriod >= 0 else {
        throw ShellExecutionError.invalidTerminationGracePeriod
    }
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

    let stdoutBuffer = OutputBuffer()
    let stderrBuffer = OutputBuffer()
    let outputBudget = ExecOutputBudget(limit: maxBuffer)
    let outputExceeded = ManagedAtomic(false)
    let killedFlag = ManagedAtomic(false)
    let terminationRequested = ManagedAtomic(false)
    let forceKillTimer = LockedState<DispatchSourceTimer?>(nil)
    let requestTermination: @Sendable () -> Void = {
        guard terminationRequested.exchangeTrue() == false else { return }
        killedFlag.store(true)
        guard process.isRunning else { return }
        // v1.5.2 C-TB: c466a3595, exec.ts:78-93. Give SIGTERM a grace period.
        #if canImport(Darwin) || canImport(Glibc)
        _ = kill(process.processIdentifier, SIGTERM)
        #else
        process.terminate()
        #endif
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + max(0, terminationGracePeriod))
        timer.setEventHandler {
            if process.isRunning { killProcessTree(process.processIdentifier) }
            timer.cancel()
        }
        forceKillTimer.withLock { $0 = timer }
        timer.resume()
    }
    let cancelReadersOnLimit = LockedState<(@Sendable () -> Void)?>(nil)

    // Each pipe has its own queue. Cancel closes the handle after the last read.
    let readers = DispatchGroup()
    func startReader(_ pipe: Pipe, append: @escaping @Sendable (Data) -> Void) -> any DispatchSourceRead {
        let handle = pipe.fileHandleForReading
        let source = DispatchSource.makeReadSource(
            fileDescriptor: handle.fileDescriptor,
            queue: DispatchQueue(label: "PiSwiftCodingAgent.process.read")
        )
        readers.enter()
        source.setEventHandler { [weak source] in
            guard let source, !source.isCancelled else { return }
            do {
                let count = max(1, Int(min(source.data, 65_536)))
                let data = try handle.read(upToCount: count) ?? Data()
                if data.isEmpty { source.cancel() }
                else { append(data) }
            } catch {
                source.cancel()
            }
        }
        source.setCancelHandler {
            #if canImport(Darwin) || canImport(Glibc)
            // Read only the bytes now in the pipe. A child can keep its write end open.
            #if canImport(Darwin)
            // Darwin's FIONREAD macro is not available in Swift.
            let request: UInt = 0x4004667f
            #else
            let request = UInt(FIONREAD)
            #endif
            var remaining: Int32 = 0
            if ioctl(handle.fileDescriptor, request, &remaining) == 0 {
                while remaining > 0 {
                    guard let data = try? handle.read(upToCount: min(Int(remaining), 65_536)),
                          !data.isEmpty else { break }
                    append(data)
                    remaining -= Int32(data.count)
                }
            }
            #endif
            try? handle.close()
            readers.leave()
        }
        source.resume()
        return source
    }
    let stdoutReader = startReader(stdoutPipe) { data in
        let (kept, exceeded) = outputBudget.take(data)
        _ = stdoutBuffer.append(kept)
        if exceeded {
            outputExceeded.store(true)
            requestTermination()
            cancelReadersOnLimit.withLock { $0 }?()
        }
    }
    let stderrReader = stderrPipe.map { pipe in
        startReader(pipe) { data in
            let (kept, exceeded) = outputBudget.take(data)
            _ = stderrBuffer.append(kept)
            if exceeded {
                outputExceeded.store(true)
                requestTermination()
                cancelReadersOnLimit.withLock { $0 }?()
            }
        }
    }
    cancelReadersOnLimit.withLock { value in
        value = {
            stdoutReader.cancel()
            stderrReader?.cancel()
        }
    }

    // Foundation reports exit independently of the queues that drain the pipes.
    readers.enter()
    process.terminationHandler = { _ in
        if outputExceeded.load() {
            stdoutReader.cancel()
            stderrReader?.cancel()
        }
        readers.leave()
    }
    do {
        try process.run()
    } catch {
        process.terminationHandler = nil
        readers.leave()
        stdoutReader.cancel()
        stderrReader?.cancel()
        return ExecResult(stdout: "", stderr: error.localizedDescription, code: 1, killed: false)
    }
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe?.fileHandleForWriting.close()

    let removeCancellationHandler = options?.signal?.onCancel {
        requestTermination()
        stdoutReader.cancel()
        stderrReader?.cancel()
    }

    var timeoutTimer: DispatchSourceTimer?
    if let timeout {
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            requestTermination()
            stdoutReader.cancel()
            stderrReader?.cancel()
            timer.cancel()
        }
        timer.resume()
        timeoutTimer = timer
    }

    let timeoutTimerRef = timeoutTimer
    return await withCheckedContinuation { continuation in
        readers.notify(queue: .global()) {
            removeCancellationHandler?()
            timeoutTimerRef?.cancel()
            forceKillTimer.withLock { $0?.cancel(); $0 = nil }

            let wasTruncated = outputExceeded.load()
            let stdoutData = stdoutBuffer.snapshot()
            let stderrData = stderrBuffer.snapshot()
            let stdoutText = String(decoding: wasTruncated ? dropIncompleteUTF8Suffix(stdoutData) : stdoutData, as: UTF8.self)
            let stderrText = String(decoding: wasTruncated ? dropIncompleteUTF8Suffix(stderrData) : stderrData, as: UTF8.self)

            let killed = killedFlag.load()
            let exitCode = Int(process.terminationStatus) + (process.terminationReason == .uncaughtSignal ? 128 : 0)
            let code = wasTruncated && exitCode == 0 ? 1 : exitCode

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

    func exchangeTrue() -> Bool {
        state.withLock { old in
            let previous = old
            old = true
            return previous
        }
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

private final class ExecOutputBudget: Sendable {
    private let used = LockedState(0)
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func take(_ data: Data) -> (Data, Bool) {
        used.withLock { used in
            let remaining = max(0, limit - used)
            let count = min(remaining, data.count)
            used += count
            return (Data(data.prefix(count)), data.count > remaining)
        }
    }
}

private func dropIncompleteUTF8Suffix(_ data: Data) -> Data {
    guard let last = data.last, last >= 0x80 else { return data }
    let bytes = Array(data.suffix(4))
    var continuationCount = 0
    for byte in bytes.reversed() {
        if byte & 0xC0 == 0x80 { continuationCount += 1; continue }
        let expected = byte & 0xE0 == 0xC0 ? 1 : byte & 0xF0 == 0xE0 ? 2 : byte & 0xF8 == 0xF0 ? 3 : 0
        return expected > continuationCount ? Data(data.dropLast(continuationCount + 1)) : data
    }
    return Data(data.dropLast(continuationCount))
}
#endif
