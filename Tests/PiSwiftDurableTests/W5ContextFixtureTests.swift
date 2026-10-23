import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.W5ContextFixtures")
struct W5ContextFixtureTests {
    @Test func contextMatchesTheUnmodifiedUpstreamImplementation() async throws {
        let url = try #require(Bundle.module.url(forResource: "context-baseline-v130", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(fixture["tag"] == "v1.3.0")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 15)
        for item in cases {
            let name = try #require(item["name"]?.stringValue)
            let entries = try #require(item["entries"]).decode([EntryRecord].self)
            let expected = try #require(item["expected"])
            let view = try deriveContext(entries: entries)
            try compare(view, expected: expected, name: name)
            let storage = MemoryStorage()
            let session = try await Session.open(storage: storage, context: .background)
            _ = try await session.commit({ tx in try await tx.createRootConversation() }, context: .background)
            var previous: ContextRange?
            for (entry, historical) in zip(entries, try #require(item["historical"]?.arrayValue)) {
                let appended = try await session.commit({ tx in
                    try await tx.appendEntry(rootConversationID, value: EntryDraft(
                        kind: entry.kind, model: entry.model, data: entry.data,
                        head: entry.head.map(EntryDraftHead.entry), edits: entry.edits))
                }, context: .background)
                #expect(appended.id == entry.id)
                let incremental = try await readContextFrom(session: session, storage: storage,
                    id: rootConversationID, context: .background, previous: previous)
                try compare(incremental.view, expected: historical, name: "Incremental \(name) at \(entry.id.rawValue)")
                previous = incremental.range
                try compare(deriveContext(entries: entries, at: entry.id), expected: historical, name: "Historical \(name) at \(entry.id.rawValue)")
            }
            try await session.close(context: .background)
        }
    }

    private func compare(_ view: ContextView, expected: JSONValue, name: String) throws {
        #expect(try JSONValue(encoding: view.entries.map(\.id)) == expected["ids"], "Active entries: \(name)")
        #expect(try JSONValue.array(view.contributions.map { .array(try EntryRecord.encodeMessages($0)) }) == expected["contributions"], "Contributions: \(name)")
        #expect(try JSONValue.array(EntryRecord.encodeMessages(view.messages)) == expected["messages"], "Message order: \(name)")
    }
}
