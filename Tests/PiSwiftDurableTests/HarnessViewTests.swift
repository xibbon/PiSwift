import Testing
import Synchronization
import PiSwiftChord
import PiSwiftAI
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Upstream v1.4.0 types.ts:78 requires an explicit checkpoint policy in each definition.

private struct ViewTestFrame: Sendable { let value: ConversationView; let ops: [Delta.Op] }
private final class ViewTestRecorder: Sendable {
    let watch: Watch<ConversationView>
    let initial: ConversationView
    private let recorded = Mutex<[ViewTestFrame]>([])
    init(_ conversation: Conversation) async throws {
        watch = try await conversation.watch(context: .background); initial = watch.value
        try watch.start { [self] call, _ in
            guard case .value(let value, let ops, _) = call else { Issue.record("Unexpected watch failure"); return }
            recorded.withLock { $0.append(.init(value: value, ops: ops)) }
        }
    }
    var frames: [ViewTestFrame] { recorded.withLock { $0 } }
    func drain() async { await watch.waitUntilIdle() }
    func stop() async { _ = await watch.stop() }
    func replay() throws -> ConversationView {
        var value = try JSONValue(encoding: initial)
        for frame in frames {
            value = try #require(try Delta.applyImmutable(value, frame.ops))
            #expect(try value.decode(ConversationView.self) == frame.value)
        }
        return try value.decode(ConversationView.self)
    }
}
private func viewFresh(_ conversation: Conversation) async throws -> ConversationView {
    let state = try await conversation.viewState(context: .background)
    defer { state.dispose() }; return state.value
}
private func viewNote(_ conversation: Conversation, _ kind: String, head: EntryID? = nil) async throws -> EntryRecord {
    try await conversation.commit({ try await $0.appendEntry(conversation.id, value: .init(kind: kind, head: head.map(EntryDraftHead.entry))) }, context: .background)
}

@Suite struct HarnessViewTests {
    @Test func hydratesActiveEntriesAndBuiltinDocuments() async throws {
        let setup = HarnessChatSetup(); setup.models.setResponses([.message(chatAssistant("hello"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("hi")), context: .background).wait(context: .background)
        let view = try await viewFresh(chat.root)
        #expect(view.conversation == ConversationRecord(id: chat.root.id))
        #expect(view.entries == (try await allEntries(chat.root)))
        #expect(view.docs.keys.sorted() == ["pi.agent", "pi.inbox", "pi.live", "pi.provider", "pi.usage"])
        #expect(view.docs["pi.live"] == [:]); #expect(view.docs["pi.inbox"] == ["items": []])
        try await chat.harness.close(context: .background)
    }
    @Test func oneFramePerTouchingCommitReplaysEveryRevision() async throws {
        let setup = HarnessChatSetup(), held = HarnessGatedResponse(message: chatAssistant("a longer answer"))
        setup.models.setResponses([held.step]); let chat = try await openChat(setup: setup)
        let recorder = try await ViewTestRecorder(chat.root), touches = Mutex(0)
        let subscription = try chat.harness.subscribeCommits { publication, _ in
            let touching = publication.changes.contains { change in
                switch change {
                case .entry(let entry): return entry.conversationId == chat.root.id
                case .document(let change): return change.source == nil && change.conversationId == chat.root.id && recorder.initial.docs[change.record.kind] != nil && !change.ops.isEmpty
                default: return false
                }
            }
            if touching { touches.withLock { $0 += 1 } }
        }
        let input = try await chat.root.submit(.input(content: .text("hi")), context: .background)
        await held.reached.wait(); await recorder.drain()
        #expect(recorder.frames.contains { $0.value.docs["pi.live"]?["generation"] != nil })
        held.release(); _ = try await input.wait(context: .background); try await chat.harness.waitForIdle(context: .background); await recorder.drain()
        #expect(recorder.frames.count == touches.withLock { $0 })
        #expect(try await recorder.replay() == viewFresh(chat.root))
        #expect(recorder.frames.first?.ops.contains { if case .splice([.key("entries")], 0, 0, let values) = $0 { return values.first?.objectValue?["kind"] == "pi.user" }; return false } == true)
        #expect(recorder.frames.flatMap(\.ops).contains(.set(["docs", "pi.live", "generation"], ["attempt": 1])))
        subscription.cancel(); await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func preservesUnchangedValuesAndSkipsUnrelatedCommits() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let other = try await chat.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let recorder = try await ViewTestRecorder(chat.root)
        _ = try await viewNote(other, "note")
        try await chat.root.configure(change: AgentChange(thinkingLevel: .set(.high)), context: .background)
        // v1.5.2 CH3: Finish this delivery before the next commit can fold into it.
        await recorder.drain()
        _ = try await viewNote(chat.root, "note"); await recorder.drain()
        #expect(recorder.frames.count == 2)
        #expect(recorder.frames[0].ops == [.set(["docs", "pi.agent", "thinkingLevel"], "high")])
        #expect(recorder.frames[0].value.entries == recorder.initial.entries)
        #expect(recorder.frames[0].value.docs["pi.live"] == recorder.initial.docs["pi.live"])
        #expect(recorder.frames[1].value.docs == recorder.frames[0].value.docs)
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func headMarkersStayInTranscriptOrder() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        _ = try await viewNote(chat.root, "a"); let b = try await viewNote(chat.root, "b"); _ = try await viewNote(chat.root, "c")
        let recorder = try await ViewTestRecorder(chat.root)
        let summary = try await viewNote(chat.root, "summary", head: b.id)
        // v1.5.2 CH3: Inspect each head change after its watch delivery has finished.
        await recorder.drain()
        _ = try await viewNote(chat.root, "d"); await recorder.drain()
        try await chat.root.reset(context: .background); await recorder.drain()
        // v1.5.2 D4: harness-view.test.ts:178 keeps summary and reset markers in ID order.
        #expect(recorder.frames.map { $0.value.entries.map(\.kind) } == [["a", "b", "c", "summary"], ["a", "b", "c", "summary", "d"], ["a", "b", "c", "summary", "d", "pi.reset"]])
        #expect(recorder.frames[0].ops == [.splice(["entries"], index: 3, remove: 0, items: [try JSONValue(encoding: summary)])])
        #expect(try await recorder.replay() == viewFresh(chat.root))
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func rawHeadDoesNotCutTranscript() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), old = try await viewNote(chat.root, "old")
        try await chat.root.reset(context: .background); let recorder = try await ViewTestRecorder(chat.root)
        _ = try await viewNote(chat.root, "summary", head: old.id); await recorder.drain()
        // v1.5.2 D4: harness-view.test.ts:178 preserves every marker in the full transcript.
        #expect(recorder.frames[0].value.entries.map(\.kind) == ["old", "pi.reset", "summary"])
        await recorder.stop(); #expect(try await viewFresh(chat.root).entries.map(\.kind) == ["old", "pi.reset", "summary"])
        try await chat.harness.close(context: .background)
    }
    @Test func forkHeadKeepsInheritedEntries() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), a = try await viewNote(chat.root, "a"), b = try await viewNote(chat.root, "b")
        let fork = try await chat.root.fork(at: b.id, options: .init(ownership: .ownerless()), context: .background)
        let recorder = try await ViewTestRecorder(fork); _ = try await viewNote(fork, "summary", head: b.id); await recorder.drain()
        #expect(recorder.initial.entries.map(\.id) == [a.id, b.id])
        // v1.5.2 D4: harness-view.test.ts:204 keeps a fork's head marker in place.
        #expect(recorder.frames[0].value.entries.map(\.kind) == ["a", "b", "summary"])
        #expect(try await recorder.frames[0].value == viewFresh(fork))
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func forkInheritsEntriesAndFollowsOnlyItsOwnCommits() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), first = try await viewNote(chat.root, "first")
        let fork = try await chat.root.fork(at: first.id, options: .init(ownership: .ownerless()), context: .background)
        let recorder = try await ViewTestRecorder(fork)
        #expect(recorder.initial.entries.map(\.kind) == ["first"])
        #expect(recorder.initial.conversation.parent == .init(conversationId: chat.root.id, at: first.id))
        _ = try await viewNote(chat.root, "parent"); _ = try await viewNote(fork, "child"); await recorder.drain()
        #expect(recorder.frames.map { $0.value.entries.map(\.kind) } == [["first", "child"]])
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func retirementDeletesDocumentAndRecreationSetsWholeDocument() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), recorder = try await ViewTestRecorder(chat.root)
        try await chat.root.commit({ tx in try await tx.retireDoc(LiveDoc, conversationId: chat.root.id) }, context: .background)
        // v1.5.2 CH3: Deliver retirement before recreation can fold into the pending call.
        await recorder.drain()
        try await chat.root.commit({ tx in try await tx.doc(LiveDoc, conversationId: chat.root.id).set("tools", []) }, context: .background)
        await recorder.drain()
        #expect(recorder.frames.map(\.ops) == [[.delete(["docs", "pi.live"])], [.set(["docs", "pi.live"], ["tools": []])]])
        #expect(recorder.frames[0].value.docs["pi.live"] == nil)
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func folds101PendingCommitsIntoTheNewestView() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), watch = try await chat.root.watch(context: .background)
        let initial = watch.value
        for _ in 0..<101 { _ = try await viewNote(chat.root, "note") }
        let frames = Mutex<[ViewTestFrame]>([])
        try watch.start { call, _ in
            guard case .value(let value, let ops, _) = call else { Issue.record("Unexpected watch failure"); return }
            frames.withLock { $0.append(.init(value: value, ops: ops)) }
        }
        await watch.waitUntilIdle()
        let frame = try #require(frames.withLock { $0.first })
        #expect(frames.withLock { $0.count } == 1)
        // v1.5.2 CH3: harness-view.test.ts:251–268 folds pending commits without a root replacement.
        if case .replace = frame.ops.first { Issue.record("Pending changes must retain delta operations") }
        #expect(try Delta.applyImmutable(JSONValue(encoding: initial), frame.ops) == JSONValue(encoding: frame.value))
        // v1.5.2 D4: harness-view.test.ts:251–269 trims the default 50/100 window.
        #expect(frame.value.entries.count == 50)
        #expect(frame.value.before != nil)
        _ = await watch.stop(); try await chat.harness.close(context: .background)
    }
    @Test func independentStateAndWatchRemountAfterLastRelease() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), state = try await chat.root.viewState(context: .background), recorder = try await ViewTestRecorder(chat.root)
        _ = try await viewNote(chat.root, "one"); await recorder.drain()
        #expect(state.value.entries.map(\.kind) == ["one"]); await recorder.stop(); #expect(recorder.frames.count == 1)
        _ = try await viewNote(chat.root, "two"); #expect(state.value.entries.map(\.kind) == ["one", "two"])
        let last = state.value; state.dispose(); #expect(try await viewFresh(chat.root) == last)
        try await chat.harness.close(context: .background)
    }
    @Test func closeEndsStateAndWatchAndRejectsAcquisition() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), watch = try await chat.root.watch(context: .background), state = try await chat.root.viewState(context: .background)
        try await chat.harness.close(context: .background)
        // v1.5.2 CH3: harness-view.test.ts:299 uses the shared ended reason.
        if case .ended = await watch.closed {} else { Issue.record("Watch did not close with Session") }
        #expect(state.value.entries.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await chat.root.watch(context: .background) }
        await #expect(throws: (any Error).self) { _ = try await chat.root.viewState(context: .background) }
    }
    @Test func queuedAcquisitionRejectsCancellationAndClose() async throws {
        let storage = ControlledStorage(), chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        // v1.5.2 D3a harness-tasks.test.ts:87–101: hold the callback on the line.
        let hold = holdSessionLine(chat.harness.session) { tx in _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "block")) }
        await hold.waitUntilEntered()
        let caller = ChordContext.background.withCancel()
        let cancelled = Task { try await chat.root.watch(context: caller.context) }
        try await eventually { chat.harness.session.line.queuedCount >= 1 }; caller.cancel(D2TestError("cancelled"))
        hold.release(); try await hold.finish()
        do { _ = try await cancelled.value; Issue.record("Cancelled watch was acquired") } catch { #expect(String(describing: error).contains("cancelled")) }
        let secondHold = holdSessionLine(chat.harness.session) { tx in _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "block2")) }
        await secondHold.waitUntilEntered()
        let queued = Task { try await chat.root.watch(context: .background) }
        try await eventually { chat.harness.session.line.queuedCount >= 1 }
        let closing = Task { try await chat.harness.close(context: .background) }
        try await eventually { chat.harness.tasks.closing }; secondHold.release(); try await secondHold.finish()
        await #expect(throws: (any Error).self) { _ = try await queued.value }; try await closing.value
    }
    @Test func sharedMountIsolatesFailingListener() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), failing = try await chat.root.watch(context: .background), recorder = try await ViewTestRecorder(chat.root), shared = try await chat.root.viewState(context: .background)
        #expect(failing.value == shared.value); shared.dispose()
        try failing.start { _, _ in throw D2TestError("listener failed") }
        _ = try await viewNote(chat.root, "one")
        // v1.5.2 CH3: Keep the healthy watch's two deliveries separate.
        await recorder.drain()
        _ = try await viewNote(chat.root, "two"); await recorder.drain()
        if case .listenerError = await failing.closed {} else { Issue.record("Listener error did not end watch") }
        #expect(recorder.frames.count == 2)
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
    @Test func oneCommitCombinesDocumentAndSeveralEntriesAndIgnoresCustomDocuments() async throws {
        let chat = try await openChat(setup: HarnessChatSetup()), recorder = try await ViewTestRecorder(chat.root)
        let other = try ConversationDocToken<JSONObject>(kind: "app.other", version: 1, fork: .initial, initial: { ["n": 0] }, checkpointWhen: { _, _, _ in false })
        try await chat.root.commit({ tx in
            _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "a"))
            try await tx.doc(LiveDoc, conversationId: chat.root.id).set("tools", [])
            _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "b"))
        }, context: .background)
        try await chat.root.commit({ tx in try await tx.doc(other, conversationId: chat.root.id).set("n", 1) }, context: .background)
        await recorder.drain(); #expect(recorder.frames.count == 1)
        #expect(recorder.frames[0].value.entries.map(\.kind) == ["a", "b"])
        #expect(try await recorder.replay() == viewFresh(chat.root))
        #expect(recorder.frames[0].ops.first == .set(["docs", "pi.live", "tools"], []))
        await recorder.stop(); try await chat.harness.close(context: .background)
    }
}

@Suite struct HarnessViewDeferredTests {
    // H8 harness-compaction.test.ts:1359.
    @Test func forkCompactionViewKeepsParentEntriesAndLeavesParentUnchanged() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let entries = try await allEntries(chat.root), last = try #require(entries.last)
        let fork = try await chat.root.fork(at: last.id, options: .init(ownership: .ownerless()), context: .background)
        let state = try await fork.viewState(context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        let outcome = try await compactionOutcome(chat, fork.compact(context: .background))
        #expect(try await compactionSubmission(chat, outcome).wait(context: .background).status == "done")
        let context = try await fork.context(context: .background)
        let u3 = try #require(entries.first { (try? textOf($0.messages()?.first))?.hasPrefix("u3") == true })
        #expect(context.head?.kind == "pi.compaction" && context.head?.head == u3.id && context.head?.conversationId == fork.id)
        #expect(context.messages.dropFirst().map(textOf) == [compactionText("u3", 100), compactionText("a3", 100)])
        #expect(try await !compactionKinds(chat.root).contains("pi.compaction"))
        // v1.5.2 D4: harness-view.test.ts:204 and view.ts:40–42 keep the fork's full transcript.
        #expect(try await state.value.entries == allEntries(fork))
        state.dispose(); try await chat.harness.close(context: .background)
    }
    // H8 harness-compaction.test.ts:1804.
    @Test func compactionKeepsRetainedEntriesMounted() async throws {
        let chat = try await compactionOpen(); try await compactionHistory(chat)
        let state = try await chat.root.viewState(context: .background)
        chat.script.appendSummary([.message(chatAssistant("SUMMARY"))])
        _ = try await compactionOutcome(chat, chat.root.compact(context: .background))
        // v1.5.2 D4: harness-view.test.ts:178 and view.ts:40–42 append a summary in ID order.
        try await eventually { state.value.entries.contains { $0.kind == "pi.compaction" } }
        #expect(try await state.value.entries == allEntries(chat.root))
        state.dispose(); try await chat.harness.close(context: .background)
    }
    // H5/H6 harness-lifecycle.test.ts:393, view operations.
    @Test func viewOperationsRejectOnceCloseBegins() async throws {
        let storage = ControlledStorage(), chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        // v1.5.2 D3a harness-tasks.test.ts:87–101: hold the callback on the line.
        let held = holdSessionLine(chat.harness.session) { tx in _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "block")) }
        await held.waitUntilEntered()
        let closing = Task { try await chat.harness.close(context: .background) }
        try await eventually { chat.harness.tasks.closing }
        await #expect(throws: HarnessClosedError.self) { _ = try await chat.root.viewState(context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await chat.root.watch(context: .background) }
        held.release(); try await held.finish(); try await closing.value
    }
    // H5/H6 harness-lifecycle.test.ts:450, queued view acquisitions.
    @Test(arguments: [false, true])
    func acquisitionQueuedAtSealRejects(isState: Bool) async throws {
        let storage = ControlledStorage(), chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        // v1.5.2 D3a harness-tasks.test.ts:87–101: hold the callback on the line.
        let held = holdSessionLine(chat.harness.session) { tx in _ = try await tx.appendEntry(chat.root.id, value: .init(kind: "block")) }
        await held.waitUntilEntered()
        let acquisition = Task {
            if isState { let state = try await chat.root.viewState(context: .background); state.dispose() }
            else { let watch = try await chat.root.watch(context: .background); _ = await watch.stop() }
        }
        try await eventually { chat.harness.session.line.queuedCount >= 1 }
        let closing = Task { try await chat.harness.close(context: .background) }
        try await eventually { chat.harness.tasks.closing }
        held.release(); try await held.finish()
        await #expect(throws: (any Error).self) { try await acquisition.value }
        try await closing.value
    }
    // H5/H6 harness-lifecycle.test.ts:533, view state and watch do not resume work.
    @Test func viewsDoNotResumeScheduling() async throws {
        let ran = Mutex(false), definition = harnessOneStep("test.h9-viewer") { _, runtime, context in
            ran.withLock { $0 = true }; try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let registry = createRegistry(); try registry.install(Extension(name: "h9-viewer", tasks: [AnyTaskDefinition(definition)]))
        let chat = try await openChat(setup: HarnessChatSetup(registry: registry))
        _ = try await harnessStart(chat.root, definition, background: true)
        let state = try await chat.root.viewState(context: .background), watch = try await chat.root.watch(context: .background)
        #expect(try await chat.harness.inspect(context: .background).scheduling == .paused)
        #expect(!ran.withLock { $0 })
        state.dispose(); _ = await watch.stop(); try await chat.harness.close(context: .background)
    }
}
