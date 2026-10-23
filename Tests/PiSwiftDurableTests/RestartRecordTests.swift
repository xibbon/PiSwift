import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.RestartRecords")
struct RestartRecordTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "restart-records-v130", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func compare(_ storage: any DurableStorage) async throws {
        for call in try #require(fixture()["reads"]?.arrayValue) {
            let method = try #require(call["method"]?.stringValue)
            let args = try #require(call["arguments"]?.arrayValue)
            let result = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
            #expect(result == call["result"], "Restart fixture read: \(method)")
        }
    }

    private func replay(_ storage: any DurableStorage) async throws {
        for batch in try #require(fixture()["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            let seq = try await storage.commit(writes, context: .background)
            #expect(try JSONValue(encoding: seq) == batch["seq"])
        }
        try await compare(storage)
    }

    @Test func typedFieldsRoundTripEveryUpstreamWrite() throws {
        let fixture = try fixture()
        #expect(fixture["tag"] == "v1.3.0")
        var marked = 0
        var absent = 0
        var rawFalse = 0
        for batch in try #require(fixture["batches"]?.arrayValue) {
            for write in try #require(batch["writes"]?.arrayValue) {
                #expect(try JSONValue(encoding: write.decode(StorageWrite.self)) == write)
                guard write["type"] == "task" else { continue }
                let json = try #require(write["value"])
                let task = try json.decode(TaskRecord.self)
                #expect(task.extensionFields["abandonOnRestart"] == nil)
                #expect(task.extensionFields["abortReason"] == nil)
                if json["abortReason"] == "restart" {
                    #expect(task.abortReason == .restart)
                    marked += 1
                } else { #expect(task.abortReason == nil) }
                if json["abandonOnRestart"] == true { #expect(task.abandonOnRestart == true) }
                else if json["abandonOnRestart"] == false {
                    #expect(task.abandonOnRestart == false)
                    rawFalse += 1
                } else {
                    #expect(task.abandonOnRestart == nil)
                    absent += 1
                }
            }
        }
        #expect(marked == 4)
        #expect(absent == 2)
        #expect(rawFalse == 1)
    }

    @Test func memoryMatchesUpstreamRecords() async throws {
        let storage = MemoryStorage()
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqlitePreservesFieldsAcrossEveryReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("restart.sqlite").path
        let storage = ReopeningStorage(storage: try await SqliteStorage.open(path: path), path: path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlPreservesFieldsAcrossEveryReopen() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let opened = try await jsonlOpen(directory)
        let storage = JsonlReopeningStorage(storage: opened, directory: directory.path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func sqliteReadsUpstreamRestartFile() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "restart-upstream-v130", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("restart.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await SqliteStorage.open(path: path.path)
        try await compare(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlReadsUpstreamRestartFiles() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "restart-upstream-jsonl-v130", withExtension: nil, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("restart-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await jsonlOpen(path)
        try await compare(storage)
        try await storage.close(context: .background)
    }

    @Test func sqliteExportsRestartFileForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_RESTART_SQLITE_EXPORT"] else { return }
        let storage = try await SqliteStorage.open(path: path)
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func jsonlExportsRestartFilesForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_RESTART_JSONL_EXPORT"] else { return }
        let storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
        try await replay(storage)
        try await storage.close(context: .background)
    }

    @Test func creationAndTimeStampCopiesPreserveTypedFields() async throws {
        let storage = MemoryStorage()
        let session = try await Session.open(storage: storage, now: { 1700000000000 }, context: .background)
        let conversation = try await createConversation(session)
        let task = TaskKind<JSONObject, JSONObject>(name: "test.restart-record", version: 1, initial: { _ in ["phase": "ready"] })
        let ids = try await session.commit({ tx in
            var ids: [TaskID] = []
            for abandon in [false, true] {
                ids.append(try await tx.createTask(task, input: [:], options: .init(
                    ownership: .conversation(), conversationId: conversation, abandonOnRestart: abandon)))
            }
            ids.append(try await tx.createTask(task, input: [:], options: .init(
                ownership: .task(taskId: ids[1]), abandonOnRestart: true)))
            return ids
        }, context: .background)
        #expect(try await storage.task(ids[0], context: .background)?.abandonOnRestart == nil)
        #expect(try await storage.task(ids[1], context: .background)?.abandonOnRestart == true)
        #expect(try await storage.task(ids[2], context: .background)?.abandonOnRestart == true)
        try await session.commitWith({ tx in
            let value = try #require(await tx.task(ids[1]))
            let marked = TaskRecord(id: value.id, conversationId: value.conversationId, kind: value.kind,
                                    version: value.version, input: value.input,
                                    state: .running(checkpoint: ["phase": "cleanup"]),
                                    abortRequested: true, abortReason: .restart, abandonOnRestart: value.abandonOnRestart,
                                    extensionFields: ["retained": ["nested": true]])
            try tx.setTask(marked)
        }, context: .background)
        let saved = try #require(await storage.task(ids[1], context: .background))
        #expect(saved.startedAt == 1700000000000)
        #expect(saved.abortReason == .restart)
        #expect(saved.abandonOnRestart == true)
        #expect(saved.extensionFields == ["retained": ["nested": true]])
        try await session.close(context: .background)
    }
}
