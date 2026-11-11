import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessWatchBoundaryTests {
    @Test(.timeLimit(.minutes(1))) func replacementUsesTheDeliveredRevisionWhenTheSourceHasAdvanced() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let watch = try await opened.root.watch(context: .background)
        let acquired = watch.value
        _ = try await failureNote(opened.root)
        // Force the same state as a replacement taken before a later source publication:
        // the delivered value is older than the source. The replacement must use that value.
        let oversized = Array(repeating: Delta.Op.set(["unused"], .null), count: maxPendingReceivedOps + 1)
        watch.advance(.value(value: acquired, ops: oversized, retired: false), context: .background)
        let calls = SessionTestLog<WatchCall<ConversationView>>()
        try watch.start { call, _ in calls.append(call) }
        await watch.waitUntilIdle()
        guard case .value(let value, let ops, _) = try #require(calls.values.first) else { return }
        #expect(calls.count == 1)
        #expect(value == acquired)
        #expect(ops == [.replace(try JSONValue(encoding: acquired))])
        #expect(try Delta.applyImmutable(.null, ops) == JSONValue(encoding: value))
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1))) func eventAdapterDeliversAll100PendingBatchesOnceInOrder() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let watch = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
        var entries: [EntryID] = []
        for _ in 0..<100 { entries.append(try await failureNote(opened.root).id) }
        let log = HarnessEventLog()
        try log.start(watch)
        await watch.waitUntilIdle()
        #expect(log.batches.count == 100)
        #expect(log.types == Array(repeating: "entry_appended", count: 100))
        #expect(log.events.compactMap { $0["entry"]?["id"]?.intValue } == entries.map { Int($0.rawValue) })
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }
}
