import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
@testable import PiSwiftDurableTesting
#if os(macOS)
import CoreServices
#endif

private final class D9WatchLog: Sendable {
    private struct State: Sendable {
        var changes: [FileChange] = []
        var listener: AsyncStream<Void>.Continuation?
    }
    private let state = Mutex(State())
    var changes: [FileChange] { state.withLock { $0.changes } }
    func append(_ change: FileChange) {
        state.withLock { value in
            value.changes.append(change)
            value.listener?.yield(())
        }
    }
    func wait(_ predicate: @Sendable ([FileChange]) -> Bool) async throws {
        // E-FLAKE: Wait for a retained callback. The test time limit detects a lost callback.
        let updates = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { listener in
            state.withLock { value in
                value.listener = listener
                if predicate(value.changes) { listener.yield(()) }
            }
        }
        defer { state.withLock { value in value.listener?.finish(); value.listener = nil } }
        for await _ in updates {
            if predicate(changes) { return }
        }
        throw CancellationError()
    }
}

struct FileWatcherD9Tests {
    // v1.5.2 D9: durable/src/env/index.ts:127–130.
    @Test func fileChangeTagsMatchTheTaggedUnion() {
        #expect(FileChange.paths(["/tmp/file"]).kind == "paths")
        #expect(FileChange.overflow.kind == "overflow")
        let failed = FileChange.failed(FileError(.invalid, message: "Watch limit"))
        #expect(failed.kind == "failed")
        guard case .failed(let error) = failed else { Issue.record("Missing failure"); return }
        #expect(error.code == .invalid)
        #expect(error.message == "Watch limit")
    }

    // v1.5.2 D9: durable/src/testing/env-conformance.ts:65–73.
    @Test func overflowCoversEveryWatchedPath() {
        #expect(EnvWatchLog.covers(.overflow, "/tree/file.txt"))
        #expect(EnvWatchLog.covers(.overflow, "/other/tree/file.txt"))
        #expect(EnvWatchLog.covers(.paths(["/tree"]), "/tree/file.txt"))
        #expect(!EnvWatchLog.covers(.paths(["/tree"]), "/other/tree/file.txt"))
        #expect(!EnvWatchLog.covers(.failed(FileError(.invalid, message: "Watch limit")), "/tree/file.txt"))
    }

    // v1.5.2 D9: durable/test/env-node-conformance.test.ts:63–88 and env/index.ts:124–140.
    @Test(.timeLimit(.minutes(1)), arguments: [WatchMode.native, .polling])
    func failedIsFinalAndStopIsIdempotent(_ mode: WatchMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-d9-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path, watch: .init(mode: mode, pollIntervalMs: 20, maxDirectories: 1))
        try await env.createDir("tree", options: nil, context: .background).get()
        let log = D9WatchLog()
        let watcher = try await env.watch([.init(path: "tree", recursive: true)],
            onChange: { log.append($0) }, context: .background).get()
        do {
            try await env.createDir("tree/child", options: nil, context: .background).get()
            try await log.wait { $0.contains { $0.kind == "failed" } }
            let count = log.changes.count
            guard case .failed(let error) = log.changes.last else {
                Issue.record("Failure was not final"); await watcher.stop(context: .background); return
            }
            #expect(error.code == .invalid)
            // A live observer proves that a later write was seen without a fixed sleep.
            let live = LocalExecutionEnv(cwd: directory.path, watch: .init(mode: .polling, pollIntervalMs: 20))
            let observed = D9WatchLog()
            let observer = try await live.watch([.init(path: "tree/later.txt")],
                onChange: { observed.append($0) }, context: .background).get()
            do {
                try await env.writeFile("tree/later.txt", content: .text("later"), context: .background).get()
                try await observed.wait { $0.contains { $0.kind == "paths" } }
                await observer.stop(context: .background)
            } catch { await observer.stop(context: .background); throw error }
            #if os(macOS)
            let native = try #require(watcher as? LocalFileWatcher)
            await native.nativeEventsForTesting([], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
            #endif
            await watcher.stop(context: .background)
            await watcher.stop(context: .background)
            #expect(log.changes.count == count)
        } catch { await watcher.stop(context: .background); throw error }
    }

    #if os(macOS)
    // E-FLAKE round 1: unrelated native events must not keep moving the
    // 50 ms flush. The churn continues for ten seconds after the first event.
    @Test(.timeLimit(.minutes(1))) func unrelatedNativeChurnCannotStarveWatchedChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-d9-churn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let noise = directory.appendingPathComponent("noise.txt")
        let watched = directory.appendingPathComponent("watched.txt")
        let log = D9WatchLog()
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: directory.path, recursive: true)],
            mode: .native, onChange: { log.append($0) }, context: .background).get()
        let churn = Task {
            let until = ContinuousClock.now + .seconds(10)
            var number = 0
            while ContinuousClock.now < until && !Task.isCancelled {
                try Data(repeating: UInt8(number % 251), count: 16 + number % 2).write(to: noise)
                number += 1
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        do {
            try await log.wait { changes in
                changes.contains { if case .paths(let paths) = $0 { paths.contains(noise.path) } else { false } }
            }
            let written = ContinuousClock.now
            try Data("watched".utf8).write(to: watched)
            try await log.wait { changes in
                changes.contains { if case .paths(let paths) = $0 { paths.contains(watched.path) } else { false } }
            }
            let latency = written.duration(to: .now)
            #expect(latency < .seconds(8))
            try await churn.value
            await watcher.stop(context: .background)
        } catch {
            churn.cancel()
            _ = try? await churn.value
            await watcher.stop(context: .background)
            throw error
        }
    }

    // v1.5.2 D9: durable/src/env/index.ts:120–130; overflow requires a full rescan.
    @Test(.timeLimit(.minutes(1))) func nativeLossFlagsEmitOverflowAndScanWithoutPaths() async throws {
        let lost = [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
            kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount]
        for flag in lost {
            #expect(LocalFileWatcher.nativeRequiresRescan(FSEventStreamEventFlags(flag)))
        }
        #expect(!LocalFileWatcher.nativeRequiresRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
        #expect(!LocalFileWatcher.nativeRequiresRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)))
        #expect(!LocalFileWatcher.nativeRequiresRescan(FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-d9-overflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("file.txt").path
        let log = D9WatchLog()
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: path)], mode: .native,
            onChange: { log.append($0) }, context: .background).get()
        do {
            let native = try #require(watcher as? LocalFileWatcher)
            // Each synthetic batch has no paths. The overflow still reaches the consumer.
            for flag in lost {
                await native.nativeEventsForTesting([], flags: FSEventStreamEventFlags(flag))
            }
            #expect(log.changes.filter { $0.kind == "overflow" }.count == lost.count)
            try Data("new".utf8).write(to: URL(fileURLWithPath: path))
            await native.nativeEventsForTesting([], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
            try await log.wait { changes in
                changes.contains { if case .paths(let paths) = $0 { paths.contains(path) } else { false } }
            }
            await watcher.stop(context: .background)
            let count = log.changes.count
            await native.nativeEventsForTesting([path], flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
            #expect(log.changes.count == count)
        } catch { await watcher.stop(context: .background); throw error }
    }
    #endif
}
