import Foundation
import PiSwiftAI
#if canImport(Darwin)
import Darwin
#endif

public struct ShellConfig: Sendable {
    public var shell: String
    public var args: [String]

    public init(shell: String, args: [String]) {
        self.shell = shell
        self.args = args
    }
}

public enum ShellConfigError: Error, CustomStringConvertible {
    case customShellNotFound(String)
    case bashNotFound(String)

    public var description: String {
        switch self {
        case .customShellNotFound(let path):
            return "Custom shell path not found: \(path)\nPlease update shellPath in ~/.pi/agent/settings.json"
        case .bashNotFound(let message):
            return message
        }
    }
}

private struct ShellConfigState: Sendable {
    var cached: ShellConfig?
}

private let shellConfigState = LockedState(ShellConfigState())

public func getShellConfig(settingsManager: SettingsManager = SettingsManager.create()) throws -> ShellConfig {
    #if canImport(UIKit)
    // Apple mobile platforms cannot launch Foundation `Process` instances and do not
    // provide a system bash. Embedders can still expose the bash tool by registering
    // a BashExecutorProvider backed by an in-process implementation such as VirtualBash.
    _ = settingsManager
    throw ShellConfigError.bashNotFound(
        "System bash is unavailable on this platform. Register a custom BashExecutorProvider instead."
    )
    #else
    if let cached = shellConfigState.withLock({ $0.cached }) {
        return cached
    }

    if let customShellPath = settingsManager.getShellPath(), !customShellPath.isEmpty {
        if FileManager.default.fileExists(atPath: customShellPath) {
            let config = ShellConfig(shell: customShellPath, args: ["-c"])
            storeShellConfig(config)
            return config
        }
        throw ShellConfigError.customShellNotFound(customShellPath)
    }

    #if os(Windows)
    let windowsResult = findWindowsBashConfig()
    if let config = windowsResult.config {
        storeShellConfig(config)
        return config
    }
    let searched = windowsResult.searched
    let searchedList = searched.isEmpty ? "" : "\n\nSearched Git Bash in:\n" + searched.map { "  \($0)" }.joined(separator: "\n")
    throw ShellConfigError.bashNotFound(
        "No bash shell found. Options:\n" +
        "  1. Install Git for Windows: https://git-scm.com/download/win\n" +
        "  2. Add your bash to PATH (Cygwin, MSYS2, etc.)\n" +
        "  3. Set shellPath in ~/.pi/agent/settings.json" +
        searchedList
    )
    #else
    if FileManager.default.fileExists(atPath: "/bin/bash") {
        let config = ShellConfig(shell: "/bin/bash", args: ["-c"])
        storeShellConfig(config)
        return config
    }
    if let bashOnPath = findBashOnPath() {
        let config = ShellConfig(shell: bashOnPath, args: ["-c"])
        storeShellConfig(config)
        return config
    }
    let config = ShellConfig(shell: "sh", args: ["-c"])
    storeShellConfig(config)
    return config
    #endif
    #endif
}

private func storeShellConfig(_ config: ShellConfig) {
    shellConfigState.withLock { state in
        state.cached = config
    }
}

#if !canImport(UIKit) && os(Windows)
private func findWindowsBashConfig() -> (config: ShellConfig?, searched: [String]) {
    var paths: [String] = []
    let env = ProcessInfo.processInfo.environment
    if let programFiles = env["ProgramFiles"] {
        paths.append("\(programFiles)\\Git\\bin\\bash.exe")
    }
    if let programFilesX86 = env["ProgramFiles(x86)"] {
        paths.append("\(programFilesX86)\\Git\\bin\\bash.exe")
    }

    for path in paths where FileManager.default.fileExists(atPath: path) {
        return (ShellConfig(shell: path, args: ["-c"]), paths)
    }

    if let bashOnPath = findBashOnPath() {
        return (ShellConfig(shell: bashOnPath, args: ["-c"]), paths)
    }

    return (nil, paths)
}

private func findBashOnPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "where")
    process.arguments = ["bash.exe"]
    let output = Pipe()
    process.standardOutput = output

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let first = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first
    if let match = first {
        let path = String(match)
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return nil
}
#elseif !canImport(UIKit)
private func findBashOnPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "bash"]
    let output = Pipe()
    process.standardOutput = output

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let first = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first
    if let match = first {
        let path = String(match)
        return path.isEmpty ? nil : path
    }
    return nil
}
#endif

public func sanitizeBinaryOutput(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(text.unicodeScalars.count)

    for scalar in text.unicodeScalars {
        let value = scalar.value
        if value == 0x09 || value == 0x0A || value == 0x0D {
            scalars.append(scalar)
            continue
        }
        if value <= 0x1F {
            continue
        }
        if value >= 0xFFF9 && value <= 0xFFFB {
            continue
        }
        scalars.append(scalar)
    }

    return String(scalars)
}

public func killProcessTree(_ pid: pid_t) {
    #if canImport(UIKit)
    // System processes cannot be spawned on Apple mobile platforms. Keeping this a
    // no-op lets shared session teardown remain platform-agnostic.
    _ = pid
    #elseif os(Windows)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "taskkill")
    process.arguments = ["/F", "/T", "/PID", String(pid)]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    #else
    let descendants = collectDescendantPids(of: pid)
    if kill(-pid, SIGKILL) != 0 {
        for childPid in descendants.sorted(by: >) {
            _ = kill(childPid, SIGKILL)
        }
        _ = kill(pid, SIGKILL)
    }
    #endif
}

#if !os(Windows) && !canImport(UIKit)
private func collectDescendantPids(of pid: pid_t) -> Set<pid_t> {
    var result = Set<pid_t>()
    var stack = childPids(of: pid)

    while let current = stack.popLast() {
        guard result.insert(current).inserted else { continue }
        stack.append(contentsOf: childPids(of: current))
    }

    return result
}

private func childPids(of pid: pid_t) -> [pid_t] {
    let executable = FileManager.default.fileExists(atPath: "/usr/bin/pgrep") ? "/usr/bin/pgrep" : "/bin/pgrep"
    guard FileManager.default.fileExists(atPath: executable) else { return [] }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-P", String(pid)]
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }

    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    return text
        .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
        .compactMap { pid_t(String($0)) }
}
#endif

/// v0.67.4: registry of detached child PIDs spawned by long-running tools (e.g., bash with `&`).
/// On normal session shutdown / signal-driven exit (SIGINT, SIGTERM), `killTrackedDetachedChildren()`
/// reaps them so the user doesn't end up with orphans.
///
/// Mirrors upstream `coding-agent/src/utils/shell.ts:trackedDetachedChildPids`.
private let trackedDetachedChildPids = LockedState<Set<pid_t>>([])

public func trackDetachedChildPid(_ pid: pid_t) {
    trackedDetachedChildPids.withLock { $0.insert(pid) }
}

public func untrackDetachedChildPid(_ pid: pid_t) {
    trackedDetachedChildPids.withLock { $0.remove(pid) }
}

/// Snapshot of currently tracked PIDs. Useful for tests / diagnostics.
public func getTrackedDetachedChildPids() -> Set<pid_t> {
    trackedDetachedChildPids.withLock { $0 }
}

/// Kill every tracked detached child and clear the registry. Call from `dispose()` /
/// signal handlers / `/quit` shutdown.
public func killTrackedDetachedChildren() {
    let pids = trackedDetachedChildPids.withLock { snap -> Set<pid_t> in
        let result = snap
        snap.removeAll()
        return result
    }
    for pid in pids {
        killProcessTree(pid)
    }
}
