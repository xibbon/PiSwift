import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

extension SqliteStorage {
    func sqlitePrepareCounts() -> [String: Int] { (db as? AppleSqliteDatabase)?.prepareCounts ?? [:] }
}

/// Rejects settlement after the callback, within the delegate's real SQL transaction.
private final class RejectingSettlementExecutor: SqliteExecutor {
    let delegate: AppleSqliteDatabase
    var reject = false
    init() throws { delegate = try AppleSqliteDatabase(path: ":memory:") }
    func exec(_ sql: String) throws { try delegate.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try delegate.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? { try delegate.get(sql, params) }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { try delegate.all(sql, params) }
    func close() throws { try delegate.close() }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try delegate.transaction { handle in
            let value = try body(handle)
            if reject { reject = false; throw StorageRejected("controlled settlement rejection") }
            return value
        }
    }
}

extension SqliteStorage {
    fileprivate func rejectNextSettlement() { (db as? RejectingSettlementExecutor)?.reject = true }
}

private actor TransactionProbe {
    let database: AppleSqliteDatabase
    init() throws {
        database = try AppleSqliteDatabase(path: ":memory:")
        try database.exec("CREATE TABLE transaction_queue (value INTEGER)")
    }
    func insert(_ value: Int64) throws {
        try database.transaction { handle in
            try handle.run("INSERT INTO transaction_queue (value) VALUES (?)", [.integer(value)])
            #expect(try handle.get("SELECT count(*) AS count FROM transaction_queue")?["count"]?.integerValue == value)
        }
    }
    func values() throws -> [Int64] {
        try database.all("SELECT value FROM transaction_queue ORDER BY value").compactMap { $0["value"]?.integerValue }
    }
    func close() throws { try database.close() }
}

@Suite("PiSwiftDurableTests.SqliteFacade")
struct SqliteFacadeTests {
    @Test func preparesStatementsOnceAcrossStorageTransactions() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background)
        let entries = try (2...101).map { id in StorageWrite.entry(value: EntryRecord(id: try EntryID(Int64(id)), conversationId: rootConversationID, kind: "cached")) }
        _ = try await storage.commit(entries, context: .background)
        _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(102), conversationId: rootConversationID, kind: "cached-again"))], context: .background)
        #expect(try await storage.entry(EntryID(2), context: .background)?.entry.kind == "cached")
        #expect(try await storage.entry(EntryID(102), context: .background)?.entry.kind == "cached-again")
        await #expect(throws: DurableStorageError.idAlreadyOwned(id: 1, recordType: "conversation")) { _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background) }
        #expect(try await storage.entry(EntryID(2), context: .background)?.entry.kind == "cached")
        #expect(await storage.sqlitePrepareCounts().values.allSatisfy { $0 == 1 })
        try await storage.close(context: .background)
    }

    @Test func commitsThroughHandleAndClosesIdempotently() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        try database.transaction { transaction in
            try transaction.exec("CREATE TABLE probe (value INTEGER)")
            try transaction.run("INSERT INTO probe (value) VALUES (?)", [.integer(1)])
        }
        #expect(try database.get("SELECT value FROM probe") == ["value": .integer(1)])
        try database.close()
        try database.close()
    }

    @Test func serializesTransactionsInActor() async throws {
        let probe = try TransactionProbe()
        // Actor calls have no suspension inside their SQL transaction.
        let first = Task { try await probe.insert(1) }
        try await first.value
        let second = Task { try await probe.insert(2) }
        try await second.value
        #expect(try await probe.values() == [1, 2])
        try await probe.close()
        let storage = try await SqliteStorage.open(path: ":memory:")
        let sequences = try await withThrowingTaskGroup(of: Seq.self) { group in
            for _ in 0..<32 { group.addTask { try await storage.commit([], context: .background) } }
            var values: [Seq] = []
            for try await seq in group { values.append(seq) }
            return values
        }
        #expect(sequences.map(\.rawValue).sorted() == Array(1...32).map(Int64.init))
        try await storage.close(context: .background)
    }

    @Test func rejectsStaleTransactionHandle() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE stale_probe (value INTEGER)")
        var handle: (any SqliteExecutor)?
        try database.transaction { transaction in
            handle = transaction
            try transaction.run("INSERT INTO stale_probe (value) VALUES (?)", [.integer(1)])
        }
        let stale = try #require(handle)
        #expect(throws: SqliteFacadeError.inactiveTransaction) { try stale.exec("INSERT INTO stale_probe (value) VALUES (2)") }
        #expect(throws: SqliteFacadeError.inactiveTransaction) { try stale.run("INSERT INTO stale_probe (value) VALUES (?)", [.integer(3)]) }
        #expect(throws: SqliteFacadeError.inactiveTransaction) { _ = try stale.get("SELECT value FROM stale_probe") }
        #expect(throws: SqliteFacadeError.inactiveTransaction) { _ = try stale.all("SELECT value FROM stale_probe") }
        #expect(try database.all("SELECT value FROM stale_probe") == [["value": .integer(1)]])
    }

    @Test func failedRollbackChangesGuaranteedRejection() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        defer { try? database.close() }
        try database.exec("CREATE TABLE rollback_probe (value INTEGER)")
        do {
            try database.transaction { transaction in
                try transaction.exec("INSERT INTO rollback_probe (value) VALUES (1)")
                try transaction.exec("COMMIT")
                throw StorageRejected("rejected after an escaped commit")
            }
            Issue.record("Rollback failure accepted")
        } catch {
            let rollback = try #require(error as? SqliteRollbackError)
            #expect(rollback.transactionError as? StorageRejected == StorageRejected("rejected after an escaped commit"))
            #expect(rollback.rollbackError is SqliteError)
            #expect(!(error is StorageRejected))
        }
        #expect(try database.get("SELECT value FROM rollback_probe") == ["value": .integer(1)])
    }

    @Test func adoptsIDsOnlyAfterSuccessfulSettlement() async throws {
        let storage = try await SqliteStorage.open(executor: RejectingSettlementExecutor())
        await storage.rejectNextSettlement()
        await #expect(throws: StorageRejected.self) {
            _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(200), conversationId: rootConversationID, kind: "rejected"))], context: .background)
        }
        let first: EntryID = try await storage.mintId()
        #expect(first.rawValue == 2)
        #expect(try await storage.entry(EntryID(200), context: .background) == nil)
        _ = try await storage.commit([.entry(value: EntryRecord(id: EntryID(100), conversationId: rootConversationID, kind: "accepted"))], context: .background)
        let adopted: EntryID = try await storage.mintId()
        #expect(adopted.rawValue == 101)
        try await storage.close(context: .background)
    }

    @Test func admittedMultiQueryReadsFinishBeforeClose() async throws {
        let storage = try await SqliteStorage.open(path: ":memory:")
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), .entry(value: EntryRecord(id: EntryID(2), conversationId: rootConversationID, kind: "probe"))], context: .background)
        // Each admitted actor call finishes its synchronous queries before returning.
        #expect(try await storage.scanEntries(.init(conversationId: rootConversationID), limit: 10, cursor: nil, context: .background).items.map(\.id.rawValue) == [2])
        #expect(try await storage.entry(rootConversationID, id: EntryID(2), context: .background)?.entry.kind == "probe")
        #expect(try await storage.findLatestHeadMarker(rootConversationID, atOrBeforeEntryId: nil, context: .background) == nil)
        try await storage.close(context: .background)
        try await storage.close(context: .background)
        await #expect(throws: DurableStorageError.closed(backend: "SqliteStorage")) {
            _ = try await storage.scanEntries(.init(conversationId: rootConversationID), limit: 10, cursor: nil, context: .background)
        }
    }

    @Test func readsDocumentFromOneStateDuringBaseReplacement() async throws {
        for yields in 0..<16 {
            let storage = try await SqliteStorage.open(path: ":memory:")
            let create: JSONValue = ["type": "document.create", "record": ["id": 5, "kind": "replaced", "scope": ["kind": "session"]], "content": ["kind": "base", "version": 1, "value": ["value": 1]]]
            let replace: JSONValue = ["type": "document.change", "id": 5, "content": ["kind": "base", "version": 1, "value": ["value": 2]]]
            _ = try await storage.commit([create.decode(StorageWrite.self)], context: .background)
            let read = Task { try await storage.document(DocumentID(5), at: .current, context: .background) }
            for _ in 0..<yields { await Task.yield() }
            let commit = Task { try await storage.commit([replace.decode(StorageWrite.self)], context: .background) }
            let stored = try await read.value
            _ = try await commit.value
            #expect(stored?.value == ["value": 1] || stored?.value == ["value": 2])
            try await storage.close(context: .background)
        }
    }

    @Test func bindsAllSQLiteValueKindsAndRejectsAllOperationsAfterClose() throws {
        let database = try AppleSqliteDatabase(path: ":memory:")
        try database.exec("CREATE TABLE bindings (n, i, r, t, b)")
        let values: [SqliteValue] = [.null, .integer(4), .real(2.5), .text("a\0b"), .blob(Data([0, 1, 255]))]
        try database.run("INSERT INTO bindings VALUES (?, ?, ?, ?, ?)", values)
        #expect(try database.get("SELECT n, i, r, t, b FROM bindings") == ["n": values[0], "i": values[1], "r": values[2], "t": values[3], "b": values[4]])
        try database.close()
        #expect(throws: SqliteFacadeError.closed) { try database.exec("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { try database.run("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.get("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.all("SELECT 1") }
        #expect(throws: SqliteFacadeError.closed) { _ = try database.transaction { _ in 1 } }
    }
}
