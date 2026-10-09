import Foundation
import Synchronization
import PiSwiftChord
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Options for snapshot-based local file watches.
public struct LocalWatchOptions: Sendable {
    /// The requested mechanism. Nil selects the platform default.
    public var mode: WatchMode?
    /// The interval between polling scans, in milliseconds.
    public var pollIntervalMs: Int
    /// The maximum number of distinct target directories in one scan.
    public var maxDirectories: Int
    /// Creates watch options. Native watches are the default on macOS; iOS uses polling.
    public init(mode: WatchMode? = nil, pollIntervalMs: Int = 2000, maxDirectories: Int = 10_000) {
        self.mode = mode; self.pollIntervalMs = pollIntervalMs; self.maxDirectories = maxDirectories
    }
}

/// A local file environment for macOS and iOS. Opened handles belong to their caller.
public final class LocalExecutionEnv: ExecutionEnv {
    /// Equal local identities refer to the same host file system.
    public let id = "local"
    private let workingDirectory: Mutex<String>
    private let watchOptions: LocalWatchOptions
    #if os(macOS)
    private let shell: LocalShell
    #endif
    private let io: LocalFileIO
    /// The working directory used to resolve relative paths.
    public var cwd: String {
        get { workingDirectory.withLock { $0 } }
        set { workingDirectory.withLock { $0 = newValue } }
    }
    /// Creates a local environment. Relative paths use the supplied working directory.
    public init(cwd: String = FileManager.default.currentDirectoryPath, watch: LocalWatchOptions = .init(),
                shellPath: String? = nil, shellEnv: [String: String]? = nil) {
        workingDirectory = Mutex(cwd); watchOptions = watch; io = LocalFileIO()
        #if os(macOS)
        shell = LocalShell(shellPath: shellPath, shellEnv: shellEnv)
        #endif
    }
    internal init(cwd: String, watch: LocalWatchOptions = .init(), io: LocalFileIO) {
        workingDirectory = Mutex(cwd); watchOptions = watch; self.io = io
        #if os(macOS)
        shell = LocalShell()
        #endif
    }
    #if os(macOS)
    internal init(cwd: String, shellPath: String? = nil, shellEnv: [String: String]? = nil, shellIO: LocalShellIO,
                  shellHooks: LocalShellHooks = .init()) {
        workingDirectory = Mutex(cwd); watchOptions = .init(); io = LocalFileIO()
        shell = LocalShell(shellPath: shellPath, shellEnv: shellEnv, io: shellIO, hooks: shellHooks)
    }
    internal convenience init(cwd: String, shellHooks: LocalShellHooks) {
        self.init(cwd: cwd, shellIO: .init(), shellHooks: shellHooks)
    }
    #endif
    private func resolve(_ path: String) -> String { LocalFS.resolve(path, cwd: cwd) }
    /// Executes a command on macOS. iOS returns shellUnavailable.
    /// The local environment ignores window and reports every decoded chunk.
    /// Spill files are not deleted, as in upstream NodeExecutionEnv. The caller owns each spill file.
    public func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> {
        #if os(macOS)
        return await shell.exec(command, cwd: cwd, options: options, context: context)
        #else
        return .failure(ExecutionError(.shellUnavailable, message: "Shell execution is unavailable"))
        #endif
    }
    /// Resolves home paths, file URLs, and relative paths.
    public func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        LocalFS.result { try LocalFS.check(context); return resolve(path) }
    }
    /// Joins components with POSIX path rules, without resolving against cwd.
    public func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> {
        LocalFS.result {
            try LocalFS.check(context)
            let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
            let normalized = LocalFS.normalize(joined)
            return joined.hasSuffix("/") && normalized != "/" ? normalized + "/" : normalized
        }
    }
    /// Reads all bytes and decodes UTF-8, with replacement for malformed input.
    public func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        await readBinaryFile(path, context: context).map {
            var decoder = rangeDecoder()
            return decoder.decode($0) + decoder.decode()
        }
    }
    /// Reads all bytes from a path. This also supports readable POSIX device files.
    public func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            let fd = open(resolved, O_RDONLY)
            guard fd >= 0 else { throw LocalFS.error(path: resolved) }
            defer { _ = close(fd) }
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try LocalFS.check(context, path: resolved)
                let count = chunk.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress!, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LocalFS.error(path: resolved) }
                try LocalFS.check(context, path: resolved)
                if count == 0 { return bytes }
                bytes.append(contentsOf: chunk.prefix(count))
            }
        }
    }
    /// Opens a strict LF text reader. A leading UTF-8 BOM is removed.
    public func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            let fd = open(resolved, O_RDONLY)
            guard fd >= 0 else { throw LocalFS.error(path: resolved) }
            do { try LocalFS.check(context, path: resolved) }
            catch { _ = close(fd); throw error }
            return LocalTextLineReader(fd: fd, path: resolved, io: io)
        }
    }
    /// Reads at most maxLines lines. Line terminators are removed.
    public func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> {
        if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "aborted", path: resolve(path))) }
        if let limit = options?.maxLines, limit <= 0 { return .success([]) }
        switch await openTextLineReader(path, context: context) {
        case .failure(let error): return .failure(error)
        case .success(let reader):
            var lines: [String] = []
            var failure: FileError?
            while options?.maxLines == nil || lines.count < options!.maxLines! {
                switch await reader.readLine(context: context) {
                case .failure(let error): failure = error
                case .success(let line): if let line { lines.append(line.text); continue }
                }
                break
            }
            await reader.close(context: context)
            return failure.map { .failure($0) } ?? .success(lines)
        }
    }
    /// Opens a binary reader without blocking on a FIFO. noFollow rejects a final symlink.
    public func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            let noFollow = options?.noFollow == true
            let fd = open(resolved, O_RDONLY | O_NONBLOCK | (noFollow ? O_NOFOLLOW : 0))
            guard fd >= 0 else {
                if noFollow && (errno == ELOOP || errno == EMLINK) { throw FileError(.invalid, message: "Symbolic link refused", path: resolved) }
                throw LocalFS.error(path: resolved)
            }
            do {
                var value = stat()
                guard fstat(fd, &value) == 0 else { throw LocalFS.error(path: resolved) }
                let kind = value.st_mode & mode_t(S_IFMT)
                guard kind == mode_t(S_IFREG) else {
                    throw FileError(kind == mode_t(S_IFDIR) ? .isDirectory : .invalid, message: "Not a regular file", path: resolved)
                }
                try LocalFS.check(context, path: resolved)
                return LocalBinaryReader(fd: fd, path: resolved, io: io)
            } catch { _ = close(fd); throw error }
        }
    }
    private func write(_ path: String, content: FileContent, append: Bool, context: ChordContext) -> Result<Void, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            try LocalFS.mkdirs(LocalFS.parent(resolved), recursive: true, context: context)
            try LocalFS.check(context, path: resolved)
            let fd = open(resolved, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o666)
            guard fd >= 0 else { throw LocalFS.error(path: resolved) }
            defer { _ = close(fd) }
            let bytes: [UInt8]
            switch content { case .text(let text): bytes = Array(text.utf8); case .bytes(let value): bytes = value }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    try LocalFS.check(context, path: resolved)
                    let count = systemWrite(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw LocalFS.error(count == 0 ? EIO : errno, path: resolved) }
                    offset += count
                }
            }
            try LocalFS.check(context, path: resolved)
        }
    }
    /// Writes bytes and creates parent directories when needed.
    public func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { write(path, content: content, append: false, context: context) }
    /// Appends bytes and creates parent directories when needed.
    public func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { write(path, content: content, append: true, context: context) }
    /// Changes a file's byte size. It does not create a missing file.
    public func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            guard size >= 0, size <= LocalFS.maxSafeInteger else { throw FileError(.invalid, message: "File size must be a non-negative safe integer", path: resolved) }
            let fd = open(resolved, O_RDWR)
            guard fd >= 0 else { throw LocalFS.error(path: resolved) }
            defer { _ = close(fd) }
            guard ftruncate(fd, off_t(size)) == 0 else { throw LocalFS.error(path: resolved) }
            try LocalFS.check(context, path: resolved)
        }
    }
    /// Flushes through an opened handle. Apple file systems use F_FULLFSYNC first.
    public func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            let fd = open(resolved, O_RDWR)
            guard fd >= 0 else { throw LocalFS.error(path: resolved) }
            defer { _ = close(fd) }
            var number = io.fullSync(fd)
            // A file system that cannot provide a full sync can still provide fsync.
            if number == EINVAL || number == ENOTSUP || number == ENOSYS || number == ENOTTY { number = io.sync(fd) }
            guard number == 0 else { throw LocalFS.error(number, path: resolved) }
            try LocalFS.check(context, path: resolved)
        }
    }
    /// Renames with rename(2), which can replace an existing destination atomically.
    public func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> {
        let base = cwd
        let source = LocalFS.resolve(sourcePath, cwd: base), destination = LocalFS.resolve(destinationPath, cwd: base)
        return LocalFS.result {
            try LocalFS.check(context, path: destination)
            try LocalFS.check(context, path: source)
            guard rename(source, destination) == 0 else { throw LocalFS.error(path: source) }
        }
    }
    /// Returns lstat metadata, without following a symlink.
    public func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> {
        let resolved = resolve(path)
        return LocalFS.result { try LocalFS.check(context, path: resolved); return try LocalFS.info(resolved, stats: LocalFS.stats(resolved)) }
    }
    /// Lists supported entry kinds in a directory.
    public func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> {
        switch await openDirReader(path, context: context) {
        case .failure(let error): return .failure(error)
        case .success(let reader):
            var entries: [FileInfo] = []
            while true {
                switch await reader.next(maxEntries: 256, context: context) {
                case .failure(let error): await reader.close(context: context); return .failure(error)
                case .success(let page): entries += page.entries
                    if page.done { await reader.close(context: context); return .success(entries) }
                }
            }
        }
    }
    /// Opens a paged POSIX directory reader.
    public func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            guard let directory = opendir(resolved) else { throw LocalFS.error(path: resolved) }
            do { try LocalFS.check(context, path: resolved) }
            catch { closedir(directory); throw error }
            return LocalDirReader(directory: directory, path: resolved)
        }
    }
    /// Starts a snapshot watch. iOS uses polling, including when native mode is requested.
    public func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> {
        let base = cwd
        let resolved = targets.map { WatchTarget(path: LocalFS.resolve($0.path, cwd: base), recursive: $0.recursive, exclude: $0.exclude) }
        return await LocalFileWatcher.start(targets: resolved, mode: watchOptions.mode, maxDirectories: watchOptions.maxDirectories,
                                            pollIntervalMilliseconds: watchOptions.pollIntervalMs, onChange: onChange, context: context)
    }
    /// Resolves the canonical file path, including symbolic links.
    public func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        let resolved = resolve(path)
        return LocalFS.result {
            try LocalFS.check(context, path: resolved)
            guard let pointer = realpath(resolved, nil) else { throw LocalFS.error(path: resolved) }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }
    /// Tests entry existence. A dangling symlink exists.
    public func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> {
        switch await fileInfo(path, context: context) {
        case .success: return .success(true)
        case .failure(let error): return error.code == .notFound ? .success(false) : .failure(error)
        }
    }
    /// Creates a directory. Parent creation is enabled by default.
    public func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> {
        LocalFS.result { try LocalFS.mkdirs(resolve(path), recursive: options?.recursive ?? true, context: context) }
    }
    /// Removes a path under the supplied recursive and force settings.
    public func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> {
        LocalFS.result { try LocalFS.remove(resolve(path), recursive: options?.recursive ?? false, force: options?.force ?? false, context: context) }
    }
    /// Creates a temporary directory. Its caller must remove it.
    public func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> {
        LocalFS.result {
            try LocalFS.check(context)
            let joined = FileManager.default.temporaryDirectory.path + "/" + (prefix ?? "tmp-")
            let base = LocalFS.normalize(joined) + (joined.hasSuffix("/") ? "/" : "")
            try LocalFS.check(context, path: base)
            var template = Array((base + "XXXXXX").utf8CString)
            return try template.withUnsafeMutableBufferPointer { buffer in
                guard let pointer = mkdtemp(buffer.baseAddress!) else { throw LocalFS.error() }
                return String(cString: pointer)
            }
        }
    }
    /// Creates an empty temporary file in its own temporary directory.
    public func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> {
        switch await createTempDir(prefix: "tmp-", context: context) {
        case .failure(let error): return .failure(error)
        case .success(let directory):
            let path = LocalFS.normalize(directory + "/" + (options?.prefix ?? "") + UUID().uuidString.lowercased() + (options?.suffix ?? ""))
            return LocalFS.result {
                try LocalFS.check(context, path: path)
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
                guard fd >= 0 else { throw LocalFS.error(path: path) }
                _ = close(fd)
                return path
            }
        }
    }
    /// Releases environment-owned resources. Callers close their own readers and watchers.
    public func cleanup(context: ChordContext) async {
        #if os(macOS)
        shell.cleanup()
        #endif
    }
}

private func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ length: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, bytes, length)
    #else
    Glibc.write(fd, bytes, length)
    #endif
}

private func systemRead(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ length: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, bytes, length)
    #else
    Glibc.read(fd, bytes, length)
    #endif
}
