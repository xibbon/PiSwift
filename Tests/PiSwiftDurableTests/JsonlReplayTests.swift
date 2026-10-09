import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    private func compareJsonlReads(_ storage: JsonlStorage, records: JSONValue) async throws {
        for (index, read) in try #require(records["reads"]?.arrayValue).enumerated() {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let actual = try await sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == read["result"], "Upstream read \(index + 1): \(method)")
        }
    }

    @Test func jsonlStorageMatchesEveryUpstreamRead() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try await JsonlStorage.open(directory: directory.path, fileSystem: LocalExecutionEnv(cwd: directory.path))
        let records = try fixture()
        for batch in try #require(records["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
        }
        try await compareJsonlReads(storage, records: records)
        try await storage.close(context: .background)
    }

    @Test func jsonlReadsUpstreamFile() async throws {
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "upstream-jsonl", withExtension: nil, subdirectory: "Fixtures"))
        let target = directory.appendingPathComponent("upstream-jsonl")
        try FileManager.default.copyItem(at: source, to: target)
        let storage = try await JsonlStorage.open(directory: target.path, fileSystem: LocalExecutionEnv(cwd: target.path))
        try await compareJsonlReads(storage, records: fixture())
        try await storage.close(context: .background)
    }

    @Test func jsonlExportForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_JSONL_EXPORT"] else { return }
        let storage = try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
        let records = try fixture()
        for batch in try #require(records["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
        }
        try await compareJsonlReads(storage, records: records)
        try await storage.close(context: .background)
    }

}
