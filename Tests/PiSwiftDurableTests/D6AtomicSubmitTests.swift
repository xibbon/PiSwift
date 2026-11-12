import Foundation
import Testing
import Synchronization
import PiSwiftChord
import PiSwiftAI
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Direct mirrors of v1.5.2 harness-submit-in-commit.test.ts:208–435.
@Suite("PiSwiftDurableTests.D6AtomicSubmit", .timeLimit(.minutes(1)))
struct D6AtomicSubmitTests {
    @Test("admits with the host's own check and writes in one commit")
    func oneStorageBatch() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: setup)
        let first = try await chat.root.submit(.input(content: .text("work")), context: .background)
        await held.reached.wait()
        let before = await storage.commits.count
        let id = try await chat.harness.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: chat.root.id)
            #expect(try live.get("run") != nil)
            let admitted = try await chat.root.submit(tx, .input(content: .text("steer"), whenBusy: .steer))
            _ = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "app.sent", data: .object(["submission": .number(Double(admitted.rawValue))])))
            return admitted
        }, context: .background)
        let commits = await storage.commits
        #expect(commits.count == before + 1)
        #expect(await storage.callBatchCounts.last == 1)
        let writes = try #require(commits.last)
        #expect(writes.contains { if case .submission(let value, _) = $0 { return value.id == id }; return false })
        #expect(writes.contains { if case .entry(let value, _) = $0 { return value.kind == "app.sent" }; return false })
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [id])
        #expect(try await first.status(context: .background).status == "placed")
        try await chat.root.abort(context: .background)
        try await chat.harness.close(context: .background)
    }

    @Test("is rolled back with the commit when the callback throws later")
    func callbackRollback() async throws {
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        let before = await storage.commits.count
        await #expect(throws: SessionError.self) {
            try await chat.harness.commit({ tx in
                _ = try await chat.root.submit(tx, .input(content: .text("hi"), requestId: "r1"))
                throw SessionError.message("host check failed")
            }, context: .background)
        }
        #expect(await storage.commits.count == before)
        #expect(try await chat.harness.commit({ tx in try await tx.submissionByRequest(chat.root.id, requestId: "r1") }, context: .background) == nil)
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("deduplicates request IDs")
    func deduplicatesRequest() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: setup)
        let first = try await chat.root.submit(.input(content: .text("work")), context: .background)
        await held.reached.wait()
        let draft: SubmissionDraft = .input(content: .text("steer"), whenBusy: .steer, requestId: "r1")
        let id = try await chat.harness.commit({ tx in try await chat.root.submit(tx, draft) }, context: .background)
        let count = await storage.commits.count
        let again = try await chat.harness.commit({ tx in try await chat.root.submit(tx, draft) }, context: .background)
        #expect(again == id)
        #expect(await storage.commits.count == count)
        try await chat.root.abort(context: .background)
        _ = try await first.wait(context: .background)
        try await chat.harness.close(context: .background)
    }

    @Test("throws ReadAfterWrite after a table write of the commit, on every path")
    func rejectsAfterFirstTableWrite() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        await #expect(throws: ReadAfterWrite.self) {
            try await chat.harness.commit({ tx in
                _ = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "app.note"))
                _ = try await chat.root.submit(tx, .input(content: .text("hi")))
            }, context: .background)
        }
        await #expect(throws: ReadAfterWrite.self) {
            try await chat.harness.commit({ tx in
                _ = try await chat.root.submit(tx, .write(entry: EntryDraft(kind: "app.note")))
                _ = try await chat.root.submit(tx, .write(entry: EntryDraft(kind: "app.other")))
            }, context: .background)
        }
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.isEmpty == true)
        try await chat.harness.close(context: .background)
    }

    @Test("throws for a transaction of another Session")
    func rejectsForeignTransaction() async throws {
        let a = try await openChat(setup: HarnessChatSetup())
        let b = try await openChat(setup: HarnessChatSetup())
        await #expect(throws: SessionError.self) {
            try await b.harness.commit({ tx in try await a.root.submit(tx, .input(content: .text("hi"))) }, context: .background)
        }
        #expect(try await a.harness.snapshot(LiveDoc, conversationId: a.root.id, context: .background)?.run == nil)
        try await a.harness.close(context: .background)
        try await b.harness.close(context: .background)
    }

    @Test("rejects input to an idle conversation without writing")
    func idleRejectWritesNothing() async throws {
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        let before = await storage.commits.count
        await #expect(throws: ConversationIdle.self) {
            try await chat.root.submit(.inputWhenIdle(content: .text("hi")), context: .background)
        }
        #expect(await storage.commits.count == before)
        #expect(try await generationLive(chat)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("returns the submission of a known request ID, also once idle")
    func knownRequestPrecedesIdleRejection() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("work"), requestId: "r1"), context: .background)
        _ = try await first.wait(context: .background)
        let draft: SubmissionDraft = .inputWhenIdle(content: .text("work"), whenBusy: .steer, requestId: "r1")
        #expect(try await chat.root.submit(draft, context: .background).id == first.id)
        #expect(try await chat.harness.commit({ tx in try await chat.root.submit(tx, draft) }, context: .background) == first.id)
        try await chat.harness.close(context: .background)
    }

    @Test("rejects before any write, so the callback may catch the rejection")
    func callerCanCatchRefusalWithoutWrite() async throws {
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: HarnessChatSetup())
        let before = await storage.commits.count
        let outcome = try await chat.harness.commit({ tx in
            do {
                _ = try await chat.root.submit(tx, .inputWhenIdle(content: .text("hi"), whenBusy: .steer))
                return "admitted"
            } catch is ConversationIdle { return "idle" }
        }, context: .background)
        #expect(outcome == "idle")
        #expect(await storage.commits.count == before)
        #expect(try await generationLive(chat)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("starts the run of an idle input once the commit is stored")
    func idleRunStartsAfterCommit() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let id = try await chat.harness.commit({ tx in
            try await chat.root.submit(tx, .input(content: .text("hi")))
        }, context: .background)
        let submission = try #require(try await chat.harness.submission(id: id, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("reads a submission by ID in a commit, with the entry its input was placed at")
    func readsSubmissionAndEntry() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let id = try await chat.harness.commit({ tx in try await chat.root.submit(tx, .input(content: .text("hi"))) }, context: .background)
        _ = try await chat.harness.submission(id: id, context: .background)?.wait(context: .background)
        let found = try await chat.harness.commit({ tx in
            let submission = try await tx.submission(id)
            let entry: EntryRecord?
            if case .input(_, _, _, .done(let input, _, _)) = submission {
                entry = try await tx.entry(input)
            } else { entry = nil }
            return (submission?.status, entry?.conversationId, entry?.kind)
        }, context: .background)
        #expect(found.0 == "done" && found.1 == chat.root.id && found.2 == "pi.user")
        #expect(try await chat.harness.commit({ tx in try await tx.submission(SubmissionID(999_999)) }, context: .background) == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("continues a failed run, and must precede the commit's table writes")
    func continuesFailedRunInsideCommit() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "Invalid request")),
                                   .message(chatAssistant("recovered"))])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("Analyze this")), context: .background)
        #expect(try await first.wait(context: .background).reason == "model_error")
        await #expect(throws: ReadAfterWrite.self) {
            try await chat.harness.commit({ tx in
                _ = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "app.note"))
                _ = try await chat.root.submit(tx, .continue())
            }, context: .background)
        }
        let id = try await chat.harness.commit({ tx in
            let continued = try await chat.root.submit(tx, .continue())
            _ = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "app.note"))
            return continued
        }, context: .background)
        #expect(try await chat.harness.submission(id: id, context: .background)?.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("rejects a busy continue and steers with whenIdle inside the commit")
    func busyContinueRejectedAndSteerQueued() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("work")), context: .background)
        await held.reached.wait()
        await #expect(throws: ConversationBusy.self) {
            try await chat.harness.commit({ tx in try await chat.root.submit(tx, .continue()) }, context: .background)
        }
        let steer = try await chat.harness.commit({ tx in
            try await chat.root.submit(tx, .inputWhenIdle(content: .text("steer"), whenBusy: .steer))
        }, context: .background)
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [steer])
        try await chat.root.abort(context: .background)
        try await chat.harness.close(context: .background)
    }

    @Test("admits inside a task's terminal commit")
    func taskTerminalCommitAdmitsInput() async throws {
        let setup = HarnessChatSetup()
        let definition = harnessOneStep("test.d6.admitting") { _, runtime, context in
            let handle = try #require(try await runtime.conversation(runtime.conversationId, context: context))
            try await runtime.commit({ tx, _ in
                let id = try await handle.submit(tx, .input(content: .text("from the task")))
                return .terminal(outcome: .completed(result: .number(Double(id.rawValue))))
            }, context: context)
        }
        try setup.registry.install(Extension(name: "admitting", tasks: [AnyTaskDefinition(definition)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let task = try await harnessStart(chat.root, definition)
        let outcome = try await chat.harness.waitForTask(id: task, context: .background)
        guard case .completed(let result, _) = outcome.outcome, let number = result.numberValue else {
            Issue.record("Admitting task did not complete")
            return
        }
        let id = try SubmissionID(Int64(number))
        let submitted = try #require(try await chat.harness.submission(id: id, context: .background))
        #expect(try await submitted.wait(context: .background).status == "done")
        let user = try #require(try await allEntries(chat.root).first { $0.kind == "pi.user" })
        #expect(user.byTaskId == task)
        try await chat.harness.close(context: .background)
    }

    @Test("leaves no submission and no run when Storage fails the commit, also after reopening")
    func storageFailureLosesWholeBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("submit.sqlite").path
        let storage = ControlledStorage(try await SqliteStorage.open(path: path))
        let setup = HarnessChatSetup()
        let chat = try await openChat(storage: storage, setup: setup)
        let before = await storage.commits.count
        await storage.failNextCommit(SessionError.message("disk full"))
        await #expect(throws: (any Error).self) {
            try await chat.harness.commit({ tx in
                _ = try await chat.root.submit(tx, .input(content: .text("hi"), requestId: "r1"))
                _ = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "app.sent"))
            }, context: .background)
        }
        // ControlledStorage records attempted batches; the failed batch did
        // not reach the wrapped SQLite store.
        #expect(await storage.commits.count == before + 1)
        try await chat.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: HarnessChatSetup())
        let found = try await reopened.harness.commit({ tx in
            let submission = try await tx.submissionByRequest(reopened.root.id, requestId: "r1")
            let tasks = try await tx.scanTasks(.init(conversationId: reopened.root.id), limit: 10).items
            let entries = try await tx.scanEntries(.init(conversationId: reopened.root.id), limit: 10).items
            return (submission, tasks, entries)
        }, context: .background)
        #expect(found.0 == nil && found.1.isEmpty && found.2.isEmpty)
        #expect(try await generationLive(reopened)?.run == nil)
        try await reopened.harness.close(context: .background)
    }

    @Test("steers a working run")
    func whenIdlePolicySteersBusyRun() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("work")), context: .background)
        await held.reached.wait()
        let steer = try await chat.root.submit(.inputWhenIdle(content: .text("also this"), whenBusy: .steer), context: .background)
        #expect(try await steer.status(context: .background).status == "queued")
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [steer.id])
        #expect(try await generationLive(chat)?.run?.inputs == [first.id])
        try await chat.root.abort(context: .background)
        try await chat.harness.close(context: .background)
    }

    @Test("queues a model-visible write while busy and places it at the next boundary")
    func modelVisibleWriteWaitsForBoundary() async throws {
        let setup = HarnessChatSetup()
        let held = HarnessGatedResponse(message: chatAssistant("answer"))
        setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("work")), context: .background)
        await held.reached.wait()
        let note = try EntryRecord.encodeMessages([.user(UserMessage(content: .text("a note the model sees"), timestamp: 1))])
        let id = try await chat.harness.commit({ tx in
            try await chat.root.submit(tx, .write(entry: EntryDraft(kind: "test.note", model: note)))
        }, context: .background)
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) == [id])
        held.release()
        #expect(try await first.wait(context: .background).status == "done")
        let write = try #require(try await chat.harness.submission(id: id, context: .background))
        #expect(try await write.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("stores no trace carrier with default no-op propagation")
    func atomicSubmissionNoopTraceCarrier() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let id = try await chat.harness.commit({ tx in
            try await chat.root.submit(tx, .input(content: .text("hi")))
        }, context: .background)
        let submission = try #require(try await chat.harness.submission(id: id, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await submission.status(context: .background).trace == nil)
        let tasks = try await chat.root.commit({ tx in
            try await tx.scanTasks(.init(conversationId: chat.root.id), limit: 10).items
        }, context: .background)
        #expect(tasks.allSatisfy { $0.trace == nil })
        try await chat.harness.close(context: .background)
    }

    @Test("rejects through a tool's conversation handle")
    func toolHandleRejectsIdleInput() async throws {
        let setup = HarnessChatSetup()
        let target = Mutex<ConversationID?>(nil)
        let seen = SessionTestLog<String>()
        try installHarnessTool(harnessTestTool("nudge", execute: { _, api, context in
            let id = try #require(target.withLock { $0 })
            let handle = try #require(try await api.conversation(id: id, context: context))
            do {
                _ = try await handle.submit(.inputWhenIdle(content: .text("nudge"), whenBusy: .steer), context: context)
                seen.append("admitted")
            } catch is ConversationIdle { seen.append("idle") }
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("nudge", [:], "c1")])),
                                   .message(chatAssistant("ok"))])
        let chat = try await openChat(setup: setup)
        let other = try await chat.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        target.withLock { $0 = other.id }
        #expect(try await chat.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        #expect(seen.values == ["idle"])
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: other.id, context: .background)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("admits atomically from a tool's commit through its conversation handle")
    func toolCommitAdmitsInputWithTaskOwnership() async throws {
        let setup = HarnessChatSetup()
        let target = Mutex<ConversationID?>(nil)
        let seen = SessionTestLog<(TaskID, SubmissionID)>()
        try installHarnessTool(harnessTestTool("delegate", execute: { _, api, context in
            let id = try #require(target.withLock { $0 })
            let handle = try #require(try await api.conversation(id: id, context: context))
            let submission = try await api.commit({ tx in
                let submitted = try await handle.submit(tx, .input(content: .text("from the tool")))
                _ = try await tx.appendEntry(id, value: EntryDraft(kind: "app.delegated", data: .object(["submission": .number(Double(submitted.rawValue))])))
                return submitted
            }, context: context)
            seen.append((api.taskId, submission))
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("delegate", [:], "c1")])),
                                   .message(chatAssistant("ok")), .message(chatAssistant("ok"))])
        let chat = try await openChat(setup: setup)
        let other = try await chat.harness.createConversation(options: .init(
            ownership: .ownerless(), agent: .init(model: .set(ModelRef(provider: "faux", modelId: "faux-1")))),
            context: .background)
        target.withLock { $0 = other.id }
        #expect(try await chat.root.submit(.input(content: .text("delegate")), context: .background).wait(context: .background).status == "done")
        let pair = try #require(seen.values.first)
        let submission = try #require(try await chat.harness.submission(id: pair.1, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        let entries = try await allEntries(other)
        #expect(entries.contains { $0.kind == "app.delegated" })
        #expect(entries.first { $0.kind == "pi.user" }?.byTaskId == pair.0)
        try await chat.harness.close(context: .background)
    }

    @Test("rejects input to an idle conversation that keeps queued items after a failed run")
    func idleRejectPreservesQueuedInput() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let failing = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "failed"))
        setup.models.setResponses([failing.step])
        let chat = try await openChat(setup: setup)
        let first = try await chat.root.submit(.input(content: .text("first")), context: .background)
        await failing.reached.wait()
        let queued = try await chat.root.submit(.input(content: .text("queued")), context: .background)
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        try await chat.harness.waitForIdle(context: .background)
        await #expect(throws: ConversationIdle.self) {
            try await chat.root.submit(.inputWhenIdle(content: .text("steer"), whenBusy: .steer), context: .background)
        }
        #expect(try await queued.status(context: .background).status == "queued")
        #expect(try await generationLive(chat)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    @Test("rejects through a handle once its invocation is aborted, and once it ended")
    func abortedAndEndedToolHandleRejectsAdmission() async throws {
        let setup = HarnessChatSetup()
        let target = Mutex<ConversationID?>(nil)
        let retained = Mutex<ConversationHandle?>(nil)
        let started = HarnessChatSignal()
        let abortSeen = HarnessChatSignal()
        let release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("hold", execute: { _, api, context in
            let id = try #require(target.withLock { $0 })
            let handle = try #require(try await api.conversation(id: id, context: context))
            retained.withLock { $0 = handle }
            let signal = try #require(context.abortSignal)
            let token = signal.addAbortListener { _ in abortSeen.signal() }
            defer { signal.removeAbortListener(token) }
            started.signal()
            await release.wait()
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("hold", [:], "c1")])),
                                   .message(chatAssistant("ok"))])
        let chat = try await openChat(setup: setup)
        let other = try await chat.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        target.withLock { $0 = other.id }
        let run = try await chat.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let tool = try #require(try await generationLive(chat)?.tools?.first?.taskId)
        let aborting = Task { try await chat.harness.abortTask(id: tool, context: .background) }
        await abortSeen.wait()
        let handle = try #require(retained.withLock { $0 })
        await #expect(throws: (any Error).self) {
            try await handle.submit(.input(content: .text("late")), context: .background)
        }
        await #expect(throws: (any Error).self) {
            try await chat.harness.commit({ tx in try await handle.submit(tx, .input(content: .text("late"))) }, context: .background)
        }
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: other.id, context: .background)?.run == nil)
        release.signal()
        _ = try await aborting.value
        _ = try await run.wait(context: .background)
        await #expect(throws: (any Error).self) {
            try await chat.harness.commit({ tx in try await handle.submit(tx, .input(content: .text("late"))) }, context: .background)
        }
        try await chat.harness.close(context: .background)
    }
}
