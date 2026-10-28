import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if os(macOS)
@Suite("PiSwiftDurableTests.D4SharedFileCloseout", .serialized)
struct D4SharedFileCloseoutTests {
    private func bridge(_ mode: String, directory: URL, backend: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = directory.appendingPathComponent("\(mode)-\(backend).log")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let log = try FileHandle(forWritingTo: url)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", root.appendingPathComponent("Scripts/durable-fixtures/shared-file-matrix.mjs").path,
                           mode, directory.path, backend]
        child.standardOutput = log
        child.standardError = log
        try child.run()
        child.waitUntilExit()
        let output = try String(contentsOf: url, encoding: .utf8)
        try #require(child.terminationStatus == 0, "\(output)")
        #expect(output.contains(mode.hasPrefix("prepare") ? "Matrix prepared" : "Mirror verified Swift"), "\(output)")
    }

    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path, prefix: backend == "prefix" ? "pi_" : nil)
    }

    private func compare(_ storage: any DurableStorage, reads: [JSONValue]) async throws {
        try #require(!reads.isEmpty)
        for read in reads {
            let method = try #require(read["method"]?.stringValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method,
                args: #require(read["arguments"]?.arrayValue), storage: storage)
            #expect(actual == read["result"], "v1.4.0 matrix: \(method)")
            if method == "task", actual != .null {
                #expect(try JSONValue(encoding: actual.decode(TaskRecord.self)) == actual)
            }
        }
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func v140FilesHaveEqualRecordsInBothDirections(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try bridge("prepare-v140", directory: directory, backend: backend)
        let manifest = try JSONValue(jsonData: Data(contentsOf: directory.appendingPathComponent("manifest-v140-\(backend).json")))
        let datasets = try #require(manifest.arrayValue)
        #expect(datasets.compactMap { $0["name"]?.stringValue } == ["tool-task-records", "nested-tool-records", "restart-records", "closeout-documents", "codemode", "codemode-checkpoints", "lifecycle-records"])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("swift-v140/\(backend)"), withIntermediateDirectories: true)
        for dataset in datasets {
            #expect(dataset["tag"] == "v1.4.0")
            let name = try #require(dataset["name"]?.stringValue)
            let final: JSONValue = ["reads": try #require(dataset["reads"])]
            for step in [final] + (dataset["checkpoints"]?.arrayValue ?? []) {
                let through = step["seq"]?.intValue
                let suffix = through.map { ".checkpoint-\($0)" } ?? ""
                let reads = try #require(step["reads"]?.arrayValue)
                let nodePath = directory.appendingPathComponent("node-v140/\(backend)/\(name)\(suffix)")
                for _ in 0..<2 {
                    let reader = try await open(nodePath, backend: backend)
                    do { try await compare(reader, reads: reads) }
                    catch { try? await reader.close(context: .background); throw error }
                    try await reader.close(context: .background)
                }
                let path = directory.appendingPathComponent("swift-v140/\(backend)/\(name)\(suffix)")
                let writer = try await open(path, backend: backend)
                do {
                    for batch in try #require(dataset["batches"]?.arrayValue) {
                        if let through, let seq = batch["seq"]?.intValue, seq > through { break }
                        let raw = try #require(batch["writes"])
                        let writes = try raw.decode([StorageWrite].self)
                        #expect(try JSONValue(encoding: writes) == raw)
                        #expect(try JSONValue(encoding: await writer.commit(writes, context: .background)) == batch["seq"])
                    }
                    try await compare(writer, reads: reads)
                } catch { try? await writer.close(context: .background); throw error }
                try await writer.close(context: .background)
                let reopened = try await open(path, backend: backend)
                do { try await compare(reopened, reads: reads) }
                catch { try? await reopened.close(context: .background); throw error }
                try await reopened.close(context: .background)
            }
        }
        try bridge("verify-v140", directory: directory, backend: backend)
    }

    private func jsonRows(_ db: any SqliteExecutor, sql: String, parameters: [SqliteValue] = []) throws -> JSONValue {
        .array(try db.all(sql, parameters).map { row in
            .object(JSONObject(row.map { key, value -> (String, JSONValue) in
                let json: JSONValue = switch value {
                case .null: .null
                case .integer(let number): .number(Double(number))
                case .real(let number): .number(number)
                case .text(let text): .string(text)
                case .blob(let data): .array(data.map { .number(Double($0)) })
                }
                return (key, json)
            }))
        })
    }

    private func checkMigrationRows(_ path: URL, expected: JSONValue, backend: String, rewrittenTask: JSONValue? = nil) throws {
        let prefix = backend == "prefix" ? "pi_" : ""
        let db = try AppleSqliteDatabase(path: path.path)
        defer { try? db.close() }
        #expect(try db.get("SELECT version FROM \(prefix)durable_schema") == ["version": .integer(2)])
        for (table, rows) in try #require(expected["rows"]?.objectValue) {
            let actual = try jsonRows(db, sql: "SELECT * FROM \(prefix)\(table) ORDER BY 1, 2")
            if table == "tasks", let rewrittenTask {
                let normalize: (JSONValue) throws -> JSONValue = { value in
                    .array(try #require(value.arrayValue).map { row in
                        guard row["id"] == rewrittenTask["id"] else { return row }
                        var fields = try #require(row.objectValue)
                        fields["record"] = try JSONValue(jsonText: #require(row["record"]?.stringValue))
                        return .object(fields)
                    })
                }
                #expect(try normalize(actual) == normalize(rows))
            } else { #expect(actual == rows) }
        }
        #expect(try jsonRows(db, sql: "SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ? ORDER BY name",
                             parameters: [.text(prefix + "tasks")]) == expected["indexes"])
        #expect(try jsonRows(db, sql: "SELECT name FROM sqlite_schema WHERE name = ?", parameters: [.text(prefix + "tasks_v2")]) == [])
    }

    @Test(arguments: ["sqlite", "prefix"])
    func eitherLanguageMigratesFrozenSchemaOneForTheOtherReader(backend: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try bridge("prepare-migration", directory: directory, backend: backend)
        let manifest = try JSONValue(jsonData: Data(contentsOf: directory.appendingPathComponent("migration.json")))
        let before = try #require(manifest["before"]), after = try #require(manifest["after"])
        #expect(before["version"] == 1)
        #expect(after["version"] == 2)
        #expect(after["rows"] == before["rows"])
        #expect(after["indexes"] == before["indexes"])
        #expect(after["indexes"]?.arrayValue?.count == 5)
        #expect(after["temporary"] == [])
        for name in ["migrate-swift.sqlite", "migrate-node.sqlite"] {
            let path = directory.appendingPathComponent(name)
            if name == "migrate-swift.sqlite" {
                let db = try AppleSqliteDatabase(path: path.path)
                #expect(try db.get("SELECT version FROM \(backend == "prefix" ? "pi_" : "")durable_schema") == ["version": .integer(1)])
                try db.close()
            }
            let storage = try await open(path, backend: backend)
            do {
                for row in try #require(before["rows"]?["tasks"]?.arrayValue) {
                    let id = try #require(row["id"]).decode(TaskID.self)
                    let record = try #require(await storage.task(id, context: .background))
                    let text = try #require(row["record"]?.stringValue)
                    #expect(try JSONValue(encoding: record) == JSONValue(jsonText: text))
                }
            } catch { try? await storage.close(context: .background); throw error }
            try await storage.close(context: .background)
            try checkMigrationRows(path, expected: after, backend: backend)
        }
        let sleepingWrite = try #require(manifest["sleepingWrite"])
        let sleepingTask = try #require(sleepingWrite["value"])
        let sleepingID = try #require(sleepingTask["id"]).decode(TaskID.self)
        #expect(sleepingTask["state"]?["status"] == "sleeping")
        let swiftSleep = directory.appendingPathComponent("migrate-swift-sleep.sqlite")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("migrate-swift.sqlite"), to: swiftSleep)
        for name in ["migrate-swift-sleep.sqlite", "migrate-node-sleep.sqlite"] {
            let path = directory.appendingPathComponent(name)
            let storage = try await open(path, backend: backend)
            do {
                if name == "migrate-swift-sleep.sqlite" {
                    let write = try sleepingWrite.decode(StorageWrite.self)
                    #expect(try JSONValue(encoding: write) == sleepingWrite)
                    #expect(try JSONValue(encoding: await storage.commit([write], context: .background)) == manifest["sleepingSeq"])
                }
                #expect(try JSONValue(encoding: await storage.task(sleepingID, context: .background)) == sleepingTask)
            } catch { try? await storage.close(context: .background); throw error }
            try await storage.close(context: .background)
            try checkMigrationRows(path, expected: #require(manifest["sleepAfter"]), backend: backend, rewrittenTask: sleepingTask)
            let reopened = try await open(path, backend: backend)
            do { #expect(try JSONValue(encoding: await reopened.task(sleepingID, context: .background)) == sleepingTask) }
            catch { try? await reopened.close(context: .background); throw error }
            try await reopened.close(context: .background)
        }
        try bridge("verify-migration", directory: directory, backend: backend)
    }
}
#endif
