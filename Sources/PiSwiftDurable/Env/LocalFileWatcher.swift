import Foundation
import Dispatch
import Synchronization
import PiSwiftChord
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if os(macOS)
import CoreServices
#endif

/// Internal hooks record native coverage and batches before an actor delivery is queued.
struct LocalNativeWatchHooks: Sendable {
    var streamStarted: @Sendable ([String]) -> Void = { _ in }
    var batchDelivered: @Sendable ([String]) -> Void = { _ in }
    var vnodeLimit: Int? = nil
}

/// A snapshot watch. Native notifications request a scan; they do not replace it.
actor LocalFileWatcher: FileWatcher {
    private struct Target: Sendable {
        let path: String
        let recursive: Bool
        let hidden: Bool
        let names: Set<String>
        func excludes(_ name: String) -> Bool { (hidden && name.hasPrefix(".")) || names.contains(name) }
    }
    private struct Entry: Equatable, Sendable {
        let kind: UInt32
        let device: UInt64
        let inode: UInt64
        var size: Int64
        var modified: Int64
        var hash: String?
        var directory: Bool { kind == UInt32(S_IFDIR) }
        var file: Bool { kind == UInt32(S_IFREG) }
    }
    private let targets: [Target]
    private let onChange: @Sendable (FileChange) -> Void
    private let maxDirectories: Int
    private let pollIntervalMilliseconds: Int
    private nonisolated let currentMode: Mutex<WatchMode>
    nonisolated var mode: WatchMode { currentMode.withLock { $0 } }
    private var snapshot: [String: Entry] = [:]
    private var closed = false
    private var timer: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    private var events: Set<String> = []
    private var physicalTargets: [String: String] = [:]
    #if os(macOS)
    private struct NativeRoot: Equatable, Sendable {
        let path: String
        let recursive: Bool
        let kind: UInt32
        let device: UInt64
        let inode: UInt64
    }
    private var stream: NativeWatchStream?
    private var streamRoots: [NativeRoot] = []
    private var nativeRootChanged = false
    private var vnodeWatches: [String: NativeVnodeWatch] = [:]
    private var vnodeMailbox: NativeVnodeMailbox?
    private var recentFiles: [String] = []
    private var nativeScanCount = 0
    #endif
    private let nativeHooks: LocalNativeWatchHooks

    private init(targets: [WatchTarget], mode: WatchMode, maxDirectories: Int,
                 pollIntervalMilliseconds: Int, nativeHooks: LocalNativeWatchHooks,
                 onChange: @escaping @Sendable (FileChange) -> Void) {
        self.targets = targets.map { Target(path: $0.path, recursive: $0.recursive == true,
            hidden: $0.exclude?.hidden == true, names: Set($0.exclude?.names ?? [])) }
        self.currentMode = Mutex(mode)
        self.maxDirectories = maxDirectories
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
        self.onChange = onChange
        self.nativeHooks = nativeHooks
    }

    deinit {
        timer?.cancel()
        settleTimer?.cancel()
        #if os(macOS)
        stream?.close()
        for watch in vnodeWatches.values { watch.close() }
        vnodeMailbox?.close()
        #endif
    }

    static func start(targets: [WatchTarget], mode: WatchMode?, maxDirectories: Int = 10_000,
                      pollIntervalMilliseconds: Int = 2000, forceNativeFailure: Bool = false,
                      nativeHooks: LocalNativeWatchHooks = .init(),
                      onChange: @escaping @Sendable (FileChange) -> Void,
                      context: ChordContext) async -> Result<any FileWatcher, FileError> {
        if context.abortSignal?.aborted == true {
            return .failure(FileError(.aborted, message: "File operation aborted"))
        }
        guard !targets.contains(where: { $0.path.utf8.contains(0) }) else {
            return .failure(FileError(.invalid, message: "Watch path contains a null byte"))
        }
        #if os(macOS)
        let selectedMode = mode ?? .native
        #else
        // iOS has no public FSEvents API. Native requests use polling.
        let selectedMode = WatchMode.polling
        #endif
        let watcher = LocalFileWatcher(targets: targets, mode: selectedMode,
            maxDirectories: maxDirectories, pollIntervalMilliseconds: max(1, pollIntervalMilliseconds), nativeHooks: nativeHooks, onChange: onChange)
        do {
            try await watcher.establish(forceNativeFailure: forceNativeFailure, context: context)
            if context.abortSignal?.aborted == true {
                await watcher.stopWatching()
                return .failure(FileError(.aborted, message: "File operation aborted"))
            }
            return .success(watcher)
        } catch let error as FileError {
            await watcher.stopWatching()
            return .failure(error)
        } catch {
            await watcher.stopWatching()
            return .failure(FileError(.invalid, message: String(describing: error)))
        }
    }

    func stop(context: ChordContext) async { stopWatching() }

    private func establish(forceNativeFailure: Bool, context: ChordContext) throws {
        defer { if context.abortSignal?.aborted == true { stopWatching() } }
        try LocalFS.check(context)
        snapshot = try scan()
        try LocalFS.check(context)
        #if os(macOS)
        if mode == .native {
            if forceNativeFailure {
                switchToPolling()
                snapshot = try scan()
            } else {
                // Rescan after new coverage starts; reconcile again if a path changed during setup.
                for _ in 0..<10 {
                    guard reconcileNativeStream() else { break }
                    snapshot = try scan()
                    try LocalFS.check(context)
                }
                if mode == .polling { snapshot = try scan() }
                else {
                    reconcileVnodeWatches()
                    snapshot = try scan()
                    reconcileVnodeWatches()
                }
            }
        }
        #endif
        try LocalFS.check(context)
        schedulePoll()
    }

    private func stopWatching() {
        guard !closed else { return }
        closed = true
        timer?.cancel(); timer = nil
        settleTimer?.cancel(); settleTimer = nil
        #if os(macOS)
        stopNativeStream()
        stopVnodeWatches()
        #endif
    }

    private func switchToPolling() {
        guard mode != .polling else { return }
        currentMode.withLock { $0 = .polling }
        #if os(macOS)
        stopNativeStream()
        stopVnodeWatches()
        #endif
        timer?.cancel(); timer = nil
        if !closed { onChange(.overflow) }
        schedulePoll()
    }

    private func schedulePoll() {
        guard !closed, mode == .polling, timer == nil else { return }
        let interval = pollIntervalMilliseconds
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
            await self?.timerFired()
        }
    }

    private func scheduleFlush() {
        guard !closed, timer == nil else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            await self?.timerFired()
        }
    }

    private func scheduleSettle() {
        settleTimer?.cancel()
        settleTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.settleFired()
        }
    }

    private func timerFired() { timer = nil; flush(); schedulePoll() }
    private func settleFired() { settleTimer = nil; flush() }

    private func flush() {
        guard !closed else { return }
        #if os(macOS)
        vnodeMailbox?.beginScan()
        #endif
        do {
            var changed = events
            events.removeAll()
            for _ in 0..<10 {
                let next = try scan()
                #if os(macOS)
                if mode == .native {
                    let newFiles = next.keys.filter { path in
                        guard let entry = next[path], entry.file else { return false }
                        return snapshot[path] == nil || snapshot[path]?.inode != entry.inode
                    }.sorted()
                    for path in newFiles {
                        noteRecentFile(path)
                    }
                }
                #endif
                for (path, entry) in next where snapshot[path] != entry { changed.insert(reported(path)) }
                for path in snapshot.keys where next[path] == nil { changed.insert(reported(path)) }
                snapshot = next
                #if os(macOS)
                if mode == .native { reconcileVnodeWatches() }
                // The new stream starts before the old one stops. This scan after
                // a rebuild also captures writes made during the start gap.
                if mode == .native, reconcileNativeStream() { continue }
                #endif
                break
            }
            if !changed.isEmpty { onChange(.paths(changed.sorted())) }
            #if os(macOS)
            if mode == .native, vnodeMailbox?.finishScan() == true { scheduleFlush() }
            #endif
        } catch let error as FileError {
            onChange(.failed(error)); stopWatching()
        } catch {
            onChange(.failed(FileError(.invalid, message: String(describing: error)))); stopWatching()
        }
    }

    private func scan() throws -> [String: Entry] {
        #if os(macOS)
        nativeScanCount += 1
        #endif
        var result: [String: Entry] = [:]
        var counted: Set<String> = []
        var listed: [String: UInt32] = [:]
        func count(_ path: String) throws {
            counted.insert(path)
            if counted.count > maxDirectories {
                throw FileError(.invalid, message: "Watched paths exceed \(maxDirectories) directories")
            }
        }
        func record(_ path: String, _ entry: Entry) -> Entry {
            var value = entry
            if mode == .polling, value.file, value.size <= 256 * 1024,
               Int64(Date().timeIntervalSince1970 * 1000) - value.modified / 1_000_000 < 5000,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                value.hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return value
        }
        func directory(_ path: String, target: Target) throws {
            guard let handle = opendir(path) else {
                let code = errno
                if path == target.path, code == EACCES || code == EPERM {
                    throw FileError(.permissionDenied, message: "Cannot read watched directory", path: path)
                }
                if [ENOENT, EACCES, EPERM, ENOTDIR].contains(code) { return }
                throw FileError(.invalid, message: "Cannot read watched directory: \(code)", path: path)
            }
            defer { closedir(handle) }
            while true {
                errno = 0
                guard let item = readdir(handle) else {
                    if errno != 0 {
                        throw FileError(errno == EACCES || errno == EPERM ? .permissionDenied : .invalid,
                                        message: "Cannot read watched directory: \(errno)", path: path)
                    }
                    break
                }
                let name = withUnsafePointer(to: item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) { String(cString: $0) }
                }
                if name == "." || name == ".." || target.excludes(name) { continue }
                let child = Self.join(path, name)
                let kind: UInt32
                if let known = listed[child] { kind = known }
                else {
                    guard let entry = try? Self.entry(child, follow: false) else { continue }
                    kind = entry.kind; listed[child] = kind
                    if result[child] == nil { result[child] = record(child, entry) }
                }
                if target.recursive, kind == UInt32(S_IFDIR) {
                    try count(child)
                    try directory(child, target: target)
                }
            }
        }
        for target in targets {
            physicalTargets[target.path] = Self.physicalPath(target.path)
            for ancestor in Self.ancestors(target.path) where result[ancestor] == nil {
                if var entry = try? Self.entry(ancestor, follow: false) {
                    entry.size = 0; entry.modified = 0
                    result[ancestor] = entry
                }
            }
            let entry: Entry
            do { entry = try Self.entry(target.path, follow: true) }
            catch let error as FileError {
                if error.code == .permissionDenied { throw error }
                continue
            }
            result[target.path] = record(target.path, entry)
            if entry.directory { try count(target.path); try directory(target.path, target: target) }
        }
        return result
    }

    private static func entry(_ path: String, follow: Bool) throws -> Entry {
        var info = stat()
        let status = path.withCString { pointer in
            follow ? stat(pointer, &info) : lstat(pointer, &info)
        }
        guard status == 0 else {
            let code = errno
            throw FileError(code == EACCES || code == EPERM ? .permissionDenied : .notFound,
                            message: "Cannot inspect watched path: \(code)", path: path)
        }
        let kind = UInt32(info.st_mode) & UInt32(S_IFMT)
        #if canImport(Darwin)
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        #else
        let modified = Int64(info.st_mtim.tv_sec) * 1_000_000_000 + Int64(info.st_mtim.tv_nsec)
        #endif
        return Entry(kind: kind, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            size: kind == UInt32(S_IFDIR) ? 0 : Int64(info.st_size), modified: kind == UInt32(S_IFDIR) ? 0 : modified)
    }

    /// FSEvents uses canonical paths even for a target that does not yet exist.
    /// Resolve its nearest existing ancestor, then retain the missing suffix.
    private static func physicalPath(_ path: String) -> String {
        var candidate = path
        var suffix: [String] = []
        while true {
            if let resolved = realPath(candidate) {
                return suffix.reduce(resolved) { join($0, $1) }
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return path }
            suffix.insert((candidate as NSString).lastPathComponent, at: 0)
            candidate = parent
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }
    private static func ancestors(_ path: String) -> [String] {
        var output: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while true {
            if current.isEmpty { current = "/" }
            output.append(current)
            if current == "/" { return output }
            current = (current as NSString).deletingLastPathComponent
        }
    }
    private static func within(_ path: String, _ parent: String) -> Bool {
        path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
    private func reported(_ path: String) -> String {
        if targets.contains(where: { Self.within(path, $0.path) }) { return path }
        return targets.first(where: { Self.within($0.path, path) })?.path ?? path
    }
    private func inScope(_ path: String) -> Bool {
        for target in targets {
            if Self.within(target.path, path) { return true }
            guard Self.within(path, target.path), path != target.path else { continue }
            let relative = path.dropFirst(target.path == "/" ? 1 : target.path.count + 1)
            let components = relative.split(separator: "/").map(String.init)
            if !target.recursive && components.count > 1 { continue }
            if components.contains(where: target.excludes) { continue }
            return true
        }
        return false
    }

    #if os(macOS)
    private func vnodeEvent() {
        guard !closed, mode == .native else { return }
        scheduleFlush()
    }

    private func noteRecentFile(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 64 { recentFiles.removeLast() }
    }

    private func reconcileVnodeWatches() {
        if vnodeMailbox == nil {
            vnodeMailbox = NativeVnodeMailbox { [weak self] in
                Task { await self?.vnodeEvent() }
            }
        }
        guard let vnodeMailbox else { return }
        var ordered: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            if seen.insert(path).inserted { ordered.append(path) }
        }
        for root in streamRoots { add(root.path) }
        for target in targets where snapshot[target.path]?.file == true { add(target.path) }
        for path in recentFiles where snapshot[path]?.file == true { add(path) }
        let directories = snapshot.keys.filter { path in
            snapshot[path]?.directory == true && targets.contains { Self.within(path, $0.path) }
        }.sorted { left, right in
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            return leftDepth == rightDepth ? left < right : leftDepth < rightDepth
        }
        for path in directories { add(path) }
        let limit = min(64, max(0, nativeHooks.vnodeLimit ?? 64))
        let needed = Set(ordered.prefix(limit))
        for path in vnodeWatches.keys.filter({ !needed.contains($0) }) {
            vnodeWatches.removeValue(forKey: path)?.close()
        }
        for path in ordered.prefix(limit) {
            guard let entry = try? Self.entry(path, follow: true) else {
                vnodeWatches.removeValue(forKey: path)?.close()
                continue
            }
            if let watch = vnodeWatches[path], watch.device == entry.device, watch.inode == entry.inode { continue }
            vnodeWatches.removeValue(forKey: path)?.close()
            if let watch = NativeVnodeWatch(path: path, mailbox: vnodeMailbox) {
                vnodeWatches[path] = watch
            }
        }
    }

    private func stopVnodeWatches() {
        vnodeMailbox?.close()
        for watch in vnodeWatches.values { watch.close() }
        vnodeWatches.removeAll()
        vnodeMailbox = nil
        recentFiles.removeAll()
    }

    func nativeWatchCountsForTesting() -> (sources: Int, scans: Int, queuedTasks: Int, processLimit: Int) {
        (vnodeWatches.count, nativeScanCount, vnodeMailbox?.queuedTasks ?? 0, NativeVnodeBudget.shared.limit())
    }

    private func nativeEvents(_ paths: [String], overflow: Bool, rootChanged: Bool) {
        guard !closed else { return }
        if overflow { onChange(.overflow) }
        if rootChanged { nativeRootChanged = true }
        var relevant = overflow || rootChanged
        for path in paths {
            if inScope(path) { events.insert(reported(path)); relevant = true }
            // FSEvents reports canonical paths. Preserve the requested path for
            // symlink targets and paths such as /var, which aliases /private/var.
            for (logical, physical) in physicalTargets {
                if Self.within(path, physical) {
                    let translated = logical + path.dropFirst(physical.count)
                    if inScope(translated) { events.insert(reported(translated)); relevant = true }
                } else if Self.within(physical, path) {
                    // A physical ancestor changed. Its identity is checked by
                    // the scan; unrelated sibling entries are not reported.
                    relevant = true
                }
            }
        }
        if relevant { scheduleFlush() }
    }

    /// Paths move from the nearest existing ancestor to the target as it appears.
    /// Root identity also changes when a directory is replaced at the same path.
    private func neededNativeRoots() -> [NativeRoot] {
        var roots: [String: NativeRoot] = [:]
        for target in targets {
            var candidate = target.path
            var entry = try? Self.entry(candidate, follow: true)
            while entry == nil {
                let parent = (candidate as NSString).deletingLastPathComponent
                if parent == candidate || parent.isEmpty { break }
                candidate = parent
                entry = try? Self.entry(candidate, follow: true)
            }
            // FSEventStreamCreate accepts directory roots. A file target is
            // covered by its parent directory, including after it appears.
            // A symlink target also needs the physical file's parent so a
            // write through the other path is visible.
            if let found = entry, !found.directory {
                if let physical = Self.realPath(candidate) {
                    let physicalParent = (physical as NSString).deletingLastPathComponent
                    if let physicalEntry = try? Self.entry(physicalParent, follow: true) {
                        roots[physicalParent] = NativeRoot(path: physicalParent, recursive: false,
                            kind: physicalEntry.kind, device: physicalEntry.device, inode: physicalEntry.inode)
                    }
                }
                candidate = (candidate as NSString).deletingLastPathComponent
                entry = try? Self.entry(candidate, follow: true)
            }
            guard let entry else { continue }
            let path = Self.realPath(candidate) ?? candidate
            let parent = (target.path as NSString).deletingLastPathComponent
            let recursive = target.recursive || candidate != target.path && candidate != parent
            let root = NativeRoot(path: path, recursive: recursive || roots[path]?.recursive == true,
                                  kind: entry.kind, device: entry.device, inode: entry.inode)
            roots[path] = root
        }
        let sorted = roots.values.sorted { $0.path < $1.path }
        return sorted.filter { child in
            !Self.ancestors(child.path).contains { ancestor in
                ancestor != child.path && roots[ancestor]?.recursive == true
            }
        }
    }

    /// Returns true when new native coverage requires another snapshot scan.
    private func reconcileNativeStream() -> Bool {
        guard mode == .native else { return false }
        let needed = neededNativeRoots()
        guard needed != streamRoots || nativeRootChanged else { return false }
        nativeRootChanged = false
        if needed.isEmpty { stopNativeStream(); return false }
        guard startNativeStream(roots: needed) else {
            switchToPolling()
            return true
        }
        scheduleSettle()
        return true
    }

    /// A loss or a mount change makes coverage uncertain, even when paths are supplied.
    nonisolated static func nativeRequiresRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount) != 0
    }

    /// Deliver a synthetic native batch through the same actor path as FSEvents.
    func nativeEventsForTesting(_ paths: [String], flags: FSEventStreamEventFlags) {
        nativeEvents(paths, overflow: Self.nativeRequiresRescan(flags),
            rootChanged: flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0)
    }

    /// Flush pending native callbacks so tests can check delivery without a timed sleep.
    func flushNativeEventsForTesting() { stream?.flushSync() }

    private func startNativeStream(roots: [NativeRoot]) -> Bool {
        let hooks = nativeHooks
        let callback = NativeWatchCallback { [weak self] paths, overflow, rootChanged in
            // Count before the hop. FlushSync waits for this callback, so the
            // delivery check does not race with tasks waiting for the actor.
            hooks.batchDelivered(paths)
            Task { await self?.nativeEvents(paths, overflow: overflow, rootChanged: rootChanged) }
        }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<NativeWatchCallback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<NativeWatchCallback>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let paths = roots.map(\.path) as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        // Use a concrete event ID. SinceNow can skip a write while a new
        // stream is starting. The scan after start covers earlier changes.
        let resumeAfter = FSEventsGetCurrentEventId()
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<NativeWatchCallback>.fromOpaque(info).takeUnretainedValue()
            let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            guard values.count >= count else { callback.deliver([], true, false); return }
            var overflow = false
            var rootChanged = false
            var changedPaths: [String] = []
            for index in 0..<count {
                if LocalFileWatcher.nativeRequiresRescan(flags[index]) { overflow = true }
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { rootChanged = true }
                if flags[index] != FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) {
                    changedPaths.append(values[index])
                }
            }
            if !changedPaths.isEmpty || overflow || rootChanged {
                callback.deliver(changedPaths, overflow, rootChanged)
            }
        }, &context, paths, resumeAfter, 0.05, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "PiSwiftDurable.file-watch"))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            return false
        }
        let previous = stream
        stream = NativeWatchStream(created)
        streamRoots = roots
        nativeHooks.streamStarted(roots.map(\.path))
        previous?.close()
        return true
    }
    private func stopNativeStream() {
        guard let stream else { return }
        stream.close()
        self.stream = nil
        streamRoots = []
    }
    #endif
}

#if os(macOS)
private final class NativeVnodeBudget: Sendable {
    static let shared = NativeVnodeBudget()
    private let used = Mutex(0)
    private init() {}
    func limit() -> Int {
        var value = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &value) == 0 else { return 0 }
        return Int(min(value.rlim_cur / 8, rlim_t(512)))
    }
    func reserve() -> Bool {
        let maximum = limit()
        return used.withLock { count in
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }
    func release() { used.withLock { $0 -= 1 } }
}

private final class NativeVnodeMailbox: Sendable {
    private struct State: Sendable {
        var queued = false
        var dirty = false
        var closed = false
        var queuedTasks = 0
    }
    private let state = Mutex(State())
    private let deliver: @Sendable () -> Void
    init(deliver: @escaping @Sendable () -> Void) { self.deliver = deliver }
    var queuedTasks: Int { state.withLock { $0.queuedTasks } }
    func signal() {
        let start = state.withLock { state in
            guard !state.closed else { return false }
            state.dirty = true
            guard !state.queued else { return false }
            state.queued = true
            state.queuedTasks += 1
            return true
        }
        if start { deliver() }
    }
    func beginScan() { state.withLock { $0.dirty = false } }
    func finishScan() -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            if state.dirty { return true }
            state.queued = false
            return false
        }
    }
    func close() { state.withLock { $0.closed = true; $0.queued = false; $0.dirty = false } }
}

private final class NativeVnodeWatch: Sendable {
    private static let queue = DispatchQueue(label: "PiSwiftDurable.file-watch.vnode")
    let device: UInt64
    let inode: UInt64
    private let source: any DispatchSourceFileSystemObject
    init?(path: String, mailbox: NativeVnodeMailbox) {
        let budget = NativeVnodeBudget.shared
        guard budget.reserve() else { return nil }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { budget.release(); return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            _ = Darwin.close(fd)
            budget.release()
            return nil
        }
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: Self.queue)
        self.source = source
        source.setEventHandler { mailbox.signal() }
        source.setCancelHandler {
            _ = Darwin.close(fd)
            budget.release()
            mailbox.signal()
        }
        source.resume()
    }
    func close() { source.cancel() }
    deinit { close() }
}

/// The stream is stopped once, including when the caller drops an open watch.
private final class NativeWatchStream: Sendable {
    private let address: Mutex<UInt>
    init(_ stream: FSEventStreamRef) { address = Mutex(UInt(bitPattern: stream)) }
    deinit { close() }
    func flushSync() {
        address.withLock { value in
            if let stream = FSEventStreamRef(bitPattern: value) { FSEventStreamFlushSync(stream) }
        }
    }
    func close() {
        address.withLock { value in
            guard let stream = FSEventStreamRef(bitPattern: value) else { return }
            value = 0
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private final class NativeWatchCallback: Sendable {
    let deliver: @Sendable ([String], Bool, Bool) -> Void
    init(_ deliver: @escaping @Sendable ([String], Bool, Bool) -> Void) { self.deliver = deliver }
}
#endif
