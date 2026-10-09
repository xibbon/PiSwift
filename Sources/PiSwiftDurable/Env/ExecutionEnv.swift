import PiSwiftChord

/// The kind of a file-system entry.
public enum FileKind: String, Sendable {
    /// A regular file.
    case file
    /// A directory.
    case directory
    /// A symbolic link.
    case symlink
}
/// A stable code for an expected file-system failure.
public enum FileErrorCode: String, Sendable {
    /// The operation was cancelled.
    case aborted
    /// The path was not found.
    case notFound = "not_found"
    /// The operation lacks file permissions.
    case permissionDenied = "permission_denied"
    /// The path is not a directory.
    case notDirectory = "not_directory"
    /// The path is a directory where a file is required.
    case isDirectory = "is_directory"
    /// The input is invalid.
    case invalid
    /// The environment does not support the operation.
    case notSupported = "not_supported"
    /// An unclassified failure.
    case unknown
}
/// An expected file-system failure with optional path and cause.
public struct FileError: Error, Sendable, CustomStringConvertible {
    /// The stable failure code.
    public let code: FileErrorCode
    /// The failure text.
    public let message: String
    /// The failure text for diagnostics.
    public var description: String { message }
    /// The file-system path.
    public let path: String?
    /// The underlying error, when available.
    public let cause: (any Error)?
    /// Creates FileError with the supplied values.
    public init(_ code: FileErrorCode, message: String, path: String? = nil, cause: (any Error)? = nil) {
        self.code = code; self.message = message; self.path = path; self.cause = cause
    }
}
/// A stable code for an expected command failure.
public enum ExecutionErrorCode: String, Sendable {
    /// The operation was cancelled.
    case aborted
    /// The command exceeded its timeout.
    case timeout
    /// The environment has no shell.
    case shellUnavailable = "shell_unavailable"
    /// The command could not start.
    case spawnError = "spawn_error"
    /// The output callback failed.
    case callbackError = "callback_error"
    /// An unclassified failure.
    case unknown
}
/// An expected command failure with optional cause and output spill path.
public struct ExecutionError: Error, Sendable, CustomStringConvertible {
    /// The stable failure code.
    public let code: ExecutionErrorCode
    /// The failure text.
    public let message: String
    /// The failure text for diagnostics.
    public var description: String { message }
    /// The underlying error, when available.
    public let cause: (any Error)?
    /// The path that contains spilled command output, when available.
    public var spillPath: String?
    /// Creates ExecutionError with the supplied values.
    public init(_ code: ExecutionErrorCode, message: String, cause: (any Error)? = nil, spillPath: String? = nil) {
        self.code = code; self.message = message; self.cause = cause; self.spillPath = spillPath
    }
}
/// Metadata for one file-system entry. Sizes are bytes; times are milliseconds.
public struct FileInfo: Sendable, Equatable {
    /// The entry name.
    public var name: String
    /// The file-system path.
    public var path: String
    /// The entry kind.
    public var kind: FileKind
    /// The file size in bytes.
    public var size: Int64
    /// The last modification time in milliseconds.
    public var mtimeMs: Int64
    /// Creates FileInfo with the supplied values.
    public init(name: String, path: String, kind: FileKind, size: Int64, mtimeMs: Int64) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.mtimeMs = mtimeMs
    }
}
/// One text line without its newline terminator.
public struct TextLine: Sendable, Equatable {
    /// The line text without its terminator.
    public var text: String
    /// Whether a newline terminated this line.
    public var terminated: Bool
    /// Creates TextLine with the supplied values.
    public init(text: String, terminated: Bool) { self.text = text; self.terminated = terminated }
}
/// An opened sequential text reader. The owner must close it.
public protocol TextLineReader: Sendable {
    /// Reads the next line, or returns nil at end of file.
    func readLine(context: ChordContext) async -> Result<TextLine?, FileError>
    /// Closes this reader or watcher and releases its resources.
    func close(context: ChordContext) async
}
/// The line interval to locate in an opened binary file.
public struct ScanLinesOptions: Sendable {
    /// The first selected line.
    public var startLine: Int
    /// The last selected line, when supplied.
    public var endLine: Int?
    /// Creates ScanLinesOptions with the supplied values.
    public init(startLine: Int, endLine: Int? = nil) { self.startLine = startLine; self.endLine = endLine }
}
/// Byte offsets and line counts from a binary line scan.
public struct LineScan: Sendable, Equatable {
    /// The number of newline characters in the scan.
    public var newlines: Int
    /// The byte offset at the start of the selected range.
    public var start: Int64
    /// The byte offset after the selected range.
    public var end: Int64
    /// The byte offset after the first line.
    public var firstLineEnd: Int64
    /// The byte offset at the start of the last line.
    public var lastLineStart: Int64
    /// The number of bytes in the selected range.
    public var selectedBytes: Int64
    /// The number of bytes in the first line.
    public var firstLineBytes: Int64
    /// Creates LineScan with the supplied values.
    public init(newlines: Int, start: Int64, end: Int64, firstLineEnd: Int64, lastLineStart: Int64, selectedBytes: Int64, firstLineBytes: Int64) {
        self.newlines = newlines; self.start = start; self.end = end; self.firstLineEnd = firstLineEnd
        self.lastLineStart = lastLineStart; self.selectedBytes = selectedBytes; self.firstLineBytes = firstLineBytes
    }
}
/// An opened file for byte-range reads and line scans.
public protocol BinaryReader: Sendable {
    /// Returns metadata for the opened file.
    func info(context: ChordContext) async -> Result<FileInfo, FileError>
    /// Reads up to length bytes at the supplied byte offset.
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError>
    /// Finds byte ranges and line counts for the selected lines.
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError>
    /// Closes this reader or watcher and releases its resources.
    func close(context: ChordContext) async
}
/// Optional hidden-file and name exclusions for a watch.
public struct WatchExclude: Sendable {
    /// Whether hidden entries are excluded.
    public var hidden: Bool?
    /// The entry names to exclude.
    public var names: [String]?
    /// Creates WatchExclude with the supplied values.
    public init(hidden: Bool? = nil, names: [String]? = nil) { self.hidden = hidden; self.names = names }
}
/// One path and its optional recursive watch settings.
public struct WatchTarget: Sendable {
    /// The file-system path.
    public var path: String
    /// Whether the operation includes child directories.
    public var recursive: Bool?
    /// The exclusions applied to this watch target.
    public var exclude: WatchExclude?
    /// Creates WatchTarget with the supplied values.
    public init(path: String, recursive: Bool? = nil, exclude: WatchExclude? = nil) {
        self.path = path; self.recursive = recursive; self.exclude = exclude
    }
}
/// A file watch notification; overflow requires a fresh scan.
public enum WatchChange: Sendable {
    /// The supplied paths changed.
    case paths([String])
    /// Changes were lost; scan the watched paths again.
    case overflow
    /// The file watch failed.
    case error(FileError)
}
/// The mechanism used by a file watcher.
public enum WatchMode: String, Sendable {
    /// The watch uses native file-system notifications.
    case native
    /// The watch checks for changes by polling.
    case polling
}
/// An active file watch that the owner must close.
public protocol FileWatcher: Sendable {
    /// The watch mechanism used by this implementation.
    var mode: WatchMode { get }
    /// Closes this reader or watcher and releases its resources.
    func close(context: ChordContext) async
}
/// One page from an opened directory reader.
public struct DirectoryPage: Sendable {
    /// The entries in this page.
    public var entries: [FileInfo]
    /// Whether no more directory entries remain.
    public var done: Bool
    /// Creates DirectoryPage with the supplied values.
    public init(entries: [FileInfo], done: Bool) { self.entries = entries; self.done = done }
}
/// An opened paged directory reader. The owner must close it.
public protocol DirReader: Sendable {
    /// Reads the next page, with at most maxEntries entries.
    func next(maxEntries: Int, context: ChordContext) async -> Result<DirectoryPage, FileError>
    /// Closes this reader or watcher and releases its resources.
    func close(context: ChordContext) async
}
/// Text or binary data to write to a file.
public enum FileContent: Sendable {
    /// UTF-8 text content.
    case text(String)
    /// Binary file content.
    case bytes([UInt8])
}
/// An optional maximum number of text lines to read.
public struct ReadTextLinesOptions: Sendable {
    /// The maximum number of lines to read or deliver.
    public var maxLines: Int?
    /// Creates ReadTextLinesOptions with the supplied values.
    public init(maxLines: Int? = nil) { self.maxLines = maxLines }
}
/// Options for opening a binary reader.
public struct OpenBinaryReaderOptions: Sendable {
    /// Whether opening a reader must reject a symbolic link.
    public var noFollow: Bool?
    /// Creates OpenBinaryReaderOptions with the supplied values.
    public init(noFollow: Bool? = nil) { self.noFollow = noFollow }
}
/// Options for directory creation.
public struct CreateDirOptions: Sendable {
    /// Whether the operation includes child directories.
    public var recursive: Bool?
    /// Creates CreateDirOptions with the supplied values.
    public init(recursive: Bool? = nil) { self.recursive = recursive }
}
/// Options for file or directory removal.
public struct RemoveOptions: Sendable {
    /// Whether the operation includes child directories.
    public var recursive: Bool?
    /// Whether removal ignores an absent path.
    public var force: Bool?
    /// Creates RemoveOptions with the supplied values.
    public init(recursive: Bool? = nil, force: Bool? = nil) { self.recursive = recursive; self.force = force }
}
/// Optional prefix and suffix for a temporary file name.
public struct CreateTempFileOptions: Sendable {
    /// The optional prefix for the temporary name.
    public var prefix: String?
    /// The optional suffix for the temporary name.
    public var suffix: String?
    /// Creates CreateTempFileOptions with the supplied values.
    public init(prefix: String? = nil, suffix: String? = nil) { self.prefix = prefix; self.suffix = suffix }
}
/// Expected file failures are values. The owner supplies an implementation.
public protocol FileSystem: Sendable {
    /// The stable environment identity; equal identities must refer to the same files.
    var id: String { get }
    /// The working directory for relative paths.
    var cwd: String { get set }
    /// Resolves a path against the current working directory.
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError>
    /// Joins path components with the environment path rules.
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError>
    /// Reads a file as text.
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError>
    /// Opens a sequential text-line reader.
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError>
    /// Reads text lines with an optional line limit.
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError>
    /// Reads all file bytes.
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError>
    /// Opens a file for byte-range reads and line scans.
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError>
    /// Replaces a file with the supplied content.
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError>
    /// Appends content to a file.
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError>
    /// Changes the file length to the supplied byte count.
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError>
    /// Flushes pending file data through the environment.
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError>
    /// Renames a file to the destination path.
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError>
    /// Returns metadata for the supplied path.
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError>
    /// Returns the entries in a directory.
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError>
    /// Opens a paged directory reader.
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError>
    /// Starts a watch and delivers path changes, overflow, or errors.
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError>
    /// Resolves the canonical path through the environment.
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError>
    /// Returns whether the supplied path exists.
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError>
    /// Creates a directory with optional recursive parent creation.
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError>
    /// Removes a file or directory under the supplied options.
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError>
    /// Creates a temporary directory and returns its path.
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError>
    /// Creates a temporary file and returns its path.
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError>
    /// Releases resources owned by this environment.
    func cleanup(context: ChordContext) async
}
/// Output thresholds after which the environment can spill output to a file.
public struct ShellSpillOptions: Sendable {
    /// The output byte threshold for spilling.
    public var afterBytes: Int
    /// The output line threshold for spilling.
    public var afterLines: Int
    /// Creates ShellSpillOptions with the supplied values.
    public init(afterBytes: Int, afterLines: Int) { self.afterBytes = afterBytes; self.afterLines = afterLines }
}
/// The command exit code and optional output spill path.
public struct ShellExecResult: Sendable, Equatable {
    /// The command exit code.
    public var exitCode: Int
    /// The path that contains spilled command output, when available.
    public var spillPath: String?
    /// Creates ShellExecResult with the supplied values.
    public init(exitCode: Int, spillPath: String? = nil) { self.exitCode = exitCode; self.spillPath = spillPath }
}
/// Limits and pacing for the delivered command output window.
public struct ShellOutputWindow: Sendable, Equatable {
    /// The maximum number of output bytes to deliver.
    public var maxBytes: Int
    /// The maximum number of lines to read or deliver.
    public var maxLines: Int
    /// The minimum interval between output deliveries, in milliseconds.
    public var minIntervalMs: Int64
    /// The maximum delivered output byte rate.
    public var bytesPerSecond: Int
    /// Creates ShellOutputWindow with the supplied values.
    public init(maxBytes: Int, maxLines: Int, minIntervalMs: Int64, bytesPerSecond: Int) {
        self.maxBytes = maxBytes; self.maxLines = maxLines; self.minIntervalMs = minIntervalMs; self.bytesPerSecond = bytesPerSecond
    }
}
/// The counts and newline state of omitted output.
public struct ShellOutputSkip: Sendable, Equatable {
    /// The number of omitted output bytes.
    public var bytes: Int
    /// The number of newline characters in the omitted output.
    public var newlines: Int
    /// Whether the omitted output ends with a newline.
    public var endsWithNewline: Bool
    /// Creates ShellOutputSkip with the supplied values.
    public init(bytes: Int, newlines: Int, endsWithNewline: Bool) { self.bytes = bytes; self.newlines = newlines; self.endsWithNewline = endsWithNewline }
}
/// The command stream that produced an output chunk.
public enum ShellOutputStream: String, Sendable {
    /// Standard output.
    case stdout
    /// Standard error.
    case stderr
}
/// The stream and optional skipped-output metadata for a chunk.
public struct ShellOutputInfo: Sendable {
    /// The stream that produced this output.
    public var stream: ShellOutputStream
    /// The omitted-output metadata, when present.
    public var skipped: ShellOutputSkip?
    /// Creates ShellOutputInfo with the supplied values.
    public init(stream: ShellOutputStream, skipped: ShellOutputSkip? = nil) { self.stream = stream; self.skipped = skipped }
}
/// Per-command working directory, environment, timeout and output settings.
public struct ShellExecOptions: Sendable {
    /// The working directory for relative paths.
    public var cwd: String?
    /// The environment variables supplied to the command.
    public var env: [String: String]?
    /// Whether the command inherits the host environment.
    public var inheritEnv: Bool?
    /// The command timeout in milliseconds.
    public var timeout: Int64?
    /// Receives output chunks with their context and stream metadata.
    public var onOutput: (@Sendable (String, ChordContext, ShellOutputInfo) throws -> Void)?
    /// The optional thresholds for output spill files.
    public var spill: ShellSpillOptions?
    /// The optional output window and pacing limits.
    public var window: ShellOutputWindow?
    /// Creates ShellExecOptions with the supplied values.
    public init(cwd: String? = nil, env: [String: String]? = nil, inheritEnv: Bool? = nil, timeout: Int64? = nil,
                onOutput: (@Sendable (String, ChordContext, ShellOutputInfo) throws -> Void)? = nil,
                spill: ShellSpillOptions? = nil, window: ShellOutputWindow? = nil) {
        self.cwd = cwd; self.env = env; self.inheritEnv = inheritEnv; self.timeout = timeout
        self.onOutput = onOutput; self.spill = spill; self.window = window
    }
}
/// A shell expression or an argument vector for direct execution.
public enum ShellCommand: Sendable {
    /// A command expression interpreted by a shell.
    case shell(String)
    /// An argument vector executed without shell interpretation.
    case argv([String])
}
/// An application-supplied command executor.
public protocol Shell: Sendable {
    /// Executes a shell expression or argument vector and reports its exit status.
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError>
    /// Releases resources owned by this environment.
    func cleanup(context: ChordContext) async
}
/// An application-supplied file system and command executor.
public protocol ExecutionEnv: FileSystem, Shell {}

/// Built-in tools use this ordinary error when the call has no environment.
public struct NoExecutionEnvironmentError: Error, Sendable, CustomStringConvertible {
    /// Creates the missing-environment error.
    public init() {}
    /// The failure text for diagnostics.
    public var description: String { "No execution environment is configured" }
}
