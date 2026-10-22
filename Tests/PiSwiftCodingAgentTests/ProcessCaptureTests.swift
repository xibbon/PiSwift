#if os(macOS) || os(Linux)
import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private let processCaptureByteCount = 1_048_576
private let processCaptureLargeCommand = "head -c 1048576 /dev/zero | tr '\\000' o; head -c 1048576 /dev/zero | tr '\\000' e >&2; exit 7"

@Test(.timeLimit(.minutes(1)))
func processCaptureExecDrainsBothLargePipes() async throws {
    let result = try await execCommand("/bin/sh", ["-c", processCaptureLargeCommand], "/")
    #expect(result.stdout == String(repeating: "o", count: processCaptureByteCount))
    #expect(result.stderr == String(repeating: "e", count: processCaptureByteCount))
    #expect(result.code == 7)
    #expect(!result.killed)
}

@Test(.timeLimit(.minutes(1)))
func processCaptureBashKeepsBothLargePipes() async throws {
    let result = try await SystemBashOperations().execute(processCaptureLargeCommand, options: nil)
    let path = try #require(result.fullOutputPath)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.count == processCaptureByteCount * 2)
    #expect(data.filter { $0 == Character("o").asciiValue! }.count == processCaptureByteCount)
    #expect(data.filter { $0 == Character("e").asciiValue! }.count == processCaptureByteCount)
    #expect(result.exitCode == 7)
    #expect(!result.cancelled)
    #expect(result.truncated)
}

private struct ProcessCaptureChild {
    let directory: URL
    let pidFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-pipe-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        pidFile = directory.appendingPathComponent("pid")
    }

    var command: String {
        "sleep 30 & printf '%s' $! > '\(pidFile.path)'; printf ready; exit 0"
    }

    func waitForStart() async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: pidFile.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The child did not start")
    }

    func cleanup() {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
            _ = kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func processCaptureTimeoutClosesDescendantPipes(bash: Bool) async throws {
    let child = try ProcessCaptureChild()
    defer { child.cleanup() }
    let started = ContinuousClock.now
    if bash {
        let result = try await SystemBashOperations().execute(child.command, options: .init(timeoutSeconds: 0.5))
        #expect(result.output == "ready")
        #expect(result.cancelled)
        #expect(result.exitCode == nil)
    } else {
        let result = try await execCommand("/bin/sh", ["-c", child.command], "/", .init(timeout: 0.5))
        #expect(result.stdout == "ready")
        #expect(result.stderr.isEmpty)
        #expect(result.killed)
        #expect(result.code == 0)
    }
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func processCaptureCancellationClosesDescendantPipes(bash: Bool) async throws {
    let child = try ProcessCaptureChild()
    defer { child.cleanup() }
    let signal = CancellationToken()
    let started = ContinuousClock.now
    if bash {
        let task = Task {
            try await SystemBashOperations().execute(child.command, options: .init(signal: signal))
        }
        try await child.waitForStart()
        try await Task.sleep(for: .milliseconds(50))
        signal.cancel()
        let result = try await task.value
        #expect(result.output == "ready")
        #expect(result.cancelled)
        #expect(result.exitCode == nil)
    } else {
        let task = Task {
            try await execCommand("/bin/sh", ["-c", child.command], "/", .init(signal: signal))
        }
        try await child.waitForStart()
        try await Task.sleep(for: .milliseconds(50))
        signal.cancel()
        let result = try await task.value
        #expect(result.stdout == "ready")
        #expect(result.stderr.isEmpty)
        #expect(result.killed)
        #expect(result.code == 0)
    }
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func processCaptureKeepsBufferedBytesWhenStopped(cancel: Bool) async throws {
    let child = try ProcessCaptureChild()
    let readerStarted = child.directory.appendingPathComponent("reader-started")
    let releaseReader = DispatchSemaphore(value: 0)
    defer {
        releaseReader.signal()
        child.cleanup()
    }
    let firstChunk = LockedState(true)
    let signal = CancellationToken()
    let command = "printf x; while [ ! -e '\(readerStarted.path)' ]; do sleep 0.01; done; head -c 4096 /dev/zero | tr '\\000' p; sleep 30 & printf '%s' $! > '\(child.pidFile.path)'; exit 0"
    let task = Task {
        try await SystemBashOperations().execute(command, options: .init(onChunk: { _ in
            let first = firstChunk.withLock { value in
                let first = value
                value = false
                return first
            }
            if first {
                // The shell writes the next block only after this read callback stops.
                try? Data().write(to: readerStarted)
                releaseReader.wait()
            }
        }, signal: signal, timeoutSeconds: cancel ? nil : 0.5))
    }
    try await child.waitForStart()
    if cancel { signal.cancel() }
    // Let the timer cancel the source while its callback still holds the reader queue.
    try await Task.sleep(for: .milliseconds(cancel ? 150 : 600))
    releaseReader.signal()
    let result = try await task.value
    #expect(result.output == "x" + String(repeating: "p", count: 4096))
    #expect(result.cancelled)
    #expect(result.exitCode == nil)
}

@Test(.timeLimit(.minutes(1)))
func processCaptureWaitsForExitAfterBothPipesClose() async throws {
    let command = "printf out; printf err >&2; exec 1>&- 2>&-; sleep 0.01; exit 7"
    for _ in 0..<50 {
        let result = try await execCommand("/bin/sh", ["-c", command], "/")
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
        #expect(result.code == 7)
        #expect(!result.killed)

        let bash = try await SystemBashOperations().execute(command, options: nil)
        #expect(bash.output.utf8.sorted() == "outerr".utf8.sorted())
        #expect(bash.exitCode == 7)
        #expect(!bash.cancelled)
    }
}

@Test(.timeLimit(.minutes(1)))
func processCaptureOutputLimitAndStartFailure() async throws {
    let limited = try await execCommand("/bin/sh", ["-c", processCaptureLargeCommand], "/", .init(maxOutputBytes: 8192))
    #expect(limited.stdout == String(repeating: "o", count: 8192))
    #expect(limited.outputExceeded)
    #expect(limited.killed)

    let failed = try await execCommand("/pi-no-such-executable-\(UUID().uuidString)", [], "/")
    #expect(failed.stdout.isEmpty)
    #expect(!failed.stderr.isEmpty)
    #expect(failed.code == 1)
    #expect(failed.killed)
}
#endif
