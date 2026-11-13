import Foundation
import PiSwiftIgnore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A directory-at-a-time walk. Rules are read only after a directory is entered.
/// This keeps ignored subtrees out of both the search and the rule loader.
struct NativeIgnoreWalker {
    enum Tool: Equatable {
        case grep, find
    }

    struct Entry {
        let url: URL
        let relative: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
    }

    private struct Layer {
        let path: [UInt8]
        let git: GitIgnoreLayer
        let plain: [GitIgnoreRule]
        let tool: [GitIgnoreRule]

        var ruleCount: Int { git.rules.count + git.info.count + plain.count + tool.count }

        func match(_ rules: [GitIgnoreRule], path candidate: [UInt8], isDirectory: Bool) -> Bool? {
            guard !rules.isEmpty else { return nil }
            let prefix = path.last == 47 ? path : path + [47]
            guard candidate.starts(with: prefix) else { return nil }
            return GitIgnore.match(rules, path: Array(candidate.dropFirst(prefix.count)), isDirectory: isDirectory)
        }
    }

    private struct Frame {
        let url: URL
        let relative: String
        let children: [URL]
        let hasLayer: Bool
        var next = 0
    }

    private let tool: Tool
    private let root: URL
    private let processDirectory: String
    private let check: @Sendable () throws -> Void
    private let overrideIgnoredFile: ((String, String) -> Bool)?
    private var global: [GitIgnoreRule]
    private var fdGlobal: [GitIgnoreRule]
    private var layers: [Layer] = []
    private var frames: [Frame] = []
    private let requireRepository: Bool
    private var activeRuleCount = 0

    init(root: String, tool: Tool, environment: [String: String] = ProcessInfo.processInfo.environment,
         processDirectory: String? = nil,
         check: @escaping @Sendable () throws -> Void = {},
         overrideIgnoredFile: ((String, String) -> Bool)? = nil) throws {
        self.tool = tool
        let canonical = root.withCString { realpath($0, nil) }
        let rootPath = canonical.map { String(cString: $0) } ?? root
        if let canonical { free(canonical) }
        self.root = URL(fileURLWithPath: rootPath)
        self.check = check
        self.overrideIgnoredFile = overrideIgnoredFile
        let processDirectory = processDirectory ?? rootPath
        self.processDirectory = processDirectory
        let globalPath = GitIgnoreSources.globalPath(environment: environment, processDirectory: processDirectory, check: check)
        global = try globalPath.map { try LocalListingPath.rules(Array($0.utf8), check: check) } ?? []
        if tool == .find {
            let home = environment["HOME"]
            let config = environment["XDG_CONFIG_HOME"] ?? home.map { $0 + "/.config" }
            fdGlobal = try config.map { try LocalListingPath.rules(Array(($0 + "/fd/ignore").utf8), check: check) } ?? []
        } else { fdGlobal = [] }

        var parents: [String] = [], path = rootPath
        while true {
            parents.append(path)
            if path == "/" { break }
            let next = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if next == path { break }
            path = next
        }
        for parent in parents.reversed() {
            try check()
            layers.append(try Self.layer(at: parent, tool: tool, processDirectory: processDirectory, check: check))
        }
        activeRuleCount = global.count + fdGlobal.count + layers.reduce(0) { $0 + $1.ruleCount }
        requireRepository = tool == .grep
        frames.append(try Self.frame(at: self.root, relative: "", hasLayer: false, check: check))
    }

    private static func layer(at path: String, tool: Tool, processDirectory: String,
                              check: @Sendable () throws -> Void) throws -> Layer {
        let bytes = Array(path.utf8)
        let git = try GitIgnoreLayer(path: bytes, processDirectory: processDirectory, check: check)
        let plain = try LocalListingPath.rules(bytes + Array("/.ignore".utf8), check: check)
        let name = tool == .grep ? "/.rgignore" : "/.fdignore"
        let specific = try LocalListingPath.rules(bytes + Array(name.utf8), check: check)
        return Layer(path: bytes, git: git, plain: plain, tool: specific)
    }

    private static func frame(at url: URL, relative: String, hasLayer: Bool, check: @Sendable () throws -> Void) throws -> Frame {
        try check()
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [])) ?? []
        return Frame(url: url, relative: relative, children: children, hasLayer: hasLayer)
    }

    private func ignored(_ candidate: [UInt8], isDirectory: Bool) -> Bool {
        // A source with no matching rule defers to the next source. Within a
        // source, the nearest directory and the last matching line win.
        let relative = Array(candidate.dropFirst(root.path == "/" ? 1 : root.path.utf8.count + 1))
        for source in 0..<3 {
            for layer in layers.reversed() {
                let match: Bool?
                switch source {
                case 0: match = layer.match(layer.tool, path: candidate, isDirectory: isDirectory)
                case 1: match = layer.match(layer.plain, path: candidate, isDirectory: isDirectory)
                default:
                    if requireRepository, !layers.contains(where: { $0.git.repository }) { continue }
                    match = layer.git.match(candidate, isDirectory: isDirectory)
                }
                if let match { return match }
                if source == 0 && layer.path == Array(root.path.utf8),
                   let match = GitIgnore.match(fdGlobal, path: relative, isDirectory: isDirectory) { return match }
                if source == 2 && layer.git.repository { break }
            }
        }
        if let repo = layers.reversed().first(where: { $0.git.repository }),
           let match = repo.git.match(candidate, isDirectory: isDirectory, info: true) { return match }
        if requireRepository && !layers.contains(where: { $0.git.repository }) { return false }
        if let match = GitIgnore.match(global, path: relative, isDirectory: isDirectory) {
            return match
        }
        return false
    }

    mutating func next() throws -> Entry? {
        while !frames.isEmpty {
            try check()
            let index = frames.count - 1
            if frames[index].next == frames[index].children.count {
                let removed = frames.removeLast()
                if removed.hasLayer { activeRuleCount -= layers.removeLast().ruleCount }
                continue
            }
            let child = frames[index].children[frames[index].next]
            frames[index].next += 1
            let name = child.lastPathComponent
            let relative = frames[index].relative.isEmpty ? name : frames[index].relative + "/" + name
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = values?.isSymbolicLink == true
            let isDirectory = values?.isDirectory == true && !isSymbolicLink
            if activeRuleCount > 0 && ignored(Array(child.path.utf8), isDirectory: isDirectory) &&
                (isDirectory || overrideIgnoredFile?(relative, name) != true) { continue }
            if isDirectory {
                let layer = try Self.layer(at: child.path, tool: tool, processDirectory: processDirectory, check: check)
                activeRuleCount += layer.ruleCount
                layers.append(layer)
                frames.append(try Self.frame(at: child, relative: relative, hasLayer: true, check: check))
            }
            return Entry(url: child, relative: relative, isDirectory: isDirectory, isSymbolicLink: isSymbolicLink)
        }
        return nil
    }
}
