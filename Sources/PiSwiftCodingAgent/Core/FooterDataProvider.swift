import Dispatch
import Foundation

public protocol FooterDataProviding: Sendable {
    func getGitBranch() -> String?
    func getExtensionStatuses() -> [String: String]
    func onBranchChange(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// SAFETY: branch cache, extension statuses, callbacks, and watcher handles are
/// accessed only while holding `lock`; callback invocation uses snapshots.
public final class FooterDataProvider: @unchecked Sendable, FooterDataProviding {
    private let lock = NSLock()
    private var extensionStatuses: [String: String] = [:]
    private var cachedBranch: String?
    private var branchCacheValid = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var gitWatcher: DispatchSourceFileSystemObject?
    private var gitFd: Int32 = -1

    public init() {
        setupGitWatcher()
    }

    deinit {
        dispose()
    }

    public func getGitBranch() -> String? {
        lock.lock()
        if branchCacheValid {
            let branch = cachedBranch
            lock.unlock()
            return branch
        }
        lock.unlock()

        let branch = resolveGitBranch()
        lock.lock()
        cachedBranch = branch
        branchCacheValid = true
        lock.unlock()
        return branch
    }

    public func getExtensionStatuses() -> [String: String] {
        lock.lock()
        let statuses = extensionStatuses
        lock.unlock()
        return statuses
    }

    public func onBranchChange(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.lock()
        callbacks[id] = callback
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.callbacks.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }

    public func setExtensionStatus(_ key: String, _ text: String?) {
        lock.lock()
        if let text {
            extensionStatuses[key] = text
        } else {
            extensionStatuses.removeValue(forKey: key)
        }
        lock.unlock()
    }

    public func dispose() {
        lock.lock()
        callbacks.removeAll()
        branchCacheValid = false
        cachedBranch = nil
        lock.unlock()
        clearWatcher()
    }

    private func resolveGitBranch() -> String? {
        guard let gitHeadPath = findGitHeadPath() else {
            return nil
        }

        // Check if this is a reftable repo (newer git storage format).
        // In reftable repos, .git/HEAD may not contain the branch ref in the
        // traditional format, so fall back to `git branch --show-current`.
        let gitDir = URL(fileURLWithPath: gitHeadPath).deletingLastPathComponent().path
        let reftablePath = URL(fileURLWithPath: gitDir).appendingPathComponent("reftable").path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: reftablePath, isDirectory: &isDir), isDir.boolValue {
            return resolveGitBranchViaCommand()
        }

        do {
            let content = try String(contentsOfFile: gitHeadPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("ref: refs/heads/") {
                return String(content.dropFirst("ref: refs/heads/".count))
            }
            return "detached"
        } catch {
            return nil
        }
    }

    private func resolveGitBranchViaCommand() -> String? {
        #if canImport(UIKit)
        // Reftable repositories require invoking git, which is unavailable on Apple
        // mobile platforms. Traditional repositories still resolve from .git/HEAD.
        return nil
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--show-current"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let output, !output.isEmpty {
                return output
            }
            return process.terminationStatus == 0 ? "detached" : nil
        } catch {
            return nil
        }
        #endif
    }

    private func invalidateBranchCache() {
        let callbacksToRun: [@Sendable () -> Void]
        lock.lock()
        branchCacheValid = false
        callbacksToRun = Array(callbacks.values)
        lock.unlock()
        for callback in callbacksToRun {
            callback()
        }
    }

    private func setupGitWatcher() {
        clearWatcher()

        guard let gitHeadPath = findGitHeadPath() else { return }
        let gitDir = URL(fileURLWithPath: gitHeadPath).deletingLastPathComponent().path

#if canImport(Darwin)
        let fd = open(gitDir, O_EVTONLY)
#else
        let fd = open(gitDir, O_RDONLY)
#endif
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib, .delete],
            queue: DispatchQueue.global(qos: .background)
        )
        source.setEventHandler { [weak self] in
            self?.invalidateBranchCache()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        lock.lock()
        gitFd = fd
        gitWatcher = source
        lock.unlock()
    }

    private func clearWatcher() {
        lock.lock()
        let watcher = gitWatcher
        gitWatcher = nil
        let fd = gitFd
        gitFd = -1
        lock.unlock()

        watcher?.cancel()
        if fd >= 0 {
            close(fd)
        }
    }

    private func findGitHeadPath() -> String? {
        var dir = FileManager.default.currentDirectoryPath
        let fm = FileManager.default

        while true {
            let gitPath = URL(fileURLWithPath: dir).appendingPathComponent(".git").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    let headPath = URL(fileURLWithPath: gitPath).appendingPathComponent("HEAD").path
                    if fm.fileExists(atPath: headPath) {
                        return headPath
                    }
                } else {
                    if let content = try? String(contentsOfFile: gitPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       content.hasPrefix("gitdir: ") {
                        let gitDir = content.dropFirst("gitdir: ".count)
                        let base = URL(fileURLWithPath: dir)
                        let resolvedGitDir = URL(fileURLWithPath: String(gitDir), relativeTo: base).path
                        let headPath = URL(fileURLWithPath: resolvedGitDir).appendingPathComponent("HEAD").path
                        if fm.fileExists(atPath: headPath) {
                            return headPath
                        }
                    }
                }
            }

            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir {
                return nil
            }
            dir = parent
        }
    }
}
