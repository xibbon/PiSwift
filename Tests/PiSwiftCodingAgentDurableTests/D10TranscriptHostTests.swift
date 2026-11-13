import PiSwiftChord
import PiSwiftDurable
import Testing
@testable import PiSwiftCodingAgentDurable

@Test(.timeLimit(.minutes(1)))
func d10TranscriptHostLoadsHistoryFillsOfflineGapAndSwitchesFork() async throws {
    let root = ConversationRecord(id: rootConversationID)
    // The first 500 entries exist at attach. The last 200 arrive while offline.
    let records = try (2...701).map {
        EntryRecord(id: try EntryID(Int64($0)), conversationId: root.id, kind: "chat", data: .string("line \($0 - 1)"))
    }
    let loader: EntryLoader = { query, limit, _ in
        let matches = records.filter { entry in
            (query.minEntryId.map { entry.id >= $0 } ?? true) &&
            (query.maxEntryId.map { entry.id <= $0 } ?? true)
        }
        let ordered = query.order == .descending ? Array(matches.reversed()) : matches
        return .init(items: Array(ordered.prefix(limit)), next: ordered.count > limit ? ["more": true] : nil)
    }
    let transcript = try ConversationTranscript(loader, options: .init(pageSize: 50))
    let initial = ConversationView(conversation: root, entries: Array(records[480..<500]),
        before: records[479].id, docs: [:])
    let source = RuntimeViewSource(.init(session: .init(id: "session", directory: "/session", cwd: "/project"),
        conversation: initial, conversations: [], models: []),
        transcript: try await transcript.merge(initial), transcriptMode: .paged, schedule: { _ in })
    var snapshots = [transcriptSnapshot("attach", source.hostCurrent())]
    #expect(entryIDs(source.hostCurrent()) == Array(records[480..<500]).map(\.id))
    #expect(source.hostCurrent().rows.first?.item == .earlier)
    let heldID = try #require(source.hostCurrent().rows.last?.id)
    for _ in 0..<3 {
        source.updateTranscript(try await transcript.loadEarlier(context: .background))
    }
    snapshots.append(transcriptSnapshot("three pages", source.hostCurrent()))
    #expect(entryIDs(source.hostCurrent()) == Array(records[330..<500]).map(\.id))
    #expect(source.hostCurrent().rows.last?.id == heldID)
    // The saved resume point is after entry 500. A long drop exceeds the watch window.
    #expect(try await transcript.resume?.from == records[500].id)
    let rejoined = ConversationView(conversation: root, entries: Array(records[680..<700]),
        before: records[679].id, docs: [:])
    source.updateConversation(rejoined, transcript: try await transcript.merge(rejoined))
    snapshots.append(transcriptSnapshot("offline", source.hostCurrent()))
    let gap = try #require(source.hostCurrent().transcript.items.compactMap { item -> TranscriptGap? in
        if case .gap(let value) = item { return value }; return nil
    }.first)
    #expect(gap.after == records[499].id)
    #expect(gap.upTo == records[680].id)
    var fills = 0
    while let gap = source.hostCurrent().transcript.items.compactMap({ item -> TranscriptGap? in
        if case .gap(let value) = item { return value }; return nil
    }).first {
        source.updateTranscript(try await transcript.fillGap(gap, context: .background))
        fills += 1
        #expect(fills <= 4)
        if fills > 4 { break }
    }
    #expect(fills == 4)
    #expect(entryIDs(source.hostCurrent()) == Array(records[330..<700]).map(\.id))
    #expect(source.hostCurrent().rows.first?.item == .earlier)
    #expect(source.current().conversation.entries.count == 20)
    snapshots.append(transcriptSnapshot("filled", source.hostCurrent()))

    // A fork has its own transcript state. No root load marker follows the switch.
    let fork = ConversationRecord(id: try ConversationID(900))
    let forkEntry = EntryRecord(id: try EntryID(901), conversationId: fork.id, kind: "chat", data: "fork only")
    let forkTranscript = try ConversationTranscript { _, _, _ in .init(items: [], next: nil) }
    let forkWindow = ConversationView(conversation: fork, entries: [forkEntry], docs: [:])
    source.replaceConversation(forkWindow, transcript: try await forkTranscript.merge(forkWindow))
    let final = source.hostCurrent()
    #expect(final.transcript.conversation == fork)
    #expect(final.rows.map(\.id) == [.entry(fork.id, forkEntry.id)])
    #expect(final.transcript.items == [.entry(forkEntry)])
    #expect(source.current().conversation == forkWindow)
    snapshots.append(transcriptSnapshot("fork", final))
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/D10-transcript.txt")
    let expected = try String(contentsOf: fixture, encoding: .utf8)
    #expect(snapshots.joined(separator: "\n") + "\n" == expected)
}

private func entryIDs(_ view: DurableHostView) -> [EntryID] {
    view.transcript.items.compactMap { item in
        if case .entry(let record) = item { return record.id }; return nil
    }
}
import Foundation

private func transcriptSnapshot(_ label: String, _ view: DurableHostView) -> String {
    let ids = entryIDs(view)
    let earlier = view.rows.contains { $0.item == .earlier }
    let gap = view.transcript.items.compactMap { item -> TranscriptGap? in
        if case .gap(let value) = item { return value }; return nil
    }.first
    let range = gap.map { "\($0.after.rawValue)..\($0.upTo.rawValue)" } ?? "none"
    return "\(label): conversation=\(view.transcript.conversation.id.rawValue) entries=\(ids.count) first=\(ids.first?.rawValue.description ?? "none") last=\(ids.last?.rawValue.description ?? "none") earlier=\(earlier) gap=\(range)"
}
