import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func transcriptEntries(_ count: Int) throws -> [EntryRecord] {
    var entries: [EntryRecord] = []
    var id: Int64 = 1
    while entries.count < count {
        if id % 3 != 0 { entries.append(.init(id: try EntryID(id), conversationId: rootConversationID, kind: "note")) }
        id += 1
    }
    return entries
}

private func transcriptWindow(_ entries: [EntryRecord], _ first: Int, _ last: Int,
                              docs: [String: JSONObject] = [:]) -> ConversationView {
    .init(conversation: .init(id: rootConversationID), entries: Array(entries[first...last]),
          before: first == 0 ? nil : entries[first - 1].id, docs: docs)
}

private func transcriptShape(_ view: TranscriptView) -> [String] {
    view.items.map { item in
        switch item {
        case .earlier: "earlier"
        case .entry(let entry): String(entry.id.rawValue)
        case .gap(let gap): "gap \(gap.after.rawValue)..\(gap.upTo.rawValue)"
        }
    }
}

private func entryShape(_ entries: ArraySlice<EntryRecord>) -> [String] { entries.map { String($0.id.rawValue) } }
private func transcriptGap(_ view: TranscriptView) throws -> TranscriptGap {
    try #require(view.items.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }.first)
}

private actor TranscriptLoader {
    let entries: [EntryRecord]
    var calls: [ConversationEntryQuery] = []
    var failure: String?
    var alwaysCursor = false
    var paused = false
    var pending: [CheckedContinuation<Void, Never>] = []
    var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ entries: [EntryRecord]) { self.entries = entries }
    func setFailure(_ message: String?) { failure = message }
    func setAlwaysCursor() { alwaysCursor = true }
    func pause() { paused = true }
    func resume() {
        paused = false
        let waiting = pending; pending.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
    func load(_ query: ConversationEntryQuery, _ limit: Int, _ context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        calls.append(query)
        let ready = callWaiters.filter { $0.0 <= calls.count }
        callWaiters.removeAll { $0.0 <= calls.count }
        for waiter in ready { waiter.1.resume() }
        if paused { await withCheckedContinuation { pending.append($0) } }
        if let failure { throw SessionError.message(failure) }
        try context.abortSignal?.throwIfAborted()
        let matching = entries.filter {
            (query.minEntryId == nil || $0.id >= query.minEntryId!) && (query.maxEntryId == nil || $0.id <= query.maxEntryId!)
        }
        let ordered = query.order == .ascending ? matching : matching.reversed()
        return .init(items: Array(ordered.prefix(limit)), next: alwaysCursor || ordered.count > limit ? ["more": true] : nil)
    }
    var loader: EntryLoader { { query, limit, context in try await self.load(query, limit, context) } }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationTranscriptTests {
    @Test func firstWindowsRetainHistoryAndMetadataChanges() async throws {
        let entries = try transcriptEntries(30)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader)
        let first = try await helper.merge(transcriptWindow(entries, 10, 19, docs: ["a": ["n": 1]]))
        #expect(transcriptShape(first) == ["earlier"] + entryShape(entries[10...19]))
        #expect(await helper.newest == entries[19].id)
        let grown = try await helper.merge(transcriptWindow(entries, 10, 21, docs: first.docs))
        let dropped = try await helper.merge(transcriptWindow(entries, 18, 21, docs: first.docs))
        #expect(grown == dropped)
        #expect(transcriptShape(dropped) == ["earlier"] + entryShape(entries[10...21]))
        let changed = try await helper.merge(transcriptWindow(entries, 18, 21, docs: ["a": ["n": 2]]))
        #expect(changed.items == dropped.items)
        #expect(changed.docs == ["a": ["n": 2]])
        #expect(first.items != grown.items)
        let whole = try ConversationTranscript(await loader.loader)
        #expect(try await whole.merge(transcriptWindow(entries, 0, 29)).items == entries.map(TranscriptItem.entry))
        #expect(await loader.calls.isEmpty)
    }

    @Test func gapUsesExclusiveBoundsAndFillsInPagesWithHoles() async throws {
        let entries = try transcriptEntries(200)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader, options: .init(pageSize: 10))
        _ = try await helper.merge(transcriptWindow(entries, 100, 109))
        var view = try await helper.merge(transcriptWindow(entries, 190, 199))
        let stale = try transcriptGap(view)
        #expect(stale == .init(after: entries[109].id, upTo: entries[190].id))
        view = try await helper.fillGap(stale, context: .background)
        #expect(try transcriptGap(view) == .init(after: entries[119].id, upTo: entries[190].id))
        let firstQuery = try #require(await loader.calls.first)
        #expect(firstQuery.minEntryId?.rawValue == entries[109].id.rawValue + 1)
        #expect(firstQuery.maxEntryId?.rawValue == entries[190].id.rawValue - 1)
        #expect(firstQuery.order == .ascending)
        // Reuse a stale descriptor after every shrink.
        for _ in 0..<7 { view = try await helper.fillGap(stale, context: .background) }
        #expect(transcriptShape(view) == ["earlier"] + entryShape(entries[100...]))
        let calls = await loader.calls.count
        #expect(try await helper.fillGap(stale, context: .background) == view)
        #expect(await loader.calls.count == calls)
    }

    @Test func earlierPagesReachStartAndRemoveMarker() async throws {
        let entries = try transcriptEntries(45)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader, options: .init(pageSize: 20))
        _ = try await helper.merge(transcriptWindow(entries, 40, 44))
        let first = try await helper.loadEarlier(context: .background)
        #expect(transcriptShape(first) == ["earlier"] + entryShape(entries[20...]))
        let second = try await helper.loadEarlier(context: .background)
        #expect(second.items == entries.map(TranscriptItem.entry))
        let calls = await loader.calls
        #expect(calls.map(\.order) == [.descending, .descending])
        #expect(calls.first?.maxEntryId == entries[39].id)
        #expect(try await helper.loadEarlier(context: .background) == second)
        #expect(await loader.calls.count == 2)
    }

    @Test func emptyWindowsPreserveGapsAndAdvanceResume() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader)
        #expect(try await helper.resume == nil)
        _ = try await helper.merge(.init(conversation: .init(id: rootConversationID), entries: [], docs: [:]))
        #expect(try await helper.resume == .init())
        let first = try await helper.merge(transcriptWindow(entries, 10, 19))
        let same = try await helper.merge(.init(conversation: first.conversation, entries: [], before: entries[19].id, docs: [:]))
        #expect(same == first)
        let past = try await helper.merge(.init(conversation: first.conversation, entries: [], before: entries[65].id, docs: [:]))
        #expect(try transcriptGap(past).upTo.rawValue == entries[65].id.rawValue + 1)
        #expect(await helper.newest == entries[65].id)
        #expect(try await helper.resume?.from?.rawValue == entries[65].id.rawValue + 1)
        let continued = try await helper.merge(transcriptWindow(entries, 66, 69))
        let inside = try await helper.merge(.init(conversation: first.conversation, entries: [], before: entries[40].id, docs: [:]))
        #expect(inside.items == continued.items)
        #expect(inside.items.filter { if case .gap = $0 { true } else { false } }.count == 1)
    }

    @Test func coveringWindowsShrinkSplitAndCloseGaps() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader)
        _ = try await helper.merge(transcriptWindow(entries, 40, 49))
        _ = try await helper.merge(transcriptWindow(entries, 90, 99))
        let split = try await helper.merge(transcriptWindow(entries, 60, 69))
        let gaps = split.items.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }
        #expect(gaps == [.init(after: entries[49].id, upTo: entries[60].id), .init(after: entries[69].id, upTo: entries[90].id)])
        let tail = try await helper.merge(transcriptWindow(entries, 70, 99))
        #expect(try transcriptGap(tail) == gaps[0])
        let all = try await helper.merge(transcriptWindow(entries, 0, 99))
        #expect(all.items == entries.map(TranscriptItem.entry))
        #expect(await loader.calls.isEmpty)
    }

    @Test func disjointOlderWindowOpensGapBelowHeldEntries() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader)
        _ = try await helper.merge(transcriptWindow(entries, 80, 89))
        let older = try await helper.merge(transcriptWindow(entries, 10, 19))
        #expect(transcriptShape(older) == ["earlier"] + entryShape(entries[10...19]) +
            ["gap \(entries[19].id.rawValue)..\(entries[80].id.rawValue)"] + entryShape(entries[80...89]))
        let filled = try await helper.fillGap(transcriptGap(older), context: .background)
        #expect(try transcriptGap(filled).after == entries[69].id)
    }

    @Test func concurrentEarlierAndGapLoadsAreShared() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        await loader.pause()
        let helper = try ConversationTranscript(await loader.loader)
        _ = try await helper.merge(transcriptWindow(entries, 40, 49))
        let gap = try transcriptGap(await helper.merge(transcriptWindow(entries, 90, 99)))
        let earlierA = Task { try await helper.loadEarlier(context: .background) }
        let fillA = Task { try await helper.fillGap(gap, context: .background) }
        await loader.waitForCalls(2)
        let earlierB = Task { try await helper.loadEarlier(context: .background) }
        let fillB = Task { try await helper.fillGap(gap, context: .background) }
        // A metadata merge while loads wait must be visible in their results.
        _ = try await helper.merge(transcriptWindow(entries, 90, 99, docs: ["live": ["n": 1]]))
        for _ in 0..<20 { await Task.yield() }
        #expect(await loader.calls.count == 2)
        await loader.resume()
        let a = try await earlierA.value; let b = try await earlierB.value
        let c = try await fillA.value; let d = try await fillB.value
        #expect(a == b); #expect(c == d)
        #expect(a.docs == ["live": ["n": 1]])
        #expect(await loader.calls.count == 2)
        #expect(try await helper.loadEarlier(context: .background).items == entries.map(TranscriptItem.entry))
    }

    @Test func staleAndCurrentGapShareOneLoad() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader, options: .init(pageSize: 10))
        _ = try await helper.merge(transcriptWindow(entries, 10, 19))
        let stale = try transcriptGap(await helper.merge(transcriptWindow(entries, 90, 99)))
        let current = try transcriptGap(await helper.fillGap(stale, context: .background))
        #expect(stale != current)
        await loader.pause()
        let a = Task { try await helper.fillGap(stale, context: .background) }
        await loader.waitForCalls(2)
        let b = Task { try await helper.fillGap(current, context: .background) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await loader.calls.count == 2)
        await loader.resume()
        #expect(try await a.value == b.value)
        #expect(await loader.calls.count == 2)
    }

    @Test func failedLoadsCanRetryAndNeedAnInitialMerge() async throws {
        let entries = try transcriptEntries(100)
        let loader = TranscriptLoader(entries)
        let helper = try ConversationTranscript(await loader.loader)
        await #expect(throws: (any Error).self) { try await helper.loadEarlier(context: .background) }
        await #expect(throws: (any Error).self) {
            try await helper.fillGap(.init(after: EntryID(1), upTo: EntryID(2)), context: .background)
        }
        _ = try await helper.merge(transcriptWindow(entries, 40, 49))
        let gap = try transcriptGap(await helper.merge(transcriptWindow(entries, 90, 99)))
        await loader.setFailure("offline")
        await #expect(throws: SessionError.message("offline")) { try await helper.loadEarlier(context: .background) }
        await #expect(throws: SessionError.message("offline")) { try await helper.fillGap(gap, context: .background) }
        await loader.setFailure(nil)
        _ = try await helper.loadEarlier(context: .background)
        #expect(try await helper.fillGap(gap, context: .background).items == entries.map(TranscriptItem.entry))
        #expect(await loader.calls.count == 4)
    }

    @Test func emptyPageWithCursorEndsRange() async throws {
        let entries = try transcriptEntries(60)
        let loader = TranscriptLoader(entries)
        await loader.setAlwaysCursor()
        let helper = try ConversationTranscript(await loader.loader, options: .init(pageSize: 100))
        _ = try await helper.merge(transcriptWindow(entries, 10, 19))
        let gap = try transcriptGap(await helper.merge(transcriptWindow(entries, 40, 49)))
        _ = try await helper.fillGap(gap, context: .background)
        let filled = try await helper.fillGap(gap, context: .background)
        #expect(transcriptShape(filled) == ["earlier"] + entryShape(entries[10...49]))
        _ = try await helper.loadEarlier(context: .background)
        let whole = try await helper.loadEarlier(context: .background)
        #expect(whole.items == entries[0...49].map(TranscriptItem.entry))
    }

    @Test func optionsAndIDBoundariesAreValidated() async throws {
        #expect(throws: (any Error).self) { try ConversationTranscript({ _, _, _ in .init(items: []) }, options: .init(pageSize: 0)) }
        #expect(throws: (any Error).self) { try ConversationTranscript({ _, _, _ in .init(items: []) }, options: .init(pageSize: -1)) }
        let max = try EntryID(EntryID.maximumRawValue)
        let helper = try ConversationTranscript { _, _, _ in .init(items: []) }
        let small = try EntryRecord(id: EntryID(1), conversationId: rootConversationID, kind: "note")
        let first = try await helper.merge(.init(conversation: .init(id: rootConversationID), entries: [small], docs: [:]))
        await #expect(throws: (any Error).self) {
            try await helper.merge(.init(conversation: first.conversation, entries: [], before: max, docs: [:]))
        }
        #expect(await helper.newest == small.id)
        let last = EntryRecord(id: max, conversationId: rootConversationID, kind: "note")
        _ = try await helper.merge(.init(conversation: first.conversation, entries: [small, last], docs: [:]))
        #expect(await helper.newest == max)
        #expect(throws: (any Error).self) { try ConversationTranscript({ _, _, _ in .init(items: []) }, options: .init(pageSize: Int.max)) }
        await #expect(throws: (any Error).self) { try await helper.resume }
    }

    @Test func itemJSONMatchesUpstreamShape() throws {
        let entry = try #require(transcriptEntries(1).first)
        let item = TranscriptItem.gap(.init(after: entry.id, upTo: try EntryID(5)))
        #expect(try JSONValue(encoding: item) == ["kind": "gap", "after": 1, "upTo": 5])
        let items: [TranscriptItem] = [.earlier, .entry(entry), item]
        #expect(try JSONDecoder().decode([TranscriptItem].self, from: JSONEncoder().encode(items)) == items)
    }

    @Test func harnessWalkthroughAppendsLoadsAndResumes() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        func append(_ count: Int) async throws {
            for _ in 0..<count {
                _ = try await chat.root.commit({ tx in
                    try await tx.appendEntry(chat.root.id, value: .init(kind: "note"))
                }, context: .background)
            }
        }
        try await append(120)
        let helper = try ConversationTranscript { query, limit, context in
            try await chat.root.entries(query: query, limit: limit, context: context)
        }
        let watch = try await chat.root.watch(context: .background, window: .init(min: 10, max: 20))
        _ = try await helper.merge(watch.value)
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { _ = try await helper.merge(value) }
        }
        // v1.5.2 D4: examples/31-transcript.ts:68–75 observes every live append.
        // The Swift watch callback is asynchronous, so drain it between writes.
        for _ in 0..<15 { try await append(1); await watch.waitUntilIdle() }
        let live = try await helper.merge(watch.value)
        #expect(live.items.compactMap { if case .entry(let entry) = $0 { entry } else { nil } }.count == 25)
        #expect(live.items.filter { if case .gap = $0 { true } else { false } }.isEmpty)
        _ = await watch.stop()
        try await append(40)
        let resume = try #require(await helper.resume)
        let resumed = try await chat.root.watch(context: .background, window: .init(from: resume.from, min: 10, max: 20))
        var view = try await helper.merge(resumed.value)
        #expect(view.items.filter { if case .gap = $0 { true } else { false } }.count == 1)
        // These bounds keep a regression from making the test loop without end.
        for _ in 0..<10 {
            guard let gap = view.items.compactMap({ if case .gap(let gap) = $0 { gap } else { nil } }).first else { break }
            view = try await helper.fillGap(gap, context: .background)
        }
        for _ in 0..<10 {
            guard view.items.first == .earlier else { break }
            view = try await helper.loadEarlier(context: .background)
        }
        #expect(view.items == (try await allEntries(chat.root)).map(TranscriptItem.entry))
        try await append(3)
        let next = try #require(await helper.resume)
        let again = try await chat.root.watch(context: .background, window: .init(from: next.from, min: 10, max: 20))
        #expect(again.value.entries.count == 3)
        view = try await helper.merge(again.value)
        #expect(view.items == (try await allEntries(chat.root)).map(TranscriptItem.entry))
        _ = await resumed.stop(); _ = await again.stop()
        try await chat.harness.close(context: .background)
    }
}
