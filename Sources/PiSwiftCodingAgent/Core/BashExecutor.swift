import Foundation
import PiSwiftAI

public struct BashExecutorOptions: Sendable {
    public var onChunk: (@Sendable (String) -> Void)?
    public var signal: CancellationToken?
    public var timeoutSeconds: Double?

    public init(onChunk: (@Sendable (String) -> Void)? = nil, signal: CancellationToken? = nil, timeoutSeconds: Double? = nil) {
        self.onChunk = onChunk
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BashResult: Sendable {
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?

    public init(output: String, exitCode: Int?, cancelled: Bool, truncated: Bool, fullOutputPath: String? = nil) {
        self.output = output
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.truncated = truncated
        self.fullOutputPath = fullOutputPath
    }
}

public struct BashExecutorProvider: Sendable {
    public let execute: @Sendable (String, BashExecutorOptions?) async throws -> BashResult
    public let isAvailable: @Sendable () -> Bool

    public init(
        execute: @escaping @Sendable (String, BashExecutorOptions?) async throws -> BashResult,
        isAvailable: @escaping @Sendable () -> Bool = { true }
    ) {
        self.execute = execute
        self.isAvailable = isAvailable
    }
}

public enum BashExecutorRegistry {
    private static let state = LockedState<BashExecutorProvider>(defaultBashProvider)

    public static func register(_ provider: BashExecutorProvider) {
        state.withLock { $0 = provider }
    }

    public static func provider() -> BashExecutorProvider {
        state.withLock { $0 }
    }

    public static func isAvailable() -> Bool {
        provider().isAvailable()
    }
}

public func executeBashWithOperations(
    _ command: String,
    operations: BashOperations,
    options: BashExecutorOptions? = nil
) async throws -> BashResult {
    try await operations.execute(command, options: options)
}

public func executeBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    try await BashExecutorRegistry.provider().execute(command, options)
}

private let defaultBashProvider: BashExecutorProvider = {
    #if canImport(UIKit)
    return BashExecutorProvider(
        execute: { _, _ in
            BashResult(output: "Not available on iOS", exitCode: 1, cancelled: false, truncated: false)
        },
        isAvailable: { false }
    )
    #else
    return BashExecutorProvider(
        execute: { command, options in
            try await executeSystemBash(command, options: options)
        },
        isAvailable: { true }
    )
    #endif
}()

#if !canImport(UIKit)
private func executeSystemBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    let process = Process()
    let shellConfig = try getShellConfig()
    process.executableURL = URL(fileURLWithPath: shellConfig.shell)
    process.arguments = shellConfig.args + [command]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let buffer = OutputBuffer()

    let appendData: @Sendable (Data) -> Void = { data in
        buffer.append(data, onChunk: options?.onChunk)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        appendData(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        appendData(handle.availableData)
    }

    try process.run()

    // v0.67.4: track the spawned PID so `killTrackedDetachedChildren()` (called from session
    // teardown / signal handlers) can reap orphans if the user's command spawned detached
    // children that survive the parent.
    let spawnedPid = process.processIdentifier
    trackDetachedChildPid(spawnedPid)

    let cancelledFlag = ManagedAtomic(false)

    let cancellationTimer = DispatchSource.makeTimerSource()
    cancellationTimer.schedule(deadline: .now(), repeating: .milliseconds(50))
    cancellationTimer.setEventHandler {
        if options?.signal?.isCancelled == true {
            cancelledFlag.store(true)
            if process.isRunning {
                killProcessTree(process.processIdentifier)
            }
            cancellationTimer.cancel()
        }
    }
    cancellationTimer.resume()

    var timeoutTimer: DispatchSourceTimer?
    if let timeoutSeconds = options?.timeoutSeconds, timeoutSeconds > 0 {
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            if process.isRunning {
                cancelledFlag.store(true)
                killProcessTree(process.processIdentifier)
            }
            timer.cancel()
        }
        timer.resume()
        timeoutTimer = timer
    }

    let timeoutTimerRef = timeoutTimer
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { proc in
            untrackDetachedChildPid(spawnedPid)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutRemainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrRemainder = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            buffer.append(stdoutRemainder, onChunk: options?.onChunk)
            buffer.append(stderrRemainder, onChunk: options?.onChunk)
            buffer.flushPending(onChunk: options?.onChunk)
            cancellationTimer.cancel()
            timeoutTimerRef?.cancel()

            let combinedData = buffer.snapshot()

            var output = String(decoding: combinedData, as: UTF8.self)
            output = sanitizeBinaryOutput(output.replacingOccurrences(of: "\r", with: ""))

            var fullOutputPath: String? = nil
            var truncated = false

            if combinedData.count > DEFAULT_MAX_BYTES {
                truncated = true
                let tempPath = FileManager.default.temporaryDirectory.appendingPathComponent("pi-bash-\(UUID().uuidString).log")
                try? combinedData.write(to: tempPath)
                fullOutputPath = tempPath.path
                let truncation = truncateTail(output)
                output = truncation.content
            }

            let cancelled = cancelledFlag.load() || proc.terminationStatus == 9

            continuation.resume(returning: BashResult(
                output: output.isEmpty ? "" : output,
                exitCode: cancelled ? nil : Int(proc.terminationStatus),
                cancelled: cancelled,
                truncated: truncated,
                fullOutputPath: fullOutputPath
            ))
        }
    }
}
#endif

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
    private struct State: Sendable {
        var data: Data
        var decoder: Utf8StreamDecoder
    }

    private let state = LockedState(State(data: Data(), decoder: Utf8StreamDecoder()))

    func append(_ chunk: Data, onChunk: (@Sendable (String) -> Void)?) {
        guard !chunk.isEmpty else { return }
        var decoded: String?
        state.withLock { state in
            state.data.append(chunk)
            decoded = state.decoder.decode(chunk)
        }
        if let decoded, !decoded.isEmpty {
            let sanitized = sanitizeBinaryOutput(decoded.replacingOccurrences(of: "\r", with: ""))
            onChunk?(sanitized)
        }
    }

    func flushPending(onChunk: (@Sendable (String) -> Void)?) {
        guard let onChunk else { return }
        var flushed: String?
        state.withLock { state in
            flushed = state.decoder.flush()
        }
        if let flushed, !flushed.isEmpty {
            let sanitized = sanitizeBinaryOutput(flushed.replacingOccurrences(of: "\r", with: ""))
            onChunk(sanitized)
        }
    }

    func snapshot() -> Data {
        state.withLock { $0.data }
    }
}

private struct Utf8StreamDecoder: Sendable {
    private var buffer: [UInt8] = []

    mutating func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        buffer.append(contentsOf: data)
        var prefixLength = buffer.count
        while prefixLength > 0 {
            if String(bytes: buffer[0..<prefixLength], encoding: .utf8) != nil {
                break
            }
            prefixLength -= 1
        }
        guard prefixLength > 0 else { return "" }
        let decoded = String(bytes: buffer[0..<prefixLength], encoding: .utf8) ?? ""
        buffer = Array(buffer[prefixLength...])
        return decoded
    }

    mutating func flush() -> String {
        guard !buffer.isEmpty else { return "" }
        let decoded = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return decoded
    }
}

