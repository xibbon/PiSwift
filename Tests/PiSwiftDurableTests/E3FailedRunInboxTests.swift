import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct E3FailedRunInboxTests {
    // Upstream v1.4.0 harness-failed-run-inbox.test.ts:36,47,77.
    @Test(arguments: [AfterFailedRun.keep, .continue, .withdraw])
    func queuedInputPolicy(_ policy: AfterFailedRun) async throws {
        let setup = HarnessChatSetup()
        let failing = HarnessGatedResponse(message: compactionFailure("Invalid request"))
        setup.models.setResponses([failing.step, .message(chatAssistant("second answer")), .message(chatAssistant("third answer"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "Analyze this report")
        await failing.reached.wait()
        let second = try await generationSubmit(chat, "Email me the summary")
        // Read the policy at failure time, after the request started.
        if policy != .keep { setup.updateSettings { $0.afterFailedRun = policy } }
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        try await chat.harness.waitForIdle(context: .background)
        if policy == .keep {
            #expect(try await second.status(context: .background).status == "queued")
            let third = try await generationSubmit(chat, "Anything else?")
            #expect(try await second.wait(context: .background).status == "done")
            #expect(try await third.wait(context: .background).status == "done")
        } else if policy == .continue {
            let settled = try await second.wait(context: .background)
            #expect(settled.status == "done")
            #expect(try await allEntries(chat.root).first { $0.id == settled.answer }?.messages()?.first.map { textOf($0) } == "second answer")
        } else {
            #expect(try await second.wait(context: .background).reason == "run_failed")
        }
        #expect(chat.harness.failure == nil)
        try await chat.harness.close(context: .background)
    }

    // Upstream v1.4.0 harness-failed-run-inbox.test.ts:56; also checks keep and resets.
    @Test(arguments: AfterFailedRun.allCases, [false, true])
    func queuedWritesAndReset(_ policy: AfterFailedRun, reset: Bool) async throws {
        let setup = HarnessChatSetup(settings: .init(afterFailedRun: policy))
        let failing = HarnessGatedResponse(message: compactionFailure("Invalid request"))
        setup.models.setResponses([failing.step])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat)
        await failing.reached.wait()
        let write = try await chat.root.submit(.write(entry: reset ? EntryDraft(kind: "pi.reset", head: .self) : queuedInputNote("note")), context: .background)
        #expect(try await write.status(context: .background).status == "queued")
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await write.status(context: .background).status == (policy == .continue ? "done" : "queued"))
        #expect(setup.models.state().callCount == 1)
        #expect(try await generationLive(chat)?.run == nil)
        if policy == .continue {
            #expect(try await allEntries(chat.root).last?.kind == (reset ? "pi.reset" : "note"))
            if reset { #expect(try await chat.root.context(context: .background).entries.map(\.kind) == ["pi.reset"]) }
        }
        try await chat.harness.close(context: .background)
    }

    @Test(arguments: [QueueMode.oneAtATime, .all])
    func continuationOrdersWritesBeforeInputsAndUsesBothQueueModes(_ mode: QueueMode) async throws {
        let setup = HarnessChatSetup(settings: .init(steeringMode: mode, followUpMode: mode, afterFailedRun: .continue))
        let failing = HarnessGatedResponse(message: compactionFailure("Invalid request"))
        setup.models.setResponses([failing.step, .message(chatAssistant("second")), .message(chatAssistant("third"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "first")
        await failing.reached.wait()
        let f1 = try await generationSubmit(chat, "f1")
        let write = try await chat.root.submit(.write(entry: queuedInputNote("note")), context: .background)
        let s1 = try await chat.root.submit(.input(content: .text("s1"), whenBusy: .steer), context: .background)
        let f2 = try await generationSubmit(chat, "f2")
        let s2 = try await chat.root.submit(.input(content: .text("s2"), whenBusy: .steer), context: .background)
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        let follow1 = try await f1.wait(context: .background), steer1 = try await s1.wait(context: .background)
        let follow2 = try await f2.wait(context: .background), steer2 = try await s2.wait(context: .background)
        #expect(follow1.answer == steer1.answer && follow2.answer == steer2.answer)
        #expect((follow1.answer == follow2.answer) == (mode == .all))
        #expect(try await write.wait(context: .background).status == "done")
        let entries = try await allEntries(chat.root)
        #expect(Array(entries.prefix(5)).map(\.kind) == ["pi.user", "pi.assistant", "note", "pi.user", "pi.user"])
        #expect(try entries.filter { $0.kind == "pi.user" }.map { textOf(try $0.messages()?.first) } == ["first", "f1", "s1", "f2", "s2"])
        try await chat.harness.close(context: .background)
    }

    @Test func continuationAppliesResetBeforeUsersAndRejectsStaleWrite() async throws {
        let setup = HarnessChatSetup(settings: .init(afterFailedRun: .continue))
        let failing = HarnessGatedResponse(message: compactionFailure("Invalid request"))
        setup.models.setResponses([failing.step, .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "first")
        await failing.reached.wait()
        let old = try #require(await allEntries(chat.root).first).id
        let follow = try await generationSubmit(chat, "follow")
        try await chat.root.reset(handoff: "new context", context: .background)
        let stale = try await chat.root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(old))), context: .background)
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        #expect(try await follow.wait(context: .background).status == "done")
        #expect(try await stale.wait(context: .background).reason == "stale")
        // A new context head requires a fresh system entry, even with no prompt sections.
        #expect(try await chat.root.context(context: .background).entries.map(\.kind) == ["pi.reset", "pi.user", "pi.system", "pi.assistant"])
        #expect(try await allEntries(chat.root).map(\.kind) == ["pi.user", "pi.assistant", "pi.reset", "pi.user", "pi.system", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }

    @Test func retryDoesNotWithdrawQueuedInputs() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(baseDelayMs: 0), afterFailedRun: .withdraw))
        let retry = HarnessGatedResponse(message: chatAssistant("recovered"))
        setup.models.setResponses([.message(compactionFailure("503 Service Unavailable")), retry.step, .message(chatAssistant("follow answer"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat)
        await retry.reached.wait()
        let follow = try await generationSubmit(chat, "follow")
        #expect(try await follow.status(context: .background).status == "queued")
        retry.release()
        #expect(try await first.wait(context: .background).status == "done")
        #expect(try await follow.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test(arguments: AfterFailedRun.allCases, [false, true])
    func noModelUsesTheSamePolicy(_ policy: AfterFailedRun, unset: Bool) async throws {
        let setup = HarnessChatSetup(settings: .init(afterFailedRun: policy))
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(model: unset ? .clear : .set(.init(provider: "faux", modelId: "missing"))), context: .background)
        // Admit on the Session line while scheduling is paused. Each admission is a separate commit.
        var ids: [SubmissionID] = []
        for draft in [SubmissionDraft.input(content: .text("first")), .input(content: .text("follow")),
                      .write(entry: queuedInputNote("note")), .input(content: .text("steer"), whenBusy: .steer)] {
            ids.append(try await chat.root.commit({ tx in
                try await admitSubmission(tx: tx, conversationId: chat.root.id, draft: draft, now: 1, queueModes: resolveSettings(setup.settings))
            }, context: .background))
        }
        try await chat.harness.waitForIdle(context: .background)
        let records = try await ids.asyncRecords(chat.harness)
        #expect(records[0].reason == "no_model")
        #expect(records[1].status == (policy == .keep ? "queued" : "unanswered"))
        #expect(records[3].status == records[1].status)
        if policy != .keep {
            #expect(records[1].reason == (policy == .continue ? "no_model" : "run_failed"))
            #expect(records[3].reason == records[1].reason)
        }
        #expect(records[2].status == (policy == .continue ? "done" : "queued"))
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.map(\.id) ==
            (policy == .continue ? [] : policy == .withdraw ? [ids[2]] : Array(ids.dropFirst())))
        #expect(setup.models.state().callCount == 0)
        #expect(chat.harness.failure == nil)
        try await chat.harness.close(context: .background)
    }

    @Test(arguments: AfterFailedRun.allCases)
    func blockingCompactionFailureUsesTheSamePolicy(_ policy: AfterFailedRun) async throws {
        let chat = try await compactionOpen(contextWindow: 1000)
        try await compactionHistory(chat)
        compactionSetPolicy(chat, compactionBlockingPolicy)
        chat.setup.updateSettings { $0.afterFailedRun = policy }
        let failing = HarnessGatedResponse(message: compactionFailure("Invalid request"))
        chat.script.appendSummary([failing.step])
        let first = try await compactionNewInput(chat)
        await failing.reached.wait()
        let second = try await generationSubmit(chat.opened, "queued")
        // Allow a continued run to proceed without another threshold failure.
        compactionSetPolicy(chat, compactionManualPolicy)
        chat.script.appendAgent([.message(chatAssistant("second answer"))])
        failing.release()
        let failed = try await first.wait(context: .background)
        #expect(failed.reason == "model_error")
        #expect(try JSONValue(encoding: failed.record)["detail"] == "Compaction failed: Summarization failed: Invalid request")
        try await chat.harness.waitForIdle(context: .background)
        let queued = try await second.status(context: .background)
        #expect(queued.status == (policy == .keep ? "queued" : policy == .continue ? "done" : "unanswered"))
        if policy == .withdraw { #expect(queued.reason == "run_failed") }
        #expect(chat.harness.failure == nil)
        try await chat.harness.close(context: .background)
    }
}

private extension Array where Element == SubmissionID {
    func asyncRecords(_ harness: Harness) async throws -> [SubmissionRecord] {
        var records: [SubmissionRecord] = []
        for id in self {
            let handle = try #require(await harness.submission(id: id, context: .background))
            records.append(try await handle.status(context: .background))
        }
        return records
    }
}
