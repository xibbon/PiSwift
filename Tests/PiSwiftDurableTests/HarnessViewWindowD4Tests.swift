import Testing
import Synchronization
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d4Note(_ conversation: Conversation, _ number: Int) async throws -> EntryRecord {
    try await conversation.commit({ tx in
        try await tx.appendEntry(conversation.id, value: .init(kind: "note", data: .number(Double(number))))
    }, context: .background)
}

@Suite struct HarnessViewWindowD4Tests {
    // v1.5.2 D4: harness-view.test.ts:398,412,437.
    @Test(.timeLimit(.minutes(1))) func newestMinGrowsToMaxThenTrimsInOneFrame() async throws {
        let opened = try await openHarness()
        let root = try await opened.harness.root(context: .background)
        var written: [EntryRecord] = []
        for i in 0..<6 { written.append(try await d4Note(root, i)) }
        let watch = try await root.watch(context: .background, window: .init(min: 3, max: 5))
        try watch.start { _, _ in }
        #expect(watch.value.entries.map(\.id) == written.suffix(3).map(\.id))
        #expect(watch.value.before == written[2].id)
        for i in 6..<9 { written.append(try await d4Note(root, i)) }
        await watch.waitUntilIdle()
        #expect(watch.value.entries.map(\.id) == written.suffix(3).map(\.id))
        #expect(watch.value.before == written[5].id)
        _ = await watch.stop()
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 D4: harness-view.test.ts:412–426 tests the exact append, trim, before operations.
    @Test(.timeLimit(.minutes(1))) func synchronousWindowObserverGetsExactTrimOperations() async throws {
        let opened = try await openHarness()
        let root = try await opened.harness.root(context: .background)
        var written: [EntryRecord] = []
        for i in 0..<3 { written.append(try await d4Note(root, i)) }
        let calls = Mutex<[(ConversationView, [Delta.Op])]>([])
        let observation = try await opened.harness.observeConversation(root.id,
            observer: Observer<ConversationView>(advance: { call, _ in
                if case .value(let value, let ops, _) = call { calls.withLock { $0.append((value, ops)) } }
            }, end: { _ in }), context: .background, window: .init(min: 3, max: 5))
        #expect(observation.value.entries.count == 3)
        for i in 3..<6 { written.append(try await d4Note(root, i)) }
        let frames = calls.withLock { $0 }
        #expect(frames.map { $0.0.entries.count } == [4, 5, 3])
        #expect(frames.last?.0.before == written[2].id)
        #expect(frames.last?.1 == [
            .splice(["entries"], index: 5, remove: 0, items: [try JSONValue(encoding: written[5])]),
            .splice(["entries"], index: 0, remove: 3, items: []),
            .set(["before"], .number(Double(written[2].id.rawValue)))
        ])
        observation.detach()
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 D4: harness-view.test.ts:455,495.
    @Test(.timeLimit(.minutes(1))) func fromIsInclusiveOnlyForFirstValue() async throws {
        let opened = try await openHarness()
        let root = try await opened.harness.root(context: .background)
        var written: [EntryRecord] = []
        for i in 0..<6 { written.append(try await d4Note(root, i)) }
        let from = try await root.watch(context: .background,
                                        window: .init(from: written[4].id, min: 3, max: 4))
        #expect(from.value.entries.map(\.id) == written.suffix(2).map(\.id))
        #expect(from.value.before == written[3].id)
        let fallback = try await root.watch(context: .background,
                                            window: .init(from: written[0].id, min: 3, max: 4))
        #expect(fallback.value.entries.map(\.id) == written.suffix(3).map(\.id))
        #expect(fallback.value.before == written[2].id)
        let future = try await root.watch(context: .background,
                                          window: .init(from: try EntryID(written[5].id.rawValue + 10), min: 3, max: 4))
        try future.start { _, _ in }
        #expect(future.value.entries.isEmpty)
        #expect(future.value.before == written[5].id)
        let next = try await d4Note(root, 6)
        await future.waitUntilIdle()
        #expect(future.value.entries.map(\.id) == [next.id])
        _ = await from.stop(); _ = await fallback.stop(); _ = await future.stop()
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 D4: harness-view.test.ts:512,525.
    @Test(.timeLimit(.minutes(1))) func eachObserverHasIndependentBounds() async throws {
        let opened = try await openHarness()
        let root = try await opened.harness.root(context: .background)
        for i in 0..<8 { _ = try await d4Note(root, i) }
        let short = try await root.watch(context: .background, window: .init(min: 2, max: 3))
        let long = try await root.watch(context: .background, window: .init(min: 5, max: 7))
        try short.start { _, _ in }
        try long.start { _, _ in }
        #expect(short.value.entries.count == 2)
        #expect(long.value.entries.count == 5)
        for i in 8..<10 { _ = try await d4Note(root, i) }
        await short.waitUntilIdle(); await long.waitUntilIdle()
        #expect(short.value.entries.count == 2)
        #expect(long.value.entries.count == 7)
        await #expect(throws: (any Error).self) {
            _ = try await root.watch(context: .background, window: .init(min: 0))
        }
        await #expect(throws: (any Error).self) {
            _ = try await root.watch(context: .background, window: .init(min: 4, max: 3))
        }
        _ = await short.stop(); _ = await long.stop()
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 D4: harness-view.test.ts:548–568 and chord/watch.ts:305–381.
    @Test(.timeLimit(.minutes(3))) func overflowReplacementContainsOnlyTheBoundedWindow() async throws {
        let opened = try await openHarness()
        let root = try await opened.harness.root(context: .background)
        let watch = try await root.watch(context: .background, window: .init(min: 2, max: 3))
        for i in 0..<10_010 { _ = try await d4Note(root, i) }
        let calls = Mutex<[[Delta.Op]]>([])
        try watch.start { call, _ in
            if case .value(_, let ops, _) = call { calls.withLock { $0.append(ops) } }
        }
        await watch.waitUntilIdle()
        let first = try #require(calls.withLock { $0.first })
        if case .replace(let value) = first.first {
            let view = try value.decode(ConversationView.self)
            #expect(view.entries.count <= 3)
            #expect(view.before != nil)
        } else {
            Issue.record("Expected a bounded root replacement after 10,000 pending operations")
        }
        _ = await watch.stop()
        try await opened.harness.close(context: .background)
    }
}
