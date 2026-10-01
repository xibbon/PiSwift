import Foundation
import PiSwiftAI

#if canImport(Darwin)
import Darwin
#endif

/// A best-effort file for MCP `notifications/message` events.
/// The file rotates to `mcp.log.1` after it exceeds 5 MiB.
public actor McpServerLog {
    public static let maxBytes = 5 * 1024 * 1024

    public let path: URL
    private var size: Int?

    public init(path: URL) {
        self.path = path
    }

    public func write(server: String, params: AnyCodable) {
        let line = formatMcpLogMessage(server: server, params: params)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if size == nil { size = currentSize() }
            if (size ?? 0) > Self.maxBytes {
                if currentSize() > Self.maxBytes {
                    let backup = URL(fileURLWithPath: path.path + ".1")
                    try? FileManager.default.removeItem(at: backup)
                    try FileManager.default.moveItem(at: path, to: backup)
                }
                size = currentSize()
            }
            let data = Data(line.utf8)
            #if canImport(Darwin)
            let descriptor = open(path.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
            guard descriptor >= 0 else { return }
            defer { _ = close(descriptor) }
            try data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw McpLogWriteError.failed
                    }
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                }
            }
            #else
            if FileManager.default.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: path)
            }
            #endif
            size = (size ?? 0) + data.count
        } catch {
            // Logging must not make an MCP request fail.
        }
    }

    private func currentSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
}

private enum McpLogWriteError: Error { case failed }

/// Format one server log event. Continuation lines use four spaces.
public func formatMcpLogMessage(server: String, params: AnyCodable, now: Date = Date()) -> String {
    let object = params.value as? [String: Any]
    let level = object?["level"] as? String ?? "info"
    let logger = (object?["logger"] as? String).flatMap { $0.isEmpty ? nil : " \($0):" } ?? ""
    let data = object?["data"] ?? (object == nil ? params.value : nil)
    let message: String
    if let string = data as? String {
        message = string
    } else if let data, JSONSerialization.isValidJSONObject(data),
              let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed, .sortedKeys]),
              let json = String(data: encoded, encoding: .utf8) {
        message = json
    } else if let data,
              let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.fragmentsAllowed]),
              let json = String(data: encoded, encoding: .utf8) {
        message = json
    } else {
        message = data.map(String.init(describing:)) ?? "undefined"
    }
    let timestamp = ISO8601DateFormatter.mcpLogDateFormatter.string(from: now)
    let continued = message.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n", with: "\n    ")
    return "\(timestamp) [\(server)] \(level)\(logger) \(continued)\n"
}

private extension ISO8601DateFormatter {
    static var mcpLogDateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
