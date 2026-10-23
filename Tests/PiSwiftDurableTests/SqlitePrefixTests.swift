import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private let sqliteHistoricalTables = [
    "durable_schema", "durable_metadata", "record_ids", "conversations", "entries", "tasks",
    "submissions", "documents", "document_revisions",
]
private let sqliteHistoricalIndexes = [
    "conversations_by_owner_conversation", "conversations_by_owner_task", "entries_by_conversation",
    "entry_heads_by_conversation", "tasks_by_status", "tasks_by_conversation", "tasks_by_kind",
    "tasks_by_abort_requested", "tasks_by_background", "submissions_by_request",
    "submissions_by_conversation", "submissions_by_status", "documents_by_address",
    "documents_by_scope", "documents_by_scope_kind", "document_revisions_by_kind",
]

@Suite("PiSwiftDurableTests.SqlitePrefix")
struct SqlitePrefixTests {
    @Test func namespacesTablesAndIndexesAcrossReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let host = try AppleSqliteDatabase(path: path)
        try host.exec("CREATE TABLE tasks (text TEXT)")
        try host.run("INSERT INTO tasks (text) VALUES (?)", [.text("host")])
        try host.close()

        let storage = try await SqliteStorage.open(path: path, prefix: "pi_")
        #expect(try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background) == Seq(1))
        try await storage.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path, prefix: "pi_")
        #expect(try await reopened.conversation(rootConversationID, context: .background) == ConversationRecord(id: rootConversationID))
        try await reopened.close(context: .background)

        let db = try AppleSqliteDatabase(path: path)
        defer { try? db.close() }
        let names = try db.all("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT GLOB 'sqlite_*'").map { try $0.sqliteText("name") }
        #expect(Set(names) == Set((sqliteHistoricalTables + sqliteHistoricalIndexes).map { "pi_" + $0 } + ["tasks"]))
        #expect(try db.get("SELECT text FROM tasks") == ["text": .text("host")])
        #expect(try db.get("SELECT typeof(next_id) AS type, next_id, next_seq FROM pi_durable_metadata") == ["type": .text("text"), "next_id": .text("2"), "next_seq": .integer(2)])
        #expect(try db.get("SELECT version FROM pi_durable_schema") == ["version": .integer(Int64(currentSqliteSchemaVersion))])
    }

    @Test(arguments: [
        ("", #"Invalid SQLite schema prefix """#),
        ("bad-prefix", #"Invalid SQLite schema prefix "bad-prefix""#),
        ("1bad", #"Invalid SQLite schema prefix "1bad""#),
        ("has space", #"Invalid SQLite schema prefix "has space""#),
        ("x\"y", #"Invalid SQLite schema prefix "x\"y""#),
        ("x\\y", #"Invalid SQLite schema prefix "x\\y""#),
        ("x\n", #"Invalid SQLite schema prefix "x\n""#),
        ("x\r", #"Invalid SQLite schema prefix "x\r""#),
        ("x\t", #"Invalid SQLite schema prefix "x\t""#),
        ("x\u{0}", #"Invalid SQLite schema prefix "x\u0000""#),
        ("x\u{1F}", #"Invalid SQLite schema prefix "x\u001f""#),
        ("é", #"Invalid SQLite schema prefix "é""#),
        ("x/", #"Invalid SQLite schema prefix "x/""#),
        ("x;DROP TABLE tasks", #"Invalid SQLite schema prefix "x;DROP TABLE tasks""#),
        ("sqlite_", #"SQLite schema prefix "sqlite_" is reserved"#),
        ("SQLITE_app_", #"SQLite schema prefix "SQLITE_app_" is reserved"#),
        ("sQlItE_1", #"SQLite schema prefix "sQlItE_1" is reserved"#),
        ("sqlite_bad-", #"Invalid SQLite schema prefix "sqlite_bad-""#),
    ])
    func rejectsPrefixBeforePathCreation(prefix: String, message: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("nested")
        let path = nested.appendingPathComponent("storage.sqlite").path
        do {
            let storage = try await SqliteStorage.open(path: path, prefix: prefix)
            try await storage.close(context: .background)
            Issue.record("Invalid prefix accepted")
        } catch { #expect(String(describing: error) == message) }
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(arguments: ["A", "z", "_", "_0", "aZ_09", "sqlite", "SQLite", "sqliteX_"])
    func acceptsIdentifierPrefix(prefix: String) async throws {
        let storage = try await SqliteStorage.open(path: ":memory:", prefix: prefix)
        #expect(try await storage.commit([], context: .background) == Seq(1))
        try await storage.close(context: .background)
    }

    @Test func prefixesAndDefaultKeepSeparateDataAndCounters() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let first = try await SqliteStorage.open(path: path, prefix: "first_")
        let second = try await SqliteStorage.open(path: path, prefix: "second_")
        let unprefixed = try await SqliteStorage.open(path: path)
        #expect(try await second.conversation(rootConversationID, context: .background) == nil)
        #expect(try await unprefixed.conversation(rootConversationID, context: .background) == nil)
        let write: JSONValue = ["type": "entry", "value": ["id": 7, "conversationId": 1, "kind": "first"]]
        #expect(try await first.commit([.conversation(value: ConversationRecord(id: rootConversationID)), write.decode(StorageWrite.self)], context: .background) == Seq(1))
        #expect(try await first.commit([], context: .background) == Seq(2))
        for storage in [second, unprefixed] {
            #expect(try await storage.entry(EntryID(7), context: .background) == nil)
            #expect(try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background) == Seq(1))
        }
        for storage in [first, second, unprefixed] { try await storage.close(context: .background) }
        for (prefix, nextId, sequence) in [(Optional("first_"), Int64(8), 3), (Optional("second_"), 2, 2), (nil, 2, 2)] {
            let storage = try await SqliteStorage.open(path: path, prefix: prefix)
            let id: EntryID = try await storage.mintId()
            #expect(id.rawValue == nextId)
            #expect(try await storage.commit([], context: .background) == Seq(Int64(sequence)))
            #expect(try await storage.entry(EntryID(7), context: .background)?.entry.kind == (prefix == "first_" ? "first" : nil))
            try await storage.close(context: .background)
        }
        let db = try AppleSqliteDatabase(path: path)
        defer { try? db.close() }
        let names = try db.all("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') AND name NOT GLOB 'sqlite_*'").map { try $0.sqliteText("name") }
        #expect(Set(names) == Set(["first_", "second_", ""].flatMap { prefix in (sqliteHistoricalTables + sqliteHistoricalIndexes).map { prefix + $0 } }))
    }

    @Test func migrationVersionAndMetadataBelongToPrefix() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        for prefix in ["first_", "second_"] {
            let storage = try await SqliteStorage.open(path: path, prefix: prefix)
            try await storage.close(context: .background)
        }
        let db = try AppleSqliteDatabase(path: path)
        try db.run("UPDATE first_durable_schema SET version = ?", [.integer(Int64(currentSqliteSchemaVersion + 1))])
        try db.exec("DELETE FROM second_durable_metadata")
        try db.close()
        do { _ = try await SqliteStorage.open(path: path, prefix: "first_"); Issue.record("Newer schema accepted") }
        catch { #expect(String(describing: error) == "Durable SQLite schema version \(currentSqliteSchemaVersion + 1) is newer than supported version \(currentSqliteSchemaVersion)") }
        do { _ = try await SqliteStorage.open(path: path, prefix: "second_"); Issue.record("Missing metadata accepted") }
        catch { #expect(String(describing: error) == "Durable SQLite metadata is missing") }
        let storage = try await SqliteStorage.open(path: path)
        #expect(try await storage.commit([], context: .background) == Seq(1))
        try await storage.close(context: .background)
    }
}
