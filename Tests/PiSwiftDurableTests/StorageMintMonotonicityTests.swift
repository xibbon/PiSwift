import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum MintBackend: String, CaseIterable, Sendable {
    case memory, sqlite, jsonl

    func open(_ directory: URL) async throws -> any DurableStorage {
        switch self {
        case .memory: return MemoryStorage()
        case .sqlite: return try await SqliteStorage.open(path: directory.appendingPathComponent("ids.sqlite").path)
        case .jsonl: return try await JsonlStorage.open(directory: directory.path)
        }
    }
}

private func mintTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func mintStoredEntry(_ id: Int64) throws -> StorageWrite {
    .entry(value: .init(id: try EntryID(id), conversationId: rootConversationID, kind: "test"))
}

struct StorageMintMonotonicityTests {
    @Test(arguments: MintBackend.allCases)
    fileprivate func mintFollowsAllStoredRecordKinds(_ backend: MintBackend) async throws {
        let directory = try mintTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var storage = try await backend.open(directory)
        let first: TaskID = try await storage.mintId()
        let second: DocumentID = try await storage.mintId()
        #expect(second.rawValue > first.rawValue)
        let records: [JSONValue] = [
            ["type": "conversation", "value": ["id": 100]],
            ["type": "entry", "value": ["id": 200, "conversationId": 100, "kind": "test"]],
            ["type": "task", "value": ["id": 300, "conversationId": 100, "kind": "test", "version": 1, "input": nil,
                                       "state": ["status": "pending", "checkpoint": [:]], "background": false, "abortRequested": false]],
            ["type": "submission", "value": ["id": 400, "conversationId": 100, "type": "input", "status": "queued"]],
            ["type": "document.create", "record": ["id": 500, "kind": "test", "scope": ["kind": "session"]],
             "content": ["kind": "base", "version": 1, "value": [:]]],
        ]
        for record in records {
            let write = try record.decode(StorageWrite.self)
            _ = try await storage.commit([write], context: .background)
            if backend != .memory {
                try await storage.close(context: .background)
                storage = try await backend.open(directory)
            }
            let minted: EntryID = try await storage.mintId()
            let object = record["value"] ?? record["record"]!
            #expect(minted.rawValue > object["id"]!.int64Value!)
        }
        let before: EntryID = try await storage.mintId()
        _ = try await storage.commit([try mintStoredEntry(50)], context: .background)
        let after: ConversationID = try await storage.mintId()
        #expect(after.rawValue > before.rawValue)
        try await storage.close(context: .background)
    }

    @Test(arguments: MintBackend.allCases)
    fileprivate func storedMaximumExhaustsIds(_ backend: MintBackend) async throws {
        let directory = try mintTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var storage = try await backend.open(directory)
        _ = try await storage.commit([try mintStoredEntry(EntryID.maximumRawValue)], context: .background)
        await #expect(throws: DurableStorageError.idSpaceExhausted) {
            let _: TaskID = try await storage.mintId()
        }
        try await storage.close(context: .background)
        if backend != .memory {
            storage = try await backend.open(directory)
            await #expect(throws: DurableStorageError.idSpaceExhausted) {
                let _: DocumentID = try await storage.mintId()
            }
            try await storage.close(context: .background)
        }
    }

    @Test func sqliteCommitMetadataKeepsTextType() async throws {
        let directory = try mintTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ids.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        let id = EntryID.maximumRawValue
        _ = try await storage.commit([try mintStoredEntry(id)], context: .background)
        try await storage.close(context: .background)
        let database = try AppleSqliteDatabase(path: path)
        defer { try? database.close() }
        let row = try #require(try database.get("SELECT next_id, typeof(next_id) AS value_type FROM durable_metadata WHERE singleton = 1"))
        #expect(row["next_id"] == .text(String(id + 1)))
        #expect(row["value_type"] == .text("text"))
    }
}
