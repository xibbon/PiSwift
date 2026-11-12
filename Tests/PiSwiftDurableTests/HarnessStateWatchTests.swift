import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

/// Conversation state replaces the removed event adapter.
@Suite(.timeLimit(.minutes(1))) struct HarnessStateWatchTests {
    @Test func realGenerationPublishesEachPartialAndTheCommittedAnswer() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock)
        let models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models)
        let watch = try await opened.root.watch(context: .background)
        let values = SessionTestLog<ConversationView>()
        try watch.start { call, _ in if case .value(let value, _, _) = call { values.append(value) } }
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        for text in ["hel", "hello", "hello world"] {
            generationPartial(models, text: text)
            try await eventually { clock.pendingSleeperCount > 0 }
            clock.advance(by: 100)
            try await eventually {
                values.values.contains { $0.docs["pi.live"]?["generation"]?["message"]?["content"]?[0]?["text"] == .string(text) }
            }
        }
        generationFinal(models, text: "hello world")
        let settled = try await submission.wait(context: .background)
        #expect(settled.status == "done")
        try await eventually {
            watch.value.entries.contains { $0.model?.first?["content"]?[0]?["text"] == "hello world" } &&
                watch.value.docs["pi.live"]?["run"] == nil
        }
        await watch.waitUntilIdle()
        #expect(watch.value.entries.contains { $0.model?.first?["content"]?[0]?["text"] == "hello world" })
        #expect(watch.value.docs["pi.live"]?["run"] == nil)
        #expect(watch.value.docs["pi.live"]?["generation"] == nil)
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test func queuedInputAndRetryAreVisibleWithoutEvents() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock)
        let held = HarnessGatedResponse(message: chatAssistant("first"))
        setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 1, baseDelayMs: 1) }
        setup.models.setResponses([held.step,
            .message(chatAssistant("", reason: .error, error: "503 Service Unavailable")),
            .message(chatAssistant("second"))])
        let opened = try await openChat(setup: setup)
        let watch = try await opened.root.watch(context: .background)
        let values = SessionTestLog<ConversationView>()
        try watch.start { call, _ in if case .value(let value, _, _) = call { values.append(value) } }
        _ = try await generationSubmit(opened, "a")
        await held.reached.wait()
        let follow = try await generationSubmit(opened, "f")
        #expect(try await follow.status(context: .background).status == "queued")
        try await eventually { values.values.contains { $0.docs["pi.inbox"]?["items"]?[0]?["id"] == .number(Double(follow.id.rawValue)) } }
        held.release()
        try await eventually { values.values.contains { $0.docs["pi.live"]?["generation"]?["retry"] != nil } }
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 100)
        #expect(try await follow.wait(context: .background).status == "done")
        try await eventually {
            watch.value.entries.contains { $0.model?.first?["content"]?[0]?["text"] == "second" } &&
                watch.value.docs["pi.live"]?["generation"] == nil
        }
        await watch.waitUntilIdle()
        #expect(watch.value.docs["pi.live"]?["generation"] == nil)
        #expect(watch.value.docs["pi.inbox"]?["items"]?.arrayValue?.isEmpty != false)
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test func lateCompactionWatchRetainsTheRetryAndClearsSettledWork() async throws {
        let chat = try await compactionOpen()
        try await compactionHistory(chat)
        chat.setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 60_000) }
        chat.script.appendSummary([.message(compactionFailure("overloaded"))])
        let id = try await chat.root.compact(context: .background)
        try await eventually { try await compactionLive(chat).compactions?.first?.retry != nil }
        let watch = try await chat.root.watch(context: .background)
        let live = try JSONValue.object(#require(watch.value.docs["pi.live"])).decode(LiveState.self)
        #expect(live.compactions == [.init(taskId: id, reason: .manual, blocking: false,
            attempt: 1, retry: .init(at: 61000, error: "overloaded"))])
        try watch.start { _, _ in }
        _ = try await chat.harness.abortTask(id: id, context: .background)
        _ = try await compactionOutcome(chat, id)
        await watch.waitUntilIdle()
        #expect(watch.value.docs["pi.live"]?["compactions"] == nil)
        _ = await watch.stop(); try await chat.harness.close(context: .background)
    }

    @Test func streamedMessageOperationsRebuildTheLatestState() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let watch = try await opened.root.watch(context: .background)
        let initial = try JSONValue(encoding: watch.value)
        let calls = SessionTestLog<WatchCall<ConversationView>>()
        try watch.start { call, _ in calls.append(call) }
        let message = try EntryRecord.encodeMessages([.assistant(chatAssistant("hel"))])[0]
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("generation", ["attempt": 1, "message": message])
        }, context: .background)
        await watch.waitUntilIdle()
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.child("generation")!.child("message")!.child("content")!.child(0)!.set("text", "hello")
        }, context: .background)
        await watch.waitUntilIdle()
        var replica = initial
        for call in calls.values {
            guard case .value(let value, let ops, _) = call else { continue }
            replica = try #require(try Delta.applyImmutable(replica, ops))
            #expect(try replica == JSONValue(encoding: value))
        }
        #expect(replica["docs"]?["pi.live"]?["generation"]?["message"]?["content"]?[0]?["text"] == "hello")
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test func lateWatchContainsToolIdentityAndExplicitNullDetails() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("tools", [["callId": "opaque/🦉", "name": "echo", "taskId": 7,
                                     "status": "running", "output": "one", "details": .null]])
            try live.set("nestedTools", [["callId": "independent", "name": "echo", "taskId": 8,
                "parentCallId": "opaque/🦉", "parentTaskId": 7, "arguments": ["text": "final"],
                "status": "running", "details": .null]])
        }, context: .background)
        let watch = try await opened.root.watch(context: .background)
        let live = try JSONValue.object(#require(watch.value.docs["pi.live"])).decode(LiveState.self)
        #expect(try live.tools?.first?.taskId == TaskID(7))
        #expect(live.tools?.first?.callId == "opaque/🦉")
        #expect(live.tools?.first?.details == .null)
        #expect(try live.nestedTools?.first?.parentTaskId == TaskID(7))
        #expect(live.nestedTools?.first?.details == .null)
        #expect(live.nestedTools?.first?.arguments == ["text": "final"])
        #expect(try JSONValue(encoding: live).decode(LiveState.self) == live)
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test func toolOutputOperationsRetainTheSlidingTail() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        try await opened.root.commit({ tx in
            try await tx.doc(LiveDoc, conversationId: opened.root.id).set("tools", [
                ["callId": "tool", "name": "echo", "status": "running", "output": "a\nb\n"]])
        }, context: .background)
        let watch = try await opened.root.watch(context: .background)
        let initial = try JSONValue(encoding: watch.value)
        let calls = SessionTestLog<WatchCall<ConversationView>>()
        try watch.start { call, _ in calls.append(call) }
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.child("tools")!.child(0)!.set("output", "b\nc\n")
        }, context: .background)
        await watch.waitUntilIdle()
        guard case .value(let value, let ops, _) = try #require(calls.values.last) else { return }
        #expect(try Delta.applyImmutable(initial, ops) == JSONValue(encoding: value))
        #expect(value.docs["pi.live"]?["tools"]?[0]?["output"] == "b\nc\n")
        _ = await watch.stop(); try await opened.harness.close(context: .background)
    }

    @Test func closeEndsTheConversationWatch() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let watch = try await opened.root.watch(context: .background)
        try watch.start { _, _ in }
        try await opened.harness.close(context: .background)
        if case .ended = await watch.closed {} else { Issue.record("Watch did not end") }
    }
}
