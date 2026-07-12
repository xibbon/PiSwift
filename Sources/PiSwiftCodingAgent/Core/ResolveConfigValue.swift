import Foundation
import PiSwiftAI

/// v0.63.0: shell-command auth and headers resolve at request time. There is no in-process
/// cache. Expiring tokens (OAuth, AWS STS, etc.) refresh naturally on every call. Caching,
/// TTL, and recovery policy are the responsibility of the user-provided wrapper command —
/// arbitrary shell commands need provider-specific strategies that pi has no way to know.
public func resolveConfigValue(_ config: String) -> String? {
    if config.hasPrefix("!") {
        return executeCommand(config)
    }
    let envValue = ProcessInfo.processInfo.environment[config]
    if let envValue, !envValue.isEmpty {
        return envValue
    }
    return config
}

public func resolveHeaders(_ headers: [String: String]?) -> [String: String]? {
    guard let headers else { return nil }
    var resolved: [String: String] = [:]
    for (key, value) in headers {
        if let resolvedValue = resolveConfigValue(value), !resolvedValue.isEmpty {
            resolved[key] = resolvedValue
        }
    }
    return resolved.isEmpty ? nil : resolved
}

private func executeCommand(_ commandConfig: String) -> String? {
    #if canImport(UIKit)
    // Shell-backed configuration is unavailable on Apple mobile platforms. API
    // keys and headers can still be provided directly or through environment values.
    _ = commandConfig
    return nil
    #else
    let command = String(commandConfig.dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }
        if group.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    } catch {
        return nil
    }
    return nil
    #endif
}
