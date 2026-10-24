import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

#if os(macOS)
// Node runs only the isolated tag mirror. No upstream checkout files are changed.
@Suite("PiSwiftDurableTests.SharedFileCloseout", .serialized)
struct SharedFileCloseoutTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func bridge(_ mode: String, directory: URL, backend: String) throws {
        let logURL = directory.appendingPathComponent("\(mode)-\(backend).log")
        #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["node", root.appendingPathComponent("Scripts/durable-fixtures/shared-file-matrix.mjs").path,
                           mode, directory.path, backend]
        child.standardOutput = log
        child.standardError = log
        try child.run()
        child.waitUntilExit()
        let output = try String(contentsOf: logURL, encoding: .utf8)
        try #require(child.terminationStatus == 0, "\(output)")
        #expect(output.contains(mode == "prepare" ? "Matrix prepared" : "Mirror verified Swift"), "\(output)")
    }

    private func prepare(_ backend: String) throws -> (URL, [JSONValue]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e12-matrix-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try bridge("prepare", directory: directory, backend: backend)
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest-\(backend).json"))
            let datasets = try #require(JSONValue(jsonData: data).arrayValue)
            #expect(datasets.compactMap { $0["name"]?.stringValue } == ["tools", "migrated", "nested", "restart", "documents", "codemode"])
            return (directory, datasets)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" {
            return try await JsonlStorage.open(directory: path.path, fileSystem: LocalExecutionEnv(cwd: path.path))
        }
        return try await SqliteStorage.open(path: path.path, prefix: backend == "prefix" ? "pi_" : nil)
    }

    private func typedReads(_ actual: JSONValue, method: String) throws {
        if method == "task", actual != .null {
            let record = try actual.decode(TaskRecord.self)
            #expect(try JSONValue(encoding: record) == actual)
            if record.kind == "pi.tool", record.version == 2 {
                let input = try record.input.decode(ToolTaskInput.self)
                #expect(try JSONValue(encoding: input) == record.input)
                if let raw = actual["state"]?["outcome"]?["result"] {
                    #expect(try JSONValue(encoding: raw.decode(ToolTaskResult.self)) == raw)
                }
            }
        }
        guard method == "document", actual != .null else { return }
        let stored = try actual.decode(StoredDocument.self)
        let kind = try #require(actual["record"]?["kind"]?.stringValue)
        let definitions = [AgentDoc.definition, InboxDoc.definition, LiveDoc.definition,
                           NestedCallDoc.definition, CodemodeRunDoc.definition,
                           CodemodeJournalDoc.definition, CodemodeStoreDoc.definition]
        guard let definition = definitions.first(where: { $0.kind == kind }) else { return }
        let value = JSONValue.object(try definition.materialize(stored))
        switch kind {
        case "pi.agent":
            let state = try value.decode(AgentState.self)
            #expect(try JSONValue(encoding: state) == value)
            try checkFilters(state, conversationId: #require(actual["record"]?["scope"]?["conversationId"]))
        case "pi.inbox": #expect(try JSONValue(encoding: value.decode(InboxState.self)) == value)
        case "pi.live": #expect(try JSONValue(encoding: value.decode(LiveState.self)) == value)
        case "pi.tool.nested-call": #expect(try JSONValue(encoding: value.decode(NestedCallState.self)) == value)
        case "pi.codemode.run":
            if let start = value["start"] { #expect(try JSONValue(encoding: start.decode(CodemodeStart.self)) == start) }
            if let details = value["result"]?["details"] {
                #expect(try JSONValue(encoding: details.decode(CodemodeToolDetails.self)) == details)
            }
        case "pi.codemode.journal": #expect(try JSONValue(encoding: value.decode(CodemodeJournal.self)) == value)
        default: #expect(value["values"]?.objectValue != nil)
        }
    }

    private func checkFilters(_ state: AgentState, conversationId: JSONValue) throws {
        let url = try #require(Bundle.module.url(forResource: "closeout-documents-v130", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        let expected = try #require(fixture["filters"]?.arrayValue?.first { $0["conversationId"] == conversationId })
        let registry = createRegistry()
        let tools = try #require(fixture["catalog"]?.arrayValue).map { item in
            let name = try #require(item["name"]?.stringValue)
            return try ToolRegistration(name: name, description: name, parameters: ["type": "object"],
                callers: try item["callers"]?.decode([ToolCaller].self), deferred: item["deferred"]?.boolValue) { _, _, _ in
                ToolExecutionResult(output: [])
            }
        }
        try registry.install(Extension(name: "fixture.tools", tools: tools))
        let agent = resolveAgent(state: state, snapshot: registry.snapshot())
        #expect(try JSONValue(encoding: agent.tools.map(\.name)) == expected["tools"])
        #expect(try JSONValue(encoding: agent.callable.map(\.name)) == expected["callable"])
        #expect(try JSONValue(encoding: agent.deferred.map(\.name)) == expected["deferred"])
    }

    private func typedWrites(_ raw: JSONValue, dataset: JSONValue, storage: any DurableStorage) async throws -> [StorageWrite] {
        var writes: [StorageWrite] = []
        for item in try #require(raw.arrayValue) {
            var write = try #require(item.objectValue)
            if item["type"] == "task", var task = item["value"]?.objectValue,
               task["kind"] == "pi.tool", task["version"] == 2 {
                if dataset["name"] == "migrated",
                   let id = task["id"], let old = try await storage.task(id.decode(TaskID.self), context: .background),
                   old.version == 1 {
                    let migrate = try #require(toolTask.eraseToAnyTaskDefinition().migrate)
                    let previous = try JSONValue(encoding: old)
                    let converted = try migrate(old.input, #require(previous["state"]?["checkpoint"]), 1)
                    task["input"] = converted.input
                    var state = try #require(task["state"]?.objectValue)
                    state["checkpoint"] = converted.checkpoint
                    task["state"] = .object(state)
                } else {
                    task["input"] = try JSONValue(encoding: #require(task["input"]).decode(ToolTaskInput.self))
                }
                if var state = task["state"]?.objectValue, var outcome = state["outcome"]?.objectValue,
                   let result = outcome["result"] {
                    outcome["result"] = try JSONValue(encoding: result.decode(ToolTaskResult.self))
                    state["outcome"] = .object(outcome)
                    task["state"] = .object(state)
                }
                write["value"] = .object(task)
            }
            #expect(JSONValue.object(write) == item)
            writes.append(try JSONValue.object(write).decode(StorageWrite.self))
        }
        return writes
    }

    private func compare(_ storage: any DurableStorage, reads: [JSONValue]) async throws {
        try #require(!reads.isEmpty)
        for read in reads {
            let method = try #require(read["method"]?.stringValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method,
                args: #require(read["arguments"]?.arrayValue), storage: storage)
            #expect(actual == read["result"], "Matrix read: \(method)")
            try typedReads(actual, method: method)
        }
    }

    private func checkMigration(_ dataset: JSONValue, storage: any DurableStorage) async throws {
        guard dataset["name"] == "tools" else { return }
        let migrate = try #require(toolTask.eraseToAnyTaskDefinition().migrate)
        let migrations = try #require(dataset["migrations"]?.arrayValue)
        #expect(migrations.count == 2)
        for expected in migrations {
            let id = try #require(expected["taskId"]).decode(TaskID.self)
            let task = try #require(try await storage.task(id, context: .background))
            let raw = try JSONValue(encoding: task)
            #expect(task.version == 1)
            let result = try migrate(task.input, #require(raw["state"]?["checkpoint"]), 1)
            #expect(result.input == expected["input"])
            #expect(result.checkpoint == expected["checkpoint"])
        }
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func nodeWritesSwiftReads(backend: String) async throws {
        let (directory, datasets) = try prepare(backend)
        defer { try? FileManager.default.removeItem(at: directory) }
        for dataset in datasets {
            let name = try #require(dataset["name"]?.stringValue)
            let final: JSONValue = ["reads": try #require(dataset["reads"])]
            for step in [final] + (dataset["checkpoints"]?.arrayValue ?? []) {
                let suffix = step["seq"]?.intValue.map { ".checkpoint-\($0)" } ?? ""
                let path = directory.appendingPathComponent("node/\(backend)/\(name)\(suffix)")
                // Opening a shared file twice also checks persisted state after Swift close.
                for _ in 0..<2 {
                    let storage = try await open(path, backend: backend)
                    do {
                        try await compare(storage, reads: #require(step["reads"]?.arrayValue))
                        if suffix.isEmpty { try await checkMigration(dataset, storage: storage) }
                    } catch { try? await storage.close(context: .background); throw error }
                    try await storage.close(context: .background)
                }
            }
        }
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func swiftWritesNodeReads(backend: String) async throws {
        let (directory, datasets) = try prepare(backend)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("swift/\(backend)"), withIntermediateDirectories: true)
        for dataset in datasets {
            let name = try #require(dataset["name"]?.stringValue)
            let final: JSONValue = ["reads": try #require(dataset["reads"])]
            for step in [final] + (dataset["checkpoints"]?.arrayValue ?? []) {
                let through = step["seq"]?.intValue
                let suffix = through.map { ".checkpoint-\($0)" } ?? ""
                let path = directory.appendingPathComponent("swift/\(backend)/\(name)\(suffix)")
                let storage = try await open(path, backend: backend)
                do {
                    for batch in try #require(dataset["batches"]?.arrayValue) {
                        if let through, let seq = batch["seq"]?.intValue, seq > through { break }
                        let raw = try #require(batch["writes"])
                        let writes = try await typedWrites(raw, dataset: dataset, storage: storage)
                        #expect(try JSONValue(encoding: writes) == raw)
                        let seq = try await storage.commit(writes, context: .background)
                        #expect(try JSONValue(encoding: seq) == batch["seq"])
                    }
                    try await compare(storage, reads: #require(step["reads"]?.arrayValue))
                    if through == nil { try await checkMigration(dataset, storage: storage) }
                } catch { try? await storage.close(context: .background); throw error }
                try await storage.close(context: .background)
                let reopened = try await open(path, backend: backend)
                do { try await compare(reopened, reads: #require(step["reads"]?.arrayValue)) }
                catch { try? await reopened.close(context: .background); throw error }
                try await reopened.close(context: .background)
            }
        }
        try bridge("verify", directory: directory, backend: backend)
    }
}
#endif
