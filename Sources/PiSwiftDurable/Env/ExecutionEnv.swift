import PiSwiftChord

public enum FileKind: String, Sendable { case file, directory, symlink }
public enum FileErrorCode: String, Sendable {
    case aborted, notFound = "not_found", permissionDenied = "permission_denied"
    case notDirectory = "not_directory", isDirectory = "is_directory", invalid
    case notSupported = "not_supported", unknown
}
public struct FileError: Error, Sendable, CustomStringConvertible {
    public let code: FileErrorCode
    public let message: String
    public var description: String { message }
    public let path: String?
    public let cause: (any Error)?
    public init(_ code: FileErrorCode, message: String, path: String? = nil, cause: (any Error)? = nil) {
        self.code = code; self.message = message; self.path = path; self.cause = cause
    }
}
public enum ExecutionErrorCode: String, Sendable {
    case aborted, timeout, shellUnavailable = "shell_unavailable", spawnError = "spawn_error"
    case callbackError = "callback_error", unknown
}
public struct ExecutionError: Error, Sendable, CustomStringConvertible {
    public let code: ExecutionErrorCode
    public let message: String
    public var description: String { message }
    public let cause: (any Error)?
    public var spillPath: String?
    public init(_ code: ExecutionErrorCode, message: String, cause: (any Error)? = nil, spillPath: String? = nil) {
        self.code = code; self.message = message; self.cause = cause; self.spillPath = spillPath
    }
}
public struct FileInfo: Sendable, Equatable {
    public var name: String
    public var path: String
    public var kind: FileKind
    public var size: Int64
    public var mtimeMs: Int64
    public init(name: String, path: String, kind: FileKind, size: Int64, mtimeMs: Int64) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.mtimeMs = mtimeMs
    }
}
public struct TextLine: Sendable, Equatable {
    public var text: String
    public var terminated: Bool
    public init(text: String, terminated: Bool) { self.text = text; self.terminated = terminated }
}
public protocol TextLineReader: Sendable {
    func readLine(context: ChordContext) async -> Result<TextLine?, FileError>
    func close(context: ChordContext) async
}
public struct ScanLinesOptions: Sendable {
    public var startLine: Int
    public var endLine: Int?
    public init(startLine: Int, endLine: Int? = nil) { self.startLine = startLine; self.endLine = endLine }
}
public struct LineScan: Sendable, Equatable {
    public var newlines: Int
    public var start: Int64
    public var end: Int64
    public var firstLineEnd: Int64
    public var lastLineStart: Int64
    public var selectedBytes: Int64
    public var firstLineBytes: Int64
    public init(newlines: Int, start: Int64, end: Int64, firstLineEnd: Int64, lastLineStart: Int64, selectedBytes: Int64, firstLineBytes: Int64) {
        self.newlines = newlines; self.start = start; self.end = end; self.firstLineEnd = firstLineEnd
        self.lastLineStart = lastLineStart; self.selectedBytes = selectedBytes; self.firstLineBytes = firstLineBytes
    }
}
public protocol BinaryReader: Sendable {
    func info(context: ChordContext) async -> Result<FileInfo, FileError>
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError>
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError>
    func close(context: ChordContext) async
}
public struct WatchExclude: Sendable {
    public var hidden: Bool?
    public var names: [String]?
    public init(hidden: Bool? = nil, names: [String]? = nil) { self.hidden = hidden; self.names = names }
}
public struct WatchTarget: Sendable {
    public var path: String
    public var recursive: Bool?
    public var exclude: WatchExclude?
    public init(path: String, recursive: Bool? = nil, exclude: WatchExclude? = nil) {
        self.path = path; self.recursive = recursive; self.exclude = exclude
    }
}
public enum WatchChange: Sendable { case paths([String]), overflow, error(FileError) }
public enum WatchMode: String, Sendable { case native, polling }
public protocol FileWatcher: Sendable {
    var mode: WatchMode { get }
    func close(context: ChordContext) async
}
public struct DirectoryPage: Sendable {
    public var entries: [FileInfo]
    public var done: Bool
    public init(entries: [FileInfo], done: Bool) { self.entries = entries; self.done = done }
}
public protocol DirReader: Sendable {
    func next(maxEntries: Int, context: ChordContext) async -> Result<DirectoryPage, FileError>
    func close(context: ChordContext) async
}
public enum FileContent: Sendable { case text(String), bytes([UInt8]) }
public struct ReadTextLinesOptions: Sendable {
    public var maxLines: Int?
    public init(maxLines: Int? = nil) { self.maxLines = maxLines }
}
public struct OpenBinaryReaderOptions: Sendable {
    public var noFollow: Bool?
    public init(noFollow: Bool? = nil) { self.noFollow = noFollow }
}
public struct CreateDirOptions: Sendable {
    public var recursive: Bool?
    public init(recursive: Bool? = nil) { self.recursive = recursive }
}
public struct RemoveOptions: Sendable {
    public var recursive: Bool?
    public var force: Bool?
    public init(recursive: Bool? = nil, force: Bool? = nil) { self.recursive = recursive; self.force = force }
}
public struct CreateTempFileOptions: Sendable {
    public var prefix: String?
    public var suffix: String?
    public init(prefix: String? = nil, suffix: String? = nil) { self.prefix = prefix; self.suffix = suffix }
}
/// Expected file failures are values. The owner supplies an implementation.
public protocol FileSystem: Sendable {
    var id: String { get }
    var cwd: String { get set }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError>
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError>
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError>
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError>
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError>
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError>
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError>
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError>
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError>
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError>
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError>
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError>
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError>
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError>
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError>
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError>
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError>
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError>
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError>
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError>
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError>
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError>
    func cleanup(context: ChordContext) async
}
public struct ShellSpillOptions: Sendable {
    public var afterBytes: Int
    public var afterLines: Int
    public init(afterBytes: Int, afterLines: Int) { self.afterBytes = afterBytes; self.afterLines = afterLines }
}
public struct ShellExecResult: Sendable, Equatable {
    public var exitCode: Int
    public var spillPath: String?
    public init(exitCode: Int, spillPath: String? = nil) { self.exitCode = exitCode; self.spillPath = spillPath }
}
public struct ShellOutputWindow: Sendable, Equatable {
    public var maxBytes: Int
    public var maxLines: Int
    public var minIntervalMs: Int64
    public var bytesPerSecond: Int
    public init(maxBytes: Int, maxLines: Int, minIntervalMs: Int64, bytesPerSecond: Int) {
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.minIntervalMs = minIntervalMs; self.bytesPerSecond = bytesPerSecond
    }
}
public struct ShellOutputSkip: Sendable, Equatable {
    public var bytes: Int
    public var newlines: Int
    public var endsWithNewline: Bool
    public init(bytes: Int, newlines: Int, endsWithNewline: Bool) { self.bytes = bytes; self.newlines = newlines; self.endsWithNewline = endsWithNewline }
}
public enum ShellOutputStream: String, Sendable { case stdout, stderr }
public struct ShellOutputInfo: Sendable {
    public var stream: ShellOutputStream
    public var skipped: ShellOutputSkip?
    public init(stream: ShellOutputStream, skipped: ShellOutputSkip? = nil) { self.stream = stream; self.skipped = skipped }
}
public struct ShellExecOptions: Sendable {
    public var cwd: String?
    public var env: [String: String]?
    public var inheritEnv: Bool?
    public var timeout: Int64?
    public var onOutput: (@Sendable (String, ChordContext, ShellOutputInfo) throws -> Void)?
    public var spill: ShellSpillOptions?
    public var window: ShellOutputWindow?
    public init(cwd: String? = nil, env: [String: String]? = nil, inheritEnv: Bool? = nil, timeout: Int64? = nil,
                onOutput: (@Sendable (String, ChordContext, ShellOutputInfo) throws -> Void)? = nil,
                spill: ShellSpillOptions? = nil, window: ShellOutputWindow? = nil) {
        self.cwd = cwd; self.env = env; self.inheritEnv = inheritEnv; self.timeout = timeout
        self.onOutput = onOutput; self.spill = spill; self.window = window
    }
}
public enum ShellCommand: Sendable { case shell(String), argv([String]) }
public protocol Shell: Sendable {
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError>
    func cleanup(context: ChordContext) async
}
public protocol ExecutionEnv: FileSystem, Shell {}

/// Built-in tools use this ordinary error when the call has no environment.
public struct NoExecutionEnvironmentError: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "No execution environment is configured" }
}
