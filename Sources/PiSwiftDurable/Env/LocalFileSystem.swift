import Foundation
import PiSwiftChord
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// POSIX operations shared by the local environment and its opened readers.
internal enum LocalFS {
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991
    static func error(_ number: Int32 = errno, path: String? = nil) -> FileError {
        let code: FileErrorCode
        switch number {
        case ENOENT: code = .notFound
        case EACCES, EPERM: code = .permissionDenied
        case ENOTDIR: code = .notDirectory
        case EISDIR: code = .isDirectory
        case EINVAL: code = .invalid
        default: code = .unknown
        }
        return FileError(code, message: String(cString: strerror(number)), path: path)
    }
    static func check(_ context: ChordContext, path: String? = nil) throws {
        if context.abortSignal?.aborted == true { throw FileError(.aborted, message: "aborted", path: path) }
        if path?.utf8.contains(0) == true { throw FileError(.invalid, message: "Path contains a null byte", path: path) }
    }
    static func result<T>(_ body: () throws -> T) -> Result<T, FileError> {
        do { return .success(try body()) }
        catch let error as FileError { return .failure(error) }
        catch { return .failure(FileError(.unknown, message: String(describing: error), cause: error)) }
    }
    static func normalize(_ path: String) -> String {
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
    static func resolve(_ path: String, cwd: String) -> String {
        var value = path
        if value == "~" { value = NSHomeDirectory() }
        else if value.hasPrefix("~/") { value = NSHomeDirectory() + "/" + value.dropFirst(2) }
        else if value.hasPrefix("file://"), let decoded = fileURLPath(value) { value = decoded }
        let base = cwd.hasPrefix("/") ? cwd : FileManager.default.currentDirectoryPath + "/" + cwd
        return normalize(value.hasPrefix("/") ? value : base + "/" + value)
    }
    private static func fileURLPath(_ value: String) -> String? {
        // Foundation repairs malformed percent escapes. Node rejects them and uses the input as an ordinary path.
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
    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    static func stats(_ path: String, follow: Bool = false) throws -> stat {
        var value = stat()
        let rc = follow ? stat(path, &value) : lstat(path, &value)
        guard rc == 0 else { throw error(path: path) }
        return value
    }
    static func info(_ path: String, stats: stat) throws -> FileInfo {
        let kind: FileKind
        switch stats.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symlink
        default: throw FileError(.invalid, message: "Unsupported file type", path: path)
        }
        #if canImport(Darwin)
        let time = stats.st_mtimespec
        #else
        let time = stats.st_mtim
        #endif
        return FileInfo(name: path == "/" ? "" : (path as NSString).lastPathComponent, path: path, kind: kind,
                        size: Int64(stats.st_size), mtimeMs: Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000)
    }
    static func mkdirs(_ path: String, recursive: Bool, context: ChordContext) throws {
        try check(context, path: path)
        if mkdir(path, 0o777) == 0 { return }
        let number = errno
        if recursive && number == EEXIST {
            guard try stats(path, follow: true).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw error(EEXIST, path: path) }
            return
        }
        if recursive && number == ENOENT {
            let parent = parent(path)
            guard parent != path else { throw error(number, path: path) }
            try mkdirs(parent, recursive: true, context: context)
            try check(context, path: path)
            if mkdir(path, 0o777) == 0 { return }
            if errno == EEXIST, try stats(path, follow: true).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return }
            throw error(path: path)
        }
        throw error(number, path: path)
    }
    static func remove(_ path: String, recursive: Bool, force: Bool, context: ChordContext) throws {
        try check(context, path: path)
        let value: stat
        do { value = try stats(path) }
        catch let failure as FileError { if force && failure.code == .notFound { return }; throw failure }
        if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            guard recursive else { throw error(EISDIR, path: path) }
            guard let directory = opendir(path) else { throw error(path: path) }
            defer { closedir(directory) }
            while true {
                errno = 0
                guard let entry = readdir(directory) else { if errno != 0 { throw error(path: path) }; break }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                try remove(path + "/" + name, recursive: true, force: force, context: context)
            }
            try check(context, path: path)
            guard rmdir(path) == 0 else { if force && errno == ENOENT { return }; throw error(path: path) }
        } else if unlink(path) != 0 { if force && errno == ENOENT { return }; throw error(path: path) }
    }
    static func read(_ fd: Int32, offset: Int64, length: Int, path: String) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let count: Int = bytes.withUnsafeMutableBytes { buffer in
            while true {
                let count = pread(fd, buffer.baseAddress, length, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                return count
            }
        }
        guard count >= 0 else { throw error(path: path) }
        bytes.removeLast(length - count)
        return bytes
    }
    static func fullSyncError(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == 0 { return 0 }
        return errno
        #else
        return fsync(fd) == 0 ? 0 : errno
        #endif
    }
    static func syncError(_ fd: Int32) -> Int32 { fsync(fd) == 0 ? 0 : errno }
}

/// Test hooks keep I/O failures and cancellation tests independent of timing.
internal struct LocalFileIO: Sendable {
    var beforeRead: (@Sendable () async -> Void)?
    var fullSync: @Sendable (Int32) -> Int32 = LocalFS.fullSyncError
    var sync: @Sendable (Int32) -> Int32 = LocalFS.syncError
}
