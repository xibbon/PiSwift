import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.ToolTaskRecords")
struct ToolTaskRecordFixtureTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "tool-task-records-v130", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func compare(_ storage: any DurableStorage) async throws {
        for call in try #require(fixture()["reads"]?.arrayValue) {
            let method = try #require(call["method"]?.stringValue)
            let args = try #require(call["arguments"]?.arrayValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == call["result"], "Mixed tool task fixture read: \(method)")
        }
    }

    // Construct current-version inputs and results through the public Swift API before storage writes.
    private func typedWrite(_ raw: JSONValue) throws -> StorageWrite {
        guard raw["type"] == "task", raw["value"]?["version"] == 2 else {
            return try raw.decode(StorageWrite.self)
        }
        var write = try #require(raw.objectValue)
        var task = try #require(raw["value"]?.objectValue)
        let input = try #require(task["input"])
        task["input"] = try JSONValue(encoding: ToolTaskInput(
            assistant: #require(input["assistant"]).decode(EntryID.self),
            callId: #require(input["callId"]?.stringValue)))
        var state = try #require(task["state"]?.objectValue)
        if var outcome = state["outcome"]?.objectValue, let result = outcome["result"] {
            let entry = try #require(result["entryId"]).decode(EntryID.self)
            let control = try result["control"]?.decode(ToolControl.self)
            outcome["result"] = try JSONValue(encoding: ToolTaskResult.model(entryId: entry, control: control))
            state["outcome"] = .object(outcome)
        } else if let checkpoint = state["checkpoint"] {
            state["checkpoint"] = try JSONValue(encoding: checkpoint.decode(ToolTaskCheckpoint.self))
        }
        task["state"] = .object(state)
        write["value"] = .object(task)
        #expect(JSONValue.object(write) == raw)
        return try JSONValue.object(write).decode(StorageWrite.self)
    }

    private func replay(_ storage: any DurableStorage) async throws {
        for batch in try #require(fixture()["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]?.arrayValue).map(typedWrite)
            let seq = try await storage.commit(writes, context: .background)
            #expect(try JSONValue(encoding: seq) == batch["seq"])
        }
        try await compare(storage)
    }

    @Test func modelInputsAndCheckpointsMatchUpstreamMigration() throws {
        let value = try fixture()
        #expect(value["tag"] == "v1.3.0")
        #expect(toolTask.version == 2)
        let migrate = try #require(toolTask.eraseToAnyTaskDefinition().migrate)
        let migrations = try #require(value["migrations"]?.arrayValue)
        #expect(migrations.count == 2)
        for expected in migrations {
            let read = try #require(value["reads"]?.arrayValue?.first {
                $0["method"] == "task" && $0["arguments"]?[0] == expected["taskId"]
            })
            let record = try #require(read["result"])
            #expect(record["input"]?["kind"] == nil)
            let checkpoint = try #require(record["state"]?["checkpoint"])
            let converted = try migrate(#require(record["input"]), checkpoint, 1)
            #expect(converted.input == expected["input"])
            #expect(converted.checkpoint == expected["checkpoint"])
            #expect(converted.checkpoint == checkpoint)
            let typed = try converted.input.decode(ToolTaskInput.self)
            guard case let .model(assistant, callId) = typed else {
                Issue.record("Expected a model tool input")
                continue
            }
            #expect(try JSONValue(encoding: ToolTaskInput(assistant: assistant, callId: callId)) == converted.input)
        }
    }

    @Test func completingResultsKeepLegacyAndCurrentShapes() throws {
        var checked = 0
        for read in try #require(fixture()["reads"]?.arrayValue) where read["method"] == "task" {
            let record = try #require(read["result"])
            guard record["state"]?["status"] == "completing" else { continue }
            let raw = try #require(record["state"]?["outcome"]?["result"])
            let result = try raw.decode(ToolTaskResult.self)
            guard case let .model(entry, control) = result else {
                Issue.record("Expected a model tool result")
                continue
            }
            #expect(try JSONValue(encoding: entry) == raw["entryId"])
            #expect(control?.addTools == ["fixture.extra"])
            #expect(raw["kind"] == (record["version"] == 1 ? nil : "model"))
            #expect(try JSONValue(encoding: result)["kind"] == "model")
            checked += 1
        }
        #expect(checked == 2)
    }

    @Test func transcriptResultsKeepContentAndDiagnostics() throws {
        var checked = 0
        for read in try #require(fixture()["reads"]?.arrayValue) where read["method"] == "entry" {
            guard read["result"]?["entry"]?["kind"] == "pi.tool-result" else { continue }
            let entry = try #require(read["result"]?["entry"]).decode(EntryRecord.self)
            let raw = try #require(read["result"]?["entry"]?["model"]?[0])
            #expect(raw["content"]?.arrayValue?.count == 2)
            #expect(raw["output"] == nil)
            #expect(raw["structuredOutput"] == nil)
            guard case .toolResult(let message) = try entry.messages()?.first else {
                Issue.record("Expected a tool result transcript message")
                continue
            }
            #expect(message.content.count == 2)
            #expect(try JSONValue(encoding: entry) == read["result"]?["entry"])
            checked += 1
        }
        #expect(checked == 2)
    }

    @Test func memoryMatchesMixedUpstreamRecords() async throws {
        let storage = MemoryStorage()
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqlitePreservesMixedRecordsAcrossEveryReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tools.sqlite").path
        let storage = ReopeningStorage(storage: try await SqliteStorage.open(path: path), path: path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlPreservesMixedRecordsAcrossEveryReopen() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JsonlReopeningStorage(storage: try await jsonlOpen(directory), directory: directory.path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqliteReadsMixedUpstreamFile() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "tool-task-upstream-v130", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("tools.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await SqliteStorage.open(path: path.path)
        try await compare(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlReadsMixedUpstreamFiles() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "tool-task-upstream-jsonl-v130", withExtension: nil, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("tools-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await jsonlOpen(path)
        try await compare(storage)
        try await storage.close(context: .background)
    }

    @Test func sqliteExportsTypedV2TasksForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_TOOL_TASK_SQLITE_EXPORT"] else { return }
        let storage = try await SqliteStorage.open(path: path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlExportsTypedV2TasksForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_TOOL_TASK_JSONL_EXPORT"] else { return }
        let storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
        try await replay(storage)
        try await storage.close(context: .background)
    }
}
