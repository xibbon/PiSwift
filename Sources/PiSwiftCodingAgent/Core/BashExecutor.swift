import Foundation
import PiSwiftAI

public struct BashExecutorOptions: Sendable {
    public var onChunk: (@Sendable (String) -> Void)?
    public var signal: CancellationToken?
    public var timeoutSeconds: Double?
    public var environment: [String: String]?
    public var cwd: String?

    public init(
        onChunk: (@Sendable (String) -> Void)? = nil,
        signal: CancellationToken? = nil,
        timeoutSeconds: Double? = nil,
        environment: [String: String]? = nil,
        cwd: String? = nil
    ) {
        self.onChunk = onChunk
        self.signal = signal
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.cwd = cwd
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
    _ = try validatedShellTimeout(options?.timeoutSeconds)
    let buffer = OutputBuffer()
    var forwardedOptions = options ?? BashExecutorOptions()
    forwardedOptions.onChunk = { chunk in
        buffer.appendText(chunk, onChunk: options?.onChunk)
    }
    var result: BashResult
    do {
        result = try await operations.execute(command, options: forwardedOptions)
    } catch {
        // v1.1.0 bash-executor.ts:122-130: keep partial output when canceled.
        guard options?.signal?.isCancelled == true else { throw error }
        buffer.flushPending(onChunk: options?.onChunk)
        let data = buffer.snapshot()
        let truncation = truncateTail(String(decoding: data, as: UTF8.self))
        var path: String?
        if truncation.truncated {
            path = try? writeOutputFile(prefix: "pi-bash", extension: ".log", data: data)
        }
        return BashResult(
            output: truncation.content, exitCode: nil, cancelled: true,
            truncated: truncation.truncated, fullOutputPath: path
        )
    }
    buffer.flushPending(onChunk: options?.onChunk)
    if let streamed = buffer.snapshot(matchingRawText: Data(result.output.utf8)) {
        // Keep the chunk boundaries that released long unfinished ANSI sequences.
        result.output = String(decoding: streamed, as: UTF8.self)
    } else {
        // Custom operations can return a tail or a separate result without streaming it.
        var outputStream = BashOutputStream()
        result.output = outputStream.appendText(result.output) + outputStream.finish()
    }
    // A custom operation can return a spill file with raw bytes. Keep its file intact.
    if let path = result.fullOutputPath,
       let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        var fileStream = BashOutputStream()
        let cleanBytes = buffer.snapshot(matchingRawText: bytes) ??
            Data((fileStream.append(bytes) + fileStream.finish()).utf8)
        if cleanBytes != bytes {
            result.fullOutputPath = try? writeOutputFile(prefix: "pi-bash", extension: ".log", data: cleanBytes)
        }
    }
    return result
}

public func executeBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    _ = try validatedShellTimeout(options?.timeoutSeconds)
    return try await executeBashWithOperations(
        command, operations: ProviderBashOperations(provider: BashExecutorRegistry.provider()), options: options
    )
}

private struct ProviderBashOperations: BashOperations {
    let provider: BashExecutorProvider

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        try await provider.execute(command, options)
    }
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
/// Runs commands in the system shell, never through `BashExecutorRegistry`. Embedders that
/// bind bash to one session use it, so a provider another session registers cannot take over.
public struct SystemBashOperations: BashOperations {
    public init() {}

    public func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        try await executeSystemBash(command, options: options)
    }
}

private func executeSystemBash(_ command: String, options: BashExecutorOptions? = nil) async throws -> BashResult {
    let timeoutSeconds = try validatedShellTimeout(options?.timeoutSeconds)
    let process = Process()
    if let cwd = options?.cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let shellConfig = try getShellConfig()
    process.executableURL = URL(fileURLWithPath: shellConfig.shell)
    process.arguments = shellConfig.args + [command]
    var environment = ProcessInfo.processInfo.environment
    for name in piSessionEnvironmentVariableNames {
        environment.removeValue(forKey: name)
    }
    if let overrides = options?.environment {
        environment.merge(overrides) { _, override in override }
    }
    process.environment = environment

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
    if let timeoutSeconds {
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

            var fullOutputPath: String? = nil
            var truncated = false

            if buffer.receivedByteCount > DEFAULT_MAX_BYTES {
                truncated = true
                fullOutputPath = try? writeOutputFile(prefix: "pi-bash", extension: ".log", data: combinedData)
                let truncation = truncateTail(output)
                output = truncation.content
            }

            let cancelled = cancelledFlag.load()

            continuation.resume(returning: BashResult(
                output: output.isEmpty ? "" : output,
                exitCode: cancelled ? nil : Int(proc.terminationStatus) + (proc.terminationReason == .uncaughtSignal ? 128 : 0),
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

/// Shared shell output stream for bytes from the system shell and text from custom operations.
struct BashOutputStream: Sendable {
    private var decoder = Utf8StreamDecoder()
    private var pendingAnsi = ""

    mutating func append(_ data: Data) -> String {
        appendText(decoder.decode(data))
    }

    mutating func appendText(_ text: String) -> String {
        let split = splitIncompleteAnsiSuffix(pendingAnsi + text)
        pendingAnsi = split.pending
        return clean(split.complete)
    }

    mutating func finish() -> String {
        let rest = pendingAnsi + decoder.flush()
        pendingAnsi = ""
        return clean(rest)
    }

    private func clean(_ text: String) -> String {
        // v1.1.0 bash-executor.ts:78: strip ANSI before binary and CR removal (decision U4).
        sanitizeBinaryOutput(stripAnsi(text)).replacingOccurrences(of: "\r", with: "")
    }
}

private final class OutputBuffer: Sendable {
    private struct State: Sendable {
        var data = Data()
        var stream = BashOutputStream()
        var receivedByteCount = 0
        var rawText: Data?
    }

    private let state = LockedState(State())

    func append(_ chunk: Data, onChunk: (@Sendable (String) -> Void)?) {
        guard !chunk.isEmpty else { return }
        let text = state.withLock { state in
            state.receivedByteCount += chunk.count
            let text = state.stream.append(chunk)
            state.data.append(contentsOf: text.utf8)
            return text
        }
        if !text.isEmpty { onChunk?(text) }
    }

    func appendText(_ chunk: String, onChunk: (@Sendable (String) -> Void)?) {
        guard !chunk.isEmpty else { return }
        let text = state.withLock { state in
            state.receivedByteCount += chunk.utf8.count
            if state.rawText == nil { state.rawText = Data() }
            state.rawText?.append(contentsOf: chunk.utf8)
            let text = state.stream.appendText(chunk)
            state.data.append(contentsOf: text.utf8)
            return text
        }
        if !text.isEmpty { onChunk?(text) }
    }

    func flushPending(onChunk: (@Sendable (String) -> Void)?) {
        let text = state.withLock { state in
            let text = state.stream.finish()
            state.data.append(contentsOf: text.utf8)
            return text
        }
        if !text.isEmpty { onChunk?(text) }
    }

    func snapshot() -> Data {
        state.withLock { $0.data }
    }

    func snapshot(matchingRawText rawText: Data) -> Data? {
        state.withLock { $0.rawText == rawText ? $0.data : nil }
    }

    var receivedByteCount: Int {
        state.withLock { $0.receivedByteCount }
    }
}

private struct Utf8StreamDecoder: Sendable {
    private var pending: [UInt8] = []
    private var atStart = true

    mutating func decode(_ data: Data) -> String {
        pending.append(contentsOf: data)
        var end = pending.count
        // Hold only a valid, incomplete UTF-8 prefix. Invalid bytes must not block later text.
        if let leadIndex = pending.indices.reversed().first(where: { pending[$0] & 0xc0 != 0x80 }) {
            let lead = pending[leadIndex]
            let expectedLength: Int
            switch lead {
            case 0xc2...0xdf: expectedLength = 2
            case 0xe0...0xef: expectedLength = 3
            case 0xf0...0xf4: expectedLength = 4
            default: expectedLength = 0
            }
            let availableLength = pending.count - leadIndex
            if expectedLength > availableLength {
                var valid = true
                if availableLength > 1 {
                    let second = pending[leadIndex + 1]
                    switch lead {
                    case 0xe0: valid = second >= 0xa0
                    case 0xed: valid = second <= 0x9f
                    case 0xf0: valid = second >= 0x90
                    case 0xf4: valid = second <= 0x8f
                    default: break
                    }
                }
                if valid { end = leadIndex }
            }
        }
        let decoded = String(decoding: pending[..<end], as: UTF8.self)
        pending = Array(pending[end...])
        return removeInitialBom(decoded)
    }

    mutating func flush() -> String {
        let decoded = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return removeInitialBom(decoded)
    }

    private mutating func removeInitialBom(_ text: String) -> String {
        guard atStart, !text.isEmpty else { return text }
        atStart = false
        return text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    }
}
