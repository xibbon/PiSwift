import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    private func compareSqliteReads(_ storage: SqliteStorage, records: JSONValue) async throws {
        for (index, read) in try #require(records["reads"]?.arrayValue).enumerated() {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let actual = try await sqliteReplayRead(method, args: args, storage: storage)
            #expect(actual == read["result"], "Upstream read \(index + 1): \(method)")
        }
    }

    @Test func sqliteStorageMatchesEveryUpstreamRead() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try await SqliteStorage.open(path: directory.appendingPathComponent("replay.sqlite").path)
        let records = try fixture()
        for batch in try #require(records["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
        }
        try await compareSqliteReads(storage, records: records)
        try await storage.close(context: .background)
    }

    @Test func sqliteReadsUpstreamFile() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: "upstream", withExtension: "sqlite", subdirectory: "Fixtures"))
        let target = directory.appendingPathComponent("upstream.sqlite")
        try FileManager.default.copyItem(at: source, to: target)
        let storage = try await SqliteStorage.open(path: target.path)
        try await compareSqliteReads(storage, records: fixture())
        try await storage.close(context: .background)
    }

    @Test func sqliteExportForUpstreamRead() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_DURABLE_SQLITE_EXPORT"] else { return }
        let storage = try await SqliteStorage.open(path: path)
        let records = try fixture()
        for batch in try #require(records["batches"]?.arrayValue) {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            #expect(try JSONValue(encoding: await storage.commit(writes, context: .background)) == batch["seq"])
        }
        try await compareSqliteReads(storage, records: records)
        try await storage.close(context: .background)
    }

    func sqliteReplayRead(_ method: String, args: [JSONValue], storage: any DurableStorage) async throws -> JSONValue {
        func encoded<T: Encodable>(_ result: T?) throws -> JSONValue {
            if let result { return try JSONValue(encoding: result) }
            return .null
        }
        func cursor() throws -> Cursor? { args.count > 2 && !args[2].isNull ? try args[2].decode(Cursor.self) : nil }
        switch method {
        case "conversation": return try encoded(await storage.conversation(args[0].decode(ConversationID.self), context: .background))
        case "entry":
            if args.count == 1 { return try encoded(await storage.entry(args[0].decode(EntryID.self), context: .background)) }
            return try encoded(await storage.entry(args[0].decode(ConversationID.self), id: args[1].decode(EntryID.self), context: .background))
        case "findLatestHeadMarker":
            let cutoff = args[1].isNull ? nil : try args[1].decode(EntryID.self)
            return try encoded(await storage.findLatestHeadMarker(args[0].decode(ConversationID.self), atOrBeforeEntryId: cutoff, context: .background))
        case "task": return try encoded(await storage.task(args[0].decode(TaskID.self), context: .background))
        case "submission": return try encoded(await storage.submission(args[0].decode(SubmissionID.self), context: .background))
        case "submissionByRequest":
            return try encoded(await storage.submissionByRequest(args[0].decode(ConversationID.self), requestId: #require(args[1].stringValue), context: .background))
        case "findDocument":
            return try encoded(await storage.findDocument(args[0].decode(DocumentAddress.self), at: args[1].decode(DocumentPoint.self), context: .background))
        case "document":
            return try encoded(await storage.document(args[0].decode(DocumentID.self), at: args[1].decode(DocumentPoint.self), context: .background))
        case "scanConversations":
            return try JSONValue(encoding: await storage.scanConversations(args[0].decode(ConversationQuery.self), limit: #require(args[1].intValue), cursor: cursor(), context: .background))
        case "scanEntries":
            return try JSONValue(encoding: await storage.scanEntries(args[0].decode(EntryQuery.self), limit: #require(args[1].intValue), cursor: cursor(), context: .background))
        case "scanTasks":
            return try JSONValue(encoding: await storage.scanTasks(args[0].decode(TaskQuery.self), limit: #require(args[1].intValue), cursor: cursor(), context: .background))
        case "scanSubmissions":
            return try JSONValue(encoding: await storage.scanSubmissions(args[0].decode(SubmissionQuery.self), limit: #require(args[1].intValue), cursor: cursor(), context: .background))
        case "scanDocuments":
            return try JSONValue(encoding: await storage.scanDocuments(args[0].decode(DocumentQuery.self), limit: #require(args[1].intValue), cursor: cursor(), context: .background))
        default:
            throw SqliteReplayError.unknownMethod(method)
        }
    }
}

private enum SqliteReplayError: Error { case unknownMethod(String) }
