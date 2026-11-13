import Foundation

/// Resolves ignore source paths without depending on an execution environment.
enum IgnorePath {
    static func resolve(_ path: String, cwd: String) -> String {
        var value = path
        if value == "~" { value = NSHomeDirectory() }
        else if value.hasPrefix("~/") { value = NSHomeDirectory() + "/" + value.dropFirst(2) }
        else if value.hasPrefix("file://"), let decoded = fileURLPath(value) { value = decoded }
        let base = cwd.hasPrefix("/") ? cwd : FileManager.default.currentDirectoryPath + "/" + cwd
        return normalize(value.hasPrefix("/") ? value : base + "/" + value)
    }

    private static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() }
            else if part != ".." || !absolute { parts.append(part) }
        }
        let joined = (absolute ? "/" : "") + parts.joined(separator: "/")
        return joined.isEmpty ? "." : joined
    }

    private static func fileURLPath(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let rawPath = normalized.prefix { $0 != "?" && $0 != "#" }
        let bytes = Array(rawPath.utf8)
        func hexadecimal(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count, hexadecimal(bytes[index + 1]), hexadecimal(bytes[index + 2]) else { return nil }
        }
        guard let url = URL(string: normalized), url.isFileURL,
              url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !components.percentEncodedPath.lowercased().contains("%2f"),
              let decoded = components.percentEncodedPath.removingPercentEncoding else { return nil }
        return decoded
    }
}
