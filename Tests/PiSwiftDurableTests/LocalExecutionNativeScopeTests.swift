#if os(macOS)
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class NativeScopeLog: Sendable {
    private struct State: Sendable {
        var roots: [[String]] = []
        var callbacks: [[String]] = []
        var paths: [String] = []
    }
    private let state = Mutex(State())
    var roots: [[String]] { state.withLock { $0.roots } }
    var callbacks: [[String]] { state.withLock { $0.callbacks } }
    var paths: [String] { state.withLock { $0.paths } }
    var hooks: LocalNativeWatchHooks {
        .init(streamStarted: { paths in self.state.withLock { $0.roots.append(paths) } },
              batchDelivered: { paths in self.state.withLock { $0.callbacks.append(paths) } })
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

    @Test("a write during native coverage renewal is found by the next scan")
    func renewalScansHandoffWrite() async throws {
        try await withDirectory { env in
            let target = env.cwd + "/later"
            let physicalTarget = try await env.canonicalPath(".", context: .background).get() + "/later"
            let marker = target + "/marker.txt"
            let log = NativeScopeLog()
            let wrote = Mutex(false)
            let hooks = LocalNativeWatchHooks(streamStarted: { paths in
                guard paths == [physicalTarget] else { return }
                wrote.withLock { value in
                    guard !value else { return }
                    value = true
                    try? Data("new".utf8).write(to: URL(fileURLWithPath: marker))
                }
            })
            let watcher = try await LocalFileWatcher.start(targets: [.init(path: target, recursive: true)],
                mode: .native, nativeHooks: hooks, onChange: { log.append($0) }, context: .background).get()
            do {
                try await env.createDir("later", options: nil, context: .background).get()
                try await log.wait { wrote.withLock { $0 } && log.paths.contains(marker) }
                #expect(watcher.mode == .native)
                await watcher.close(context: .background)
            } catch { await watcher.close(context: .background); throw error }
        }
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
                try await log.wait { log.paths.contains(target) }
                // FSEvents accepts directory roots; the file remains covered
                // by its parent after it appears.
                #expect(log.roots.last == [root + "/later/deep"])
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

    @Test("file changes outside native stream paths stay outside callbacks")
    func unrelatedChangesDoNotDeliverNativeBatches() async throws {
        try await withDirectory { env in
            try await env.createDir("project", options: nil, context: .background).get()
            try await env.createDir("unrelated", options: nil, context: .background).get()
            let project = env.cwd + "/project", outside = env.cwd + "/unrelated"
            let log = NativeScopeLog(), other = NativeScopeLog()
            let watcher = try await watch([.init(path: project, recursive: true)], log: log)
            let observer = try await watch([.init(path: outside, recursive: true)], log: other)
            do {
                let before = log.callbacks.count
                for index in 0..<64 {
                    try await env.writeFile("unrelated/file-\(index)", content: .text("outside"), context: .background).get()
                }
                // A live observer proves the native event service delivered the outside writes.
                try await other.wait { other.paths.contains(outside + "/file-63") }
                try await flush(watcher)
                #expect(!log.callbacks.dropFirst(before).joined().contains { $0.hasPrefix(outside + "/") })
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
