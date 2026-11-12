import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable

@Suite("PiSwiftDurableTests.D2TaggedBatchFixtures", .serialized)
struct D2TaggedBatchFixtureTests {
    private func fixture() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "batch-v152", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    private func open(_ path: URL, backend: String) async throws -> any DurableStorage {
        if backend == "jsonl" { return try await JsonlStorage.open(directory: path.path) }
        return try await SqliteStorage.open(path: path.path, prefix: backend == "prefix" ? "batch_" : nil)
    }

    private func checkReads(_ storage: any DurableStorage, _ reads: [JSONValue]) async throws {
        for read in reads {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == read["result"], "Tagged read: \(method) \(args)")
        }
    }

    @Test(arguments: ["sqlite", "prefix", "jsonl"])
    func opensTaggedBatchedFile(backend: String) async throws {
        let resource = backend == "jsonl" ? "batch-v152-jsonl" :
            (backend == "prefix" ? "batch-v152-prefixed" : "batch-v152-upstream")
        let ext: String? = backend == "jsonl" ? nil : "sqlite"
        let source = try #require(Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d2-tagged-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(backend == "jsonl" ? "store" : "store.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await open(path, backend: backend)
        try await checkReads(storage, #require(fixture()["reads"]?.arrayValue))
        try await storage.close(context: .background)
    }

    @Test func repairsTornTaggedJSONLExactly() async throws {
        let cases = try #require(fixture()["torn"]?.arrayValue)
        for item in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d2-torn-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = try #require(item["inputFiles"]?.objectValue)
            for (name, value) in input {
                let encoded = try #require(value.stringValue)
                let bytes = try #require(Data(base64Encoded: encoded))
                try bytes.write(to: directory.appendingPathComponent(name))
            }
            if item["error"] != nil && item["error"] != .null {
                await #expect(throws: (any Error).self) { _ = try await JsonlStorage.open(directory: directory.path) }
                continue
            }
            let storage = try await JsonlStorage.open(directory: directory.path)
            try await checkReads(storage, #require(item["reads"]?.arrayValue))
            try await storage.close(context: .background)
            let recovered = try #require(item["recoveredFiles"]?.objectValue)
            for (name, value) in recovered {
                let encoded = try #require(value.stringValue)
                let expected = try #require(Data(base64Encoded: encoded))
                #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == expected,
                        "Tagged recovery bytes differ for \(name), cut \(item["length"] ?? .null)")
            }
        }
    }

    @Test func batchExportForUpstreamRead() async throws {
        let values = try fixture()
        let specs = [("PI_DURABLE_BATCH_SQLITE_EXPORT", "sqlite"),
                     ("PI_DURABLE_BATCH_PREFIX_SQLITE_EXPORT", "prefix"),
                     ("PI_DURABLE_BATCH_JSONL_EXPORT", "jsonl")]
        for (key, backend) in specs {
            guard let path = ProcessInfo.processInfo.environment[key] else { continue }
            let storage = try await open(URL(fileURLWithPath: path), backend: backend)
            for call in try #require(values["commits"]?.arrayValue) {
                let batches = try #require(call["batches"]?.arrayValue).map { batch in
                    try #require(batch.arrayValue).map { try $0.decode(StorageWrite.self) }
                }
                let receipts = Mutex<[(Int, Seq)]>([])
                let result = try await storage.commit(batches, receive: { index, seq in
                    receipts.withLock { $0.append((index, seq)) }
                }, context: .background)
                #expect(result.stored == call["stored"]?.intValue)
                #expect((result.refused != nil) == (call["refused"] != .null))
                let expected = try #require(call["receipts"]?.arrayValue)
                #expect(receipts.withLock { $0.map(\.0) } == expected.compactMap { $0["index"]?.intValue })
                #expect(receipts.withLock { $0.map { $0.1.rawValue } } == expected.compactMap { $0["seq"]?.int64Value })
            }
            try await checkReads(storage, #require(values["reads"]?.arrayValue))
            try await storage.close(context: .background)
        }
    }
}
