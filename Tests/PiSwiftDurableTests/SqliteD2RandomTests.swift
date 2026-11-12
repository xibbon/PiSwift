import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private struct D2Random {
    var state: UInt32
    mutating func int(_ max: Int) -> Int {
        state &+= 0x6d2b79f5
        var value = (state ^ (state >> 15)) &* (state | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return Int((value ^ (value >> 14)) % UInt32(max))
    }
}
private struct D2Outcome: Equatable {
    let stored: Int
    let refused: Bool
    let receipts: [Seq]
}
private func randomOutcome(_ storage: any DurableStorage, _ batches: [[StorageWrite]]) async throws -> D2Outcome {
    let receipts = Mutex<[Seq]>([])
    let result = try await storage.commit(batches, receive: { index, seq in
        receipts.withLock { #expect(index == $0.count); $0.append(seq) }
    }, context: .background)
    return .init(stored: result.stored, refused: result.refused != nil, receipts: receipts.withLock { $0 })
}
private func randomSnapshot(_ storage: any DurableStorage, documents: [Int], at: DocumentPoint) async throws -> JSONValue {
    var values: JSONObject = [:]
    values["conversations"] = try JSONValue(encoding: await storage.scanConversations(.init(), limit: 10_000, cursor: nil, context: .background))
    values["entries"] = try JSONValue(encoding: await storage.scanEntries(.init(conversationId: rootConversationID, order: .ascending), limit: 10_000, cursor: nil, context: .background))
    values["tasks"] = try JSONValue(encoding: await storage.scanTasks(.init(), limit: 10_000, cursor: nil, context: .background))
    values["submissions"] = try JSONValue(encoding: await storage.scanSubmissions(.init(), limit: 10_000, cursor: nil, context: .background))
    for id in documents {
        do { values["doc\(id)"] = try JSONValue(encoding: await storage.document(DocumentID(Int64(id)), at: at, context: .background)) }
        catch { values["doc\(id)"] = ["error": .string(String(describing: error))] }
    }
    return .object(values)
}
extension SqliteStorage {
    fileprivate func randomTableDump() throws -> [[SqliteRow]] {
        try ["durable_metadata", "record_ids", "conversations", "entries", "tasks", "submissions", "documents", "document_revisions"].map { try db.all("SELECT * FROM \($0) ORDER BY 1, 2") }
    }
    fileprivate func staleRandomRevisions() throws -> [SqliteRow] {
        try db.all("""
            SELECT revision.document_id, revision.seq FROM document_revisions AS revision
            JOIN documents AS document ON document.id = revision.document_id
            WHERE (document.scope_kind != 'conversation' OR json_extract(document.record, '$.history') = 'latest')
            AND (document.retired_at IS NOT NULL OR revision.seq < (
                SELECT MAX(seq) FROM document_revisions WHERE document_id = revision.document_id AND kind = 'base'))
            """)
    }
}

@Suite("PiSwiftDurableTests.SqliteD2Random")
struct SqliteD2RandomTests {
    @Test(arguments: [1, 2, 3, 4, 5, 6]) func randomBatchesAgreeWithMemoryAndIndividualCommits(seed: Int) async throws {
        let memory = MemoryStorage()
        let grouped = try await SqliteStorage.open(path: ":memory:")
        let single = try await SqliteStorage.open(path: ":memory:")
        let root: [[StorageWrite]] = [[.conversation(value: ConversationRecord(id: rootConversationID))]]
        for storage in [memory as any DurableStorage, grouped, single] { _ = try await randomOutcome(storage, root) }
        var random = D2Random(state: UInt32(seed)), nextID = 2
        var documents: [Int] = [], allSequences: [Seq] = []
        var refusals = 0, prefixes = 0, groups = 0
        func write(_ value: JSONValue) throws -> StorageWrite { try value.decode(StorageWrite.self) }
        for round in 0..<120 {
            var batches: [[StorageWrite]] = []
            for _ in 0..<(1 + random.int(6)) {
                var writes: [StorageWrite] = []
                for _ in 0..<(1 + random.int(4)) {
                    let operation = random.int(round % 4 == 0 ? 4 : 8)
                    let fresh = nextID; nextID += 1
                    switch operation {
                    case 0, 1:
                        let id = round % 4 != 0 && random.int(10) == 0 ? max(1, fresh - 2) : fresh
                        writes.append(try write(["type": "entry", "value": ["id": .number(Double(id)), "conversationId": 1, "kind": "note", "data": .number(Double(random.int(1000)))]]))
                    case 2:
                        let id = 100_000 + random.int(8)
                        writes.append(try write(["type": "task", "value": ["id": .number(Double(id)), "conversationId": 1, "kind": "random", "version": 1, "input": nil, "background": false, "abortRequested": false, "state": ["status": "pending", "checkpoint": ["n": .number(Double(random.int(10)))]]]]))
                    case 3:
                        let id = 200_000 + random.int(8)
                        writes.append(try write(["type": "submission", "value": ["id": .number(Double(id)), "conversationId": 1, "type": "input", "status": "queued", "requestId": .string("r\(id)")]]))
                    case 4:
                        documents.append(fresh)
                        let latest = random.int(2) == 0
                        let record: JSONValue = ["id": .number(Double(fresh)), "kind": "random", "key": .string(String(random.int(30))), "scope": ["kind": "conversation", "conversationId": 1], "history": latest ? "latest" : "rewindable", "fork": latest ? "current" : "asOf"]
                        writes.append(try write(["type": "document.create", "record": record, "content": ["kind": "base", "version": 1, "value": ["n": 0]]]))
                    default:
                        guard !documents.isEmpty else { continue }
                        let id = documents[random.int(documents.count)]
                        if operation == 7 {
                            writes.append(try write(["type": "document.retire", "id": .number(Double(id))]))
                        } else {
                            let content: JSONValue = operation == 5 ? ["kind": "base", "version": 1, "value": ["n": .number(Double(random.int(100)))]] : ["kind": "delta", "version": 1, "ops": [["s", ["n"], .number(Double(random.int(100)))]]]
                            writes.append(try write(["type": "document.change", "id": .number(Double(id)), "content": content]))
                        }
                    }
                }
                if !writes.isEmpty { batches.append(writes) }
            }
            let expected = try await randomOutcome(memory, batches)
            let actual = try await randomOutcome(grouped, batches)
            #expect(actual == expected, "seed \(seed), round \(round)")
            for batch in batches {
                if try await randomOutcome(single, [batch]).stored == 0 { break }
            }
            #expect(try await grouped.randomTableDump() == single.randomTableDump(), "seed \(seed), round \(round)")
            #expect(try await grouped.staleRandomRevisions().isEmpty)
            allSequences += expected.receipts
            if expected.refused { refusals += 1; if expected.stored > 0 { prefixes += 1 } }
            else if batches.count > 1 { groups += 1 }
            let point: DocumentPoint = allSequences.isEmpty ? .current : .sequence(allSequences[random.int(allSequences.count)])
            #expect(try await randomSnapshot(grouped, documents: documents, at: .current) == randomSnapshot(memory, documents: documents, at: .current))
            #expect(try await randomSnapshot(grouped, documents: documents, at: point) == randomSnapshot(memory, documents: documents, at: point))
        }
        #expect(refusals > 10)
        #expect(prefixes > 10)
        #expect(groups > 10)
        for storage in [memory as any DurableStorage, grouped, single] { try await storage.close(context: .background) }
    }
}
