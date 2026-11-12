import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private struct D2Statement: Sendable {
    let sql: String
    let params: [SqliteValue]
}
private final class D2StatementLog: Sendable {
    let rows = Mutex<[D2Statement]>([])
    func append(_ sql: String, _ params: [SqliteValue] = []) { rows.withLock { $0.append(.init(sql: sql, params: params)) } }
    func reset() { rows.withLock { $0 = [] } }
    var statements: [D2Statement] { rows.withLock { $0 } }
}
private final class D2RecordingExecutor: SqliteExecutor {
    let delegate: any SqliteExecutor
    let log: D2StatementLog
    init(_ delegate: any SqliteExecutor, log: D2StatementLog) { self.delegate = delegate; self.log = log }
    func exec(_ sql: String) throws { log.append(sql); try delegate.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { log.append(sql, params); try delegate.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? { log.append(sql, params); return try delegate.get(sql, params) }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { log.append(sql, params); return try delegate.all(sql, params) }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try delegate.transaction { try body(D2RecordingExecutor($0, log: log)) }
    }
    func close() throws { try delegate.close() }
}
private func statementWrite(_ value: JSONValue) throws -> StorageWrite { try value.decode(StorageWrite.self) }
private func statementCreate(_ id: Int, key: String? = nil) throws -> StorageWrite {
    var record: JSONObject = ["id": .number(Double(id)), "kind": "counter", "scope": ["kind": "session"]]
    record["key"] = key.map(JSONValue.string)
    return try statementWrite(["type": "document.create", "record": .object(record), "content": ["kind": "base", "version": 1, "value": ["n": 0]]])
}
private func statementChange(_ id: Int, base: Bool = false) throws -> StorageWrite {
    try statementWrite(["type": "document.change", "id": .number(Double(id)), "content": base ? ["kind": "base", "version": 1, "value": ["n": 2]] : ["kind": "delta", "version": 1, "ops": [["s", ["n"], 1]]]])
}
extension SqliteStorage {
    fileprivate func d2Plans(_ statements: [D2Statement]) throws -> [String] {
        try statements.filter { $0.sql.contains("json_each") }.flatMap { statement in
            try db.all("EXPLAIN QUERY PLAN " + statement.sql, statement.params).map { try $0.sqliteText("detail") }
        }
    }
}

@Suite("PiSwiftDurableTests.SqliteD2Statements")
struct SqliteD2StatementTests {
    private func group(_ count: Int, data: JSONValue = 0) async throws -> [D2Statement] {
        let log = D2StatementLog()
        let storage = try await SqliteStorage.open(executor: D2RecordingExecutor(AppleSqliteDatabase(path: ":memory:"), log: log))
        var setup: [StorageWrite] = [.conversation(value: ConversationRecord(id: rootConversationID))]
        for id in 2..<(count + 2) { setup.append(try statementCreate(id, key: String(id))) }
        _ = try await storage.commit([setup], receive: { _, _ in }, context: .background)
        var batches: [[StorageWrite]] = []
        for id in 2..<(count + 2) {
            let entry = try statementWrite(["type": "entry", "value": ["id": .number(Double(id + count)), "conversationId": 1, "kind": "note", "data": data]])
            batches.append([try statementChange(id), entry])
        }
        log.reset()
        let result = try await storage.commit(batches, receive: { _, _ in }, context: .background)
        #expect(result.stored == count)
        let statements = log.statements
        // Read every inserted record to verify that bound text survives without extra escaping.
        for id in (count + 2)..<(2 * count + 2) {
            #expect(try await storage.entry(EntryID(Int64(id)), context: .background)?.entry.data == data)
        }
        try await storage.close(context: .background)
        return statements
    }

    @Test func mixedBatchesUseTheSameEightSQLTexts() async throws {
        let one = try await group(1), three = try await group(3), many = try await group(150)
        #expect(one.count == 8)
        #expect(three.count == 8)
        #expect(many.count == 8)
        #expect(one.map(\.sql) == three.map(\.sql))
        #expect(three.map(\.sql) == many.map(\.sql))
    }

    @Test func smallRowsSplitAt512KiCharacters() async throws {
        let statements = try await group(100, data: .string(String(repeating: "x", count: 7_000)))
        let inserts = statements.filter { $0.sql.hasPrefix("INSERT INTO entries") }
        #expect(statements.count == 9)
        #expect(inserts.count == 2)
        for insert in inserts {
            #expect(insert.sql.contains("json_each"))
            #expect(try #require(insert.params.first?.textValue).utf16.count <= 512 * 1024)
        }
    }

    @Test func largeRowsUsePowerOfTwoBoundChunks() async throws {
        let two = try await group(2, data: .string(String(repeating: "\"", count: 400_000)))
        let nineteen = try await group(19, data: .string(String(repeating: "\"", count: 10_000)))
        #expect(two.filter { $0.sql.hasPrefix("INSERT INTO entries") }.map { $0.params.count } == [10])
        let inserts = nineteen.filter { $0.sql.hasPrefix("INSERT INTO entries") }
        #expect(inserts.map { $0.params.count } == [80, 10, 5])
        #expect(inserts.allSatisfy { !$0.sql.contains("json_each") })
    }

    @Test func batchQueriesUseStoredTableIndexes() async throws {
        let log = D2StatementLog()
        let storage = try await SqliteStorage.open(executor: D2RecordingExecutor(AppleSqliteDatabase(path: ":memory:"), log: log))
        _ = try await storage.commit([[.conversation(value: ConversationRecord(id: rootConversationID))], [statementCreate(2)]], receive: { _, _ in }, context: .background)
        log.reset()
        let entry = try statementWrite(["type": "entry", "value": ["id": 4, "conversationId": 1, "kind": "note"]])
        let retirement = try statementWrite(["type": "document.retire", "id": 2])
        _ = try await storage.commit([[statementChange(2)], [statementChange(2, base: true), entry], [retirement, statementCreate(3)]], receive: { _, _ in }, context: .background)
        let statements = log.statements
        #expect(statements.filter { $0.sql.contains("json_each") }.count > 5)
        let plans = try await storage.d2Plans(statements)
        #expect(plans.filter { $0.hasPrefix("SCAN") && !$0.contains("VIRTUAL TABLE") }.isEmpty)
        try await storage.close(context: .background)
    }

    @Test func schemaMatchesVersion140Fixture() throws {
        let fixture = try #require(Bundle.module.url(forResource: "nested-tool-upstream-v140", withExtension: "sqlite", subdirectory: "Fixtures"))
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("fixture.sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let original = try AppleSqliteDatabase(path: copy.path)
        defer { try? original.close() }
        let fresh = try AppleSqliteDatabase(path: ":memory:")
        defer { try? fresh.close() }
        try applySqliteMigrations(fresh, schema: .default)
        // SQLite preserves whitespace in sqlite_schema.sql. Compare SQL tokens to allow
        // the two language ports to use different indentation and quoting styles.
        func dump(_ executor: any SqliteExecutor) throws -> [String] {
            try executor.all("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").map { row in
                let type = try row.sqliteText("type"), name = try row.sqliteText("name")
                let sql = try row.sqliteText("sql")
                return type + ":" + name + ":" + sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            }
        }
        #expect(try dump(fresh) == dump(original))
    }
}
