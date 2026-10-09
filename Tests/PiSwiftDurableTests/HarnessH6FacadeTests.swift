import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func h6ExpectClosed<Value>(_ operation: () async throws -> Value) async {
    do { _ = try await operation(); Issue.record("Closed operation returned") }
    catch { #expect(String(describing: error).contains("closed")) }
}
private func h6FacadeTree(_ harness: Harness, _ root: Conversation, _ owner: HarnessTestTask, _ inner: HarnessTestTask, background: Bool = false) async throws -> (TaskID, Conversation, TaskID) {
    let ids = try await root.commit({ tx in
        let ownerId = try await tx.createTask(owner, input: 0, options: .init(ownership: .conversation(), background: background))
        let child = try await tx.createConversation(ownership: .task(taskId: ownerId))
        let innerId = try await tx.createTask(inner, input: 0, options: .init(ownership: .conversation(), conversationId: child.id))
        let live = try await tx.doc(LiveDoc, conversationId: child.id)
        try live.set("run", JSONValue(encoding: LiveRun(taskId: innerId, inputs: [])))
        return (ownerId, child.id, innerId)
    }, context: .background)
    return (ids.0, try #require(try await harness.conversation(id: ids.1, context: .background)), ids.2)
}

@Suite struct HarnessH6FacadeTests {
    // H5 deferred harness-lifecycle.test.ts:393.
    @Test func submissionAndResetOperationsRejectOnceCloseStarts() async throws {
        let setup = HarnessChatSetup(), storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: setup)
        let done = try await opened.root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let held = await storage.holdCommits(), root = opened.root
        let blocking = Task { try await root.commit({ tx in _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "blocker")) }, context: .background) }
        await held.waitUntilEntered()
        let closing = Task { try await opened.harness.close(context: .background) }
        try await eventually { opened.harness.tasks.closing }
        await h6ExpectClosed { try await root.submit(.input(content: .text("x")), context: .background) }
        await h6ExpectClosed { try await root.reset(context: .background) }
        await h6ExpectClosed { try await done.status(context: .background) }
        await h6ExpectClosed { try await done.wait(context: .background) }
        await h6ExpectClosed { try await done.abort(context: .background) }
        await h6ExpectClosed { try await opened.harness.submission(id: done.id, context: .background) }
        await h6ExpectClosed { try await opened.harness.abortSubmission(id: done.id, context: .background) }
        await held.release(); try await blocking.value; try await closing.value
    }

    // H5 deferred harness-lifecycle.test.ts:450.
    @Test func settledSubmissionWaitAdmittedBeforeCloseStillReturns() async throws {
        let storage = ControlledStorage()
        let opened = try await openChat(storage: storage, setup: HarnessChatSetup())
        let done = try await opened.root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let held = await storage.holdCommits(), root = opened.root
        let blocking = Task { try await root.commit({ tx in _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "blocker")) }, context: .background) }
        await held.waitUntilEntered()
        let wait = Task { try await done.wait(context: .background) }
        try await eventually { opened.harness.session.line.queuedCount >= 1 }
        let closing = Task { try await opened.harness.close(context: .background) }
        try await eventually { opened.harness.tasks.closing }
        await held.release(); try await blocking.value
        #expect(try await wait.value.status == "done")
        try await closing.value
    }

    // H5 deferred harness-lifecycle.test.ts:533,565 and harness-inspect.test.ts:145.
    @Test(arguments: [false, true])
    func submissionReadsStayPausedAndProgressCallsEnableScheduling(wait: Bool) async throws {
        let ran = Mutex(false)
        let definition = harnessOneStep("test.h6-progress") { _, runtime, context in
            ran.withLock { $0 = true }; try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let registry = createRegistry()
        try registry.install(Extension(name: "progress", tasks: [AnyTaskDefinition(definition)]))
        let setup = HarnessChatSetup(registry: registry)
        let opened = try await openChat(setup: setup)
        _ = try await harnessStart(opened.root, definition, background: true)
        let queuedId = try await opened.root.commit({ tx in
            try await tx.createSubmission(.write(conversationId: opened.root.id)).id
        }, context: .background)
        let acquired = try #require(try await opened.harness.submission(id: queuedId, context: .background))
        #expect(try await acquired.status(context: .background).status == "queued")
        #expect(try await opened.harness.inspect(context: .background).submissions.map(\.id).contains(queuedId))
        #expect(!ran.withLock { $0 })
        #expect(try await opened.harness.inspect(context: .background).scheduling == .paused)
        let operation = Task {
            if wait { _ = try await acquired.wait(context: .background) }
            else { _ = try await opened.root.submit(.write(entry: EntryDraft(kind: "note")), context: .background) }
        }
        try await eventually { ran.withLock { $0 } }
        try await opened.harness.close(context: .background)
        _ = try? await operation.value
    }

    // H5 deferred harness-ownership.test.ts:200,286.
    @Test func taskAbortWithdrawsChildInputsKeepsOwnInputsAndAllWrites() async throws {
        let clock = TestClock(), definition = harnessOneStep("test.h6-held") { _, runtime, context in
            try await runtime.sleep(until: 1_000_000, context: context)
        }
        let registry = Registry()
        try registry.install(Extension(name: "held", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: registry, clock: clock), context: .background)
        let root = try await harness.root(context: .background)
        let (owner, child, inner) = try await h6FacadeTree(harness, root, definition, definition)
        try await root.commit({ tx in try await tx.doc(LiveDoc, conversationId: root.id).set("run", JSONValue(encoding: LiveRun(taskId: owner, inputs: []))) }, context: .background)
        let own = try await root.submit(.input(content: .text("own")), context: .background)
        let below = try await child.submit(.input(content: .text("below")), context: .background)
        let write = try await child.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        #expect(try await harness.abortTask(id: owner, context: .background) == .marked)
        _ = try await harness.waitForTask(id: inner, context: .background)
        #expect(try await own.status(context: .background).status == "queued")
        #expect(try await below.wait(context: .background).reason == "aborted")
        #expect(try await write.status(context: .background).status == "queued")
        try await harness.close(context: .background)
    }

    // H5 deferred harness-ownership.test.ts:247.
    @Test func conversationAbortWithdrawsInputsKeepsWritesAndBackgroundTasks() async throws {
        let clock = TestClock(), definition = harnessOneStep("test.h6-conversation-hold") { _, runtime, context in
            try await runtime.sleep(until: 1_000_000, context: context)
        }
        let registry = Registry()
        try registry.install(Extension(name: "held", tasks: [AnyTaskDefinition(definition)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: registry, clock: clock), context: .background)
        let root = try await harness.root(context: .background)
        let foreground = try await h6FacadeTree(harness, root, definition, definition)
        let background = try await h6FacadeTree(harness, root, definition, definition, background: true)
        try await root.commit({ tx in try await tx.doc(LiveDoc, conversationId: root.id).set("run", JSONValue(encoding: LiveRun(taskId: foreground.0, inputs: []))) }, context: .background)
        let input = try await root.submit(.input(content: .text("later")), context: .background)
        let write = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        try await root.abort(context: .background)
        _ = try await harness.waitForTask(id: foreground.0, context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        #expect(try await write.status(context: .background).status == "queued")
        #expect(try await harness.getTask(id: background.0, context: .background)?.state.status != "terminal")
        #expect(try await harness.getTask(id: background.2, context: .background)?.state.status != "terminal")
        _ = try await harness.abortTask(id: background.0, context: .background)
        try await harness.close(context: .background)
    }
    // H5 deferred harness-ownership.test.ts:395.
    @Test func lateInputBelowHeldFailedOwnerIsWithdrawn() async throws {
        let clock = TestClock(), abortGate = SessionTestGate(), abortReached = SessionTestGate(), failGate = SessionTestGate()
        let owner = harnessOneStep("test.h6-failing-owner") { _, runtime, context in
            await failGate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .failed(error: TaskOutcomeError(message: "failed"))) }, context: context)
        }
        let inner = harnessOneStep("test.h6-slow-abort", run: { _, runtime, context in
            try await runtime.sleep(until: 1_000_000, context: context)
        }, abort: { _, runtime, context in
            abortReached.release(); await abortGate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        let registry = Registry()
        try registry.install(Extension(name: "held", tasks: [AnyTaskDefinition(owner), AnyTaskDefinition(inner)]))
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: registry, clock: clock), context: .background)
        let root = try await harness.root(context: .background)
        let tree = try await h6FacadeTree(harness, root, owner, inner)
        try harness.resume(); failGate.release()
        await abortReached.wait()
        #expect(try await harness.getTask(id: tree.0, context: .background)?.state.status == "completing")
        let late = try await tree.1.submit(.input(content: .text("late")), context: .background)
        #expect(try await late.wait(context: .background).reason == "aborted")
        abortGate.release()
        _ = try await harness.waitForTask(id: tree.0, context: .background)
        try await harness.close(context: .background)
    }

    // H5 deferred harness-ownership.test.ts:900.
    @Test func backgroundSupervisorResubmitsIdempotentlyAfterSQLiteReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("supervisor.sqlite").path
        let children = try ConversationDocToken<JSONObject>(kind: "test.h6-children", version: 1, fork: .initial, initial: { [:] })
        let supervisor = harnessOneStep("test.h6-supervisor") { task, runtime, context in
            let parent = try ConversationID(Int64(task.input))
            let state = try #require(try await runtime.snapshot(children, conversationId: parent, context: context))
            let childId = try #require(state["child"]).decode(ConversationID.self)
            let child = try #require(try await runtime.conversation(childId, context: context))
            let submission = try await child.submit(.input(content: .text("work"), requestId: "stable"), context: context)
            let receipt = try await submission.wait(context: context)
            let answer = try #require(receipt.answer)
            try await runtime.commit({ _, _ in try completed(Int(answer.rawValue)) }, context: context)
        }
        let setup = HarnessChatSetup(), busy = HarnessUnanswered()
        try setup.registry.install(Extension(name: "supervisor", tasks: [AnyTaskDefinition(supervisor)]))
        setup.models.setResponses([busy.step, .message(chatAssistant("answer"))])
        var opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let root = opened.root
        let ids = try await root.commit({ tx in
            let taskId = try await tx.createTask(supervisor, input: Int(root.id.rawValue), options: .init(ownership: .conversation(), background: true))
            let child = try await tx.createConversation(ownership: .task(taskId: taskId))
            try await configure(tx: tx, conversationId: child.id, change: .init(model: .set(ModelRef(provider: "faux", modelId: "faux-1"))))
            try await tx.doc(children, conversationId: root.id).set("child", JSONValue(encoding: child.id))
            return (taskId, child.id)
        }, context: .background)
        try opened.harness.resume(); await busy.reached.wait()
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let receipt = try await opened.harness.waitForTask(id: ids.0, context: .background)
        if case .completed = receipt.outcome {} else { Issue.record("Supervisor failed to complete") }
        let child = try #require(try await opened.harness.conversation(id: ids.1, context: .background))
        #expect(try await allEntries(child).filter { $0.kind == "pi.user" }.count == 1)
        try await opened.root.waitForIdle(context: .background)
        try await opened.harness.close(context: .background)
    }

    // H5 deferred harness-structured.test.ts:1131. A nonfinite usage number replaces the non-JSON JS function.
    @Test func faultedGenerationKeepsRunUntilOwnedWorkDrainsAndFinalCommitRetries() async throws {
        let abortGate = SessionTestGate(), abortReached = SessionTestGate(), clock = TestClock()
        let child = harnessOneStep("test.h6-hooked-child", run: { _, runtime, context in
            try await runtime.sleep(until: 1_000_000, context: context)
        }, abort: { _, runtime, context in
            abortReached.release(); await abortGate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        let setup = HarnessChatSetup(clock: clock), handle = Mutex<Harness?>(nil)
        try setup.registry.install(Extension(name: "hooked", hooks: [hook(GenerationHooks(
            beforeRequest: { _, api, context in
                let harness = try #require(handle.withLock { $0 })
                try await harness.commit({ tx in
                    _ = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: api.taskId), conversationId: api.conversationId))
                    let live = try await tx.doc(LiveDoc, conversationId: api.conversationId)
                    try live.child("generation")!.set("message", EntryRecord.encodeMessages([.assistant(chatAssistant("partial"))])[0])
                }, context: context)
                return nil
            }
        ))], tasks: [AnyTaskDefinition(child)]))
        let manual = HarnessManualModels(base: setup.models)
        let storage = HarnessSelectiveStorage()
        let opened = try await openChat(storage: storage, setup: setup, models: manual)
        handle.withLock { $0 = opened.harness }
        let submission = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        try await eventually { manual.seen.withLock { !$0.isEmpty } }
        var invalid = chatAssistant("invalid")
        invalid.usage.cost.total = .infinity
        manual.stream.push(.done(reason: .stop, message: invalid))
        await abortReached.wait()
        let live = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
        let generation = try #require(live.run?.taskId)
        #expect(try await opened.harness.getTask(id: generation, context: .background)?.state.status == "completing")
        #expect(try await submission.status(context: .background).status == "placed")
        storage.rejectOnce { writes in
            writes.contains { write in
                if case .task(let record, _) = write { return record.id == generation && record.state.status == "terminal" }
                return false
            }
        }
        abortGate.release()
        try await eventually { setup.reports.values.contains { $0 is StorageRejected } }
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.run?.taskId == generation)
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user"])
        try await opened.root.commit({ tx in _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: "note")) }, context: .background)
        let receipt = try await submission.wait(context: .background)
        #expect(receipt.reason == "faulted")
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        #expect(try await allEntries(opened.root).map(\.kind) == ["pi.user", "note", "pi.assistant"])
        try await opened.harness.close(context: .background)
    }

    // upstream harness-submissions.test.ts:149. The submission table read itself spans close.
    @Test func unsettledSubmissionReadSpanningCloseCannotRegisterALateWaiter() async throws {
        let storage = H6CountingStorage(), setup = HarnessChatSetup(), busy = HarnessUnanswered()
        setup.models.setResponses([busy.step])
        let opened = try await openChat(storage: storage, setup: setup)
        let input = try await opened.root.submit(.input(content: .text("hi")), context: .background)
        await busy.reached.wait()
        let release = SessionTestGate()
        storage.holdSubmissionRead(release)
        let pending = Task { try await input.wait(context: .background) }
        await storage.submissionReadStarted.wait()
        let closing = Task { try await opened.harness.close(context: .background) }
        try await eventually { opened.harness.tasks.closing }
        release.release()
        await h6ExpectClosed { try await pending.value }
        try await closing.value
    }

}
