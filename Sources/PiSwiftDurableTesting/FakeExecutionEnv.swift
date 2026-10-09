import Foundation
import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// An in-memory file system with scripted command results. It does not start a process.
public final class FakeExecutionEnv: ExecutionEnv {
    public typealias ExecStep = @Sendable (ShellCommand, ShellExecOptions?, PiSwiftChord.Context) async -> Result<ShellExecResult, ExecutionError>
    public struct ExecCall: Sendable {
        public let command: ShellCommand
        public let cwd: String
    }
    private struct State: Sendable {
        var cwd: String
        var files: [String: [UInt8]] = [:]
        var directories: Set<String> = ["/"]
        var steps: [ExecStep] = []
        var calls: [ExecCall] = []
        var nextTemp = 0
    }
    public let id: String
    private let state: Mutex<State>
    public init(cwd: String = "/", id: String = "fake", files: [String: String] = [:], exec: [ExecStep] = []) {
        self.id = id
        var initial = State(cwd: Self.normalize(cwd), steps: exec)
        var directory = initial.cwd
        repeat { initial.directories.insert(directory); directory = Self.parent(directory) } while directory != "/"
        for (path, text) in files {
            let absolute = Self.resolve(path, cwd: initial.cwd)
            initial.files[absolute] = Array(text.utf8)
            var parent = Self.parent(absolute)
            repeat { initial.directories.insert(parent); parent = Self.parent(parent) } while parent != "/"
        }
        state = Mutex(initial)
    }
    public var cwd: String {
        get { state.withLock { $0.cwd } }
        set { state.withLock { $0.cwd = Self.normalize(newValue) } }
    }
    public var execCalls: [ExecCall] { state.withLock { $0.calls } }
    public func appendExec(_ step: @escaping ExecStep) { state.withLock { $0.steps.append(step) } }
    public func exec(_ command: ShellCommand, options: ShellExecOptions?, context: PiSwiftChord.Context) async -> Result<ShellExecResult, ExecutionError> {
        if context.abortSignal?.aborted == true { return .failure(ExecutionError(.aborted, message: "Command aborted")) }
        let step = state.withLock { value -> ExecStep? in
            value.calls.append(ExecCall(command: command, cwd: options?.cwd ?? value.cwd))
            return value.steps.isEmpty ? nil : value.steps.removeFirst()
        }
        guard let step else { return .failure(ExecutionError(.spawnError, message: "No command result is queued")) }
        return await step(command, options, context)
    }
    private static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        return "/" + components.joined(separator: "/")
    }
    private static func resolve(_ path: String, cwd: String) -> String { normalize(path.hasPrefix("/") ? path : cwd + "/" + path) }
    private static func parent(_ path: String) -> String { normalize(path.split(separator: "/").dropLast().joined(separator: "/")) }
    private static func info(_ path: String, bytes: [UInt8]? = nil) -> FileInfo {
        FileInfo(name: path.split(separator: "/").last.map(String.init) ?? "/", path: path,
                 kind: bytes == nil ? .directory : .file, size: Int64(bytes?.count ?? 0), mtimeMs: 0)
    }
    private func missing<T>(_ path: String) -> Result<T, FileError> { .failure(FileError(.notFound, message: "File not found", path: path)) }
    private func cancelled<T>(_ context: PiSwiftChord.Context) -> Result<T, FileError>? {
        context.abortSignal?.aborted == true ? .failure(FileError(.aborted, message: "File operation aborted")) : nil
    }
    public func absolutePath(_ path: String, context: PiSwiftChord.Context) async -> Result<String, FileError> {
        cancelled(context) ?? .success(Self.resolve(path, cwd: cwd))
    }
    public func joinPath(_ parts: [String], context: PiSwiftChord.Context) async -> Result<String, FileError> {
        if let result: Result<String, FileError> = cancelled(context) { return result }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        let absolute = joined.hasPrefix("/")
        var components: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == "." { continue }
            if part == "..", let last = components.last, last != ".." { components.removeLast() }
            else if part != ".." || !absolute { components.append(part) }
        }
        let result = (absolute ? "/" : "") + components.joined(separator: "/")
        return .success(result.isEmpty ? "." : result)
    }
    public func readBinaryFile(_ path: String, context: PiSwiftChord.Context) async -> Result<[UInt8], FileError> {
        if let result: Result<[UInt8], FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return state.withLock { value in value.files[key].map(Result.success) ?? missing(key) }
    }
    public func readTextFile(_ path: String, context: PiSwiftChord.Context) async -> Result<String, FileError> {
        await readBinaryFile(path, context: context).map { String(decoding: $0, as: UTF8.self) }
    }
    public func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: PiSwiftChord.Context) async -> Result<[String], FileError> {
        if let maxLines = options?.maxLines, maxLines <= 0 { return .success([]) }
        return await readTextFile(path, context: context).map { text in
            let lines = FakeTextLineReader.lines(text).map(\.text)
            return Array(lines.prefix(options?.maxLines ?? lines.count))
        }
    }
    public func openTextLineReader(_ path: String, context: PiSwiftChord.Context) async -> Result<any TextLineReader, FileError> {
        await readTextFile(path, context: context).map { FakeTextLineReader($0) as any TextLineReader }
    }
    public func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: PiSwiftChord.Context) async -> Result<any BinaryReader, FileError> {
        let absolute = Self.resolve(path, cwd: cwd)
        return await readBinaryFile(path, context: context).map { FakeBinaryReader(bytes: $0, info: Self.info(absolute, bytes: $0)) as any BinaryReader }
    }
    private func bytes(_ content: FileContent) -> [UInt8] { switch content { case .text(let value): Array(value.utf8); case .bytes(let value): value } }
    public func writeFile(_ path: String, content: FileContent, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd), data = bytes(content)
        return state.withLock { value in
            guard value.directories.contains(Self.parent(key)) else { return missing(Self.parent(key)) }
            value.files[key] = data; return .success(())
        }
    }
    public func appendFile(_ path: String, content: FileContent, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd), data = bytes(content)
        return state.withLock { value in
            guard value.directories.contains(Self.parent(key)) else { return missing(Self.parent(key)) }
            value.files[key, default: []].append(contentsOf: data); return .success(())
        }
    }
    public func truncateFile(_ path: String, size: Int64, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        guard size >= 0, size <= Int64(Int.max) else { return .failure(FileError(.invalid, message: "Invalid file size")) }
        return state.withLock { value in
            guard var data = value.files[key] else { return missing(key) }
            if data.count > Int(size) { data.removeLast(data.count - Int(size)) }
            else { data.append(contentsOf: repeatElement(0, count: Int(size) - data.count)) }
            value.files[key] = data; return .success(())
        }
    }
    public func flushFile(_ path: String, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        await fileInfo(path, context: context).map { _ in () }
    }
    public func renameFile(_ sourcePath: String, destinationPath: String, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let source = Self.resolve(sourcePath, cwd: cwd), destination = Self.resolve(destinationPath, cwd: cwd)
        return state.withLock { value in
            guard let data = value.files[source] else { return missing(source) }
            guard value.directories.contains(Self.parent(destination)) else { return missing(Self.parent(destination)) }
            value.files.removeValue(forKey: source); value.files[destination] = data; return .success(())
        }
    }
    public func fileInfo(_ path: String, context: PiSwiftChord.Context) async -> Result<FileInfo, FileError> {
        if let result: Result<FileInfo, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return state.withLock { value in
            if let data = value.files[key] { return .success(Self.info(key, bytes: data)) }
            return value.directories.contains(key) ? .success(Self.info(key)) : missing(key)
        }
    }
    public func listDir(_ path: String, context: PiSwiftChord.Context) async -> Result<[FileInfo], FileError> {
        if let result: Result<[FileInfo], FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return state.withLock { value in
            guard value.directories.contains(key) else { return missing(key) }
            let files = value.files.filter { Self.parent($0.key) == key }.map { Self.info($0.key, bytes: $0.value) }
            let directories = value.directories.filter { $0 != key && Self.parent($0) == key }.map { Self.info($0) }
            return .success((files + directories).sorted { $0.path < $1.path })
        }
    }
    public func openDirReader(_ path: String, context: PiSwiftChord.Context) async -> Result<any DirReader, FileError> {
        await listDir(path, context: context).map { FakeDirReader($0) as any DirReader }
    }
    public func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: PiSwiftChord.Context) async -> Result<any FileWatcher, FileError> {
        .failure(FileError(.notSupported, message: "Fake file watches are not supported"))
    }
    public func canonicalPath(_ path: String, context: PiSwiftChord.Context) async -> Result<String, FileError> { await absolutePath(path, context: context) }
    public func exists(_ path: String, context: PiSwiftChord.Context) async -> Result<Bool, FileError> {
        if let result: Result<Bool, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return .success(state.withLock { $0.files[key] != nil || $0.directories.contains(key) })
    }
    public func createDir(_ path: String, options: CreateDirOptions?, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return state.withLock { value in
            if options?.recursive != true && !value.directories.contains(Self.parent(key)) { return missing(Self.parent(key)) }
            var parent = key
            repeat { value.directories.insert(parent); parent = Self.parent(parent) } while options?.recursive == true && parent != "/"
            return .success(())
        }
    }
    public func remove(_ path: String, options: RemoveOptions?, context: PiSwiftChord.Context) async -> Result<Void, FileError> {
        if let result: Result<Void, FileError> = cancelled(context) { return result }
        let key = Self.resolve(path, cwd: cwd)
        return state.withLock { value in
            if value.files.removeValue(forKey: key) != nil { return .success(()) }
            guard value.directories.contains(key) else { return options?.force == true ? .success(()) : missing(key) }
            if options?.recursive != true && (value.files.keys.contains { $0.hasPrefix(key + "/") } || value.directories.contains { $0.hasPrefix(key + "/") }) {
                return .failure(FileError(.invalid, message: "Directory is not empty", path: key))
            }
            value.files = value.files.filter { !$0.key.hasPrefix(key + "/") }
            value.directories = value.directories.filter { $0 != key && !$0.hasPrefix(key + "/") }
            return .success(())
        }
    }
    private func temp(prefix: String?, suffix: String?) -> String {
        state.withLock { value in value.nextTemp += 1; return Self.resolve("\(prefix ?? "tmp")\(value.nextTemp)\(suffix ?? "")", cwd: value.cwd) }
    }
    public func createTempDir(prefix: String?, context: PiSwiftChord.Context) async -> Result<String, FileError> {
        let path = temp(prefix: prefix, suffix: nil)
        return await createDir(path, options: .init(recursive: true), context: context).map { path }
    }
    public func createTempFile(options: CreateTempFileOptions?, context: PiSwiftChord.Context) async -> Result<String, FileError> {
        let path = temp(prefix: options?.prefix, suffix: options?.suffix)
        return await writeFile(path, content: .bytes([]), context: context).map { path }
    }
    public func cleanup(context: PiSwiftChord.Context) async {}
}

private actor FakeTextLineReader: TextLineReader {
    private var pending: [TextLine]
    init(_ text: String) { pending = Self.lines(text) }
    static func lines(_ text: String) -> [TextLine] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { TextLine(text: String($0), terminated: true) }
        if text.hasSuffix("\n") { lines.removeLast() }
        else if !lines.isEmpty { lines[lines.count - 1].terminated = false }
        return text.isEmpty ? [] : lines
    }
    func readLine(context: PiSwiftChord.Context) async -> Result<TextLine?, FileError> {
        if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "Read aborted")) }
        return .success(pending.isEmpty ? nil : pending.removeFirst())
    }
    func close(context: PiSwiftChord.Context) async { pending.removeAll() }
}
private actor FakeDirReader: DirReader {
    private var pending: [FileInfo]
    init(_ entries: [FileInfo]) { pending = entries }
    func next(maxEntries: Int, context: PiSwiftChord.Context) async -> Result<DirectoryPage, FileError> {
        if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "Read aborted")) }
        guard maxEntries > 0 else { return .failure(FileError(.invalid, message: "Page size must be positive")) }
        let entries = Array(pending.prefix(maxEntries)); pending.removeFirst(entries.count)
        return .success(DirectoryPage(entries: entries, done: pending.isEmpty))
    }
    func close(context: PiSwiftChord.Context) async { pending.removeAll() }
}
private actor FakeBinaryReader: BinaryReader {
    private let bytes: [UInt8]
    private let fileInfo: FileInfo
    private var closed = false
    init(bytes: [UInt8], info: FileInfo) { self.bytes = bytes; fileInfo = info }
    func info(context: PiSwiftChord.Context) async -> Result<FileInfo, FileError> { .success(fileInfo) }
    func read(offset: Int64, length: Int, context: PiSwiftChord.Context) async -> Result<[UInt8], FileError> {
        guard !closed, offset >= 0, length >= 0, offset <= Int64(bytes.count) else { return .failure(FileError(.invalid, message: "Invalid read range")) }
        if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "Read aborted")) }
        return .success(Array(bytes[Int(offset)..<min(bytes.count, Int(offset) + min(length, bytes.count - Int(offset)))]))
    }
    func scanLines(options: ScanLinesOptions, context: PiSwiftChord.Context) async -> Result<LineScan, FileError> {
        guard !closed, options.startLine >= 0, options.endLine.map({ $0 > options.startLine }) ?? true else {
            return .failure(FileError(.invalid, message: "Invalid line range"))
        }
        if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "Read aborted")) }
        var starts = [0], ends: [Int] = []
        for (index, byte) in bytes.enumerated() where byte == 10 { ends.append(index); starts.append(index + 1) }
        ends.append(bytes.count)
        let first = min(options.startLine, starts.count), last = min(options.endLine ?? starts.count, starts.count)
        let start = first < starts.count ? starts[first] : bytes.count
        let end = last > first ? ends[last - 1] : start
        let firstEnd = last > first ? ends[first] : start, lastStart = last > first ? starts[last - 1] : start
        let hasBOM = bytes.starts(with: [0xef, 0xbb, 0xbf])
        func decodedSize(_ from: Int, _ to: Int) -> Int64 {
            let lower = hasBOM && from < 3 ? min(to, 3) : from
            return Int64(String(decoding: bytes[lower..<to], as: UTF8.self).utf8.count)
        }
        return .success(LineScan(newlines: ends.count - 1, start: Int64(start), end: Int64(end),
            firstLineEnd: Int64(firstEnd), lastLineStart: Int64(lastStart),
            selectedBytes: decodedSize(start, end), firstLineBytes: decodedSize(start, firstEnd)))
    }
    func close(context: PiSwiftChord.Context) async { closed = true }
}
