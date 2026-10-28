import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D4CurrentFixtures")
struct D4CurrentFixtureTests {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    // The frozen tests execute each prior case. Compare every result field with
    // the new tag, including opaque record fields and all seeded tool results.
    @Test(arguments: ["closeout-documents", "codemode", "context-baseline", "edit-fixtures",
                      "nested-tool-records", "read-differential", "restart-records", "search",
                      "structured-tool-schema", "tool-task-records", "w5-examples"])
    func currentTagKeepsEveryPriorScenario(name: String) throws {
        var previous = try #require(fixture("\(name)-v130").objectValue)
        var current = try #require(fixture("\(name)-v140").objectValue)
        #expect(previous.removeValue(forKey: "tag") == "v1.3.0")
        #expect(current.removeValue(forKey: "tag") == "v1.4.0")
        let oldProvenance = previous.removeValue(forKey: "provenance")
        let newProvenance = current.removeValue(forKey: "provenance")
        if let oldProvenance, let newProvenance {
            let expected = try JSONValue(jsonText: oldProvenance.jsonText().replacingOccurrences(of: "v1.3.0", with: "v1.4.0"))
            #expect(newProvenance == expected)
        } else { #expect(oldProvenance == newProvenance) }
        if name == "codemode" { #expect(current.removeValue(forKey: "checkpointEvidence") != nil) }
        #expect(JSONValue.object(current) == .object(previous), "Current fixture: \(name)")
    }

    private func compare(_ storage: any DurableStorage, reads: [JSONValue]) async throws {
        for read in reads {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let actual = try await PiSwiftDurableTests().sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == read["result"], "Current fixture read: \(method)")
        }
    }

    @Test(arguments: ["closeout-documents", "nested-tool-records", "restart-records", "tool-task-records"])
    func memoryReplaysEveryCurrentBatch(name: String) async throws {
        let data = try fixture("\(name)-v140")
        let storage = MemoryStorage()
        for batch in try #require(data["batches"]?.arrayValue) {
            let raw = try #require(batch["writes"])
            let writes = try raw.decode([StorageWrite].self)
            #expect(try JSONValue(encoding: writes) == raw)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
            for checkpoint in data["checkpoints"]?.arrayValue ?? [] where checkpoint["seq"] == batch["seq"] {
                try await compare(storage, reads: #require(checkpoint["reads"]?.arrayValue))
            }
        }
        try await compare(storage, reads: #require(data["reads"]?.arrayValue))
        try await storage.close(context: .background)
    }

    @Test(arguments: ["nested-tool", "restart", "tool-task"])
    func sqliteReadsCurrentUpstreamFiles(name: String) async throws {
        let record = name == "restart" ? "restart-records" : "\(name)-records"
        let data = try fixture("\(record)-v140")
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "\(name)-upstream-v140", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("current.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        for _ in 0..<2 {
            let storage = try await SqliteStorage.open(path: path.path)
            try await compare(storage, reads: #require(data["reads"]?.arrayValue))
            try await storage.close(context: .background)
        }
    }

    @Test(arguments: ["nested-tool", "restart", "tool-task"])
    func jsonlReadsCurrentUpstreamFiles(name: String) async throws {
        let record = name == "restart" ? "restart-records" : "\(name)-records"
        let data = try fixture("\(record)-v140")
        let directory = try jsonlTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "\(name)-upstream-jsonl-v140", withExtension: nil, subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("current-jsonl")
        try FileManager.default.copyItem(at: source, to: path)
        for _ in 0..<2 {
            let storage = try await jsonlOpen(path)
            try await compare(storage, reads: #require(data["reads"]?.arrayValue))
            try await storage.close(context: .background)
        }
    }

    @Test func prefixedSqliteReadsEveryCurrentRecordAcrossReopen() async throws {
        let data = try fixture("records")
        #expect(data["tag"] == "v1.4.0")
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "prefix-upstream-v140", withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("current-prefix.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        for _ in 0..<2 {
            let storage = try await SqliteStorage.open(path: path.path, prefix: "pi_")
            try await compare(storage, reads: #require(data["reads"]?.arrayValue))
            try await storage.close(context: .background)
        }
    }

    @Test func codemodeBaseKeepsHistoricalAndForkValues() async throws {
        let data = try #require(fixture("codemode-v140")["checkpointEvidence"])
        #expect(data["taskPoliciesAt1000"] == ["run": false, "journal": false])
        #expect(data["after64"]?["deltasSinceBase"] == 64)
        #expect(data["after65"]?["deltasSinceBase"] == 0)
        #expect(data["after66"]?["deltasSinceBase"] == 1)
        #expect(data["historical"] == ["values": ["counter": 32]])
        #expect(data["forkSnapshot"] == ["values": ["counter": 32]])
        let id = try #require(data["documentId"]).decode(DocumentID.self)
        #expect(data["baseBatch"]?["writes"] == [["type": "document.change", "id": try JSONValue(encoding: id),
            "content": ["version": 1, "kind": "base", "value": ["values": ["counter": 65]]]]])
        let storage = MemoryStorage()
        let batches = try #require(data["batches"]?.arrayValue)
        for batch in batches {
            let raw = try #require(batch["writes"])
            let writes = try raw.decode([StorageWrite].self)
            #expect(try JSONValue(encoding: writes) == raw)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
            let expected: JSONValue?
            if batch["seq"] == 67 { expected = data["after64"] }
            else if batch["seq"] == data["baseBatch"]?["seq"] { expected = data["after65"] }
            else if batch["seq"] == batches.last?["seq"] { expected = data["after66"] }
            else { expected = nil }
            if let expected {
                let document = try #require(try await storage.document(id, at: .current, context: .background))
                #expect(try JSONValue(encoding: document) == expected)
            }
        }
        let session = try await Session.open(storage: storage, context: .background)
        let conversation = try #require(data["conversationId"]).decode(ConversationID.self)
        let cutoff = try #require(data["cutoffId"]).decode(EntryID.self)
        let fork = try #require(data["forkId"]).decode(ConversationID.self)
        #expect(try await session.snapshotAsOf(CodemodeStoreDoc, conversationId: conversation, at: cutoff, context: .background) == data["historical"]?.objectValue)
        #expect(try await session.snapshot(CodemodeStoreDoc, conversationId: fork, context: .background) == data["forkSnapshot"]?.objectValue)
        #expect(try await session.snapshot(CodemodeStoreDoc, conversationId: conversation, context: .background) == data["after66"]?["value"]?.objectValue)
        try await session.close(context: .background)
    }
}
