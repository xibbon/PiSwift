import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

/// Writes the file, then holds the call until the first harness stops.
private struct CodemodeCrashAfterWriteEnv: ExecutionEnv {
    let base: FakeExecutionEnv
    let written: HarnessChatSignal
    let paths: SessionTestLog<String>
    var id: String { base.id }
    var cwd: String { get { base.cwd } nonmutating set { base.cwd = newValue } }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.absolutePath(path, context: context) }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> { await base.joinPath(parts, context: context) }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.readTextFile(path, context: context) }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> { await base.openTextLineReader(path, context: context) }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> { await base.readTextLines(path, options: options, context: context) }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> { await base.readBinaryFile(path, context: context) }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> { await base.openBinaryReader(path, options: options, context: context) }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> {
        let result = await base.writeFile(path, content: content, context: context)
        guard case .success = result else { return result }
        paths.append(path)
        written.signal()
        do { try await harnessToolAwaitAbort(context) }
        catch { return .failure(.init(.aborted, message: "Harness stopped after output write", path: path)) }
        return result
    }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { await base.appendFile(path, content: content, context: context) }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> { await base.truncateFile(path, size: size, context: context) }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> { await base.flushFile(path, context: context) }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> { await base.renameFile(sourcePath, destinationPath: destinationPath, context: context) }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> { await base.fileInfo(path, context: context) }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> { await base.listDir(path, context: context) }
    func listFiles(_ path: String, options: ListFilesOptions?, context: ChordContext) async -> Result<FileListing, FileError> { await base.listFiles(path, options: options, context: context) }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> { await base.openDirReader(path, context: context) }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> { await base.watch(targets, onChange: onChange, context: context) }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.canonicalPath(path, context: context) }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> { await base.exists(path, context: context) }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> { await base.createDir(path, options: options, context: context) }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> { await base.remove(path, options: options, context: context) }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> { await base.createTempDir(prefix: prefix, context: context) }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> { await base.createTempFile(options: options, context: context) }
    func cleanup(context: ChordContext) async { await base.cleanup(context: context) }
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> { await base.exec(command, options: options, context: context) }
}

@Suite("PiSwiftDurableTests.CodemodeOutputRestart")
struct CodemodeOutputRestartTests {
    // Upstream packages/durable/test/codemode.test.ts:975.
    @Test func outputFilePathStaysTheSameAfterRestart() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("codemode-output.sqlite").path
        let output = String(repeating: "x", count: 1000)
        let sandbox = DeterministicCodemodeSandbox { _ in .init(result: .init(value: .string(output))) }
        let setup = HarnessChatSetup()
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, models: false)))
        setup.models.setResponses([.message(e10Call("// @options: {\"max_output_tokens\": 20}\nreturn \"x\".repeat(1000);")), .message(chatAssistant("done"))])
        let env = FakeExecutionEnv(cwd: "/workspace", id: "codemode-output-files")
        let written = HarnessChatSignal(), paths = SessionTestLog<String>()
        let held = CodemodeCrashAfterWriteEnv(base: env, written: written, paths: paths)
        let first = try await e10Open(setup: setup, env: held, storage: SqliteStorage.open(path: path))
        let id = try await first.root.submit(.input(content: .text("go")), context: .background).id
        await written.wait()
        let firstPath = try #require(paths.values.first)
        #expect(paths.values.count == 1)
        #expect(try await env.readTextFile(firstPath, context: .background).get() == output)
        let tasks = try await first.harness.commit({ tx in
            try await tx.scanTasks(.init(conversationId: first.root.id, kind: "pi.tool"), limit: 100).items
        }, context: .background)
        let task = try #require(tasks.first { $0.input["kind"] == "model" })
        let beforeClose = try await first.harness.snapshot(CodemodeRunDoc, taskId: task.id, context: .background)
        #expect(beforeClose?["result"] == nil)
        #expect(beforeClose?["outputDir"]?.stringValue == (firstPath as NSString).deletingLastPathComponent)
        try await first.harness.close(context: .background)

        // The second environment uses the same files but does not hold writes.
        let second = try await e10Open(setup: setup, env: env, storage: SqliteStorage.open(path: path))
        try second.harness.resume()
        let submission = try #require(try await second.harness.submission(id: id, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        let message = try await e10Message(second.root)
        #expect(message["isError"]?.boolValue != true)
        #expect(message["details"]?["fullOutputPath"]?.stringValue == firstPath)
        #expect(e10Text(message).contains("[Full output: \(firstPath)"))
        let files = try await env.listDir((firstPath as NSString).deletingLastPathComponent, context: .background).get()
        #expect(files.map(\.name) == ["output.txt"])
        #expect(try await env.readTextFile(firstPath, context: .background).get() == output)
        #expect(await sandbox.starts.count == 2)
        try await second.harness.close(context: .background)
        #expect(setup.reports.values.isEmpty)
    }
}
