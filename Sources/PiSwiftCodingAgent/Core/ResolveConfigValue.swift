import Foundation
import PiSwiftAI

private enum TemplatePart {
    case literal(String)
    case env(String)
}

private enum ConfigValueReference {
    case command(String)
    case template([TemplatePart])
}

private func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 95 || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
}

private func isNamePart(_ scalar: Unicode.Scalar) -> Bool {
    isNameStart(scalar) || (48...57).contains(scalar.value)
}

private func configCommand(_ config: String) -> String {
    String(decoding: config.utf8.dropFirst(), as: UTF8.self)
}

private func parseConfigValueReference(_ config: String) -> ConfigValueReference {
    if isCommandConfigValue(config) { return .command(config) }
    let scalars = Array(config.unicodeScalars)
    func literal(_ start: Int, _ end: Int) -> String {
        String(String.UnicodeScalarView(scalars[start..<end]))
    }
    var parts: [TemplatePart] = []
    func appendLiteral(_ value: String) {
        guard !value.isEmpty else { return }
        if case .literal(let previous) = parts.last {
            parts[parts.count - 1] = .literal(previous + value)
        } else { parts.append(.literal(value)) }
    }
    var cursor = 0
    while cursor < scalars.count {
        guard scalars[cursor].value == 36 else {
            appendLiteral(literal(cursor, cursor + 1))
            cursor += 1
            continue
        }
        let next = cursor + 1
        guard next < scalars.count else { appendLiteral("$"); break }
        if scalars[next].value == 36 || scalars[next].value == 33 {
            appendLiteral(literal(next, next + 1))
            cursor += 2
            continue
        }
        if scalars[next].value == 123, let end = scalars[(next + 1)...].firstIndex(where: { $0.value == 125 }) {
            let name = scalars[(next + 1)..<end]
            if let first = name.first, isNameStart(first), name.allSatisfy(isNamePart) {
                parts.append(.env(literal(next + 1, end)))
            } else { appendLiteral(literal(cursor, end + 1)) }
            cursor = end + 1
            continue
        }
        if isNameStart(scalars[next]) {
            var end = next + 1
            while end < scalars.count && isNamePart(scalars[end]) { end += 1 }
            parts.append(.env(literal(next, end)))
            cursor = end
            continue
        }
        appendLiteral("$")
        cursor = next
    }
    return .template(parts)
}

private func resolveEnvConfigValue(_ name: String, env: [String: String]?) -> String? {
    if let value = env?[name], !value.isEmpty { return value }
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
    return nil
}

private func resolveTemplate(_ parts: [TemplatePart], env: [String: String]?) -> String? {
    var result = ""
    for part in parts {
        switch part {
        case .literal(let value): result += value
        case .env(let name):
            guard let value = resolveEnvConfigValue(name, env: env) else { return nil }
            result += value
        }
    }
    return result
}

public func getConfigValueEnvVarName(_ config: String) -> String? {
    guard case .template(let parts) = parseConfigValueReference(config), parts.count == 1,
          case .env(let name) = parts[0] else { return nil }
    return name
}

public func getConfigValueEnvVarNames(_ config: String) -> [String] {
    guard case .template(let parts) = parseConfigValueReference(config) else { return [] }
    var names: [String] = []
    for case .env(let name) in parts where !names.contains(name) { names.append(name) }
    return names
}

public func getMissingConfigValueEnvVarNames(_ config: String, env: [String: String]? = nil) -> [String] {
    getConfigValueEnvVarNames(config).filter { resolveEnvConfigValue($0, env: env) == nil }
}

public func isCommandConfigValue(_ config: String) -> Bool { config.utf8.first == 33 }

public func isConfigValueConfigured(_ config: String, env: [String: String]? = nil) -> Bool {
    getMissingConfigValueEnvVarNames(config, env: env).isEmpty
}

// A wrapper retains cached failures as well as successful values. The lock makes
// concurrent calls execute a given command once, as the synchronous upstream does.
private struct CommandResult: Sendable { let value: String? }
private let commandResultCache = LockedState<[String: CommandResult]>([:])

public func clearConfigValueCache() { commandResultCache.withLock { $0.removeAll() } }

public func resolveConfigValue(_ config: String, env: [String: String]? = nil) -> String? {
    switch parseConfigValueReference(config) {
    case .command(let command):
        return commandResultCache.withLock { cache in
            if let result = cache[command] { return result.value }
            let value = executeConfigCommand(configCommand(command))
            cache[command] = CommandResult(value: value)
            return value
        }
    case .template(let parts): return resolveTemplate(parts, env: env)
    }
}

public func resolveConfigValueUncached(_ config: String, env: [String: String]? = nil) -> String? {
    switch parseConfigValueReference(config) {
    case .command(let command): return executeConfigCommand(configCommand(command))
    case .template(let parts): return resolveTemplate(parts, env: env)
    }
}

public enum ConfigValueResolutionError: Error, LocalizedError, Sendable {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

public func resolveConfigValueOrThrow(_ config: String, description: String, env: [String: String]? = nil) throws -> String {
    if let value = resolveConfigValueUncached(config, env: env) { return value }
    if isCommandConfigValue(config) {
        throw ConfigValueResolutionError.failed("Failed to resolve \(description) from shell command: \(configCommand(config))")
    }
    let names = getMissingConfigValueEnvVarNames(config, env: env)
    if !names.isEmpty {
        let label = names.count == 1 ? "environment variable" : "environment variables"
        throw ConfigValueResolutionError.failed("Failed to resolve \(description) from \(label): \(names.joined(separator: ", "))")
    }
    throw ConfigValueResolutionError.failed("Failed to resolve \(description)")
}

public func resolveHeaders(_ headers: ProviderHeaders?, env: [String: String]? = nil) -> ProviderHeaders? {
    guard let headers else { return nil }
    var result: ProviderHeaders = [:]
    for (key, value) in headers {
        if let value {
            if let resolved = resolveConfigValue(value, env: env), !resolved.isEmpty { result.updateValue(resolved, forKey: key) }
        } else { result.updateValue(nil, forKey: key) }
    }
    return result.isEmpty ? nil : result
}

public func resolveHeadersOrThrow(_ headers: ProviderHeaders?, description: String, env: [String: String]? = nil) throws -> ProviderHeaders? {
    guard let headers else { return nil }
    var result: ProviderHeaders = [:]
    for key in headers.keys.sorted() {
        if let value = headers[key] ?? nil {
            result.updateValue(try resolveConfigValueOrThrow(value, description: "\(description) header \"\(key)\"", env: env), forKey: key)
        } else { result.updateValue(nil, forKey: key) }
    }
    return result.isEmpty ? nil : result
}

private func executeConfigCommand(_ command: String) -> String? {
    #if canImport(UIKit)
    return nil
    #else
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() }
    catch { return nil }
    // Drain stdout while the command runs, so a full pipe cannot block its exit.
    stdout.fileHandleForWriting.closeFile()
    let output = LockedState(Data())
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        stdout.fileHandleForReading.closeFile()
        output.withLock { $0 = data }
        drained.signal()
    }
    let deadline = DispatchTime.now() + 10
    guard exited.wait(timeout: deadline) == .success,
          drained.wait(timeout: deadline) == .success else {
        if process.isRunning { process.terminate() }
        return nil
    }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    let data = output.withLock { $0 }
    // execSync uses a 1 MiB default stdout limit and JavaScript String.trim().
    guard data.count <= 1024 * 1024 else { return nil }
    let whitespace = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: whitespace)
    return trimmed.isEmpty ? nil : trimmed
    #endif
}
