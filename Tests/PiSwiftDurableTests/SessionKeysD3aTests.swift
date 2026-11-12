import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.SessionKeysD3a")
struct SessionKeysD3aTests {
    private func key(_ spec: JSONValue) throws -> String {
        let kind = try #require(spec["kind"]?.numberValue).rounded(.towardZero)
        let id = try #require(spec["id"]?.numberValue).rounded(.towardZero)
        let extra = try #require(spec["extra"]?.numberValue).rounded(.towardZero)
        let value = Int64(id), suffix = Int64(extra)
        switch Int(kind) {
        case 0: return SessionKeys.taskKey(try TaskID(value))
        case 1: return SessionKeys.conversationKey(try ConversationID(value))
        case 2: return SessionKeys.entryKey(try EntryID(value))
        case 3: return SessionKeys.appendKey(try ConversationID(value))
        case 4: return SessionKeys.submissionKey(try SubmissionID(value))
        case 5: return SessionKeys.requestKey(try ConversationID(value), "r:\(suffix)")
        case 6:
            return SessionKeys.documentKey(DocumentAddress(kind: "kind:\(suffix)",
                scope: .conversation(conversationId: try ConversationID(value))))
        case 7: return SessionKeys.incarnationKey(try DocumentID(value))
        case 8: return SessionKeys.scopeKey(.session())
        case 9: return SessionKeys.scopeKey(.conversation(conversationId: try ConversationID(value)))
        case 10: return SessionKeys.scopeKey(.task(taskId: try TaskID(value)))
        default: return SessionKeys.ownedKey("c\(value)")
        }
    }

    @Test func taggedKeyPairsAndGates() throws {
        let url = try #require(Bundle.module.url(forResource: "session-keys-v152", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        let pairs = try #require(fixture["pairs"]?.arrayValue)
        #expect(pairs.count >= 1_000)
        for pair in pairs {
            let left = try key(#require(pair["left"]))
            let right = try key(#require(pair["right"]))
            #expect(left == pair["leftKey"]?.stringValue)
            #expect(right == pair["rightKey"]?.stringValue)
            #expect((left == right) == pair["gated"]?.boolValue)
            #expect(pair["drained"]?.boolValue == true)
        }
        let tables = try #require(fixture["tables"]?.arrayValue)
        #expect(tables.count == 200)
        for table in tables {
            let id = try ConversationID(Int64(#require(table["id"]?.numberValue)))
            let entry = try EntryID(Int64(#require(table["entry"]?.numberValue)))
            let task = try TaskID(Int64(#require(table["task"]?.numberValue)))
            let submission = try SubmissionID(Int64(#require(table["submission"]?.numberValue)))
            let requestID = table["requestId"]?.stringValue
            let writes: [StorageWrite] = [
                .conversation(value: ConversationRecord(id: id)),
                .entry(value: EntryRecord(id: entry, conversationId: id, kind: "key")),
                .task(value: TaskRecord(id: task, conversationId: id, kind: "key", version: 1,
                    input: .null, state: .pending(checkpoint: .null))),
                .submission(value: .input(id: submission, conversationId: id, requestId: requestID, state: .queued()))
            ]
            var actual: [String] = []
            SessionKeys.tableKeys(writes, into: &actual)
            #expect(actual == table["keys"]?.arrayValue?.compactMap(\.stringValue))
        }
    }
}
