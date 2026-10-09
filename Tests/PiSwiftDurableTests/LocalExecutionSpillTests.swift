#if os(macOS)
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class SpillTextLog: Sendable {
    private let state = Mutex("")
    var text: String { state.withLock { $0 } }
    func append(_ text: String) { state.withLock { $0 += text } }
}

private struct SpillTestError: Error, Sendable {
    let message: String
}

private func withSpillTestEnv(
    shellIO: LocalShellIO = .init(), _ use: (LocalExecutionEnv) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-spill-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let env = LocalExecutionEnv(cwd: directory.path, shellIO: shellIO)
    do {
        try await use(env)
        await env.cleanup(context: .background)
    } catch {
        await env.cleanup(context: .background)
        throw error
    }
}

private func removeTestSpill(_ path: String?) {
    if let path { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
}

struct LocalExecutionSpillTests {
    // env-node.test.ts:904.
    @Test("does not spill output below its thresholds")
    func belowThresholds() async throws {
        try await withSpillTestEnv { (env: LocalExecutionEnv) async throws in
            let result = try await env.exec(.shell("printf short"),
                options: .init(timeout: .seconds(15), spill: .init(afterBytes: 100, afterLines: 10)), context: .background).get()
            defer { removeTestSpill(result.spillPath) }
            #expect(result.exitCode == 0)
            #expect(result.spillPath == nil)
        }
    }

    // env-node.test.ts:919. Shell octal output replaces Node Buffer writes.
    @Test("preserves raw spill bytes while it streams decoded text")
    func rawBytes() async throws {
        try await withSpillTestEnv { (env: LocalExecutionEnv) async throws in
            let log = SpillTextLog()
            let result = try await env.exec(.shell("printf '\\146\\200\\000\\157'"),
                options: .init(timeout: .seconds(15), onOutput: { text, _, _ in log.append(text) },
                               spill: .init(afterBytes: 1, afterLines: 10)), context: .background).get()
            defer { removeTestSpill(result.spillPath) }
            let path = try #require(result.spillPath)
            #expect(try await env.readBinaryFile(path, context: .background).get() == [0x66, 0x80, 0x00, 0x6f])
            #expect(log.text == "f\u{FFFD}\0o")
        }
    }

    // env-node.test.ts:937.
    @Test("reports the spill path when a command times out")
    func timeoutSpill() async throws {
        try await withSpillTestEnv { (env: LocalExecutionEnv) async throws in
            let result = await env.exec(.shell("printf 12345678901234567890; sleep 60"),
                options: .init(timeout: .seconds(1), spill: .init(afterBytes: 10, afterLines: 10)), context: .background)
            switch result {
            case .failure(let error):
                defer { removeTestSpill(error.spillPath) }
                #expect(error.code == .timeout)
                let path = try #require(error.spillPath)
                #expect(try await env.readTextFile(path, context: .background).get() == "12345678901234567890")
            case .success: Issue.record("Command with a 60 second sleep did not time out")
            }
        }
    }

    // env-node.test.ts:951.
    @Test("fails when it cannot preserve a requested spill")
    func spillCreationFailure() async throws {
        var io = LocalShellIO()
        io.createSpill = { throw SpillTestError(message: "test spill creation failure") }
        try await withSpillTestEnv(shellIO: io) { (env: LocalExecutionEnv) async throws in
            let result = await env.exec(.shell("printf 12345678901234567890"),
                options: .init(timeout: .seconds(15), spill: .init(afterBytes: 10, afterLines: 10)), context: .background)
            switch result {
            case .failure(let error):
                defer { removeTestSpill(error.spillPath) }
                #expect(error.code == .unknown)
                #expect(error.message.contains("Failed to preserve complete shell output"))
            case .success: Issue.record("Command succeeded after requested spill creation failed")
            }
        }
    }

    // env-node.test.ts:967.
    @Test("preserves complete large output in the spill")
    func largeOutput() async throws {
        try await withSpillTestEnv { (env: LocalExecutionEnv) async throws in
            let result = try await env.exec(.shell("head -c 500000 /dev/zero | tr '\\000' x"),
                options: .init(timeout: .seconds(15), spill: .init(afterBytes: 10, afterLines: 10)), context: .background).get()
            defer { removeTestSpill(result.spillPath) }
            let path = try #require(result.spillPath)
            #expect(try await env.readTextFile(path, context: .background).get() == String(repeating: "x", count: 500_000))
        }
    }

    // env-node.test.ts:985.
    @Test("streams and spills all lines after the line threshold")
    func lineThreshold() async throws {
        try await withSpillTestEnv { (env: LocalExecutionEnv) async throws in
            let log = SpillTextLog()
            let result = try await env.exec(.shell("i=1; while [ $i -le 15000 ]; do echo line-$i; i=$((i+1)); done"),
                options: .init(timeout: .seconds(30), onOutput: { text, _, _ in log.append(text) },
                               spill: .init(afterBytes: 1024 * 1024, afterLines: 100)), context: .background).get()
            defer { removeTestSpill(result.spillPath) }
            #expect(log.text == (1...15_000).map { "line-\($0)\n" }.joined())
            let path = try #require(result.spillPath)
            let lines = try await env.readTextLines(path, options: nil, context: .background).get()
            #expect(lines.count == 15_000)
            #expect(lines.last == "line-15000")
        }
    }

    // env-node-spill.test.ts:64. Delay the writer and apply a one-byte queue limit.
    @Test("keeps inherited stdio open while a spill write is pending")
    func pendingWriteKeepsInheritedStdio() async throws {
        let writes = Mutex(0)
        var io = LocalShellIO()
        let write = io.writeSpill
        io.spillHighWaterMark = 1
        io.writeSpill = { fd, bytes in
            writes.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.6)
            try write(fd, bytes)
        }
        try await withSpillTestEnv(shellIO: io) { (env: LocalExecutionEnv) async throws in
            let log = SpillTextLog()
            let result = try await env.exec(.shell("printf '%020d' 0 | tr 0 a; (sleep 0.2; printf '%01000d' 0 | tr 0 b) &"),
                options: .init(timeout: .seconds(20), onOutput: { text, _, _ in log.append(text) },
                               spill: .init(afterBytes: 10, afterLines: 10)), context: .background).get()
            defer { removeTestSpill(result.spillPath) }
            #expect(writes.withLock { $0 } > 0)
            let expected = String(repeating: "a", count: 20) + String(repeating: "b", count: 1000)
            #expect(log.text == expected)
            let path = try #require(result.spillPath)
            #expect(try await env.readTextFile(path, context: .background).get() == expected)
        }
    }
}
#endif
