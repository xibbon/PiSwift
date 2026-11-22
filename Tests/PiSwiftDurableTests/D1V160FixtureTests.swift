import Foundation
import CryptoKit
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("v1.6.0 TypeScript durable records")
struct D1V160FixtureTests {
    @Test func swiftV160ExportForUpstreamRead() async throws {
        let source = try fixture()
        for (backend, key) in [("sqlite", "PI_DURABLE_V160_SQLITE_EXPORT"),
                               ("jsonl", "PI_DURABLE_V160_JSONL_EXPORT")] {
            guard let path = ProcessInfo.processInfo.environment[key] else { continue }
            let storage: any DurableStorage
            if backend == "sqlite" { storage = try await SqliteStorage.open(path: path) }
            else { storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path)) }
            do {
                for batch in try #require(source["batches"]?.arrayValue) {
                    let writes = try #require(batch["writes"]).decode([StorageWrite].self)
                    #expect(try JSONValue(encoding: await storage.commitOne(writes, context: .background)) == batch["seq"])
                }
                for read in try #require(source["reads"]?.arrayValue) {
                    let actual = try await PiSwiftDurableTests().sqliteReplayRead(
                        #require(read["method"]?.stringValue), args: #require(read["arguments"]?.arrayValue), storage: storage)
                    #expect(actual == read["result"])
                }
            } catch { try? await storage.close(context: .background); throw error }
            try await storage.close(context: .background)
        }
    }

    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "v160-record-records-v160", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func copiedFile(_ backend: String) throws -> (directory: URL, path: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d1-v160-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = backend == "sqlite" ? "v160-record-upstream-v160" : "v160-record-upstream-jsonl-v160"
        let source = try #require(Bundle.module.url(forResource: name,
            withExtension: backend == "sqlite" ? "sqlite" : nil, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent(backend == "sqlite" ? "fixture.sqlite" : "fixture-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        return (directory, path)
    }

    private func physicalTaskHash(_ id: TaskID, backend: String, path: URL) throws -> [UInt8] {
        let bytes: Data
        if backend == "sqlite" {
            let db = try AppleSqliteDatabase(path: path.path)
            defer { try? db.close() }
            let row = try #require(try db.get("SELECT record FROM tasks WHERE id = ?", [.integer(id.rawValue)]))
            bytes = Data(try row.sqliteText("record").utf8)
        } else {
            bytes = try Data(contentsOf: path.appendingPathComponent("task-\(id.rawValue).jsonl"))
        }
        return Array(SHA256.hash(data: bytes))
    }

    private var blockedOrders: [String: String] {
        ["parkedTool": "D2", "signalOnlySleep": "D2", "timedSignalSleep": "D2",
         "anyWait": "D3", "afterTools": "D5", "yield": "D5",
         "executeTool": "D3a", "wakeTime": "D3", "wakeExpired": "D3",
         "wakeSignal": "D2", "wakeTasks": "D3"]
    }

    @Test func taggedWritesAndRecordsRoundTrip() throws {
        let source = try fixture()
        #expect(source["tag"] == "v1.6.0")
        for batch in try #require(source["batches"]?.arrayValue) {
            for raw in try #require(batch["writes"]?.arrayValue) {
                #expect(try JSONValue(encoding: raw.decode(StorageWrite.self)) == raw)
            }
        }
        let cases = try #require(source["cases"]?.objectValue)
        for name in ["parkedTool", "signalOnlySleep", "timedSignalSleep", "anyWait",
                     "wakeTime", "wakeExpired", "wakeSignal", "wakeTasks", "afterTools", "yield"] {
            #expect(cases[name] != nil)
        }
        for read in try #require(source["reads"]?.arrayValue) {
            let raw = try #require(read["result"])
            switch read["method"]?.stringValue {
            case "task":
                #expect(try JSONValue(encoding: raw.decode(TaskRecord.self)) == raw)
                if let checkpoint = raw["state"]?["checkpoint"] {
                    if raw["kind"] == "pi.tool", raw["version"] == 4 {
                        #expect(try JSONValue(encoding: checkpoint.decode(ToolTaskCheckpoint.self)) == checkpoint)
                    }
                    if raw["kind"] == "pi.generation", raw["version"] == 3 {
                        #expect(try JSONValue(encoding: checkpoint.decode(GenerationCheckpoint.self)) == checkpoint)
                    }
                }
            case "submission":
                #expect(try JSONValue(encoding: raw.decode(SubmissionRecord.self)) == raw)
            default: break
            }
        }
    }

    @Test func taggedTaskMigrationOracles() throws {
        let source = try fixture()
        for item in try #require(source["migrations"]?.arrayValue) {
            let kind = try #require(item["kind"]?.stringValue)
            let definition = try #require(createRegistry().snapshot().task(name: kind))
            #expect(definition.version == item["toVersion"]?.numberValue)
            let migrate = try #require(definition.migrate)
            let input = try #require(item["input"])
            let checkpoint = try #require(item["checkpoint"])
            let version = try #require(item["fromVersion"]?.numberValue)
            let result = try migrate(input, checkpoint, version)
            #expect(result.input == item["result"]?["input"])
            #expect(result.checkpoint == item["result"]?["checkpoint"])
        }
    }

    @Test(arguments: ["sqlite", "jsonl"])
    func taggedFileOpensWithoutChangingBlockedRecords(backend: String) async throws {
        let copied = try copiedFile(backend)
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        let source = try fixture()
        let cases = try #require(source["cases"]?.objectValue)
        let physicalBefore = try Dictionary(uniqueKeysWithValues: blockedOrders.keys.map { name in
            let id = try #require(cases[name]).decode(TaskID.self)
            return (name, try physicalTaskHash(id, backend: backend, path: copied.path))
        })
        let viewerStorage: any DurableStorage
        if backend == "sqlite" { viewerStorage = try await SqliteStorage.open(path: copied.path.path) }
        else { viewerStorage = try await JsonlStorage.open(directory: copied.path.path,
            fileSystem: LocalExecutionEnv(cwd: copied.path.path), options: .init(readOnly: true)) }
        let viewer = try await Harness.open(storage: viewerStorage,
            options: .init(models: FakeDurableModels(), registry: createRegistry(), readOnly: true,
                now: { 1_700_000_000_000 }), context: .background)
        #expect(try await viewer.inspect(context: .background).scheduling == .paused)
        try await viewer.close(context: .background)
        for (name, hash) in physicalBefore {
            let id = try #require(cases[name]).decode(TaskID.self)
            #expect(try physicalTaskHash(id, backend: backend, path: copied.path) == hash)
        }
        let storage: any DurableStorage
        if backend == "sqlite" { storage = try await SqliteStorage.open(path: copied.path.path) }
        else { storage = try await JsonlStorage.open(directory: copied.path.path,
            fileSystem: LocalExecutionEnv(cwd: copied.path.path)) }
        var before: [TaskID: JSONValue] = [:]
        for value in try #require(source["cases"]?.objectValue).values {
            let id = try value.decode(TaskID.self)
            let record = try #require(try await storage.task(id, context: .background))
            before[id] = try JSONValue(encoding: record)
        }
        let notify = try #require(source["notifySubmissionId"]).decode(SubmissionID.self)
        let submission = try #require(try await storage.submission(notify, context: .background))
        #expect(try JSONValue(encoding: submission)["notify"] != nil)
        let inbox = try #require(source["inboxDocumentId"]).decode(DocumentID.self)
        #expect(try await storage.document(inbox, at: .current, context: .background) != nil)
        // An unrelated Swift commit must not rewrite a blocked task.
        let session = try await Session.open(storage: storage, context: .background)
        _ = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()).id }, context: .background)
        try await session.close(context: .background)
        for (name, hash) in physicalBefore {
            let id = try #require(cases[name]).decode(TaskID.self)
            #expect(try physicalTaskHash(id, backend: backend, path: copied.path) == hash)
        }
        for (id, raw) in before {
            let reopened: any DurableStorage
            if backend == "sqlite" { reopened = try await SqliteStorage.open(path: copied.path.path) }
            else { reopened = try await JsonlStorage.open(directory: copied.path.path,
                fileSystem: LocalExecutionEnv(cwd: copied.path.path)) }
            let record = try #require(try await reopened.task(id, context: .background))
            #expect(try JSONValue(encoding: record) == raw)
            try await reopened.close(context: .background)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["sqlite", "jsonl"])
    func taggedBlockedPhasesStayByteIdentical(backend: String) async throws {
        let copied = try copiedFile(backend)
        defer { try? FileManager.default.removeItem(at: copied.directory) }
        let source = try fixture()
        let cases = try #require(source["cases"]?.objectValue)
        var hashes: [String: [UInt8]] = [:]
        for name in blockedOrders.keys {
            let id = try #require(cases[name]).decode(TaskID.self)
            hashes[name] = try physicalTaskHash(id, backend: backend, path: copied.path)
        }
        let storage: any DurableStorage
        if backend == "sqlite" { storage = try await SqliteStorage.open(path: copied.path.path) }
        else { storage = try await JsonlStorage.open(directory: copied.path.path,
            fileSystem: LocalExecutionEnv(cwd: copied.path.path)) }
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: createRegistry(),
                now: { 1_700_000_000_000 }), context: .background)
        do {
            func verify(_ inspection: HarnessInspection) throws {
                for (name, order) in blockedOrders {
                    let id = try #require(cases[name]).decode(TaskID.self)
                    let task = try #require(inspection.tasks.first { $0.record.id == id })
                    if case .blocked(let reason, let error) = task.state {
                        #expect(reason == .migrationFailed)
                        #expect(String(describing: error).contains(order), "\(name) must name \(order)")
                    } else { Issue.record("\(name) was not blocked") }
                }
            }
            try verify(await harness.inspect(context: .background))
            try harness.resume()
            // Let the scheduler attempt pending reservations before the second inspection.
            for _ in 0..<20 { await Task.yield() }
            try verify(await harness.inspect(context: .background))
        } catch { try? await harness.close(context: .background); throw error }
        try await harness.close(context: .background)
        for (name, hash) in hashes {
            let id = try #require(cases[name]).decode(TaskID.self)
            #expect(try physicalTaskHash(id, backend: backend, path: copied.path) == hash)
        }
    }
}
