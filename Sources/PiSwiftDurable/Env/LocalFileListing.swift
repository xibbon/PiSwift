import Foundation
import PiSwiftChord
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

internal struct LocalListingHooks: Sendable {
    var beforeDirectory: (@Sendable () -> Void)?
}

internal enum LocalFileListing {
    private struct Frame {
        let path: [UInt8]
        let relative: [UInt8]
        var names: [[UInt8]]
        var next = 0
    }

    /// The environment and tests use the same worker. Tests can supply config without changing HOME.
    static func list(_ root: String, options: ListFilesOptions?, context: ChordContext,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     hooks: LocalListingHooks = .init()) async -> Result<FileListing, FileError> {
        let bounds: ListFilesBounds
        switch listFilesBounds(options: options, path: root) {
        case .failure(let error): return .failure(error)
        case .success(let value): bounds = value
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "PiSwiftDurable.files.list").async {
                continuation.resume(returning: LocalFS.result {
                    try walk(root, options: options, bounds: bounds, context: context, environment: environment, hooks: hooks)
                })
            }
        }
    }

    private static func names(_ path: [UInt8], context: ChordContext, hooks: LocalListingHooks) throws -> [[UInt8]] {
        hooks.beforeDirectory?()
        try LocalFS.check(context)
        guard let directory = LocalListingPath.withCString(path, { opendir($0) }) else { return [] }
        defer { closedir(directory) }
        var names: [[UInt8]] = []
        // readdir streams one directory. Sorting requires only this directory's names.
        while let entry = readdir(directory) {
            try LocalFS.check(context)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { pointer in
                    Array(UnsafeBufferPointer(start: pointer, count: strlen(UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))))
                }
            }
            if name == [46] || name == [46, 46] { continue }
            names.append(name)
        }
        names.sort { $0.lexicographicallyPrecedes($1) }
        return names
    }

    private static func walk(_ root: String, options: ListFilesOptions?, bounds: ListFilesBounds,
                             context: ChordContext, environment: [String: String], hooks: LocalListingHooks) throws -> FileListing {
        try LocalFS.check(context, path: root)
        let metadata = try LocalFS.stats(root, follow: true)
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw LocalFS.error(ENOTDIR, path: root) }
        // Canonical parents make a symlinked root use the target's parent ignore files.
        let canonical = root.withCString { realpath($0, nil) }
        let rootPath: [UInt8]
        if let canonical { rootPath = Array(UnsafeBufferPointer(start: UnsafeRawPointer(canonical).assumingMemoryBound(to: UInt8.self), count: strlen(canonical))); free(canonical) }
        else { rootPath = Array(root.utf8) }
        let processDirectory = FileManager.default.currentDirectoryPath
        let useGitignore = options?.gitignore ?? true
        let globalPath = useGitignore ? GitIgnoreSources.globalPath(environment: environment, processDirectory: processDirectory, context: context) : nil
        let global = try globalPath.map { try LocalListingPath.rules(Array($0.utf8), context: context) } ?? []
        var layers: [GitIgnoreLayer] = []
        if useGitignore {
            var parents: [[UInt8]] = [], path = rootPath
            while true {
                parents.append(path)
                guard path != [47], let slash = path.lastIndex(of: 47) else { break }
                path = slash == 0 ? [47] : Array(path[..<slash])
            }
            for parent in parents.reversed() {
                try LocalFS.check(context, path: root)
                layers.append(try .init(path: parent, processDirectory: processDirectory, context: context))
            }
        }
        let started = ContinuousClock.now
        var frames = [Frame(path: rootPath, relative: [], names: try names(rootPath, context: context, hooks: hooks))]
        let excluded = (options?.exclude ?? []).map { Array($0.utf8) }
        var entries: [FileListEntry] = [], bytes = 0
        while !frames.isEmpty {
            try LocalFS.check(context, path: root)
            let last = frames.count - 1
            if frames[last].next == frames[last].names.count {
                frames.removeLast()
                if useGitignore { layers.removeLast() }
                continue
            }
            let name = frames[last].names[frames[last].next]
            frames[last].next += 1
            if name == Array(".git".utf8) || excluded.contains(name) { continue }
            let path = frames[last].path + (frames[last].path.last == 47 ? [] : [47]) + name
            let relative = frames[last].relative + (frames[last].relative.isEmpty ? [] : [47]) + name
            var stats = stat()
            guard LocalListingPath.withCString(path, { lstat($0, &stats) == 0 }) else { continue }
            let kind: FileKind
            switch stats.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG): kind = .file
            case mode_t(S_IFDIR): kind = .directory
            case mode_t(S_IFLNK): kind = .symlink
            default: continue
            }
            var ignored: Bool?
            if useGitignore && layers.contains(where: \.repository) {
                var info: Bool?
                for layer in layers.reversed() {
                    if ignored == nil { ignored = layer.match(path, isDirectory: kind == .directory) }
                    if info == nil { info = layer.match(path, isDirectory: kind == .directory, info: true) }
                    if layer.repository { break }
                }
                if ignored == nil { ignored = info ?? GitIgnore.match(global, path: relative, isDirectory: kind == .directory) }
            }
            if ignored == true { continue }
            // The crate applies hidden filtering only when no ignore rule matched.
            if ignored == nil && options?.hidden == false && name.first == 46 { continue }
            let text = String(decoding: relative, as: UTF8.self)
            let size = text.utf8.count + 2
            if entries.count >= bounds.maxEntries || size > bounds.maxBytes - bytes
                || started.duration(to: .now) > .milliseconds(bounds.timeoutMs) {
                return FileListing(entries: entries, truncated: true)
            }
            entries.append(.init(path: text, kind: kind)); bytes += size
            if kind == .directory {
                if useGitignore { layers.append(try .init(path: path, processDirectory: processDirectory, context: context)) }
                frames.append(Frame(path: path, relative: relative, names: try names(path, context: context, hooks: hooks)))
            }
        }
        return FileListing(entries: entries, truncated: false)
    }
}
