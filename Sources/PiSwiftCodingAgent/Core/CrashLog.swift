import Foundation

public struct CrashRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case uncaughtException = "uncaught_exception", fatalError = "fatal_error" }
    public var timestamp: String
    public var version: String
    public var kind: Kind
    public var message: String
    public var stack: String?
    public var sessionFile: String?
    public var cwd: String
    public var notified: Bool?

    public init(timestamp: String, version: String, kind: Kind, message: String, stack: String? = nil, sessionFile: String? = nil, cwd: String, notified: Bool? = nil) {
        self.timestamp = timestamp
        self.version = version
        self.kind = kind
        self.message = message
        self.stack = stack
        self.sessionFile = sessionFile
        self.cwd = cwd
        self.notified = notified
    }
}

public struct CrashExtension: Sendable {
    public var label: String
    public var dylibPath: String
    public var symbolPrefixes: [String]

    public init(label: String, dylibPath: String, symbolPrefixes: [String] = []) {
        self.label = label
        self.dylibPath = dylibPath
        self.symbolPrefixes = symbolPrefixes
    }
}

/// Swift stacks contain dylib paths and mangled symbols, not JavaScript source files.
/// Inspect frame lines only; the error text must never count as an extension match.
public func findExtensionStackMatches(_ stack: String?, extensions: [CrashExtension]) -> [String] {
    guard let stack else { return [] }
    let frames = stack.split(separator: "\n").dropFirst().map(String.init)
    var seen = Set<String>()
    return extensions.compactMap { ext in
        let path = ext.dylibPath.replacingOccurrences(of: "\\", with: "/")
        let matched = frames.contains { frame in
            let normalized = frame.replacingOccurrences(of: "\\", with: "/")
            return (!path.isEmpty && !isSyntheticPath(path) && normalized.contains(path)) || ext.symbolPrefixes.contains { !$0.isEmpty && normalized.contains($0) }
        }
        return matched && seen.insert(ext.label).inserted ? ext.label : nil
    }
}

public struct CrashLog: Sendable {
    public let path: String

    public init(path: String = URL(fileURLWithPath: getAgentDir()).appendingPathComponent("crashes.json").path) {
        self.path = path
    }

    public func read() -> [CrashRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        guard let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(CrashRecord.self, from: data)
        }
    }

    private func write(_ records: [CrashRecord]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(records)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    /// Best effort because the caller can already be failing.
    @discardableResult public func append(kind: CrashRecord.Kind, error: Error, stack: String? = nil, sessionFile: String? = nil, cwd: String, version: String) -> CrashRecord? {
        let record = CrashRecord(timestamp: ISO8601DateFormatter().string(from: Date()), version: version, kind: kind, message: error.localizedDescription, stack: stack, sessionFile: sessionFile, cwd: cwd)
        do {
            try write(Array((read() + [record]).suffix(5)))
            return record
        } catch { return nil }
    }

    public func unannounced(now: Date = Date()) -> [CrashRecord] {
        read().filter { record in
            guard record.notified != true, let date = ISO8601DateFormatter().date(from: record.timestamp) else { return false }
            return now.timeIntervalSince(date) <= 7 * 24 * 60 * 60
        }
    }

    /// Marks every pending record, matching upstream's announce-once behavior.
    @discardableResult public func takeUnannounced(now: Date = Date()) -> CrashRecord? {
        let records = read()
        let pending = unannounced(now: now).last
        guard pending != nil else { return nil }
        try? write(records.map { record in
            var copy = record
            copy.notified = true
            return copy
        })
        return pending
    }

    public func clear() { try? FileManager.default.removeItem(atPath: path) }
}
