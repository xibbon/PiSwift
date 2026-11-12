import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct ViewWindowDifferentialTests {
    private struct Fixture: Decodable { let tag: String; let cases: [Case] }
    private struct Case: Decodable {
        let index: Int; let fork: Bool; let min: Int; let max: Int; let from: Int?
        let inboxChanges: [[InboxItem]]; let transcriptSteps: [TranscriptStep]; let pageSize: Int; let initial: Projection; let bursts: [Int]; let frames: [Projection]
    }
    private struct Projection: Decodable, Equatable {
        let entries: [Int]; let kinds: [String]; let inbox: InboxState; let before: Int?
    }
    private struct TranscriptStep: Decodable { let action: String; let frame: Int?; let inbox: InboxState; let items: [[Int]] }
    private struct Frame: Sendable { let value: ConversationView; let ops: [Delta.Op] }

    @Test(.timeLimit(.minutes(2))) func taggedWindowOracleReplaysThroughSwiftHarness() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("Scripts/durable-fixtures/view-window-v152.json")))
        #expect(fixture.tag == "v1.5.2")
        #expect(fixture.cases.count == 30)
        for item in fixture.cases {
            let chat = try await openChat(setup: HarnessChatSetup())
            let initialEntries = try await chat.root.commit({ tx in
                var written: [EntryRecord] = []
                for index in 0..<300 {
                    let kind = index == 100 ? "summary" : index == 200 ? "pi.reset" : "note"
                    let head: EntryDraftHead? = index == 100 ? .entry(written[50].id) : nil
                    written.append(try await tx.appendEntry(chat.root.id, value: .init(kind: kind, data: .number(Double(index)), head: head)))
                }
                return written
            }, context: .background)
            let conversation: Conversation
            if item.fork {
                conversation = try await chat.root.fork(at: initialEntries[299].id, options: .init(ownership: .ownerless()), context: .background)
            } else { conversation = chat.root }
            var cursor: Cursor?
            var paged: [EntryID] = []
            repeat {
                let page = try await conversation.entries(limit: item.pageSize, cursor: cursor, context: .background)
                paged.append(contentsOf: page.items.map(\.id))
                cursor = page.next
            } while cursor != nil
            #expect(paged == initialEntries.reversed().map(\.id))
            let from: EntryID?
            if let position = item.from {
                from = position <= 300 ? initialEntries[position - 1].id : try EntryID(initialEntries[299].id.rawValue + 1000)
            } else { from = nil }
            let watch = try await conversation.watch(context: .background, window: .init(from: from, min: item.min, max: item.max))
            let initial = watch.value
            let frames = Mutex<[Frame]>([])
            try watch.start { call, _ in
                if case .value(let value, let ops, _) = call { frames.withLock { $0.append(.init(value: value, ops: ops)) } }
            }
            var all = initialEntries
            for (step, count) in item.bursts.enumerated() {
                let start = all.count
                let inboxItems = try JSONValue(encoding: item.inboxChanges[step])
                let added = try await conversation.commit({ tx in
                    var written: [EntryRecord] = []
                    for offset in 0..<count {
                        written.append(try await tx.appendEntry(conversation.id, value: .init(kind: "note", data: .number(Double(start + offset)))))
                    }
                    try await tx.doc(InboxDoc, conversationId: conversation.id).set("items", inboxItems)
                    return written
                }, context: .background)
                all.append(contentsOf: added)
                await watch.waitUntilIdle()
            }
            let positions: [EntryID: Int] = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
            func project(_ value: ConversationView) throws -> Projection {
                Projection(entries: try value.entries.map { Int(try #require($0.data?.numberValue)) }, kinds: value.entries.map(\.kind), inbox: try JSONValue.object(try #require(value.docs["pi.inbox"])).decode(InboxState.self), before: value.before.flatMap { positions[$0] })
            }
            #expect(try project(initial) == item.initial, "Initial case \(item.index)")
            let recorded = frames.withLock { $0 }
            #expect(recorded.count == item.frames.count)
            var rebuilt = try JSONValue(encoding: initial)
            for (frame, expected) in zip(recorded, item.frames) {
                rebuilt = try #require(try Delta.applyImmutable(rebuilt, frame.ops))
                #expect(try rebuilt.decode(ConversationView.self) == frame.value)
                #expect(try project(frame.value) == expected, "Frame case \(item.index)")
            }
            let transcript = try ConversationTranscript({ query, limit, context in
                try await conversation.entries(query: query, limit: limit, context: context)
            }, options: .init(pageSize: item.pageSize))
            var transcriptView: TranscriptView?
            for step in item.transcriptSteps {
                let current: TranscriptView
                switch step.action {
                case "initial": current = try await transcript.merge(initial)
                case "earlier": current = try await transcript.loadEarlier(context: .background)
                case "merge": current = try await transcript.merge(recorded[try #require(step.frame)].value)
                case "fill":
                    let gap = try #require(transcriptView?.items.compactMap { row -> TranscriptGap? in
                        if case .gap(let gap) = row { return gap }; return nil
                    }.first)
                    current = try await transcript.fillGap(gap, context: .background)
                default: throw SessionError.message("Unknown transcript fixture step")
                }
                #expect(try JSONValue.object(try #require(current.docs["pi.inbox"])).decode(InboxState.self) == step.inbox)
                transcriptView = current
                let rows: [[Int]] = try current.items.map { row in
                    switch row {
                    case .entry(let entry): return [0, Int(try #require(entry.data?.numberValue))]
                    case .gap(let gap): return [1, try #require(positions[gap.after]), try #require(positions[gap.upTo])]
                    case .earlier: return [2]
                    }
                }
                #expect(rows == step.items, "Transcript case \(item.index), \(step.action)")
            }
            _ = await watch.stop()
            try await chat.harness.close(context: .background)
        }
    }
}

