import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func localConformanceDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func localEnvConformanceCases(_ mode: WatchMode) -> [EnvConformanceCase] {
    envConformanceCases(capabilities: .init(exec: false), makeSymlink: { target, path, context in
        if context.abortSignal?.aborted == true { throw FileError(.aborted, message: "Link creation aborted", path: path) }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }, withEnv: { use in
        let directory = try localConformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path, watch: .init(mode: mode, pollIntervalMs: 100))
        do {
            try await use(env)
            await env.cleanup(context: .background)
        } catch { await env.cleanup(context: .background); throw error }
    })
}

private final class LocalConformanceWatchLog: Sendable {
    private let storage = Mutex<[WatchChange]>([])
    var changes: [WatchChange] { storage.withLock { $0 } }
    func append(_ change: WatchChange) { storage.withLock { $0.append(change) } }
    func wait(_ condition: @Sendable ([WatchChange]) -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(changes) {
            if clock.now > deadline { throw EnvConformanceFailure("Watch deadline expired; got \(changes)") }
            try await clock.sleep(for: .milliseconds(20))
        }
    }
}

struct LocalExecutionConformanceTests {
    // upstream env-node-conformance.test.ts:33; the six exec cases run in E2.
    #if os(macOS)
    @Test("LocalExecutionEnv native conformance", arguments: localEnvConformanceCases(.native))
    func native(_ testCase: EnvConformanceCase) async throws { try await testCase.run() }
    #endif

    // upstream env-node-conformance.test.ts:48; each callback has a fresh cwd.
    @Test("LocalExecutionEnv polling conformance", arguments: localEnvConformanceCases(.polling))
    func polling(_ testCase: EnvConformanceCase) async throws { try await testCase.run() }

    // upstream env-node-conformance.test.ts:63.
    @Test("refuses a tree over the directory budget and stops with an error when one grows past it",
          arguments: [WatchMode.native, .polling])
    func directoryBudget(_ mode: WatchMode) async throws {
        let directory = try localConformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path, watch: .init(mode: mode, pollIntervalMs: 100, maxDirectories: 3))
        try await env.createDir("tree/a/b", options: nil, context: .background).get()
        try await env.createDir("tree/c", options: nil, context: .background).get()
        let rejected = await env.watch([.init(path: "tree", recursive: true)], onChange: { _ in }, context: .background)
        if case .failure(let error) = rejected { #expect(error.code == .invalid) }
        else { Issue.record("Watch accepted a tree above its directory budget") }
        try await env.remove("tree/c", options: .init(recursive: true), context: .background).get()
        let log = LocalConformanceWatchLog()
        let watcher = try await env.watch([.init(path: "tree", recursive: true)], onChange: { log.append($0) }, context: .background).get()
        do {
            try await env.createDir("tree/d", options: nil, context: .background).get()
            try await log.wait { $0.contains { if case .error = $0 { true } else { false } } }
            if case .error(let error) = log.changes.last { #expect(error.code == .invalid) }
            else { Issue.record("Growing past the directory budget did not end with an error") }
            await watcher.close(context: .background)
        } catch { await watcher.close(context: .background); throw error }
    }

    // upstream env-node-conformance.test.ts:103.
    @Test("reads ranges spanning several internal chunks exactly")
    func multiChunkRanges() async throws {
        let directory = try localConformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let byteCount: Int = 2_621_440
        var bytes: [UInt8] = Array(repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8((index * 31) % 251) }
        try Data(bytes).write(to: directory.appendingPathComponent("big.bin"))
        let env = LocalExecutionEnv(cwd: directory.path)
        let reader = try await env.openBinaryReader("big.bin", options: nil, context: .background).get()
        do {
            let all = try await reader.read(offset: 0, length: bytes.count + 10, context: .background).get()
            #expect(all.count == bytes.count)
            #expect(all == bytes)
            let rangeStart: Int = 1_048_573
            let rangeEnd: Int = 1_048_580
            let expectedMiddle: [UInt8] = Array(bytes[rangeStart..<rangeEnd])
            let middle = try await reader.read(offset: Int64(rangeStart), length: 7, context: .background).get()
            #expect(middle == expectedMiddle)
            await reader.close(context: .background)
        } catch { await reader.close(context: .background); throw error }
    }

    // upstream env-node-conformance.test.ts:120; POSIX mkfifo replaces a shell command.
    @Test("refuses a FIFO without waiting for a writer")
    func fifoDoesNotWaitForWriter() async throws {
        let directory = try localConformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pipe").path
        #expect(mkfifo(path, 0o600) == 0)
        let result = await LocalExecutionEnv(cwd: directory.path).openBinaryReader("pipe", options: nil, context: .background)
        if case .failure(let error) = result { #expect(error.code == .invalid) }
        else { Issue.record("Binary reader accepted a FIFO") }
    }

    #if os(macOS)
    @Test("native watch failure emits overflow and continues with polling")
    func nativeFailureFallsBackToPolling() async throws {
        let directory = try localConformanceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("file.txt").path
        let log = LocalConformanceWatchLog()
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: path)], mode: .native,
            pollIntervalMilliseconds: 100, forceNativeFailure: true, onChange: { log.append($0) }, context: .background).get()
        do {
            #expect(watcher.mode == .polling)
            #expect(log.changes.contains { if case .overflow = $0 { true } else { false } })
            try await LocalExecutionEnv(cwd: directory.path).writeFile("file.txt", content: .text("x"), context: .background).get()
            try await log.wait { changes in
                changes.contains { if case .paths(let paths) = $0 { paths.contains(path) } else { false } }
            }
            await watcher.close(context: .background)
        } catch { await watcher.close(context: .background); throw error }
    }
    #endif

    @Test("capabilities select 24 complete cases and 18 file-side cases")
    func capabilitySelection() {
        let provider: @Sendable (@Sendable (any ExecutionEnv) async throws -> Void) async throws -> Void = { _ in }
        #expect(envConformanceCases(withEnv: provider).count == 24)
        #expect(envConformanceCases(capabilities: .init(exec: false), withEnv: provider).count == 18)
        #expect(envConformanceCases(capabilities: .init(exec: false, symlinks: false, watch: false), withEnv: provider).count == 8)
    }
}
