import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.NestedToolRecords")
struct NestedToolRecordFixtureTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "nested-tool-records-v130", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func compare(_ storage: any DurableStorage, reads: [JSONValue]) async throws {
        for call in reads {
            let method = try #require(call["method"]?.stringValue)
            let args = try #require(call["arguments"]?.arrayValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == call["result"], "Nested tool fixture read: \(method)")
        }
    }

    // Use the public Swift nested input and receipt before each task write.
    private func typedWrite(_ raw: JSONValue) throws -> StorageWrite {
        guard raw["type"] == "task", raw["value"]?["input"]?["kind"] == "nested" else {
            return try raw.decode(StorageWrite.self)
        }
        var write = try #require(raw.objectValue)
        var task = try #require(raw["value"]?.objectValue)
        let input = try #require(task["input"]).decode(ToolTaskInput.self)
        guard case let .nested(parent, parentCallId, key, call, progress) = input else {
            throw TaskDefinitionError("Expected a nested tool input")
        }
        task["input"] = try JSONValue(encoding: ToolTaskInput.nested(
            parent: parent, parentCallId: parentCallId, key: key, call: call, progress: progress))
        if var state = task["state"]?.objectValue, var outcome = state["outcome"]?.objectValue,
           let result = outcome["result"] {
            #expect(try result.decode(ToolTaskResult.self) == .nested)
            outcome["result"] = try JSONValue(encoding: ToolTaskResult.nested)
            state["outcome"] = .object(outcome)
            task["state"] = .object(state)
        }
        write["value"] = .object(task)
        #expect(JSONValue.object(write) == raw)
        return try JSONValue.object(write).decode(StorageWrite.self)
    }

    private func replay(_ storage: any DurableStorage, through: Int? = nil) async throws {
        let value = try fixture()
        let checkpoints = try #require(value["checkpoints"]?.arrayValue)
        for batch in try #require(value["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]?.arrayValue).map(typedWrite)
            let seq = try await storage.commit(writes, context: .background)
            #expect(try JSONValue(encoding: seq) == batch["seq"])
            for checkpoint in checkpoints where checkpoint["seq"] == batch["seq"] {
                try await compare(storage, reads: #require(checkpoint["reads"]?.arrayValue))
            }
            if let through, batch["seq"]?.intValue == through { return }
        }
        try await compare(storage, reads: #require(value["reads"]?.arrayValue))
    }

    @Test func nestedInputsAndReceiptsKeepUpstreamShapes() throws {
        let value = try fixture()
        #expect(value["tag"] == "v1.3.0")
        var keys: Set<String> = []
        var noProgress = 0
        var receipts = 0
        var restartMarks = 0
        for read in try #require(value["reads"]?.arrayValue) where read["method"] == "task" {
            let record = try #require(read["result"])
            guard record["input"]?["kind"] == "nested" else { continue }
            let input = try #require(record["input"]).decode(ToolTaskInput.self)
            #expect(try JSONValue(encoding: input) == record["input"])
            guard case let .nested(parent, parentCallId, key, call, progress) = input else { continue }
            #expect(try JSONValue(encoding: parent) == record["owner"])
            #expect(call.id == "\(parentCallId)/\(key)")
            keys.insert(key)
            if progress == false { noProgress += 1 }
            if let result = record["state"]?["outcome"]?["result"] {
                #expect(try result.decode(ToolTaskResult.self) == .nested)
                #expect(result == ["kind": "nested"])
                receipts += 1
            }
            if record["abortReason"] == "restart" {
                #expect(record["abandonOnRestart"] == true)
                #expect(record["abortRequested"] == true)
                restartMarks += 1
            }
        }
        #expect(keys == ["1", "waiting", "gated", "deep"])
        #expect(noProgress == 1)
        #expect(receipts == 4)
        #expect(restartMarks == 3)
    }

    @Test func familyResultsKeepPayloadsUntilTheParentRetires() throws {
        let value = try fixture()
        let finalReads = try #require(value["reads"]?.arrayValue)
        let checkpointReads = try #require(value["checkpoints"]?.arrayValue).flatMap { $0["reads"]?.arrayValue ?? [] }
        var results = 0
        var pending = 0
        var codes: Set<String> = []
        for read in finalReads + checkpointReads where read["method"] == "document" && read["result"] != .null {
            let raw = try #require(read["result"]?["value"])
            let state = try raw.decode(NestedCallState.self)
            #expect(try JSONValue(encoding: state) == raw)
            #expect(state.taskId != nil)
            if let result = state.result {
                let encoded = try JSONValue(encoding: result)
                #expect(encoded["output"] == nil)
                #expect(encoded["control"] == nil)
                for diagnostic in encoded["diagnostics"]?.arrayValue ?? [] {
                    if let code = diagnostic["code"]?.stringValue { codes.insert(code) }
                }
                if encoded["isError"] == false {
                    #expect(encoded["structuredOutput"] == ["answer": 42, "nested": ["value", nil]])
                    #expect(encoded["usage"]?["totalTokens"] == 10)
                    #expect(encoded["durationMs"] == 12)
                } else { #expect(encoded["structuredOutput"] == nil) }
                results += 1
            } else { pending += 1 }
        }
        #expect(results == 4)
        #expect(pending == 1)
        #expect(codes == ["fixture", "interrupted", "abandoned"])
        let members = try #require(value["cases"]?["members"]?.arrayValue)
        #expect(members.count == 5)
        for member in members where member["retired"] == true {
            let read = try #require(finalReads.first { $0["method"] == "document" && $0["arguments"]?[0] == member["id"] })
            #expect(read["result"] == .null)
        }
        let retirements = try #require(value["batches"]?.arrayValue).flatMap { $0["writes"]?.arrayValue ?? [] }.filter { $0["type"] == "document.retire" }
        #expect(Set(retirements.compactMap { $0["id"]?.intValue }) == Set(members.filter { $0["retired"] == true }.compactMap { $0["id"]?.intValue }))
    }

    @Test func memoryMatchesUpstreamNestedRecords() async throws {
        let storage = MemoryStorage()
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqlitePreservesNestedRecordsAcrossEveryReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested.sqlite").path
        let storage = ReopeningStorage(storage: try await SqliteStorage.open(path: path), path: path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlPreservesNestedRecordsAcrossEveryReopen() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = JsonlReopeningStorage(storage: try await jsonlOpen(directory), directory: directory.path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqliteReadsUpstreamNestedFile() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "nested-tool-upstream-v130", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("nested.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await SqliteStorage.open(path: path.path)
        try await compare(storage, reads: #require(fixture()["reads"]?.arrayValue))
        try await storage.close(context: .background)
    }

    @Test func jsonlReadsUpstreamNestedFiles() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "nested-tool-upstream-jsonl-v130", withExtension: nil, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("nested-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await jsonlOpen(path)
        try await compare(storage, reads: #require(fixture()["reads"]?.arrayValue))
        try await storage.close(context: .background)
    }

    @Test func sqliteExportsTypedNestedRecordsForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_NESTED_TOOL_SQLITE_EXPORT"] else { return }
        let storage = try await SqliteStorage.open(path: path)
        try await replay(storage)
        try await storage.close(context: .background)
        for checkpoint in try #require(fixture()["checkpoints"]?.arrayValue) {
            let seq = try #require(checkpoint["seq"]?.intValue)
            let partial = try await SqliteStorage.open(path: "\(path).checkpoint-\(seq)")
            try await replay(partial, through: seq)
            try await partial.close(context: .background)
        }
    }

    @Test func jsonlExportsTypedNestedRecordsForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_NESTED_TOOL_JSONL_EXPORT"] else { return }
        let storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
        try await replay(storage)
        try await storage.close(context: .background)
        for checkpoint in try #require(fixture()["checkpoints"]?.arrayValue) {
            let seq = try #require(checkpoint["seq"]?.intValue)
            let partialPath = "\(path).checkpoint-\(seq)"
            let partial = try await JsonlStorage.open(directory: partialPath, fileSystem: LocalExecutionEnv(cwd: partialPath))
            try await replay(partial, through: seq)
            try await partial.close(context: .background)
        }
    }
}
