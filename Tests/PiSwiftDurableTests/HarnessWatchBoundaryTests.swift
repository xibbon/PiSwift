// v1.5.2 D4: harness-view.test.ts:251–269 folds pending view operations.
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

    @Test(.timeLimit(.minutes(1))) func conversationWatchFoldsPendingEntriesIntoOneValue() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let watch = try await opened.root.watch(context: .background)
        let initial = try JSONValue(encoding: watch.value)
        for _ in 0..<100 { _ = try await failureNote(opened.root) }
        let calls = SessionTestLog<WatchCall<ConversationView>>()
        try watch.start { call, _ in calls.append(call) }
        await watch.waitUntilIdle()
        #expect(calls.count == 1)
        guard case .value(let value, let ops, _) = try #require(calls.values.first) else { return }
        #expect(value == watch.value)
        #expect(try Delta.applyImmutable(initial, ops) == JSONValue(encoding: value))
        #expect(!ops.isEmpty)
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }
}
