import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.JsonlReadOnly", .timeLimit(.minutes(1)))
struct JsonlReadOnlyTests {
    // v1.5.2 jsonl-storage.test.ts:1317.
    @Test("skips torn lines, unconfirmed tails, and due reclamation in memory without writing")
    func skipsTornLinesUnconfirmedTailsAndDueReclamationInMemoryWithoutWriting() async throws {
        try await jsonlWithStorage { writer, directory, fs in
            try await jsonlRoot(writer)
            let live: TaskID = try await writer.mintId()
            let ended: TaskID = try await writer.mintId()
            _ = try await writer.commit([.task(value: jsonlTask(live)), .task(value: jsonlTask(ended))], context: .background)
            fs.fail(.init(operation: .remove, call: 1, mode: .before))
            _ = try await writer.commit([.task(value: jsonlTask(ended, terminal: true))], context: .background)
            fs.clear()
            #expect(jsonlExists(directory, jsonlTaskName(ended)))
            let unconfirmed: JSONValue = ["format": 1, "type": "record", "seq": 4, "ordinal": 0,
                "payload": ["type": "task", "value": try JSONValue(encoding: jsonlTask(live, phase: "unconfirmed"))]]
            try jsonlAppendBytes(directory, jsonlTaskName(live), bytes: Array((try unconfirmed.jsonText() + "\n{\"format\":1").utf8))
            try jsonlAppendBytes(directory, "main.jsonl", bytes: Array("{\"format\":1,\"type\":\"commit\"".utf8))
            try Data("leftover".utf8).write(to: directory.appendingPathComponent(jsonlTaskName(live) + ".reclaim"))
            let before = try jsonlDirectoryBytes(directory)
            let env = JsonlReadOnlyEnv(directory)
            let viewer = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(fsync: true, readOnly: true))
            #expect(try await viewer.task(live, context: .background) == jsonlTask(live))
            #expect(try await viewer.task(ended, context: .background) == jsonlTask(ended, terminal: true))
            await #expect(throws: JsonlStorageReadOnlyError.self) {
                _ = try await viewer.commit([.task(value: jsonlTask(live, phase: "next"))], context: .background)
            }
            try await viewer.close(context: .background)
            #expect(env.mutations.isEmpty)
            #expect(try jsonlDirectoryBytes(directory) == before)
            let repaired = try await jsonlOpen(directory)
            try await repaired.close(context: .background)
            #expect(try jsonlDirectoryBytes(directory) != before)
            #expect(!jsonlExists(directory, jsonlTaskName(ended)))
            #expect(!jsonlExists(directory, jsonlTaskName(live) + ".reclaim"))
        }
    }

    // v1.5.2 jsonl-storage.test.ts:1364.
    @Test("keeps a torn-only main file") func keepsATornOnlyMainFile() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let torn = Data("{\"format\":1,\"type\":\"commit\"".utf8)
        try torn.write(to: directory.appendingPathComponent("main.jsonl"))
        let env = JsonlReadOnlyEnv(directory)
        let viewer = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(readOnly: true))
        #expect(try await viewer.conversation(rootConversationID, context: .background) == nil)
        try await viewer.close(context: .background)
        #expect(try Data(contentsOf: directory.appendingPathComponent("main.jsonl")) == torn)
        #expect(torn.count == 27)
        #expect(env.mutations.isEmpty)
    }

    // v1.5.2 jsonl-storage.test.ts:1372.
    @Test("creates no missing directory") func createsNoMissingDirectory() async throws {
        let parent = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("missing")
        let env = JsonlReadOnlyEnv(missing)
        try await jsonlExpectError("directory listing") {
            _ = try await JsonlStorage.open(directory: missing.path, fileSystem: env, options: .init(readOnly: true))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(env.mutations.isEmpty)
    }

    // v1.5.2 jsonl-storage.test.ts:1380.
    @Test("retries a recovery that raced a writer's commit, and fails on corruption at once")
    func retriesARecoveryThatRacedAWriterCommitAndFailsOnCorruptionAtOnce() async throws {
        try await jsonlWithStorage { writer, directory, _ in
            try await jsonlRoot(writer)
            let id: TaskID = try await writer.mintId()
            _ = try await writer.commit([.task(value: jsonlTask(id))], context: .background)
            let env = JsonlReadOnlyEnv(directory, raceFile: jsonlTaskName(id)) {
                _ = try await writer.commit([.task(value: jsonlTask(id, terminal: true))], context: .background)
            }
            let viewer = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(readOnly: true))
            #expect(try await viewer.task(id, context: .background) == jsonlTask(id, terminal: true))
            #expect(env.mainReads == 2)
            try await viewer.close(context: .background)
            #expect(env.mutations.isEmpty)
            let broken: TaskID = try await writer.mintId()
            _ = try await writer.commit([.task(value: jsonlTask(broken))], context: .background)
            try Data().write(to: directory.appendingPathComponent(jsonlTaskName(broken)))
            let counting = JsonlReadOnlyEnv(directory)
            try await jsonlExpectError("Missing confirmed sidecar record") {
                _ = try await JsonlStorage.open(directory: directory.path, fileSystem: counting, options: .init(readOnly: true))
            }
            #expect(counting.mainReads == 1)
            #expect(counting.mutations.isEmpty)
        }
    }

    @Test func snapshotMintingCommitAndCloseFollowTaggedRules() async throws {
        try await jsonlWithStorage { writer, directory, _ in
            try await jsonlRoot(writer)
            let env = JsonlReadOnlyEnv(directory)
            let viewer = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(readOnly: true))
            let before = try jsonlDirectoryBytes(directory)
            let first: EntryID = try await viewer.mintId()
            let second: EntryID = try await viewer.mintId()
            #expect(second.rawValue == first.rawValue + 1)
            #expect(try jsonlDirectoryBytes(directory) == before)
            let receipts = Mutex(0)
            for batches: [[StorageWrite]] in [[], [[]], [[.conversation(value: .init(id: try ConversationID(100)))]]] {
                do {
                    _ = try await viewer.commit(batches, receive: { _, _ in receipts.withLock { $0 += 1 } }, context: .background)
                    Issue.record("Read-only commit succeeded")
                } catch let error as JsonlStorageReadOnlyError {
                    #expect(error.message == "JSONL storage is open read-only")
                }
            }
            #expect(receipts.withLock { $0 } == 0)
            let id: EntryID = try await writer.mintId()
            _ = try await writer.commit([.entry(value: .init(id: id, conversationId: rootConversationID, kind: "later"))], context: .background)
            #expect(try await viewer.entry(id, context: .background) == nil)
            try await viewer.close(context: .background)
            try await viewer.close(context: .background)
            await #expect(throws: DurableStorageError.self) { let _: EntryID = try await viewer.mintId() }
            await #expect(throws: DurableStorageError.self) { _ = try await viewer.conversation(rootConversationID, context: .background) }
            await #expect(throws: DurableStorageError.self) { _ = try await viewer.commit([], receive: { _, _ in }, context: .background) }
            #expect(env.mutations.isEmpty)
        }
    }

    @Test("all 23 tagged structural cuts preserve bytes and read the complete prefix")
    func all23TaggedStructuralCutsPreserveBytesAndReadTheCompletePrefix() async throws {
        let path = try #require(Bundle.module.url(forResource: "batch-v152", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: path))
        let cases = try #require(fixture["torn"]?.arrayValue)
        #expect(cases.count == 23)
        for item in cases {
            let directory = try jsonlTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            for (name, value) in try #require(item["inputFiles"]?.objectValue) {
                let encoded = try #require(value.stringValue)
                let bytes = try #require(Data(base64Encoded: encoded))
                try bytes.write(to: directory.appendingPathComponent(name))
            }
            let before = try jsonlDirectoryBytes(directory)
            let env = JsonlReadOnlyEnv(directory)
            if item["error"] != nil && item["error"] != .null {
                do {
                    _ = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(readOnly: true))
                    Issue.record("Expected tagged corruption for cut \(item["length"] ?? .null)")
                } catch let error as JsonlCorruptionError {
                    #expect(error.message == item["error"]?["message"]?.stringValue)
                }
            } else {
                let viewer = try await JsonlStorage.open(directory: directory.path, fileSystem: env, options: .init(readOnly: true))
                for read in try #require(item["reads"]?.arrayValue) {
                    let method = try #require(read["method"]?.stringValue)
                    let args = try #require(read["arguments"]?.arrayValue)
                    let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: viewer)
                    #expect(actual == read["result"], "Cut \(item["length"] ?? .null): \(method)")
                }
                try await viewer.close(context: .background)
            }
            #expect(try jsonlDirectoryBytes(directory) == before)
            #expect(env.mutations.isEmpty)
        }
    }
}

private func jsonlDirectoryBytes(_ directory: URL) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map {
        ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
    })
}

/// All mutation methods fail. A successful test thus proves no repair was attempted.
private final class JsonlReadOnlyEnv: FileSystem {
    private let base: LocalExecutionEnv
    private let raceFile: String?
    private let race: Mutex<(@Sendable () async throws -> Void)?>
    private let reads = Mutex(0)
    private let writes = Mutex<[String]>([])
    var mainReads: Int { reads.withLock { $0 } }
    var mutations: [String] { writes.withLock { $0 } }
    var id: String { base.id }
    var cwd: String { get { base.cwd } set { base.cwd = newValue } }
    init(_ directory: URL, raceFile: String? = nil, race: (@Sendable () async throws -> Void)? = nil) {
        base = LocalExecutionEnv(cwd: directory.path); self.raceFile = raceFile; self.race = Mutex(race)
    }
    private func mutation<T>(_ name: String) -> Result<T, FileError> {
        writes.withLock { $0.append(name) }
        return .failure(.init(.permissionDenied, message: "Unexpected read-only mutation: \(name)"))
    }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == "main.jsonl" { reads.withLock { $0 += 1 } }
        if name == raceFile, let action = race.withLock({ let action = $0; $0 = nil; return action }) {
            do { try await action() }
            catch { return .failure(.init(.unknown, message: String(describing: error))) }
        }
        return await base.readBinaryFile(path, context: context)
    }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.absolutePath(path, context: context) }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> { await base.joinPath(parts, context: context) }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.readTextFile(path, context: context) }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> { await base.openTextLineReader(path, context: context) }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> { await base.readTextLines(path, options: options, context: context) }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> { await base.openBinaryReader(path, options: options, context: context) }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { mutation("writeFile") }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { mutation("appendFile") }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> { mutation("truncateFile") }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> { mutation("flushFile") }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> { mutation("renameFile") }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> { await base.fileInfo(path, context: context) }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> { await base.listDir(path, context: context) }
    func listFiles(_ path: String, options: ListFilesOptions?, context: ChordContext) async -> Result<FileListing, FileError> { await base.listFiles(path, options: options, context: context) }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> { await base.openDirReader(path, context: context) }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (FileChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> { await base.watch(targets, onChange: onChange, context: context) }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.canonicalPath(path, context: context) }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> { await base.exists(path, context: context) }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> { mutation("createDir") }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> { mutation("remove") }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> { mutation("createTempDir") }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> { mutation("createTempFile") }
    func cleanup(context: ChordContext) async { await base.cleanup(context: context) }
}
