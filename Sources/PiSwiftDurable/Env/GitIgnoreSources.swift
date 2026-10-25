import Foundation
import PiSwiftChord
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One directory's rules. The walk keeps these layers on an explicit stack.
internal struct GitIgnoreLayer {
    let path: [UInt8]
    let repository: Bool
    let rules: [GitIgnoreRule]
    let info: [GitIgnoreRule]

    init(path: [UInt8], processDirectory: String, context: ChordContext) throws {
        self.path = path
        let git = path + Array("/.git".utf8)
        var metadata = stat()
        let hasGit = LocalListingPath.withCString(git) { stat($0, &metadata) == 0 }
        repository = hasGit || LocalListingPath.exists(path + Array("/.jj".utf8))
        rules = try LocalListingPath.rules(path + Array("/.gitignore".utf8), context: context)
        var infoPath = git + Array("/info/exclude".utf8)
        if hasGit && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
            // ignore 0.4.33 reads info/exclude through commondir for a .git file.
            // Its relative gitdir paths use the process directory, not the work tree.
            if let line = LocalListingPath.firstLine(git, context: context),
               line.hasPrefix("gitdir: ") {
                let gitDirectory = LocalFS.resolve(String(line.dropFirst(8)), cwd: processDirectory)
                if let common = LocalListingPath.firstLine(Array((gitDirectory + "/commondir").utf8), context: context) {
                    let base = common.hasPrefix(".") ? gitDirectory : processDirectory
                    infoPath = Array((LocalFS.resolve(String(common), cwd: base) + "/info/exclude").utf8)
                } else { infoPath = [] }
            } else { infoPath = [] }
        }
        info = hasGit ? try LocalListingPath.rules(infoPath, context: context) : []
    }

    func match(_ path: [UInt8], isDirectory: Bool, info: Bool = false) -> Bool? {
        let rules = info ? self.info : self.rules
        guard !rules.isEmpty else { return nil }
        let prefix = self.path.last == 47 ? self.path : self.path + [47]
        guard path.starts(with: prefix) else { return nil }
        return GitIgnore.match(rules, path: Array(path.dropFirst(prefix.count)), isDirectory: isDirectory)
    }
}

internal enum GitIgnoreSources {
    /// Matches the pinned crate's lookup, including its fallback after GIT_CONFIG_GLOBAL.
    /// The crate does not parse include directives, sections, or repository config.
    static func globalPath(environment: [String: String], processDirectory: String, context: ChordContext = .background) -> String? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let candidates = [environment["GIT_CONFIG_GLOBAL"], home + "/.gitconfig", xdg + "/git/config",
                          environment["GIT_CONFIG_SYSTEM"].flatMap { $0.isEmpty ? nil : $0 } ?? "/etc/gitconfig"]
        let expression = try? NSRegularExpression(pattern: #"(?im)^[\t\n\r\x0b\x0c ]*excludesfile[\t\n\r\x0b\x0c ]*=[\t\n\r\x0b\x0c ]*"?[\t\n\r\x0b\x0c ]*([^\t\n\r\x0b\x0c ]+?)[\t\n\r\x0b\x0c ]*"?[\t\n\r\x0b\x0c ]*$"#,
                                                 options: [.useUnixLineSeparators])
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty,
                  let bytes = try? LocalListingPath.bytes(Array(LocalFS.resolve(candidate, cwd: processDirectory).utf8), context: context) else { continue }
            // Map each byte to one UTF-16 unit so regex ranges also index the original bytes.
            // The crate requires UTF-8 only for the captured path, not for the whole config.
            let text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar(UInt32($0))! }))
            guard
                  let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let pathText = String(bytes: bytes[match.range(at: 1).location..<NSMaxRange(match.range(at: 1))], encoding: .utf8) else { continue }
            let path = pathText.replacingOccurrences(of: "~", with: home)
            return LocalFS.resolve(path, cwd: processDirectory)
        }
        return LocalFS.resolve(xdg + "/git/ignore", cwd: processDirectory)
    }
}

/// Raw paths preserve POSIX names. Only the returned listing uses UTF-8 replacement.
internal enum LocalListingPath {
    static func withCString<T>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        (path + [0]).withUnsafeBytes { body($0.bindMemory(to: CChar.self).baseAddress!) }
    }
    static func exists(_ path: [UInt8]) -> Bool {
        withCString(path) { access($0, F_OK) == 0 }
    }
    static func firstLine(_ path: [UInt8], context: ChordContext) -> String? {
        text(path, context: context)?.components(separatedBy: "\n").first.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
    static func rules(_ path: [UInt8], context: ChordContext) throws -> [GitIgnoreRule] {
        var rules: [GitIgnoreRule] = [], first = true
        try lines(path, context: context) { line in
            var line = line
            if first { while line.hasPrefix("\u{feff}") { line.removeFirst() }; first = false }
            if let rule = GitIgnoreRule(line) { rules.append(rule) }
        }
        return rules
    }
    static func text(_ path: [UInt8], context: ChordContext = .background) -> String? {
        var parts: [String] = []
        try? lines(path, context: context) { parts.append($0) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    static func bytes(_ path: [UInt8], context: ChordContext) throws -> [UInt8]? {
        guard !path.contains(0) else { return nil }
        try LocalFS.check(context)
        let fd = withCString(path) { open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        var bytes: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try LocalFS.check(context)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return bytes }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func lines(_ path: [UInt8], context: ChordContext, receive: (String) -> Void) throws {
        guard !path.isEmpty, !path.contains(0) else { return }
        try LocalFS.check(context)
        let fd = withCString(path) { open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else { return }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return }
        var line: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try LocalFS.check(context)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return }
            if count == 0 {
                if !line.isEmpty, let text = String(bytes: line, encoding: .utf8) { receive(text) }
                return
            }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    // BufRead::lines in the pinned crate stops at malformed UTF-8.
                    guard let text = String(bytes: line, encoding: .utf8) else { return }
                    receive(text); line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
        }
    }
}
