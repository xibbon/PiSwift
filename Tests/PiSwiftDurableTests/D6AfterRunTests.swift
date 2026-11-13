import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D6AfterRun", .serialized)
struct D6AfterRunTests {
    // v1.5.2 harness-after-run.test.ts:182
    @Test(.timeLimit(.minutes(1)))
    func waitsForChildrenWithInputsSettledAtAnswer() async throws {
        let gate = SessionTestGate(), seen = SessionTestLog<GenerationRunSummary>()
        let child = harnessOneStep("test.after-run-child") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, _, _ in
                seen.append(run)
                return AfterRunResult(tasks: [try runEndTask(child, input: 7)])
            }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let submission = try await generationSubmit(chat)
        try await harnessEventually { try await generationLive(chat)?.run?.afterRun?.tasks?.count == 1 }
        let live = try #require(await generationLive(chat))
        let childID = try #require(live.run?.afterRun?.tasks?.first)
        #expect(live.run?.inputs == [])
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(seen.count == 1)
        #expect(seen.values.first?.reason == .answer)
        #expect(try await chat.harness.getTask(id: childID, context: .background)?.owner == live.run?.taskId)
        gate.release()
        #expect(try await chat.harness.waitForTask(id: childID, context: .background).outcome == .completed(result: .number(1)))
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await generationLive(chat)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:252,517
    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "nil", "failed"])
    func endsNormallyWhenNoChildrenOrChildFails(mode: String) async throws {
        let child = harnessOneStep("test.after-run-failed") { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .failed(error: TaskOutcomeError(message: "child failed"))) }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
                mode == "nil" ? nil : AfterRunResult(tasks: mode == "empty" ? [] : [try runEndTask(child, input: 0)])
            }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await generationLive(chat)?.run == nil)
        #expect(try await generationLive(chat)?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:539,618
    @Test(.timeLimit(.minutes(1)))
    func reportsRejectedRequestsAndUsesInstalledInitialOnce() async throws {
        let starts = Mutex(0), ran = Mutex(0)
        let installed = HarnessTestTask(name: "test.after-run-installed", version: 1,
            initial: { _ in starts.withLock { $0 += 1 }; return HarnessTaskCheckpoint() },
            phase: { _, runtime, context in
                ran.withLock { $0 += 1 }
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
            })
        let stale = harnessOneStep("test.after-run-installed") { _, _, _ in
            Issue.record("The stale definition ran")
        }
        let unknown = harnessOneStep("test.after-run-unknown") { _, _, _ in
            Issue.record("An uninstalled definition ran")
        }
        let throwing = HarnessTestTask(name: "test.after-run-throwing", version: 1,
            initial: { _ in throw TaskDefinitionError("initial failed") },
            phase: { _, _, _ in Issue.record("A throwing definition ran") }, abort: { _, _, _ in })
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [
            hook(GenerationHooks(afterRun: { _, _, _ in
                AfterRunResult(tasks: [try runEndTask(unknown, input: 0),
                                       try runEndTask(generationTask, input: GenerationInput()),
                                       try runEndTask(throwing, input: 0),
                                       try runEndTask(stale, input: 9)])
            }))
        ], tasks: [AnyTaskDefinition(installed), AnyTaskDefinition(throwing)]))
        try setup.registry.install(Extension(name: "broken", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            throw TaskDefinitionError("hook failed")
        }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(starts.withLock { $0 } == 1)
        #expect(ran.withLock { $0 } == 1)
        #expect(setup.reports.infos.filter { $0.kind == "extension_error" }.count == 2)
        let rejected = try #require(setup.reports.values.first as? RunEndTaskRequestErrors)
        #expect(rejected.errors == ["Task test.after-run-unknown is not installed",
                                    "An afterRun hook cannot start the built-in task pi.generation",
                                    "initial failed"])
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:657
    @Test(.timeLimit(.minutes(1)))
    func readsAnsweredRunHistoryInsideHook() async throws {
        let observed = SessionTestLog<[String]>()
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, api, context in
            let page = try await api.entries(.init(minEntryId: run.first, maxEntryId: run.last), limit: 100, context: context)
            observed.append(page.items.map(\.kind))
            return AfterRunResult(tasks: [])
        }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(observed.count == 1)
        #expect(Set(observed.values.first ?? []) == Set(["pi.user", "pi.assistant"]))
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:279
    @Test(.timeLimit(.minutes(1)))
    func queuesNextInputUntilChildSettles() async throws {
        let gate = SessionTestGate()
        let child = harnessOneStep("test.after-run-queue") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat, "one").wait(context: .background).status == "done")
        try await harnessEventually { try await generationLive(chat)?.run?.afterRun?.tasks?.count == 1 }
        let second = try await generationSubmit(chat, "two")
        #expect(try await second.status(context: .background).status == "queued")
        #expect(setup.models.state().callCount == 1)
        gate.release()
        #expect(try await second.wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:430; tagged phase-only SQLite checkpoint.
    @Test(.timeLimit(.minutes(1)))
    func finishReasksAfterRestartWhileDrainDoesNot() async throws {
        let source = try #require(Bundle.module.url(forResource: "phase-only-upstream-v152", withExtension: "sqlite", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-after-run-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("phase.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let asked = SessionTestLog<GenerationRunSummary>()
        let registry = Registry()
        try registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, _, _ in
            asked.append(run)
            return AfterRunResult(tasks: [])
        }))]))
        let storage = try await SqliteStorage.open(path: path.path)
        let harness = try await Harness.open(storage: storage,
            options: .init(models: FakeDurableModels(), registry: registry, now: { 0 }), context: .background)
        try harness.resume()
        _ = try await harness.waitForTask(id: TaskID(2), context: .background)
        _ = try await harness.waitForTask(id: TaskID(3), context: .background)
        #expect(asked.count == 1)
        #expect(asked.values.first?.reason == .answer)
        try await harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:430, orderly close in drain.
    @Test(.timeLimit(.minutes(1)))
    func drainRestartsChildWithoutReaskingHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-drain-reopen-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let started = HarnessChatSignal(), runs = Mutex(0), asked = Mutex(0)
        let child = harnessOneStep("test.after-run-drain-restart") { _, runtime, context in
            let count = runs.withLock { value in value += 1; return value }
            if count == 1 { started.signal(); try await harnessToolAwaitAbort(context) }
            else { try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context) }
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            asked.withLock { $0 += 1 }
            return AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationSubmit(first).wait(context: .background).status == "done")
        await started.wait()
        try await first.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await reopened.harness.waitForIdle(context: .background)
        #expect(asked.withLock { $0 } == 1)
        #expect(runs.withLock { $0 } == 2)
        #expect(try await generationLive(reopened)?.run == nil)
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:758
    @Test(.timeLimit(.minutes(1)))
    func answeredPhasesCompleteAtRestartLimitWithoutAskingAgain() async throws {
        let source = try #require(Bundle.module.url(forResource: "phase-only-upstream-v152", withExtension: "sqlite", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-after-run-cutoff-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("phase.sqlite")
        try FileManager.default.copyItem(at: source, to: path)
        let storage = try await SqliteStorage.open(path: path.path)
        for id in [try TaskID(2), try TaskID(3)] {
            let saved = try #require(await storage.task(id, context: .background))
            let marked = TaskRecord(id: saved.id, conversationId: saved.conversationId, kind: saved.kind,
                version: saved.version, input: saved.input, state: saved.state, owner: saved.owner,
                background: saved.background, abortRequested: saved.abortRequested, abortReason: saved.abortReason,
                abandonOnRestart: saved.abandonOnRestart, startedAt: saved.startedAt, endedAt: saved.endedAt,
                memos: saved.memos, restarts: 1, trace: saved.trace, links: saved.links,
                extensionFields: saved.extensionFields)
            _ = try await storage.commitOne([.task(value: marked)], context: .background)
        }
        let asked = Mutex(0), reports = HarnessReports(), registry = Registry()
        try registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            asked.withLock { $0 += 1 }
            return AfterRunResult(tasks: [])
        }))]))
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry,
            settings: HarnessSettingsProvider { HarnessSettings(restartLimit: 1) }, now: { 0 },
            onReport: { (report: Report) in reports.appendReport(report) }), context: .background)
        try harness.resume()
        for id in [try TaskID(2), try TaskID(3)] {
            #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        }
        #expect(asked.withLock { $0 } == 0)
        #expect(reports.infos.filter { $0.kind == "task_interrupted" }.count == 2)
        try await harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:373
    @Test(.timeLimit(.minutes(1)))
    func asksOnlyAfterOnYieldContinuationEnds() async throws {
        let yields = Mutex(0), runs = SessionTestLog<GenerationRunSummary>()
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(
            onYield: { _, _, _ in
                let count = yields.withLock { value in value += 1; return value }
                return count == 1 ? GenerationYield(continue: .text("continue")) : nil
            }, afterRun: { run, _, _ in
                runs.append(run)
                return AfterRunResult(tasks: [])
            }))]))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(yields.withLock { $0 } == 2)
        #expect(runs.count == 1)
        let answers = try await allEntries(chat.root).filter { $0.kind == "pi.assistant" }
        #expect(answers.count == 2)
        #expect(runs.values.first?.answer == answers.last?.id)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:222,1046
    @Test(.timeLimit(.minutes(1)), arguments: ["finish", "handoff", "limit"])
    func terminateRoundSummarizesNewestResultOrHandoff(mode: String) async throws {
        let setup = HarnessChatSetup(), summaries = SessionTestLog<GenerationRunSummary>()
        let handoff = mode == "handoff" ? "fresh start" : nil
        try installHarnessTool(harnessTestTool("finish", execute: { _, _, _ in
            ToolExecutionResult(output: [], control: .init(terminate: true, handoff: handoff))
        }), setup: setup)
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, _, _ in
            summaries.append(run)
            return AfterRunResult(tasks: [])
        }))]))
        setup.models.setResponses([.message(try toolCalls([("finish", [:], "c1")]))])
        let chat = try await openChat(setup: setup)
        if mode == "limit" { try await chat.root.configure(change: .init(maxTurns: .set(1)), context: .background) }
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        let entries = try await allEntries(chat.root)
        let summary = try #require(summaries.values.first)
        #expect(summaries.count == 1)
        #expect(summary.reason == .terminate)
        #expect(summary.first == entries.first { $0.kind == "pi.user" }?.id)
        #expect(summary.answer == entries.last { $0.kind == "pi.assistant" }?.id)
        #expect(summary.last == entries.last { $0.kind == (mode == "handoff" ? "pi.reset" : "pi.tool-result") }?.id)
        #expect(try await generationLive(chat)?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:354
    @Test(.timeLimit(.minutes(1)))
    func placesQueuedResetOnlyAfterChild() async throws {
        let gate = SessionTestGate()
        let child = harnessOneStep("test.after-run-reset") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: "test.after-run-result"))
                return .terminal(outcome: .completed(result: .number(1)))
            }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await harnessEventually { try await generationLive(chat)?.run?.afterRun?.tasks?.count == 1 }
        try await chat.root.reset(context: .background)
        #expect(try await allEntries(chat.root).allSatisfy { $0.kind != "pi.reset" })
        gate.release()
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await allEntries(chat.root).suffix(2).map(\.kind) == ["test.after-run-result", "pi.reset"])
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:479,517
    @Test(.timeLimit(.minutes(1)), arguments: ["run", "child"])
    func abortDuringDrainKeepsAnsweredSubmission(mode: String) async throws {
        let started = HarnessChatSignal(), aborted = Mutex(0)
        let child = harnessOneStep("test.after-run-abort", run: { _, _, context in
            started.signal()
            try await harnessToolAwaitAbort(context)
        }, abort: { _, runtime, context in
            aborted.withLock { $0 += 1 }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "stopped")) }, context: context)
        })
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let submission = try await generationSubmit(chat)
        #expect(try await submission.wait(context: .background).status == "done")
        await started.wait()
        let run = try #require(await generationLive(chat)?.run)
        let childID = try #require(run.afterRun?.tasks?.first)
        if mode == "run" { try await chat.root.abort(context: .background) }
        else { _ = try await chat.harness.abortTask(id: childID, context: .background) }
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await generationLive(chat)?.run == nil)
        #expect(try await generationLive(chat)?.runFailure == nil)
        #expect(try await submission.status(context: .background).status == "done")
        #expect(aborted.withLock { $0 } == 1)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:479, finish branch.
    @Test(.timeLimit(.minutes(1)))
    func abortDuringFinishKeepsAnsweredSubmission() async throws {
        let started = HarnessChatSignal()
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, context in
            started.signal()
            try await harnessToolAwaitAbort(context)
            return nil
        }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let submission = try await generationSubmit(chat)
        #expect(try await submission.wait(context: .background).status == "done")
        await started.wait()
        try await chat.root.abort(context: .background)
        try await chat.harness.waitForIdle(context: .background)
        #expect(try await generationLive(chat)?.run == nil)
        #expect(try await generationLive(chat)?.runFailure == nil)
        #expect(try await submission.status(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:924
    @Test(.timeLimit(.minutes(1)))
    func missingFirstUsesAnswerAsHistoryStart() async throws {
        let rootRef = Mutex<Conversation?>(nil), summaries = SessionTestLog<GenerationRunSummary>()
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(
            onYield: { _, _, _ in
                let root = try #require(rootRef.withLock { $0 })
                try await root.commit({ tx in
                    let live = try await tx.doc(LiveDoc, conversationId: root.id)
                    try live.child("run")?.remove("first")
                }, context: .background)
                return nil
            }, afterRun: { run, _, _ in
                summaries.append(run)
                return AfterRunResult(tasks: [])
            }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        rootRef.withLock { $0 = chat.root }
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        let summary = try #require(summaries.values.first)
        #expect(summary.first == summary.answer && summary.last == summary.answer)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:904
    @Test(.timeLimit(.minutes(1)))
    func forkOfBusyRunStartsIdle() async throws {
        let gate = SessionTestGate()
        let child = harnessOneStep("test.after-run-fork") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer")), .message(chatAssistant("later"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await harnessEventually { try await generationLive(chat)?.run?.afterRun?.tasks?.count == 1 }
        _ = try await generationSubmit(chat, "later")
        let answer = try #require(await allEntries(chat.root).last { $0.kind == "pi.assistant" })
        let fork = try await chat.root.fork(at: answer.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: fork.id, context: .background)?.run == nil)
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: fork.id, context: .background)?.items.isEmpty == true)
        gate.release()
        try await chat.harness.waitForIdle(context: .background)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:1189,1201
    @Test(.timeLimit(.minutes(1)))
    func endRunHonorsOwnershipAndKeepsFailedFirst() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let owner = try TaskID(91), other = try TaskID(92), first = try EntryID(93)
        try await chat.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: chat.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: owner, inputs: [],
                afterRun: LiveAfterRun(tasks: [try TaskID(94)]))))
            try endRun(tx: tx, live: live, taskId: other, settlement: .unanswered(reason: "faulted"), failure: .faulted)
            #expect(try live.get("run") != nil)
            try endRun(tx: tx, live: live, taskId: owner, settlement: .unanswered(reason: "aborted"), failure: .aborted)
            #expect(try live.get("run") == nil && live.get("runFailure") == nil)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: owner, inputs: [], first: first)))
            try endRun(tx: tx, live: live, taskId: owner,
                       settlement: .unanswered(reason: "model_error"), failure: .modelError)
        }, context: .background)
        let failure = try #require(await generationLive(chat)?.runFailure)
        #expect(failure.reason == .modelError && failure.first == first)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:859
    @Test(.timeLimit(.minutes(1)))
    func continueAfterFailedRunUsesOriginalFirstEntry() async throws {
        let summaries = SessionTestLog<GenerationRunSummary>()
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, _, _ in
            summaries.append(run)
            return AfterRunResult(tasks: [])
        }))]))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "failed")),
                                   .message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).reason == "model_error")
        #expect(summaries.count == 0)
        let user = try #require(await allEntries(chat.root).first { $0.kind == "pi.user" })
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(summaries.values.first?.first == user.id)
        #expect(summaries.count == 1)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:1063
    @Test(.timeLimit(.minutes(1)))
    func idleContinueHistoryStartsAtFirstToolRound() async throws {
        let summaries = SessionTestLog<GenerationRunSummary>(), kinds = SessionTestLog<[String]>()
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, api, context in
            summaries.append(run)
            let page = try await api.entries(.init(minEntryId: run.first, maxEntryId: run.last, order: .ascending),
                                             limit: 100, context: context)
            kinds.append(page.items.map(\.kind).filter { $0 != "pi.system" })
            return AfterRunResult(tasks: [])
        }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])),
                                   .message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let prompt = UserMessage(content: .text("go"), timestamp: 1)
        _ = try await chat.root.submit(.write(entry: EntryDraft(kind: "app.prompt",
            model: EntryRecord.encodeMessages([.user(prompt)]))), context: .background)
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(summaries.count == 1)
        #expect(kinds.values == [["pi.assistant", "pi.tool-result", "pi.assistant"]])
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:819
    @Test(.timeLimit(.minutes(1)))
    func childAdmitsFollowUpBeforeRunEnds() async throws {
        let summaries = SessionTestLog<GenerationRunSummary>()
        let child = harnessOneStep("test.after-run-follow-up") { _, runtime, context in
            let handle = try #require(await runtime.conversation(runtime.conversationId, context: context))
            try await runtime.commit({ tx, _ in
                _ = try await handle.submit(tx, .input(content: .text("fix the tests"), whenBusy: .followUp, requestId: "fix-1"))
                return .terminal(outcome: .completed(result: .number(1)))
            }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { run, _, _ in
            summaries.append(run)
            return summaries.count == 1 ? AfterRunResult(tasks: [try runEndTask(child, input: 0)]) : nil
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("fixed"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        let entries = try await allEntries(chat.root).filter { $0.kind != "pi.system" }
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant", "pi.user", "pi.assistant"])
        #expect(summaries.count == 2)
        #expect(summaries.values.last?.first == entries[2].id)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:883
    @Test(.timeLimit(.minutes(1)))
    func deselectedHookIsNotAskedAfterFinishRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-deselect-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let started = HarnessChatSignal(), asked = Mutex(0), setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, context in
            asked.withLock { $0 += 1 }
            started.signal()
            try await harnessToolAwaitAbort(context)
            return nil
        }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationSubmit(first).wait(context: .background).status == "done")
        await started.wait()
        try await first.harness.close(context: .background)
        setup.registry.uninstall(name: "after-run")
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await reopened.harness.waitForIdle(context: .background)
        #expect(asked.withLock { $0 } == 1)
        #expect(try await generationLive(reopened)?.run == nil)
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:956
    @Test(.timeLimit(.minutes(1)))
    func childCutOffAtRestartLimitStillEndsAnsweredRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-child-cutoff-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let started = HarnessChatSignal(), runs = Mutex(0)
        let child = harnessOneStep("test.after-run-cutoff") { _, _, context in
            runs.withLock { $0 += 1 }
            started.signal()
            try await harnessToolAwaitAbort(context)
        }
        let setup = HarnessChatSetup(settings: .init(restartLimit: 1))
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationSubmit(first).wait(context: .background).status == "done")
        await started.wait()
        let runID = try #require(await generationLive(first)?.run?.taskId)
        let childID = try #require(await generationLive(first)?.run?.afterRun?.tasks?.first)
        try await first.harness.close(context: .background)
        // An orderly close retains a pending task. A process cut-off stores the
        // charged restart count before the next reservation.
        let recoveryStorage = try await SqliteStorage.open(path: path)
        let saved = try #require(await recoveryStorage.task(childID, context: .background))
        let cutOff = TaskRecord(id: saved.id, conversationId: saved.conversationId, kind: saved.kind,
            version: saved.version, input: saved.input, state: saved.state, owner: saved.owner,
            background: saved.background, abortRequested: saved.abortRequested, abortReason: saved.abortReason,
            abandonOnRestart: saved.abandonOnRestart, startedAt: saved.startedAt, endedAt: saved.endedAt,
            memos: saved.memos, restarts: 1, trace: saved.trace, links: saved.links,
            extensionFields: saved.extensionFields)
        _ = try await recoveryStorage.commitOne([.task(value: cutOff)], context: .background)
        try await recoveryStorage.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try await reopened.harness.waitForIdle(context: .background)
        #expect(try await reopened.harness.waitForTask(id: runID, context: .background).outcome.status == "completed")
        #expect(try await generationLive(reopened)?.runFailure == nil)
        #expect(runs.withLock { $0 } == 1)
        #expect(setup.reports.infos.contains { $0.kind == "task_faulted" })
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:1020
    @Test(.timeLimit(.minutes(1)))
    func loweringLimitDuringFinishDoesNotInterruptNormalCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-limit-lowered-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let firstStarted = HarnessChatSignal(), secondStarted = HarnessChatSignal(), gate = SessionTestGate()
        let asked = Mutex(0), setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, context in
            let count = asked.withLock { value in value += 1; return value }
            if count == 1 { firstStarted.signal(); try await harnessToolAwaitAbort(context) }
            else { secondStarted.signal(); await gate.wait() }
            return AfterRunResult(tasks: [])
        }))]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationSubmit(first).wait(context: .background).status == "done")
        await firstStarted.wait()
        try await first.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try reopened.harness.resume()
        await secondStarted.wait()
        setup.updateSettings { $0.restartLimit = 1 }
        gate.release()
        try await reopened.harness.waitForIdle(context: .background)
        #expect(asked.withLock { $0 } == 2)
        #expect(setup.reports.infos.allSatisfy { $0.kind != "task_interrupted" })
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:786
    @Test(.timeLimit(.minutes(1)))
    func missingChildDefinitionKeepsRunBusyUntilAbort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-child-missing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let started = HarnessChatSignal()
        let child = harnessOneStep("test.after-run-missing") { _, _, context in
            started.signal()
            try await harnessToolAwaitAbort(context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            AfterRunResult(tasks: [try runEndTask(child, input: 0)])
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await generationSubmit(first).wait(context: .background).status == "done")
        await started.wait()
        let childID = try #require(await generationLive(first)?.run?.afterRun?.tasks?.first)
        try await first.harness.close(context: .background)
        setup.registry.uninstall(name: "after-run")
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let live = try #require(await generationLive(reopened))
        #expect(live.run?.afterRun?.tasks == [childID])
        #expect(try await reopened.harness.inspect(context: .background).tasks.contains { $0.record.id == childID })
        try await reopened.root.abort(context: .background)
        try await reopened.harness.waitForIdle(context: .background)
        #expect(try await reopened.harness.waitForTask(id: childID, context: .background).outcome.status == "orphaned")
        #expect(try await generationLive(reopened)?.runFailure == nil)
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:695
    @Test(.timeLimit(.minutes(1)))
    func readsFullHistoryAcrossCompaction() async throws {
        let gate = SessionTestGate(), started = HarnessChatSignal(), kinds = SessionTestLog<[String]>()
        let setup = HarnessChatSetup(settings: .init(compaction: .init(enabled: false, keepRecentTokens: 1)))
        try installHarnessTool(harnessTestTool("edit", execute: { _, _, _ in
            started.signal(); await gate.wait()
            return ToolExecutionResult(output: [.text(.init(text: "edited"))])
        }), setup: setup)
        try setup.registry.install(Extension(name: "after-run", hooks: [
            hook(CompactionHooks(beforeCompact: { _, _, _ in .summary("earlier work") })),
            hook(GenerationHooks(afterRun: { run, api, context in
                let page = try await api.entries(.init(minEntryId: run.first, maxEntryId: run.last, order: .ascending),
                                                 limit: 100, context: context)
                kinds.append(page.items.map(\.kind).filter { $0 != "pi.system" })
                return AfterRunResult(tasks: [])
            }))
        ]))
        setup.models.setResponses([.message(try toolCalls([("edit", [:], "c1")])), .message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        let submission = try await generationSubmit(chat)
        await started.wait()
        let compaction = try await chat.root.compact(context: .background)
        _ = try await chat.harness.waitForTask(id: compaction, context: .background)
        gate.release()
        #expect(try await submission.wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(kinds.values == [["pi.user", "pi.assistant", "pi.tool-result", "pi.compaction", "pi.assistant"]])
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:1095
    @Test(.timeLimit(.minutes(1)))
    func handoffLeavesQueuedCompactionStaleBeforeAfterRun() async throws {
        let gate = SessionTestGate(), started = HarnessChatSignal(), summaries = SessionTestLog<GenerationRunSummary>()
        let child = harnessOneStep("test.after-run-handoff") { _, runtime, context in
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: "test.after-run-result"))
                return .terminal(outcome: .completed(result: .number(1)))
            }, context: context)
        }
        let setup = HarnessChatSetup(settings: .init(compaction: .init(enabled: false, keepRecentTokens: 1)))
        try installHarnessTool(harnessTestTool("handoff", execute: { _, _, _ in
            started.signal(); await gate.wait()
            return ToolExecutionResult(output: [], control: .init(terminate: true, handoff: "fresh start"))
        }), setup: setup)
        try setup.registry.install(Extension(name: "after-run", hooks: [
            hook(CompactionHooks(beforeCompact: { _, _, _ in .summary("earlier work") })),
            hook(GenerationHooks(afterRun: { run, _, _ in
                summaries.append(run)
                return AfterRunResult(tasks: [try runEndTask(child, input: 0)])
            }))
        ], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(try toolCalls([("handoff", [:], "c1")]))])
        let chat = try await openChat(setup: setup)
        let submission = try await generationSubmit(chat)
        await started.wait()
        let compaction = try await chat.root.compact(context: .background)
        _ = try await chat.harness.waitForTask(id: compaction, context: .background)
        gate.release()
        #expect(try await submission.wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        let entries = try await allEntries(chat.root)
        #expect(entries.allSatisfy { $0.kind != "pi.compaction" })
        #expect(entries.suffix(2).map(\.kind) == ["pi.reset", "test.after-run-result"])
        #expect(summaries.values.first?.last == entries.last { $0.kind == "pi.reset" }?.id)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:984
    @Test(.timeLimit(.minutes(1)))
    func loweringLimitDuringChildCompletionDoesNotReportInterruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d6-child-limit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), attempts = Mutex(0)
        let child = harnessOneStep("test.after-run-limit") { _, runtime, context in
            let count = attempts.withLock { value in value += 1; return value }
            if count == 1 { started.signal(); try await harnessToolAwaitAbort(context) }
            else {
                setup.updateSettings { $0.restartLimit = 1 }
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
            }
        }
        try setup.registry.install(Extension(name: "task", tasks: [AnyTaskDefinition(child)]))
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let id = try await harnessStart(first.root, child)
        try first.harness.resume()
        await started.wait()
        try await first.harness.close(context: .background)
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        #expect(try await reopened.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        #expect(setup.reports.infos.allSatisfy { $0.kind != "task_interrupted" })
        try await reopened.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:252, no-hook branch.
    @Test(.timeLimit(.minutes(1)))
    func answerWithoutAfterRunHookEndsInAnswerCommit() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        #expect(try await generationLive(chat)?.run == nil)
        #expect(try await generationLive(chat)?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:279, busy policy branches.
    @Test(.timeLimit(.minutes(1)))
    func acceptsWritesAndQueuesSteersAndFollowUpsDuringDrain() async throws {
        let gate = SessionTestGate(), asked = Mutex(0)
        let child = harnessOneStep("test.after-run-queued") { _, runtime, context in
            await gate.wait()
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(runtime.conversationId, value: EntryDraft(kind: "test.after-run-result"))
                return .terminal(outcome: .completed(result: .number(1)))
            }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, _, _ in
            let count = asked.withLock { value in value += 1; return value }
            return count == 1 ? AfterRunResult(tasks: [try runEndTask(child, input: 0)]) : nil
        }))], tasks: [AnyTaskDefinition(child)]))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second")),
                                   .message(chatAssistant("third"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await harnessEventually { try await generationLive(chat)?.run?.afterRun?.tasks?.count == 1 }
        let steer = try await chat.root.submit(.input(content: .text("steer"), whenBusy: .steer), context: .background)
        let followUp = try await generationSubmit(chat, "later")
        await #expect(throws: ConversationBusy.self) {
            try await chat.root.submit(.input(content: .text("x"), whenBusy: .reject), context: .background)
        }
        await #expect(throws: ConversationBusy.self) {
            try await chat.root.submit(.continue(), context: .background)
        }
        let idleSteer = try await chat.root.submit(.inputWhenIdle(content: .text("steer 2"), whenBusy: .steer), context: .background)
        let note = try await chat.root.submit(.write(entry: EntryDraft(kind: "test.note")), context: .background)
        #expect(try await note.status(context: .background).status == "done")
        #expect(try await steer.status(context: .background).status == "queued")
        gate.release()
        for pending in [steer, followUp, idleSteer] {
            #expect(try await pending.wait(context: .background).status == "done")
        }
        try await chat.harness.waitForIdle(context: .background)
        let kinds = try await allEntries(chat.root).map(\.kind).filter { $0 != "pi.system" }
        #expect(kinds == ["pi.user", "pi.assistant", "test.note", "test.after-run-result",
                          "pi.user", "pi.user", "pi.assistant", "pi.user", "pi.assistant"])
        try await chat.harness.close(context: .background)
    }

    // v1.5.2 harness-after-run.test.ts:373, queued steer branch.
    @Test(.timeLimit(.minutes(1)))
    func queuedSteerDropsOnYieldContinuationAndAsksBothRunEnds() async throws {
        let rootRef = Mutex<Conversation?>(nil), summaries = SessionTestLog<GenerationRunSummary>()
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(
            onYield: { _, _, _ in
                if summaries.count > 0 { return nil }
                let root = try #require(rootRef.withLock { $0 })
                _ = try await root.submit(.input(content: .text("steer"), whenBusy: .steer), context: .background)
                return GenerationYield(continue: .text("again"))
            }, afterRun: { run, _, _ in
                summaries.append(run)
                return AfterRunResult(tasks: [])
            }))]))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second"))])
        let chat = try await openChat(setup: setup)
        rootRef.withLock { $0 = chat.root }
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        try await chat.harness.waitForIdle(context: .background)
        #expect(summaries.count == 2)
        let users = try await allEntries(chat.root).filter { $0.kind == "pi.user" }
        #expect(users.count == 2)
        let contents: [UserContent] = try users.compactMap { try $0.messages()?.first }.compactMap { message in
            if case .user(let value) = message { return value.content }; return nil
        }
        let texts = contents.compactMap { content -> String? in
            if case .text(let value) = content { return value }
            return nil
        }
        #expect(texts == ["hi", "steer"])
        try await chat.harness.close(context: .background)
    }
}
