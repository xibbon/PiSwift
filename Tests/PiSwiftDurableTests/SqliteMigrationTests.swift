import Foundation

import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.SqliteMigrations")
struct SqliteMigrationTests {
    @Test func createsCurrentSchemaAndRepeats() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        try applySqliteMigrations(db)
        try applySqliteMigrations(db)
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(currentSqliteSchemaVersion))])
        #expect(try db.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1") == ["next_id": .text("2"), "next_seq": .integer(1)])
    }

    @Test func rejectsNewerDatabase() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        try applySqliteMigrations(db)
        try db.run("UPDATE durable_schema SET version = ? WHERE singleton = 1", [.integer(Int64(currentSqliteSchemaVersion + 1))])
        do { try applySqliteMigrations(db); Issue.record("Newer schema accepted") }
        catch { #expect(String(describing: error).contains("is newer than supported version")) }
    }

    @Test func rollsBootstrapAndAllPendingMigrationsBackTogether() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        let first = SqliteMigration(version: 1, statements: ["CREATE TABLE migration_first (value TEXT) STRICT", "INSERT INTO migration_first (value) VALUES ('retained')"])
        let second = SqliteMigration(version: 2, statements: ["CREATE TABLE migration_second (value TEXT) STRICT"])
        #expect(throws: (any Error).self) {
            try applySqliteMigrations(db, migrations: [first, SqliteMigration(version: 2, statements: second.statements + ["THIS IS NOT SQL"])])
        }
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE name IN ('durable_schema', 'migration_first', 'migration_second')") == ["count": .integer(0)])
        try applySqliteMigrations(db, migrations: [first, second])
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(2)])
        #expect(try db.get("SELECT value FROM migration_first") == ["value": .text("retained")])
    }

    @Test func preservesDataForMigrationRetry() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        let write: JSONValue = ["type": "entry", "value": ["id": 2, "conversationId": 1, "kind": "retained", "data": ["retained": true]]]
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), try write.decode(StorageWrite.self)], context: .background)
        try await storage.close(context: .background)
        let db = try AppleSqliteDatabase(path: path)
        defer { try? db.close() }
        let version = currentSqliteSchemaVersion + 1
        #expect(throws: (any Error).self) { try applySqliteMigrations(db, migrations: sqliteMigrations + [SqliteMigration(version: version, statements: ["CREATE TABLE migration_probe (value TEXT) STRICT", "THIS IS NOT SQL"])]) }
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(currentSqliteSchemaVersion))])
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE type = 'table' AND name = 'migration_probe'") == ["count": .integer(0)])
        try applySqliteMigrations(db, migrations: sqliteMigrations + [SqliteMigration(version: version, statements: ["CREATE TABLE migration_probe (value TEXT) STRICT"])])
        #expect(try db.get("SELECT version FROM durable_schema WHERE singleton = 1") == ["version": .integer(Int64(version))])
        let row = try #require(try db.get("SELECT record, commit_seq FROM entries WHERE id = 2"))
        if case .text(let record) = row["record"] { #expect(try JSONValue(jsonText: record) == write["value"]) }
        else { Issue.record("Missing retained record") }
        #expect(row["commit_seq"] == .integer(1))
        #expect(try db.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1") == ["next_id": .text("3"), "next_seq": .integer(2)])
    }

    @Test func rejectsNoncontiguousVersionsBeforeSQL() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        #expect(throws: (any Error).self) { try applySqliteMigrations(db, migrations: [SqliteMigration(version: 2, statements: [])]) }
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE name = 'durable_schema'") == ["count": .integer(0)])
    }
}
