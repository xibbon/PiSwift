import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    @Test func memoryStorageMatchesEveryUpstreamRead() async throws {
        let records = try fixture()
        let batches = try #require(records["batches"]?.arrayValue)
        let reads = try #require(records["reads"]?.arrayValue)
        let storage = MemoryStorage()
        #expect(batches.count == 14)
        #expect(reads.count == records["counts"]?["reads"]?.intValue)
        // The generator records all reads after all write batches.
        for (index, batch) in batches.enumerated() {
            let writes = try #require(batch["writes"]).decode([StorageWrite].self)
            let actual = try await storage.commit(writes, context: .background)
            #expect(try JSONValue(encoding: actual) == batch["seq"], "Upstream batch \(index + 1)")
        }
        for (index, read) in reads.enumerated() {
            let method = try #require(read["method"]?.stringValue)
            let args = try #require(read["arguments"]?.arrayValue)
            let expected = try #require(read["result"])
            let actual = try await replayRead(method, args: args, storage: storage)
            #expect(actual == expected, "Upstream read \(index + 1): \(method), arguments \(args)")
        }
        try await storage.close(context: .background)
    }

    private func replayRead(_ method: String, args: [JSONValue], storage: MemoryStorage) async throws -> JSONValue {
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
            throw ReplayError.unknownMethod(method)
        }
    }
}

private enum ReplayError: Error { case unknownMethod(String) }
