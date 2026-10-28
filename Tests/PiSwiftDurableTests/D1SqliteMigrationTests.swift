import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

// Upstream v1.4.0 durable/test/sqlite-migrations.test.ts:47 and
// durable/src/storage/sqlite/migrations.ts:91 define the version 2 rebuild.
@Suite("PiSwiftDurableTests.D1SqliteMigrations")
struct D1SqliteMigrationTests {
    private func insertTask(_ db: any SqliteExecutor, schema: SqliteSchema, id: Int64, status: String) throws {
        // Keep spaces, key order, and Unicode in the stored text to detect re-encoding.
        let state: String
        switch status {
        case "waiting": state = #"{"status":"waiting", "checkpoint":{"phase":"run"},"on":[],"policy":"allSettled"}"#
        case "terminal": state = #"{"status":"terminal", "outcome":{"status":"completed","result":null}}"#
        default: state = #"{"status":"running", "checkpoint":{"phase":"run"}}"#
        }
        let record = #"{ "id":\#(id), "conversationId":1, "kind":"test.task", "version":1, "input":null, "background":true, "abortRequested":true, "state":\#(state), "extension":{"text":"é ☀","ordered":{"b":2,"a":1}} }"#
        try db.run("INSERT INTO \(schema.tables.tasks) (id, conversation_id, kind, status, abort_requested, background, record) VALUES (?, 1, ?, ?, 1, 1, ?)",
                   [.integer(id), .text(#""test.task""#), .text(status), .text(record)])
    }

    private func insertSleeping(_ db: any SqliteExecutor, schema: SqliteSchema, id: Int64 = 6) throws {
        try db.run("INSERT INTO \(schema.tables.tasks) (id, conversation_id, kind, status, abort_requested, background, record) VALUES (?, 1, ?, 'sleeping', 0, 0, '{}')",
                   [.integer(id), .text(#""test.task""#)])
    }

    private func taskRows(_ db: any SqliteExecutor, schema: SqliteSchema) throws -> [SqliteRow] {
        try db.all("SELECT *, CAST(record AS BLOB) AS record_bytes FROM \(schema.tables.tasks) ORDER BY id")
    }

    private func taskIndexes(_ db: any SqliteExecutor, schema: SqliteSchema) throws -> [SqliteRow] {
        try db.all("SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ? ORDER BY name", [.text(schema.tables.tasks)])
    }

    private func checkVersionTwo(_ db: any SqliteExecutor, schema: SqliteSchema) throws {
        #expect(try db.get("SELECT version FROM \(schema.tables.durableSchema) WHERE singleton = 1") == ["version": .integer(2)])
        let indexes = try taskIndexes(db, schema: schema).map { try $0.sqliteText("name") }
        #expect(indexes == [schema.indexes.tasksByAbortRequested, schema.indexes.tasksByBackground,
                            schema.indexes.tasksByConversation, schema.indexes.tasksByKind,
                            schema.indexes.tasksByStatus].sorted())
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE name = ?", [.text(schema.tables.tasks + "_v2")]) == ["count": .integer(0)])
        #expect(try db.get("SELECT typeof(next_id) AS type FROM \(schema.tables.durableMetadata)") == ["type": .text("text")])
    }

    @Test(arguments: ["", "pi_"])
    func freshDatabaseReachesVersionTwo(prefix: String) throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        let schema = try SqliteSchema(prefix: prefix.isEmpty ? nil : prefix)
        try applySqliteMigrations(db, schema: schema)
        try applySqliteMigrations(db, schema: schema)
        try checkVersionTwo(db, schema: schema)
        try insertSleeping(db, schema: schema)
        // A schema 1 reader must reject even a schema 2 file with no sleeping task.
        try db.run("DELETE FROM \(schema.tables.tasks)")
        #expect(throws: SqliteFacadeError.newerSchema(found: 2, supported: 1)) {
            try applySqliteMigrations(db, schema: schema, migrations: Array(makeSqliteMigrations(for: schema).prefix(1)))
        }
    }

    @Test(arguments: ["", "pi_"])
    func migrationKeepsEveryTaskColumnAndRecordByte(prefix: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("migration.sqlite").path
        let schema = try SqliteSchema(prefix: prefix.isEmpty ? nil : prefix)
        let db = try AppleSqliteDatabase(path: path)
        defer { try? db.close() }
        let migrations = makeSqliteMigrations(for: schema)
        try applySqliteMigrations(db, schema: schema, migrations: Array(migrations.prefix(1)))
        for (id, status) in [(Int64(5), "waiting"), (7, "running"), (8, "terminal")] {
            try insertTask(db, schema: schema, id: id, status: status)
        }
        let records = try taskRows(db, schema: schema)
        let indexes = try taskIndexes(db, schema: schema)
        #expect(throws: (any Error).self) { try insertSleeping(db, schema: schema) }
        #expect(try db.get("SELECT version FROM \(schema.tables.durableSchema)") == ["version": .integer(1)])
        try db.close()

        let storage = try await SqliteStorage.open(path: path, prefix: prefix.isEmpty ? nil : prefix)
        #expect(try await storage.task(TaskID(5), context: .background)?.state.status == "waiting")
        #expect(try await storage.task(TaskID(7), context: .background)?.state.status == "running")
        #expect(try await storage.task(TaskID(8), context: .background)?.state.status == "terminal")
        try await storage.close(context: .background)

        let migrated = try AppleSqliteDatabase(path: path)
        defer { try? migrated.close() }
        try checkVersionTwo(migrated, schema: schema)
        #expect(try taskRows(migrated, schema: schema) == records)
        #expect(try taskIndexes(migrated, schema: schema) == indexes)
        try insertSleeping(migrated, schema: schema)
    }

    @Test(arguments: ["", "pi_"])
    func failedRebuildLeavesVersionOneUsable(prefix: String) throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        let schema = try SqliteSchema(prefix: prefix.isEmpty ? nil : prefix)
        let migrations = makeSqliteMigrations(for: schema)
        try applySqliteMigrations(db, schema: schema, migrations: Array(migrations.prefix(1)))
        try insertTask(db, schema: schema, id: 5, status: "waiting")
        let records = try taskRows(db, schema: schema)
        let indexes = try taskIndexes(db, schema: schema)
        // Fail after the old table was dropped and the new table was renamed.
        let failed = SqliteMigration(version: 2, statements: Array(migrations[1].statements.prefix(4)) + ["THIS IS NOT SQL"])
        #expect(throws: (any Error).self) {
            try applySqliteMigrations(db, schema: schema, migrations: [migrations[0], failed])
        }
        #expect(try db.get("SELECT version FROM \(schema.tables.durableSchema)") == ["version": .integer(1)])
        #expect(try taskRows(db, schema: schema) == records)
        #expect(try taskIndexes(db, schema: schema) == indexes)
        #expect(try db.get("SELECT count(*) AS count FROM sqlite_schema WHERE name = ?", [.text(schema.tables.tasks + "_v2")]) == ["count": .integer(0)])
        #expect(throws: (any Error).self) { try insertSleeping(db, schema: schema) }
        try insertTask(db, schema: schema, id: 7, status: "running")
        let retained = try taskRows(db, schema: schema)
        try applySqliteMigrations(db, schema: schema)
        try checkVersionTwo(db, schema: schema)
        #expect(try taskRows(db, schema: schema) == retained)
        try insertSleeping(db, schema: schema)
    }

    private func recordSnapshot(_ db: any SqliteExecutor, schema: SqliteSchema, excluding task: TaskID? = nil) throws -> [String: [SqliteRow]] {
        let tables = [schema.tables.conversations, schema.tables.entries, schema.tables.tasks,
                      schema.tables.submissions, schema.tables.documents]
        var result: [String: [SqliteRow]] = [:]
        for table in tables {
            let exclude = table == schema.tables.tasks ? task : nil
            let filter = exclude == nil ? "" : " WHERE id != ?"
            let params: [SqliteValue] = exclude.map { [.integer($0.rawValue)] } ?? []
            result[table] = try db.all("SELECT *, CAST(record AS BLOB) AS record_bytes FROM \(table)\(filter) ORDER BY id", params)
        }
        result[schema.tables.documentRevisions] = try db.all("SELECT *, CAST(content AS BLOB) AS content_bytes FROM \(schema.tables.documentRevisions) ORDER BY document_id, seq")
        return result
    }

    @Test(arguments: ["tool-task-upstream-v130", "nested-tool-upstream-v130", "restart-upstream-v130", "prefix-upstream-v130"])
    func frozenTypeScriptFilesMigrateAndStoreSleepingTasks(fixture: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(Bundle.module.url(forResource: fixture, withExtension: "sqlite", subdirectory: "Fixtures"))
        let path = directory.appendingPathComponent("frozen.sqlite").path
        try FileManager.default.copyItem(atPath: source.path, toPath: path)
        let prefix = fixture == "prefix-upstream-v130" ? "pi_" : nil
        let schema = try SqliteSchema(prefix: prefix)
        let before = try AppleSqliteDatabase(path: path)
        defer { try? before.close() }
        #expect(try before.get("SELECT version FROM \(schema.tables.durableSchema)") == ["version": .integer(1)])
        #expect(throws: (any Error).self) { try insertSleeping(before, schema: schema, id: 9_000_000_000_000_000) }
        let records = try recordSnapshot(before, schema: schema)
        let metadata = try before.all("SELECT * FROM \(schema.tables.durableMetadata)")
        let ids = try before.all("SELECT * FROM \(schema.tables.recordIds) ORDER BY id")
        let indexes = try taskIndexes(before, schema: schema)
        try #require(!(records[schema.tables.tasks] ?? []).isEmpty)
        try before.close()

        let storage = try await SqliteStorage.open(path: path, prefix: prefix)
        try await storage.close(context: .background)
        let migrated = try AppleSqliteDatabase(path: path)
        defer { try? migrated.close() }
        try checkVersionTwo(migrated, schema: schema)
        #expect(try recordSnapshot(migrated, schema: schema) == records)
        #expect(try migrated.all("SELECT * FROM \(schema.tables.durableMetadata)") == metadata)
        #expect(try migrated.all("SELECT * FROM \(schema.tables.recordIds) ORDER BY id") == ids)
        #expect(try taskIndexes(migrated, schema: schema) == indexes)
        try migrated.close()

        let writer = try await SqliteStorage.open(path: path, prefix: prefix)
        let sleepingID: TaskID = try await writer.mintId()
        let sleeping = TaskRecord(id: sleepingID, conversationId: rootConversationID,
            kind: "test.sleeping", version: 1, input: ["value": "retained"],
            state: .sleeping(checkpoint: ["phase": "resume", "opaque": ["b": 2, "a": 1]], until: 1_700_000_000_000.5))
        _ = try await writer.commit([.task(value: sleeping)], context: .background)
        #expect(try await writer.task(sleepingID, context: .background) == sleeping)
        try await writer.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path, prefix: prefix)
        #expect(try await reopened.task(sleepingID, context: .background) == sleeping)
        #expect(try await reopened.scanTasks(TaskQuery(status: .sleeping), limit: 10, cursor: nil, context: .background).items == [sleeping])
        try await reopened.close(context: .background)
        let after = try AppleSqliteDatabase(path: path)
        defer { try? after.close() }
        #expect(try recordSnapshot(after, schema: schema, excluding: sleepingID) == records)
        #expect(try after.get("SELECT status FROM \(schema.tables.tasks) WHERE id = ?", [.integer(sleepingID.rawValue)]) == ["status": .text("sleeping")])
        try checkVersionTwo(after, schema: schema)
    }
}
