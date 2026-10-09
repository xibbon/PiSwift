import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func sqliteWrites(_ values: [JSONValue]) throws -> [StorageWrite] { try values.map { try $0.decode(StorageWrite.self) } }
private func sqliteEntry(_ id: Int64, data: JSONValue? = nil) -> JSONValue {
    var value: JSONObject = ["id": .number(Double(id)), "conversationId": 1, "kind": "message"]
    value["data"] = data
    return ["type": "entry", "value": .object(value)]
}
private func sqliteCreate(_ id: Int64, value: JSONValue, rewindable: Bool = false) -> JSONValue {
    var record: JSONObject = ["id": .number(Double(id)), "kind": "test", "scope": ["kind": "session"]]
    if rewindable { record["scope"] = ["kind": "conversation", "conversationId": 1]; record["history"] = "rewindable"; record["fork"] = "asOf" }
    return ["type": "document.create", "record": .object(record), "content": ["kind": "base", "version": 1, "value": value]]
}
private func sqliteChange(_ id: Int64, _ content: JSONValue) -> JSONValue {
    ["type": "document.change", "id": .number(Double(id)), "content": content]
}
private func sqliteDelta(_ id: Int64, _ count: Int) -> JSONValue {
    sqliteChange(id, ["kind": "delta", "version": 1, "ops": [["s", ["count"], .number(Double(count))]]])
}
private func sqliteBase(_ id: Int64, _ value: JSONValue) -> JSONValue {
    sqliteChange(id, ["kind": "base", "version": 1, "value": value])
}
private func sqliteScalar(_ path: String, _ sql: String) throws -> Int64 {
    let db = try AppleSqliteDatabase(path: path)
    defer { try? db.close() }
    let row = try #require(try db.get(sql))
    guard case .integer(let result) = try #require(row["value"]) else { throw SqliteTestError.notInteger }
    return result
}
private enum SqliteTestError: Error { case notInteger, callback }

@Suite("PiSwiftDurableTests.SqliteStorage")
struct SqliteStorageTests {
    private func withFile(_ body: (SqliteStorage, String) async throws -> Void) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        do { try await body(storage, path) }
        catch { try? await storage.close(context: .background); throw error }
        try await storage.close(context: .background)
    }
    private func commit(_ storage: SqliteStorage, _ values: [JSONValue]) async throws -> Seq {
        try await storage.commit(sqliteWrites(values), context: .background)
    }
    private func root(_ storage: SqliteStorage) async throws {
        _ = try await commit(storage, [["type": "conversation", "value": ["id": 1]]])
    }

    @Test func persistsRecordsSequenceAndIDsAcrossReopen() async throws {
        try await withFile { storage, path in
            try await root(storage)
            let id: EntryID = try await storage.mintId()
            #expect(try await commit(storage, [sqliteEntry(id.rawValue)]) == Seq(2))
            try await storage.close(context: .background)
            let reopened = try await SqliteStorage.open(path: path)
            #expect(try await reopened.entry(id, context: .background)?.commitSeq == Seq(2))
            let next: EntryID = try await reopened.mintId()
            #expect(next.rawValue == id.rawValue + 1)
            #expect(try await reopened.commit([], context: .background) == Seq(3))
            try await reopened.close(context: .background)
        }
    }

    @Test func rejectsPersistedMetadataCorruption() async throws {
        try await withFile { storage, path in
            try await storage.close(context: .background)
            let db = try AppleSqliteDatabase(path: path)
            try db.exec("DELETE FROM durable_metadata")
            try db.close()
            await #expect(throws: (any Error).self) { _ = try await SqliteStorage.open(path: path) }
        }
    }

    @Test func rejectsDocumentMissingRequiredBase() async throws {
        try await withFile { storage, path in
            try await root(storage)
            _ = try await commit(storage, [sqliteCreate(2, value: ["retained": true])])
            let db = try AppleSqliteDatabase(path: path)
            try db.run("DELETE FROM document_revisions WHERE document_id = ?", [.integer(2)])
            try db.close()
            do { _ = try await storage.document(DocumentID(2), at: .current, context: .background); Issue.record("Missing base accepted") }
            catch { #expect(String(describing: error).contains("Document 2 is missing a required base")) }
        }
    }

    @Test func replaysDetachedRootReplacementsAndRejectsCorruptOperations() async throws {
        try await withFile { storage, path in
            try await root(storage)
            _ = try await commit(storage, [sqliteCreate(2, value: ["nested": ["value": 1], "rows": []])])
            _ = try await commit(storage, [sqliteChange(2, ["kind": "delta", "version": 1,
                "ops": [["r", ["nested": ["value": 2], "rows": [["id": 1]]]]]])])
            _ = try await commit(storage, [sqliteChange(2, ["kind": "delta", "version": 1,
                "ops": [["s", ["nested", "value"], 3], ["p", ["rows"], 1, 0, [["id": 2]]], ["m", ["rows"], [1, 0]]]])])
            _ = try await commit(storage, [sqliteChange(2, ["kind": "delta", "version": 1, "ops": [["s", ["nested", "value"], 4]]])])
            let expected: JSONObject = ["nested": ["value": 4], "rows": [["id": 2], ["id": 1]]]
            var value = try #require(try await storage.document(DocumentID(2), at: .current, context: .background)).value
            #expect(value == expected)
            value = ["detached": true]
            #expect(value != expected)
            #expect(try await storage.document(DocumentID(2), at: .current, context: .background)?.value == expected)
            let db = try AppleSqliteDatabase(path: path)
            try db.run("UPDATE document_revisions SET content = ? WHERE document_id = ? AND seq = (SELECT max(seq) FROM document_revisions WHERE document_id = ?)", [.text("[[\"unknown\"]]"), .integer(2), .integer(2)])
            try db.close()
            do { _ = try await storage.document(DocumentID(2), at: .current, context: .background); Issue.record("Corrupt delta accepted") }
            catch { #expect(String(describing: error).contains("unknown op verb")) }
        }
    }

    @Test func rollsRowsAndSequenceBackTogether() async throws {
        // Swift JSONValue cannot contain a circular object. A document copy failure
        // supplies the failure after an earlier SQL row was inserted in the transaction.
        try await withFile { storage, path in
            try await root(storage)
            await #expect(throws: StorageRejected.self) {
                _ = try await commit(storage, [sqliteEntry(2), ["type": "document.copy", "record": ["id": 4, "kind": "missing", "scope": ["kind": "conversation", "conversationId": 1], "history": "rewindable", "fork": "asOf"], "source": ["id": 999, "at": "current"]]])
            }
            #expect(try await storage.entry(EntryID(2), context: .background) == nil)
            #expect(try await commit(storage, [sqliteEntry(3)]) == Seq(2))
            #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM entries") == 1)
            #expect(try sqliteScalar(path, "SELECT next_seq AS value FROM durable_metadata WHERE singleton = 1") == 3)
        }
    }

    @Test func reconstructsAncientAndRecentPointsAfterReopen() async throws {
        try await withFile { storage, path in
            try await root(storage)
            var ancient = try await commit(storage, [sqliteCreate(2, value: ["count": 0], rewindable: true)])
            var recent = ancient
            for count in 1...40 {
                recent = try await commit(storage, [count == 20 ? sqliteBase(2, ["count": 20]) : sqliteDelta(2, count)])
                if count == 5 { ancient = recent }
            }
            try await storage.close(context: .background)
            let reopened = try await SqliteStorage.open(path: path)
            #expect(try await reopened.document(DocumentID(2), at: .sequence(ancient), context: .background)?.value == ["count": 5])
            #expect(try await reopened.document(DocumentID(2), at: .sequence(recent), context: .background)?.value == ["count": 40])
            try await reopened.close(context: .background)
        }
    }

    @Test func usesIndexesForAddressesScopesHistoryAndRevisionTails() throws {
        let db = try AppleSqliteDatabase(path: ":memory:")
        defer { try? db.close() }
        try applySqliteMigrations(db)
        let queries: [(String, [SqliteValue], String)] = [
            ("SELECT record FROM documents WHERE kind = ? AND scope_kind = ? AND owner_id = ? AND family = ? AND key_value = ? AND retired_at IS NULL ORDER BY created_at DESC LIMIT 1", [.text("kind"), .text("session"), .integer(0), .integer(0), .text("")], "documents_by_address"),
            ("SELECT record FROM documents WHERE kind = ? AND scope_kind = ? AND owner_id = ? AND family = ? AND key_value = ? AND created_at <= ? AND (retired_at IS NULL OR retired_at > ?) ORDER BY created_at DESC LIMIT 1", [.text("kind"), .text("conversation"), .integer(1), .integer(0), .text(""), .integer(10), .integer(10)], "documents_by_address"),
            ("SELECT record FROM documents WHERE scope_kind = ? AND owner_id = ? AND kind = ? AND id > ? ORDER BY id LIMIT ?", [.text("task"), .integer(1), .text("kind"), .integer(0), .integer(10)], "documents_by_scope_kind"),
            ("SELECT record FROM entries WHERE conversation_id = ? AND id <= ? ORDER BY id DESC LIMIT ?", [.integer(1), .integer(10), .integer(10)], "entries_by_conversation"),
            ("SELECT record FROM entries WHERE conversation_id = ? AND head IS NOT NULL AND id <= ? ORDER BY id DESC LIMIT 1", [.integer(1), .integer(10)], "entry_heads_by_conversation"),
            ("SELECT record FROM tasks WHERE status = ? AND id > ? ORDER BY id LIMIT ?", [.text("pending"), .integer(0), .integer(10)], "tasks_by_status"),
            ("SELECT seq, kind, version, content FROM document_revisions WHERE document_id = ? AND kind = 'base' AND seq <= ? ORDER BY seq DESC LIMIT 1", [.integer(1), .integer(10)], "document_revisions_by_kind"),
            ("SELECT seq, kind, version, content FROM document_revisions WHERE document_id = ? AND seq > ? AND seq <= ? ORDER BY seq", [.integer(1), .integer(5), .integer(10)], "sqlite_autoindex_document_revisions_1")
        ]
        for (sql, parameters, index) in queries {
            let rows = try db.all("EXPLAIN QUERY PLAN " + sql, parameters)
            let details = rows.compactMap { row -> String? in if case .text(let detail) = row["detail"] { return detail }; return nil }.joined(separator: "\n")
            #expect(details.contains(index), "Query plan: \(details)")
            #expect(!details.contains("SCAN documents"))
            #expect(!details.contains("SCAN document_revisions"))
        }
    }

    @Test func reclaimsCurrentOnlyRevisionsAfterBaseOrRetirement() async throws {
        try await withFile { storage, path in
            _ = try await commit(storage, [sqliteCreate(2, value: ["count": 0])])
            for count in 1...10 { _ = try await commit(storage, [sqliteDelta(2, count)]) }
            #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM document_revisions WHERE document_id = 2") == 11)
            let db = try AppleSqliteDatabase(path: path)
            let row = try #require(try db.get("SELECT content FROM document_revisions WHERE document_id = 2 AND kind = 'delta' ORDER BY seq DESC LIMIT 1"))
            if case .text(let content) = row["content"] { #expect(try JSONValue(jsonText: content) == [["s", ["count"], 10]]) }
            else { Issue.record("Missing stored delta") }
            try db.close()
            _ = try await commit(storage, [sqliteBase(2, ["count": 11])])
            #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM document_revisions WHERE document_id = 2") == 1)
            _ = try await commit(storage, [sqliteChange(2, ["kind": "delta", "version": 1, "ops": [["r", ["count": 12]]]])])
            #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM document_revisions WHERE document_id = 2") == 2)
            _ = try await commit(storage, [["type": "document.retire", "id": 2]])
            #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM document_revisions WHERE document_id = 2") == 0)
        }
    }

    @Test func autoCheckpointsAndTruncatesWALOnClose() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("storage.sqlite").path
        let storage = try await SqliteStorage.open(executor: AppleSqliteDatabase(path: path, walAutoCheckpointPages: 1))
        try await root(storage)
        for index in 0..<20 { _ = try await commit(storage, [sqliteEntry(Int64(index + 2), data: ["text": .string(String(repeating: "x", count: 32 * 1024)), "index": .number(Double(index))])]) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path + "-wal")
        #expect((attributes[.size] as? NSNumber)?.intValue ?? Int.max < 512 * 1024)
        let observer = try AppleSqliteDatabase(path: path)
        #expect(try sqliteScalar(path, "SELECT count(*) AS value FROM entries") == 20)
        try await storage.close(context: .background)
        let after = try FileManager.default.attributesOfItem(atPath: path + "-wal")
        #expect((after[.size] as? NSNumber)?.intValue == 0)
        try observer.close()
    }

    @Test func reusesPagesReleasedByCurrentOnlyBases() async throws {
        try await withFile { storage, path in
            let large: JSONValue = ["text": .string(String(repeating: "x", count: 512 * 1024))]
            _ = try await commit(storage, [sqliteCreate(2, value: large)])
            _ = try await commit(storage, [sqliteBase(2, ["text": "small"])])
            let pages = try sqliteScalar(path, "SELECT page_count AS value FROM pragma_page_count()")
            let free = try sqliteScalar(path, "SELECT freelist_count AS value FROM pragma_freelist_count()")
            #expect(free > 0)
            _ = try await commit(storage, [sqliteBase(2, large)])
            #expect(try sqliteScalar(path, "SELECT page_count AS value FROM pragma_page_count()") <= pages + 2)
            #expect(try sqliteScalar(path, "SELECT freelist_count AS value FROM pragma_freelist_count()") < free)
        }
    }

    @Test func representativeRowAndDocumentStorageIsBounded() async throws {
        try await withFile { storage, path in
            try await root(storage)
            for index in 0..<100 { _ = try await commit(storage, [sqliteEntry(Int64(index + 2), data: ["index": .number(Double(index)), "text": .string(String(repeating: "x", count: 1024))])]) }
            _ = try await commit(storage, [sqliteCreate(102, value: ["count": 0], rewindable: true)])
            for count in 1...100 { _ = try await commit(storage, [sqliteDelta(102, count)]) }
            let entryBytes = try sqliteScalar(path, "SELECT sum(length(CAST(record AS BLOB))) AS value FROM entries")
            let documentBytes = try sqliteScalar(path, "SELECT sum(length(CAST(record AS BLOB))) AS value FROM documents")
            let revisionBytes = try sqliteScalar(path, "SELECT sum(length(CAST(content AS BLOB))) AS value FROM document_revisions")
            try await storage.close(context: .background)
            let bytes = try #require((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue)
            print("D3 representative SQLite: file \(bytes) bytes; entry JSON \(entryBytes); document JSON \(documentBytes); revision content JSON \(revisionBytes) (100 entries, 101 document revisions)")
            #expect(bytes < 1024 * 1024)
        }
    }
}
