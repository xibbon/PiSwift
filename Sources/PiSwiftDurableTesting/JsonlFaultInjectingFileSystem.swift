import Foundation
import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Records file mutations and adds one selected I/O failure.
public final class FaultInjectingFileSystem: FileSystem {
    public enum Operation: String, Sendable, CaseIterable { case append, flush, write, rename, remove }
    public enum Mode: String, Sendable, CaseIterable { case before, after, short }
    public struct Failure: Sendable, CustomStringConvertible {
        public let operation: Operation
        public let call: Int
        public let mode: Mode
        public init(operation: Operation, call: Int, mode: Mode) {
            self.operation = operation; self.call = call; self.mode = mode
        }
        public var description: String { "\(operation.rawValue) \(call) \(mode.rawValue)" }
    }
    private struct State: Sendable {
        var operations: [String] = []
        var calls: [Operation: Int] = [:]
        var failure: Failure?
    }
    private let hook = Mutex<(@Sendable (Operation, String) async -> Void)?>(nil)
    public var beforeOperation: (@Sendable (Operation, String) async -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }
    private let wrapped: Mutex<any FileSystem>
    private var base: any FileSystem { wrapped.withLock { $0 } }
    private let state = Mutex(State())
    public var id: String { base.id }
    public var cwd: String { get { base.cwd } set { wrapped.withLock { $0.cwd = newValue } } }
    public var operations: [String] { state.withLock { $0.operations } }
    public init(_ base: any FileSystem) { self.wrapped = Mutex(base) }
    /// Sets a fault and clears operation counts.
    public func fail(_ failure: Failure) { state.withLock { $0 = State(failure: failure) } }
    /// Removes the fault and clears operation counts.
    public func clear() { state.withLock { $0 = State() } }
    private func observe(_ operation: Operation, path: String, destination: String? = nil) -> Mode? {
        state.withLock { state in
            let call = (state.calls[operation] ?? 0) + 1
            state.calls[operation] = call
            let suffix = destination.map { "->" + URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            state.operations.append("\(operation.rawValue):\(URL(fileURLWithPath: path).lastPathComponent)\(suffix)")
            guard let failure = state.failure, failure.operation == operation, failure.call == call else { return nil }
            return failure.mode
        }
    }
    private func error(_ operation: Operation, path: String, mode: Mode) -> FileError {
        FileError(.unknown, message: "injected \(mode.rawValue) \(operation.rawValue) failure", path: path)
    }
    private func partial(_ content: FileContent) -> FileContent {
        let bytes: [UInt8]
        switch content { case .text(let text): bytes = Array(text.utf8); case .bytes(let value): bytes = value }
        return .bytes(Array(bytes.prefix(max(1, bytes.count / 2))))
    }
    public func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        return await base.absolutePath(path, context: context)
    }
    public func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> {
        return await base.joinPath(parts, context: context)
    }
    public func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        return await base.readTextFile(path, context: context)
    }
    public func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> {
        return await base.openTextLineReader(path, context: context)
    }
    public func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> {
        return await base.readTextLines(path, options: options, context: context)
    }
    public func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> {
        return await base.readBinaryFile(path, context: context)
    }
    public func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> {
        return await base.openBinaryReader(path, options: options, context: context)
    }
    public func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> {
        let mode = observe(.write, path: path)
        if let action = beforeOperation { await action(.write, path) }
        if mode == .before { return .failure(error(.write, path: path, mode: mode!)) }
        let selected = mode == .short ? partial(content) : content
        let result = await base.writeFile(path, content: selected, context: context)
        if case .failure = result { return result }
        if let mode { return .failure(error(.write, path: path, mode: mode)) }
        return result
    }
    public func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> {
        let mode = observe(.append, path: path)
        if let action = beforeOperation { await action(.append, path) }
        if mode == .before { return .failure(error(.append, path: path, mode: mode!)) }
        let selected = mode == .short ? partial(content) : content
        let result = await base.appendFile(path, content: selected, context: context)
        if case .failure = result { return result }
        if let mode { return .failure(error(.append, path: path, mode: mode)) }
        return result
    }
    public func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> {
        return await base.truncateFile(path, size: size, context: context)
    }
    public func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> {
        let mode = observe(.flush, path: path)
        if let action = beforeOperation { await action(.flush, path) }
        if mode == .before || mode == .short { return .failure(error(.flush, path: path, mode: mode!)) }
        let result = await base.flushFile(path, context: context)
        if case .failure = result { return result }
        if let mode { return .failure(error(.flush, path: path, mode: mode)) }
        return result
    }
    public func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> {
        let mode = observe(.rename, path: sourcePath, destination: destinationPath)
        if let action = beforeOperation { await action(.rename, sourcePath) }
        if mode == .before || mode == .short { return .failure(error(.rename, path: sourcePath, mode: mode!)) }
        let result = await base.renameFile(sourcePath, destinationPath: destinationPath, context: context)
        if case .failure = result { return result }
        if let mode { return .failure(error(.rename, path: sourcePath, mode: mode)) }
        return result
    }
    public func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> {
        return await base.fileInfo(path, context: context)
    }
    public func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> {
        return await base.listDir(path, context: context)
    }
    public func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> {
        return await base.openDirReader(path, context: context)
    }
    public func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> {
        return await base.watch(targets, onChange: onChange, context: context)
    }
    public func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        return await base.canonicalPath(path, context: context)
    }
    public func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> {
        return await base.exists(path, context: context)
    }
    public func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> {
        return await base.createDir(path, options: options, context: context)
    }
    public func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> {
        let mode = observe(.remove, path: path)
        if let action = beforeOperation { await action(.remove, path) }
        if mode == .before || mode == .short { return .failure(error(.remove, path: path, mode: mode!)) }
        let result = await base.remove(path, options: options, context: context)
        if case .failure = result { return result }
        if let mode { return .failure(error(.remove, path: path, mode: mode)) }
        return result
    }
    public func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> {
        return await base.createTempDir(prefix: prefix, context: context)
    }
    public func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> {
        return await base.createTempFile(options: options, context: context)
    }
    public func cleanup(context: ChordContext) async {
        await base.cleanup(context: context)
    }
}
