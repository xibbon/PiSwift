import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private struct BatchDriverState {
    var transactions = 0
    var committedEntries = 0
    var statements = 0
    var failEntryID: Int64?
    var failCopyRead = false
}

private final class BatchDriverControl: Sendable {
    let value = Mutex(BatchDriverState())
    func withLock<T: Sendable>(_ body: (inout sending BatchDriverState) throws -> sending T) rethrows -> sending T { try value.withLock(body) }
}

/// Keeps the driver inside the storage actor. The control state is safe for receipts.
private final class BatchDriver: SqliteExecutor {
    let database: AppleSqliteDatabase
    let state: BatchDriverControl
    init(state: BatchDriverControl, path: String = ":memory:") throws {
        self.state = state
        database = try AppleSqliteDatabase(path: path)
    }
    func exec(_ sql: String) throws { try database.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try database.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? { try database.get(sql, params) }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { try database.all(sql, params) }
    func close() throws { try database.close() }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        state.withLock { $0.transactions += 1 }
        let result = try database.transaction { try body(BatchTransaction(executor: $0, state: state)) }
        let count = try database.get("SELECT count(*) AS count FROM entries")?.sqliteInteger("count") ?? 0
        state.withLock { $0.committedEntries = Int(count) }
        return result
    }
}

private final class BatchTransaction: SqliteExecutor {
    let executor: any SqliteExecutor
    let state: BatchDriverControl
    init(executor: any SqliteExecutor, state: BatchDriverControl) {
        self.executor = executor; self.state = state
    }
    func exec(_ sql: String) throws { try executor.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws {
        state.withLock { $0.statements += 1 }
        var entryIDs: [Int64] = []
        if sql.hasPrefix("INSERT INTO entries"), let first = params.first {
            if case .text(let text) = first, case .array(let rows) = try JSONValue(jsonText: text) {
                entryIDs = rows.compactMap { row in
                    guard case .array(let cells) = row, case .number(let number) = cells.first else { return nil }
                    return Int64(number)
                }
            } else if let id = first.integerValue { entryIDs = [id] }
        }
        if let failingID = state.withLock({ $0.failEntryID }), entryIDs.contains(failingID) {
            // Use a Durable error type to prove that source, rather than type, selects refusal.
            throw DurableStorageError.documentAddressOccupied
        }
        try executor.run(sql, params)
    }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        if sql == "SELECT record FROM documents WHERE id = ?", state.withLock({ $0.failCopyRead }) {
            throw DurableStorageError.documentAddressOccupied
        }
        state.withLock { $0.statements += 1 }
        return try executor.get(sql, params)
    }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        state.withLock { $0.statements += 1 }
        return try executor.all(sql, params)
    }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T { try executor.transaction(body) }
    func close() throws { try executor.close() }
}

private func batchEntry(_ raw: Int64) throws -> StorageWrite {
    .entry(value: EntryRecord(id: try EntryID(raw), conversationId: rootConversationID, kind: "message"))
}
private func batchWrite(_ json: JSONValue) throws -> StorageWrite { try json.decode(StorageWrite.self) }
private func batchDocument(_ id: Int, conversation: Int = 1) throws -> StorageWrite {
    try batchWrite(["type": "document.create", "record": ["id": .number(Double(id)), "kind": "batch", "scope": ["kind": "conversation", "conversationId": .number(Double(conversation))], "history": "rewindable", "fork": "asOf"], "content": ["kind": "base", "version": 1, "value": ["count": 1]]])
}
private func batchCopy(_ id: Int, source: Int, conversation: Int) throws -> StorageWrite {
    try batchWrite(["type": "document.copy", "record": ["id": .number(Double(id)), "kind": "batch", "scope": ["kind": "conversation", "conversationId": .number(Double(conversation))], "history": "rewindable", "fork": "asOf"], "source": ["id": .number(Double(source)), "at": "current"]])
}
private func batchRoot(_ storage: SqliteStorage) async throws {
    let result = try await storage.commit([[.conversation(value: ConversationRecord(id: rootConversationID))]], receive: { _, _ in }, context: .background)
    #expect(result.stored == 1)
}

@Suite("PiSwiftDurableTests.SqliteD2Batch")
struct SqliteD2BatchTests {
    @Test func cancelledContextDoesNotInterruptSqliteCommit() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        let cancelled = ChordContext.background.withCancel()
        cancelled.cancel()
        let result = try await storage.commit([[.conversation(value: ConversationRecord(id: rootConversationID))]], receive: { _, _ in }, context: cancelled.context)
        #expect(result.stored == 1)
        #expect(try await storage.conversation(rootConversationID, context: .background) != nil)
        try await storage.close(context: .background)
    }

    @Test func receiptsFollowTheTransactionAndIncludeTheLastBatch() async throws {
        let state = BatchDriverControl()
        let storage = try await SqliteStorage.open(executor: BatchDriver(state: state))
        try await batchRoot(storage)
        state.withLock { $0.transactions = 0 }
        let receipts = Mutex<[(Int, Seq)]>([])
        let result = try await storage.commit([[batchEntry(2)], [batchEntry(3)], [batchEntry(4)]], receive: { index, seq in
            #expect(state.withLock { $0.transactions } == 1)
            #expect(state.withLock { $0.committedEntries } == 3)
            receipts.withLock { $0.append((index, seq)) }
        }, context: .background)
        #expect(result.stored == 3)
        #expect(result.refused == nil)
        #expect(receipts.withLock { $0.map(\.0) } == [0, 1, 2])
        #expect(receipts.withLock { $0.map { $0.1.rawValue } } == [2, 3, 4])
        #expect(try await storage.entry(EntryID(4), context: .background)?.commitSeq == Seq(4))
        try await storage.close(context: .background)
    }

    @Test func refusalStoresOnlyThePrefixAndDoesNotConsumeASequence() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        try await batchRoot(storage)
        let receipts = Mutex<[Int]>([])
        let result = try await storage.commit([[batchEntry(2)], [batchEntry(3), batchEntry(2)], [batchEntry(4)]], receive: { index, _ in receipts.withLock { $0.append(index) } }, context: .background)
        #expect(result.stored == 1)
        #expect(result.refused as? DurableStorageError == .idAlreadyOwned(id: 2, recordType: "entry"))
        #expect(receipts.withLock { $0 } == [0])
        #expect(try await storage.entry(EntryID(2), context: .background) != nil)
        #expect(try await storage.entry(EntryID(3), context: .background) == nil)
        #expect(try await storage.entry(EntryID(4), context: .background) == nil)
        let next = Mutex<[Seq]>([])
        _ = try await storage.commit([[batchEntry(4)]], receive: { _, seq in next.withLock { $0.append(seq) } }, context: .background)
        #expect(next.withLock { $0 } == [try Seq(3)])
        try await storage.close(context: .background)
    }

    @Test func driverFailureRollsBackAllBatchesAndSendsNoReceipts() async throws {
        let state = BatchDriverControl()
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("batch-fault.sqlite").path
        let storage = try await SqliteStorage.open(executor: BatchDriver(state: state, path: path))
        try await batchRoot(storage)
        state.withLock { $0.failEntryID = 3 }
        let receipts = Mutex<[Int]>([])
        await #expect(throws: DurableStorageError.documentAddressOccupied) {
            _ = try await storage.commit([[batchEntry(2)], [batchEntry(3)]], receive: { index, _ in receipts.withLock { $0.append(index) } }, context: .background)
        }
        #expect(receipts.withLock { $0.isEmpty })
        #expect(try await storage.entry(EntryID(2), context: .background) == nil)
        try await storage.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path)
        #expect(try await reopened.entry(EntryID(2), context: .background) == nil)
        #expect(try await reopened.entry(EntryID(3), context: .background) == nil)
        _ = try await reopened.commit([[batchEntry(4)]], receive: { _, seq in #expect(seq == (try? Seq(2))) }, context: .background)
        try await reopened.close(context: .background)
    }

    @Test func copyUsesEarlierBatchesAndDriverFailureDuringCopyRollsBack() async throws {
        let state = BatchDriverControl()
        let storage = try await SqliteStorage.open(executor: BatchDriver(state: state))
        try await batchRoot(storage)
        let change = try batchWrite(["type": "document.change", "id": 2, "content": ["kind": "delta", "version": 1, "ops": [["s", ["count"], 2]]]])
        let result = try await storage.commit([[batchDocument(2)], [change], [.conversation(value: ConversationRecord(id: ConversationID(3))), batchCopy(4, source: 2, conversation: 3)]], receive: { _, _ in }, context: .background)
        #expect(result.stored == 3)
        #expect(try await storage.document(DocumentID(4), at: .current, context: .background)?.value == ["count": 2])
        state.withLock { $0.failCopyRead = true }
        await #expect(throws: DocumentCopyFailure.self) {
            _ = try await storage.commit([[batchEntry(5)], [.conversation(value: ConversationRecord(id: ConversationID(6))), batchCopy(7, source: 2, conversation: 6)]], receive: { _, _ in Issue.record("Receipt sent for rolled back transaction") }, context: .background)
        }
        state.withLock { $0.failCopyRead = false }
        #expect(try await storage.entry(EntryID(5), context: .background) == nil)
        #expect(try await storage.conversation(ConversationID(6), context: .background) == nil)
        try await storage.close(context: .background)
    }

    @Test func oneHundredFiftyBatchesUseAConstantNumberOfStatements() async throws {
        let state = BatchDriverControl()
        let storage = try await SqliteStorage.open(executor: BatchDriver(state: state))
        try await batchRoot(storage)
        state.withLock { $0.statements = 0; $0.transactions = 0 }
        let batches = try (2..<152).map { [try batchEntry(Int64($0))] }
        let result = try await storage.commit(batches, receive: { _, _ in }, context: .background)
        #expect(result.stored == 150)
        // Metadata read, ID read, two table inserts, metadata update.
        #expect(state.withLock { $0.statements } == 5)
        #expect(state.withLock { $0.transactions } == 1)
        try await storage.close(context: .background)
    }

    @Test(arguments: [true, false]) func tenThousandWrites(manyBatches: Bool) async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        try await batchRoot(storage)
        let writes = try (2..<10_002).map { try batchEntry(Int64($0)) }
        let batches = manyBatches ? writes.map { [$0] } : [writes]
        let receipts = Mutex(0)
        let start = ContinuousClock.now
        let result = try await storage.commit(batches, receive: { _, _ in receipts.withLock { $0 += 1 } }, context: .background)
        let elapsed = start.duration(to: .now)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("SQLite D2: 10000 writes, \(batches.count) batches: \(elapsed), peak RSS \(usage.ru_maxrss) bytes")
        #expect(result.stored == batches.count)
        #expect(receipts.withLock { $0 } == batches.count)
        #expect(try await storage.entry(EntryID(10_001), context: .background) != nil)
        try await storage.close(context: .background)
    }
}
