import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private func d3bEntry(_ id: Int64, _ conversation: Int64, head: Int64? = nil) throws -> StorageWrite {
    .entry(value: EntryRecord(id: try EntryID(id), conversationId: try ConversationID(conversation),
                              kind: "note", head: try head.map(EntryID.init)))
}

@Suite("PiSwiftDurableTests.SessionConversationTailsD3b", .timeLimit(.minutes(1)))
struct SessionConversationTailsD3bTests {
    @Test("reads once, then follows the commits")
    func readsOnceThenFollows() async throws {
        let tails = SessionConversationTails()
        let counter = SessionTestLog<Int>()
        let first = try await tails.latest(rootConversationID) {
            counter.append(1); return try EntryID(5)
        }
        #expect(first?.rawValue == 5)
        _ = try await tails.latest(rootConversationID) { counter.append(1); return nil }
        #expect(counter.count == 1)
        tails.apply([try d3bEntry(9, 1)])
        #expect(try await tails.latest(rootConversationID) { nil }?.rawValue == 9)
    }

    @Test("knows a new root conversation is empty, and a fork only once read or written")
    func rootAndFork() async throws {
        let tails = SessionConversationTails()
        let fork = try ConversationID(3)
        tails.apply([
            .conversation(value: .init(id: rootConversationID)),
            .conversation(value: .init(id: fork, parent: .init(conversationId: rootConversationID, at: try EntryID(4))))
        ])
        #expect(try await tails.latest(rootConversationID) { try EntryID(99) } == nil)
        #expect(try await tails.marker(rootConversationID, atOrBefore: nil) { throw SessionError.closed } == nil)
        #expect(tails.peek(fork) == nil)
        #expect(try await tails.latest(fork) { try EntryID(4) }?.rawValue == 4)
        tails.apply([try d3bEntry(5, 3)])
        #expect(try await tails.latest(fork) { throw SessionError.closed }?.rawValue == 5)
    }

    @Test("answers a cutoff from the newest marker only at or after it")
    func markerCutoff() async throws {
        let tails = SessionConversationTails()
        tails.apply([.conversation(value: .init(id: rootConversationID)), try d3bEntry(10, 1), try d3bEntry(11, 1, head: 10)])
        #expect(try await tails.marker(rootConversationID, atOrBefore: nil) { throw SessionError.closed }?.id.rawValue == 11)
        #expect(try await tails.marker(rootConversationID, atOrBefore: try EntryID(12)) { throw SessionError.closed }?.id.rawValue == 11)
        let reads = SessionTestLog<Int>()
        let cutoff = try EntryID(10)
        #expect(try await tails.marker(rootConversationID, atOrBefore: cutoff) { reads.append(1); return nil } == nil)
        #expect(try await tails.marker(rootConversationID, atOrBefore: cutoff) { reads.append(1); return nil } == nil)
        #expect(reads.count == 2)
    }

    @Test("keeps a bounded number of conversations, fewer with markers")
    func boundedCounts() throws {
        let tails = SessionConversationTails()
        for id in 1...5_000 {
            tails.apply([try d3bEntry(Int64(2 * id), Int64(id)),
                         try d3bEntry(Int64(2 * id + 1), Int64(id), head: Int64(2 * id))])
        }
        #expect(tails.size == 4096)
        #expect(tails.markers == 256)
    }

    @Test("freezes the markers it keeps")
    func markerValueIsImmutable() async throws {
        let tails = SessionConversationTails()
        let marker = try d3bEntry(2, 1, head: 1)
        tails.apply([marker])
        let found = try await tails.marker(rootConversationID, atOrBefore: nil) { throw SessionError.closed }
        if case .entry(let value, _) = marker { #expect(found == value) }
        else { Issue.record("Expected entry") }
    }
}
