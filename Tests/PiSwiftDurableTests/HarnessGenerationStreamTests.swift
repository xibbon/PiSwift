import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessGenerationStreamTests {
    @Test func partialsUseDeltasAndFinalWritesBase() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let storage = ControlledStorage(), opened = try await openChat(storage: storage, setup: setup, models: models)
        let record = try #require(await storage.findDocument(.init(kind: "pi.live", scope: .conversation(conversationId: opened.root.id)), at: .current, context: .background))
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models, text: "a")
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == .string("a") }
        generationPartial(models, text: "ab")
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == .string("ab") }
        generationFinal(models)
        #expect(try await submission.wait(context: .background).status == "done")
        let contents: [DocumentContent] = await storage.commits.flatMap { writes in writes.compactMap { write in
            if case .documentChange(let id, let content, _) = write, id == record.id { return content }; return nil
        } }
        #expect(contents.contains { if case .delta = $0 { true } else { false } })
        guard case .base = contents.last else { Issue.record("Final live write must be a base"); return }
        let append = contents.contains { content in
            guard case .delta(_, let ops, _) = content else { return false }
            return ops.contains { if case .append = $0 { true } else { false } }
        }
        #expect(append)
        try await opened.harness.close(context: .background)
    }
    @Test func partialThrottleUsesConfiguredIntervalAndStopsBeforeClassification() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(settings: .init(progress: .init(partialIntervalMs: 5000)), clock: clock)
        let models = HarnessManualModels(base: FakeDurableModels()), opened = try await openChat(setup: setup, models: models)
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models)
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 300)
        #expect(try await generationLive(opened)?.generation?.message == nil)
        generationFinal(models)
        #expect(try await submission.wait(context: .background).status == "done")
        clock.advance(by: 10000)
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func classificationJoinsInFlightPartialCommit() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let storage = ControlledStorage(), opened = try await openChat(storage: storage, setup: setup, models: models)
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models)
        try await eventually { clock.pendingSleeperCount > 0 }
        let gate = await storage.holdCommits()
        clock.advance(by: 100)
        await gate.waitUntilEntered()
        generationFinal(models)
        let waiter = settled { try await submission.wait(context: .background) }
        #expect(!waiter.isSettled)
        await gate.release()
        try await eventually { waiter.isSettled }
        #expect(try waiter.result?.get().status == "done")
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func abortedStreamConvertsCommittedPartial() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models), submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models)
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message != nil }
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant"])
        guard case .assistant(let message) = try entries.last?.messages()?.first else { Issue.record("No converted partial"); return }
        #expect(message.stopReason == .aborted && textOf(.assistant(message)) == "partial")
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func emptyStartThenDeferredLeavesNoPartial() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models), submission = try await generationSubmit(opened)
        let values = Mutex<[JSONObject]>([])
        let listener = try opened.harness.subscribeCommits { publication, _ in
            for change in publication.changes { if case .document(let document) = change, document.record.kind == "pi.live", let value = document.value { values.withLock { $0.append(value) } } }
        }
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        var message = chatAssistant("", reason: .pending); message.content = []
        models.stream.push(.start(partial: message))
        message.stopReason = .deferred; message.deferred = .init(provider: "faux", modelId: "faux-1", api: "openai-completions", id: "test")
        models.stream.push(.done(reason: .deferred, message: message))
        try await eventually { try await generationLive(opened)?.generation?.deferred != nil }
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        #expect(values.withLock { $0.allSatisfy { $0["generation"]?["message"] == nil } })
        listener.cancel()
        try await opened.harness.close(context: .background)
    }
    @Test func faultedRunConvertsPartialAndSettlesInputs() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models), submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        generationPartial(models)
        try await eventually { clock.pendingSleeperCount > 0 }
        clock.advance(by: 100)
        try await eventually { try await generationLive(opened)?.generation?.message != nil }
        var invalid = chatAssistant("final"); invalid.usage.cost.total = .nan
        models.stream.push(.done(reason: .stop, message: invalid))
        #expect(try await submission.wait(context: .background).reason == "faulted")
        #expect(try await generationLive(opened) == LiveState())
        let entries = try await allEntries(opened.root)
        #expect(entries.count == 2)
        guard case .assistant(let partial) = try entries.last?.messages()?.first else { Issue.record("No converted partial"); return }
        #expect(partial.stopReason == .aborted && textOf(.assistant(partial)) == "partial")
        try await opened.harness.close(context: .background)
    }
    @Test func blockedRunIsOrphanedWithFullCleanup() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let ids = try await opened.root.commit({ tx in
            let entry = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(UserMessage(content: .text("hi"), timestamp: 1))])))
            let submission = try await tx.createSubmission(.input(conversationId: opened.root.id, state: .placed(entry: entry.id)))
            let future = TaskKind<GenerationInput, GenerationCheckpoint>(name: "pi.generation", version: 2,
                initial: { _ in GenerationCheckpoint(phase: .prepare, attempt: 1) })
            let task = try await tx.createTask(future, input: GenerationInput(), options: .init(ownership: .conversation()))
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [submission.id])))
            return (task, submission.id)
        }, context: .background)
        await #expect(throws: ConversationBusy.self) { try await opened.root.submit(.input(content: .text("busy"), whenBusy: .reject), context: .background) }
        _ = try await opened.harness.abortTask(id: ids.0, context: .background)
        let outcome = try await opened.harness.waitForTask(id: ids.0, context: .background)
        #expect(outcome.outcome.status == "orphaned")
        #expect(try await opened.harness.submission(id: ids.1, context: .background)?.wait(context: .background).reason == "task_too_old")
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
    @Test func rejectsRegistryWithoutBuiltins() async throws {
        struct EmptyRegistry: RegistryReader {
            func snapshot() -> RegistrySnapshot { RegistrySnapshot(extensions: [], builtins: []) }
            func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void { {} }
        }
        await #expect(throws: HarnessOpenError.self) {
            try await Harness.open(storage: MemoryStorage(), options: HarnessOptions(models: FakeDurableModels(), registry: EmptyRegistry()), context: .background)
        }
    }
}
