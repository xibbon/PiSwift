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
}

private func storeShellConfig(_ config: ShellConfig) {
    shellConfigState.withLock { state in
        state.cached = config
    }
}

#if os(Windows)
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
#else
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
    #if os(Windows)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "taskkill")
    process.arguments = ["/F", "/T", "/PID", String(pid)]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    #else
    if kill(-pid, SIGKILL) != 0 {
        _ = kill(pid, SIGKILL)
    }
    #endif
}

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
