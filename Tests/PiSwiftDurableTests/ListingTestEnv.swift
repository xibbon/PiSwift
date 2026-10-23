import Synchronization
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

/// Test-only listing. Git ignore rules are disabled in its conformance capabilities.
/// Files and directories stay in memory. This fake is not a production listing implementation.
final class ListingTestEnv: ExecutionEnv {
    let base = FakeExecutionEnv(cwd: "/work")
    private let links = Mutex<[String: String]>([:])
    var id: String { base.id }
    var cwd: String { get { base.cwd } set { base.cwd = newValue } }
    func addLink(_ target: String, at path: String) { links.withLock { $0[path] = target } }

    func listFiles(_ path: String, options: ListFilesOptions?, context: ChordContext) async -> Result<FileListing, FileError> {
        do {
            let bounds = try listFilesBounds(options: options, path: path).get()
            if context.abortSignal?.aborted == true { throw FileError(.aborted, message: "aborted", path: path) }
            var root = try await base.absolutePath(path, context: context).get()
            let snapshot = links.withLock { $0 }
            // Resolve a root link. Links below the root remain entries and are never followed.
            var visited: Set<String> = []
            while let target = snapshot[root] {
                guard visited.insert(root).inserted else { throw FileError(.invalid, message: "Symbolic link loop", path: path) }
                let parent = root.split(separator: "/").dropLast().joined(separator: "/")
                root = try await base.absolutePath(target.hasPrefix("/") ? target : "/" + parent + "/" + target, context: context).get()
            }
            let info = try await base.fileInfo(root, context: context).get()
            guard info.kind == .directory else { throw FileError(.notDirectory, message: "Not a directory", path: path) }
            let started = ContinuousClock.now
            var entries: [FileListEntry] = [], bytes = 0, truncated = false
            let hidden = options?.hidden ?? true, exclude = options?.exclude ?? []
            func walk(_ directory: String, prefix: String) async throws {
                var children = try await base.listDir(directory, context: context).get().map { ($0.name, $0.kind, $0.path) }
                for link in snapshot.keys where String(link.split(separator: "/").dropLast().joined(separator: "/")) == String(directory.dropFirst()) {
                    let name = String(link.split(separator: "/").last!)
                    children.append((name, .symlink, link))
                }
                children.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
                for (name, kind, absolute) in children {
                    if context.abortSignal?.aborted == true { throw FileError(.aborted, message: "aborted", path: path) }
                    if name == ".git" || exclude.contains(name) || (!hidden && name.hasPrefix(".")) { continue }
                    let relative = prefix + name, size = relative.utf8.count + 2
                    if entries.count >= bounds.maxEntries || bytes + size > bounds.maxBytes
                        || started.duration(to: .now) > .milliseconds(bounds.timeoutMs) {
                        truncated = true; return
                    }
                    entries.append(.init(path: relative, kind: kind)); bytes += size
                    if kind == .directory { try await walk(absolute, prefix: relative + "/") }
                    if truncated { return }
                }
            }
            try await walk(root, prefix: "")
            return .success(FileListing(entries: entries, truncated: truncated))
        } catch let error as FileError { return .failure(error) }
        catch { return .failure(FileError(.unknown, message: String(describing: error), path: path)) }
    }

    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        await base.absolutePath(path, context: context)
    }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> {
        await base.joinPath(parts, context: context)
    }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        await base.readTextFile(path, context: context)
    }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> {
        await base.openTextLineReader(path, context: context)
    }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> {
        await base.readTextLines(path, options: options, context: context)
    }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> {
        await base.readBinaryFile(path, context: context)
    }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> {
        await base.openBinaryReader(path, options: options, context: context)
    }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> {
        await base.writeFile(path, content: content, context: context)
    }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> {
        await base.appendFile(path, content: content, context: context)
    }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> {
        await base.truncateFile(path, size: size, context: context)
    }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> {
        await base.flushFile(path, context: context)
    }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> {
        await base.renameFile(sourcePath, destinationPath: destinationPath, context: context)
    }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> {
        await base.fileInfo(path, context: context)
    }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> {
        await base.listDir(path, context: context)
    }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> {
        await base.openDirReader(path, context: context)
    }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> {
        await base.watch(targets, onChange: onChange, context: context)
    }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        await base.canonicalPath(path, context: context)
    }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> {
        await base.exists(path, context: context)
    }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> {
        await base.createDir(path, options: options, context: context)
    }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> {
        await base.remove(path, options: options, context: context)
    }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> {
        await base.createTempDir(prefix: prefix, context: context)
    }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> {
        await base.createTempFile(options: options, context: context)
    }
    func cleanup(context: ChordContext) async { await base.cleanup(context: context) }
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> {
        await base.exec(command, options: options, context: context)
    }
}
