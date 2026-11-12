import PiSwiftChord
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentDurable

// v1.5.2 D4: harness/view.ts:358–370 trims the library watch. The host still shows all rows until D10.
@Test func runtimeSourceRetainsRowsDroppedByWindow() throws {
    let root = rootConversationID
    let records = try (2...8).map { id in
        EntryRecord(id: try EntryID(Int64(id)), conversationId: root, kind: "note")
    }
    let initial = ConversationView(conversation: .init(id: root), entries: Array(records.prefix(5)), docs: [:])
    let source = RuntimeViewSource(DurableView(
        session: .init(id: "session", directory: "/session", cwd: "/project"),
        conversation: initial, conversations: [], models: []),
        schedule: { _ in })
    source.updateConversation(.init(conversation: initial.conversation,
                                    entries: Array(records.suffix(3)), before: records[4].id,
                                    docs: ["pi.live": ["run": ["taskId": 2]]]))
    #expect(source.current().conversation.entries.map(\.id) == records.map(\.id))
    #expect(source.current().conversation.before == nil)
    #expect(source.current().conversation.docs["pi.live"]?["run"]?["taskId"] == 2)
}
