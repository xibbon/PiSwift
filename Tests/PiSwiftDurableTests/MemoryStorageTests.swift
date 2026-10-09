import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    @Test("does not expose retained state through a prepared commit")
    func preparedCommitDetachedValues() async throws {
        let storage = MemoryStorage()
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID))], context: .background)
        let entryID = try EntryID(2)
        let prepared = try await storage.prepareCommit([
            .entry(value: EntryRecord(id: entryID, conversationId: rootConversationID, kind: "test", data: ["nested": [1]])),
        ])
        var exposed = prepared.writes
        guard case let .entry(value, extensions) = try #require(exposed.first) else {
            Issue.record("Expected an entry write")
            return
        }
        var data = try #require(value.data?.objectValue)
        var nested = try #require(data["nested"]?.arrayValue)
        nested.append(2)
        data["nested"] = .array(nested)
        exposed[0] = .entry(value: EntryRecord(id: value.id, conversationId: value.conversationId,
                                              kind: value.kind, data: .object(data)), extensions: extensions)
        #expect(exposed != prepared.writes)
        #expect(try JSONValue(encoding: #require(prepared.writes.first))["value"]?["data"]?["nested"] == [1])
        #expect(await prepared.apply() == (try Seq(2)))
        #expect(await prepared.apply() == (try Seq(2)))
        #expect(try await storage.entry(entryID, context: .background)?.entry.data == ["nested": [1]])
    }
}
