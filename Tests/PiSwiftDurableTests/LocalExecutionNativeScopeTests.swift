#if os(macOS)
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class NativeScopeLog: Sendable {
    private struct State: Sendable {
        var roots: [[String]] = []
        var batches = 0
        var paths: [String] = []
    }
    private let state = Mutex(State())
    var roots: [[String]] { state.withLock { $0.roots } }
    var batches: Int { state.withLock { $0.batches } }
    var paths: [String] { state.withLock { $0.paths } }
    var hooks: LocalNativeWatchHooks {
        .init(streamStarted: { paths in self.state.withLock { $0.roots.append(paths) } },
              batchDelivered: { self.state.withLock { $0.batches += 1 } })
    }
    func append(_ change: WatchChange) {
        if case .paths(let paths) = change { state.withLock { $0.paths += paths } }
    }
    func wait(_ predicate: @Sendable () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            if clock.now > deadline { throw NativeScopeDeadline() }
            try await clock.sleep(for: .milliseconds(20))
        }
    }
}

private struct NativeScopeDeadline: Error {}

struct LocalExecutionNativeScopeTests {
    private func withDirectory(_ body: (LocalExecutionEnv) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-e1-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(LocalExecutionEnv(cwd: directory.path))
    }
    private func watch(_ targets: [WatchTarget], log: NativeScopeLog) async throws -> any FileWatcher {
        let watcher = try await LocalFileWatcher.start(targets: targets, mode: .native, nativeHooks: log.hooks,
                                                        onChange: { log.append($0) }, context: .background).get()
        #expect(watcher.mode == .native)
        return watcher
    }
    private func flush(_ watcher: any FileWatcher) async throws {
        let native = try #require(watcher as? LocalFileWatcher)
        await native.flushNativeEventsForTesting()
    }

    @Test("native coverage moves down as a missing target and its parent appear")
    func missingTargetMovesCoverageDown() async throws {
        try await withDirectory { env in
            let root = try await env.canonicalPath(".", context: .background).get()
            let target = env.cwd + "/later/deep/file.txt"
            let log = NativeScopeLog()
            let watcher = try await watch([.init(path: target)], log: log)
            do {
                #expect(log.roots == [[root]])
                try await env.createDir("later/deep", options: nil, context: .background).get()
                try await log.wait { log.roots.last == [root + "/later/deep"] && log.paths.contains(target) }
                try await env.writeFile("later/deep/file.txt", content: .text("one"), context: .background).get()
                try await log.wait { log.roots.last == [root + "/later/deep/file.txt"] }
                let before = log.paths.count
                try await env.writeFile("later/deep/file.txt", content: .text("two"), context: .background).get()
                try await log.wait { log.paths.dropFirst(before).contains(target) }
                #expect(watcher.mode == .native)
                await watcher.close(context: .background)
            } catch { await watcher.close(context: .background); throw error }
        }
    }

    @Test("native coverage rebuilds when a watched directory is replaced")
    func replacedDirectoryRebuildsStream() async throws {
        try await withDirectory { env in
            try await env.createDir("project", options: nil, context: .background).get()
            let physical = try await env.canonicalPath("project", context: .background).get()
            let target = env.cwd + "/project"
            let log = NativeScopeLog()
            let watcher = try await watch([.init(path: target, recursive: true)], log: log)
            do {
                #expect(log.roots == [[physical]])
                try await env.renameFile("project", destinationPath: "old", context: .background).get()
                try await env.createDir("project", options: nil, context: .background).get()
                try await log.wait { log.roots.count >= 2 && log.roots.last == [physical] }
                let marker = target + "/new.txt"
                try await env.writeFile("project/new.txt", content: .text("new"), context: .background).get()
                try await log.wait { log.paths.contains(marker) }
                #expect(watcher.mode == .native)
                await watcher.close(context: .background)
            } catch { await watcher.close(context: .background); throw error }
        }
    }

    @Test("file changes outside all native stream paths queue no actor batches")
    func unrelatedChangesDoNotDeliverNativeBatches() async throws {
        try await withDirectory { env in
            try await env.createDir("project", options: nil, context: .background).get()
            try await env.createDir("unrelated", options: nil, context: .background).get()
            let project = env.cwd + "/project", outside = env.cwd + "/unrelated"
            let log = NativeScopeLog(), other = NativeScopeLog()
            let watcher = try await watch([.init(path: project, recursive: true)], log: log)
            let observer = try await watch([.init(path: outside, recursive: true)], log: other)
            do {
                try await env.writeFile("project/probe", content: .text("ready"), context: .background).get()
                try await log.wait { log.paths.contains(project + "/probe") }
                try await flush(watcher)
                let before = log.batches
                for index in 0..<64 {
                    try await env.writeFile("unrelated/file-\(index)", content: .text("outside"), context: .background).get()
                }
                // A live observer proves the native event service delivered the outside writes.
                try await other.wait { other.paths.contains(outside + "/file-63") }
                try await flush(watcher)
                #expect(log.batches == before)
                #expect(!log.paths.contains { $0.hasPrefix(outside + "/") })
                await watcher.close(context: .background)
                await observer.close(context: .background)
            } catch {
                await watcher.close(context: .background)
                await observer.close(context: .background)
                throw error
            }
        }
    }

    @Test("recursive native stream roots cover overlapping target paths once")
    func recursiveRootsAreDeduplicated() async throws {
        try await withDirectory { env in
            try await env.writeFile("project/sub/file.txt", content: .text("one"), context: .background).get()
            let project = try await env.canonicalPath("project", context: .background).get()
            let log = NativeScopeLog()
            let watcher = try await watch([.init(path: env.cwd + "/project", recursive: true),
                                           .init(path: env.cwd + "/project/sub", recursive: true),
                                           .init(path: env.cwd + "/project/sub/file.txt")], log: log)
            #expect(log.roots == [[project]])
            await watcher.close(context: .background)
        }
    }
}
#endif
