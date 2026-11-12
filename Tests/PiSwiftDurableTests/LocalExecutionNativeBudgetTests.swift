#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private final class NativeBudgetLog: Sendable {
    private let state = Mutex<[String]>([])
    var paths: [String] { state.withLock { $0 } }
    func append(_ change: WatchChange) {
        if case .paths(let paths) = change { state.withLock { $0 += paths } }
    }
    func wait(for path: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !paths.contains(path) {
            if ContinuousClock.now > deadline { throw NativeBudgetDeadline() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct NativeBudgetDeadline: Error {}

@Suite(.timeLimit(.minutes(4))) struct LocalExecutionNativeBudgetTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-native-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openFDs() -> [Int32] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap(Int32.init)
    }

    private func ownedFDs(under root: String) -> Int {
        let name = (root as NSString).lastPathComponent
        return openFDs().reduce(into: 0) { count, fd in
            var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = bytes.withUnsafeMutableBufferPointer { buffer in
                fcntl(fd, F_GETPATH, buffer.baseAddress!)
            }
            if result == 0 {
                let path = String(cString: bytes)
                if path.contains("/" + name) { count += 1 }
            }
        }
    }

    private func cpuNanos() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    @Test("native descriptor budget bounds a 5,000-directory, 20,000-file tree")
    func largeTreeUsesBoundedDescriptors() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = Data("x".utf8)
        try await Task.detached(priority: .background) {
            for index in 0..<5_000 {
                let child = root.appendingPathComponent(String(format: "dir-%04d", index))
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
                for item in 0..<4 { try file.write(to: child.appendingPathComponent("file-\(item)")) }
                if index % 16 == 0 { try await Task.sleep(for: .milliseconds(2)) }
            }
        }.value
        let log = NativeBudgetLog()
        let baseline = openFDs().count
        let physical = root.resolvingSymlinksInPath().path
        let ownedBefore = ownedFDs(under: physical)
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: root.path, recursive: true)],
            mode: .native, maxDirectories: 6_000, onChange: { log.append($0) }, context: .background).get()
        do {
            let native = try #require(watcher as? LocalFileWatcher)
            let counts = await native.nativeWatchCountsForTesting()
            let owned = ownedFDs(under: physical)
            let after = openFDs().count
            #expect(watcher.mode == .native)
            #expect(counts.sources <= 64)
            #expect(counts.sources <= counts.processLimit)
            #expect(owned <= counts.processLimit)
            #expect(owned - ownedBefore <= counts.processLimit)
            print("E-WATCH descriptors totalBefore=\(baseline) totalAfter=\(after) owned=\(owned) cap=\(counts.processLimit)")
            let marker = root.appendingPathComponent("dir-0000/new.txt")
            let start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = cpuNanos()
            try file.write(to: marker)
            try await log.wait(for: marker.path)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let cpu = Double(cpuNanos() - cpuStart) / 1_000_000
            print("E-WATCH 20000-file write reportMs=\(elapsed) processCpuMs=\(cpu)")
            await watcher.close(context: .background)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ownedFDs(under: physical) > 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let ownedAfterClose = ownedFDs(under: physical)
            let totalAfterClose = openFDs().count
            print("E-WATCH descriptors totalAfterClose=\(totalAfterClose) ownedBefore=\(ownedBefore) ownedAfterClose=\(ownedAfterClose)")
            #expect(ownedAfterClose == ownedBefore)
        } catch { await watcher.close(context: .background); throw error }
    }

    @Test("zero vnode allowance keeps native FSEvents working")
    func zeroAllowanceUsesFSEvents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = NativeBudgetLog()
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: root.path, recursive: true)],
            mode: .native, nativeHooks: .init(vnodeLimit: 0),
            onChange: { log.append($0) }, context: .background).get()
        do {
            let native = try #require(watcher as? LocalFileWatcher)
            #expect(await native.nativeWatchCountsForTesting().sources == 0)
            let marker = root.appendingPathComponent("new.txt")
            try Data("new".utf8).write(to: marker)
            try await log.wait(for: marker.path)
            #expect(watcher.mode == .native)
            await watcher.close(context: .background)
        } catch { await watcher.close(context: .background); throw error }
    }

    @Test("ten thousand file writes share a pending native scan")
    func writeBurstCoalesces() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("a".utf8).write(to: file)
        let log = NativeBudgetLog()
        let watcher = try await LocalFileWatcher.start(targets: [.init(path: file.path)],
            mode: .native, onChange: { log.append($0) }, context: .background).get()
        do {
            let native = try #require(watcher as? LocalFileWatcher)
            try await Task.sleep(for: .milliseconds(650))
            let idleStart = await native.nativeWatchCountsForTesting()
            try await Task.sleep(for: .milliseconds(250))
            let idleEnd = await native.nativeWatchCountsForTesting()
            print("E-WATCH pre-burst delayedScans=\(idleEnd.scans - idleStart.scans)")
            let fd = open(file.path, O_WRONLY)
            try #require(fd >= 0)
            for index in 0..<10_000 {
                var byte = UInt8(index % 251)
                _ = withUnsafePointer(to: &byte) { pwrite(fd, $0, 1, 0) }
            }
            _ = Darwin.close(fd)
            try await log.wait(for: file.path)
            try await Task.sleep(for: .milliseconds(250))
            let after = await native.nativeWatchCountsForTesting()
            let scans = after.scans - idleEnd.scans
            let tasks = after.queuedTasks - idleEnd.queuedTasks
            print("E-WATCH burst writes=10000 scans=\(scans) vnodeTasks=\(tasks)")
            #expect(tasks <= 2)
            #expect(scans <= 3)
            await watcher.close(context: .background)
        } catch { await watcher.close(context: .background); throw error }
    }
}
#endif
