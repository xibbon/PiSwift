import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D5bGenerationRun", .serialized)
struct D5bGenerationRunTests {
    @Test(.timeLimit(.minutes(1)))
    func continueAnswersFailedRunWithoutAddingUserEntry() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "Invalid request")),
                                   .message(chatAssistant("recovered"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "Analyze this")
        #expect(try await first.wait(context: .background).reason == "model_error")
        let failure = try #require(await generationLive(chat)?.runFailure)
        #expect(failure.reason == .modelError && failure.detail == "Invalid request")
        let continued = try await chat.root.submit(.continue(), context: .background)
        #expect(try await continued.wait(context: .background).status == "done")
        #expect(try await continued.status(context: .background).type == "continue")
        #expect(try await allEntries(chat.root).filter { $0.kind == userEntry.kind }.count == 1)
        #expect(try await generationLive(chat)?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func continueWithNothingToAnswerEndsWithoutModelRequest() async throws {
        let setup = HarnessChatSetup()
        let chat = try await openChat(setup: setup)
        let continued = try await chat.root.submit(.continue(), context: .background)
        #expect(try await continued.wait(context: .background).reason == "nothing_to_answer")
        #expect(setup.models.state().callCount == 0)
        #expect(try await generationLive(chat)?.runFailure?.reason == .nothingToAnswer)
        #expect(try await allEntries(chat.root).isEmpty)
        try await chat.harness.close(context: .background)
    }

    @Test("continues a cut-off answer with unresolved tool calls", .timeLimit(.minutes(1)))
    func continueAfterLengthAnswerWithMissingToolResult() async throws {
        let setup = HarnessChatSetup()
        var cut = try toolCalls([("echo", [:], "c1")])
        cut.stopReason = .length
        cut.content.insert(.text(.init(text: "calling")), at: 0)
        setup.models.setResponses([.message(cut), .factory { request, _, _, _ in
            #expect(request.messages.suffix(2).map(\.role) == ["assistant", "toolResult"])
            return chatAssistant("resumed")
        }])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).status == "done")
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    @Test("does not continue a cut-off text answer", .timeLimit(.minutes(1)))
    func continueAfterLengthTextAnswerFindsNothing() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("cut", reason: .length))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).reason == "nothing_to_answer")
        #expect(setup.models.state().callCount == 1)
        try await chat.harness.close(context: .background)
    }

    @Test("counts tool rounds only and starts a fresh budget", .timeLimit(.minutes(1)))
    func turnLimitCountsRoundsAndResetsForNewRun() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("one")),
                                   .message(try toolCalls([("echo", [:], "c2")])),
                                   .message(try toolCalls([("echo", [:], "c3")])), .message(chatAssistant("unreached"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(2)), context: .background)
        #expect(try await generationSubmit(chat, "one").wait(context: .background).status == "done")
        let second = try await generationSubmit(chat, "two").wait(context: .background)
        #expect(second.reason == "turn_limit")
        #expect(second.record.stateDetailText == "2 turns")
        #expect(setup.models.state().callCount == 4)
        try await chat.harness.close(context: .background)
    }

    @Test("rejects an invalid turn limit", .timeLimit(.minutes(1)))
    func turnLimitRejectsZeroAndNegative() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        for value in [0, -1] {
            await #expect(throws: (any Error).self) {
                try await chat.root.configure(change: .init(maxTurns: .set(value)), context: .background)
            }
        }
        try await chat.root.configure(change: .init(maxTurns: .set(3)), context: .background)
        #expect(try await chat.root.agent(context: .background).maxTurns == 3)
        try await chat.harness.close(context: .background)
    }

    @Test("leaves last-round inputs to afterFailedRun", .timeLimit(.minutes(1)), arguments: AfterFailedRun.allCases)
    func turnLimitAppliesQueuedInputPolicy(policy: AfterFailedRun) async throws {
        let setup = HarnessChatSetup(settings: .init(afterFailedRun: policy))
        let started = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("echo", execute: { _, _, _ in
            started.signal(); await release.wait(); return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("after"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(1)), context: .background)
        let first = try await generationSubmit(chat)
        await started.wait()
        let queued = try await chat.root.submit(.input(content: .text("also"), whenBusy: .followUp), context: .background)
        release.signal()
        #expect(try await first.wait(context: .background).reason == "turn_limit")
        try await chat.root.waitForIdle(context: .background)
        let state = try await queued.status(context: .background)
        switch policy {
        case .keep: #expect(state.status == "queued")
        case .continue: #expect(state.status == "done")
        case .withdraw: #expect(state.status == "unanswered" && SettledSubmission(state).reason == "run_failed")
        }
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func continueRejectsBusyAfterRequestIdDeduplication() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let gated = HarnessGatedResponse(message: chatAssistant("recovered"))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "Invalid request")), gated.step])
        let chat = try await openChat(setup: setup)
        _ = try await generationSubmit(chat).wait(context: .background)
        let continued = try await chat.root.submit(.continue(requestId: "resume-1"), context: .background)
        await gated.reached.wait()
        await #expect(throws: ConversationBusy.self) {
            try await chat.root.submit(.continue(), context: .background)
        }
        let repeated = try await chat.root.submit(.continue(requestId: "resume-1"), context: .background)
        #expect(repeated.id == continued.id)
        gated.release()
        #expect(try await continued.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("answers the tool results of a round aborted midway", .timeLimit(.minutes(1)))
    func continueAfterAbortedToolRound() async throws {
        let setup = HarnessChatSetup()
        let started = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("wait", execute: { _, _, context in
            started.signal()
            try await harnessToolAwaitAbort(context)
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("wait", [:], "c1")])), .factory { request, _, _, _ in
            #expect(request.messages.last?.role == "toolResult")
            return chatAssistant("after the abort")
        }])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat)
        await started.wait()
        try await chat.root.abort(context: .background)
        #expect(try await first.wait(context: .background).reason == "aborted")
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("skips system messages when deciding there is something to answer", .timeLimit(.minutes(1)))
    func continueSkipsTrailingSystemMessage() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        var failure = chatAssistant("", reason: .error, error: "failed")
        failure.content = []
        setup.models.setResponses([.message(chatAssistant("first")), .message(failure), .message(chatAssistant("resumed"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(instructions: .set("Be thorough.")), context: .background)
        _ = try await generationSubmit(chat, "one").wait(context: .background)
        try await chat.root.configure(change: .init(instructions: .set("Be brief.")), context: .background)
        #expect(try await generationSubmit(chat, "two").wait(context: .background).reason == "model_error")
        #expect(try await chat.root.context(context: .background).messages.last?.role == "system")
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("places inputs a failed run left queued first", .timeLimit(.minutes(1)))
    func continueJoinsQueuedInputsFromFailedRun() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let failed = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "failed"))
        let resumed = HarnessGatedResponse(message: chatAssistant("both handled"))
        setup.models.setResponses([failed.step, resumed.step])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "first")
        await failed.reached.wait()
        let queued = try await chat.root.submit(.input(content: .text("second"), whenBusy: .followUp), context: .background)
        failed.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        #expect(try await queued.status(context: .background).status == "queued")
        let continued = try await chat.root.submit(.continue(), context: .background)
        await resumed.reached.wait()
        #expect(try await generationLive(chat)?.run?.inputs == [queued.id, continued.id])
        resumed.release()
        let answer = try await continued.wait(context: .background)
        #expect(answer.status == "done")
        #expect(try await queued.wait(context: .background).answer == answer.answer)
        try await chat.harness.close(context: .background)
    }

    @Test("places a reset kept by a failed run and finds nothing to answer", .timeLimit(.minutes(1)))
    func continuePlacesQueuedResetBeforeAnswerCheck() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let failed = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "failed"))
        setup.models.setResponses([failed.step])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "first")
        await failed.reached.wait()
        try await chat.root.reset(context: .background)
        failed.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.count == 1)
        #expect(try await chat.root.submit(.continue(), context: .background).wait(context: .background).reason == "nothing_to_answer")
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.isEmpty == true)
        #expect(setup.models.state().callCount == 1)
        try await chat.harness.close(context: .background)
    }

    @Test("starts the inputs queued behind a continue with nothing to answer under afterFailedRun continue", .timeLimit(.minutes(1)))
    func queuedInputStartsAfterEmptyContinue() async throws {
        // v1.5.2 D5b harness-continue.test.ts:290–304. One transaction holds
        // admission until the queued input is stored behind the continue.
        let setup = HarnessChatSetup(settings: .init(afterFailedRun: .continue))
        setup.models.setResponses([.message(chatAssistant("answered")), .message(chatAssistant("second answered"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat, "one").wait(context: .background).status == "done")
        // E-FLAKE: Hold scheduler dispatch while the two submissions commit.
        // Their queued state is then observable before the empty continue
        // advances to the next run.
        try await chat.root.waitForIdle(context: .background)
        chat.harness.tasks.state.withLock { $0.enabled = false }
        let ids = try await chat.root.commit({ tx in
            let continued = try await admitSubmission(tx: tx, conversationId: chat.root.id, draft: .continue(),
                now: 1, queueModes: resolveSettings(setup.settings))
            let queued = try await admitSubmission(tx: tx, conversationId: chat.root.id,
                draft: .input(content: .text("two"), whenBusy: .followUp),
                now: 1, queueModes: resolveSettings(setup.settings))
            return (continued, queued)
        }, context: .background)
        let continued = try #require(try await chat.harness.submission(id: ids.0, context: .background))
        let queued = try #require(try await chat.harness.submission(id: ids.1, context: .background))
        #expect(try await queued.status(context: .background).status == "queued")
        try chat.harness.resume()
        #expect(try await continued.wait(context: .background).reason == "nothing_to_answer")
        let settled = try await queued.wait(context: .background)
        #expect(settled.status == "done")
        let answer = try #require(await allEntries(chat.root).first { $0.id == settled.answer })
        #expect(try textOf(answer.messages()?.first) == "second answered")
        try await chat.harness.close(context: .background)
    }

    @Test("is submitted by a tool through the handle of a conversation it owns, and rejected there while busy", .timeLimit(.minutes(1)))
    func ownedToolConversationContinueRejectsBusy() async throws {
        // v1.5.2 D5b harness-continue.test.ts:306–354.
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let gated = HarnessGatedResponse(message: chatAssistant("child recovered"))
        let outcome = Mutex<(first: String?, resumed: String?, busy: Bool)>((nil, nil, false))
        try installHarnessTool(harnessTestTool("delegate", execute: { _, api, context in
            let child = try await api.commit({ tx in
                let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                try await configure(tx: tx, conversationId: created.id,
                    change: .init(model: .set(.init(provider: "faux", modelId: "faux-1"))))
                return created.id
            }, context: context)
            let handle = try #require(try await api.conversation(id: child, context: context))
            let first = try await handle.submit(.input(content: .text("work")), context: context)
            let failed = try await first.wait(context: context)
            outcome.withLock { $0.first = failed.status }
            let resumed = try await handle.submit(.continue(), context: context)
            await gated.reached.wait()
            do { _ = try await handle.submit(.continue(), context: context) }
            catch is ConversationBusy { outcome.withLock { $0.busy = true } }
            gated.release()
            let settled = try await resumed.wait(context: context)
            outcome.withLock { $0.resumed = settled.status }
            return .init(output: [.text(TextContent(text: settled.status))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("delegate", [:], "c1")])),
                                   .message(chatAssistant("", reason: .error, error: "failed")),
                                   gated.step, .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        #expect(try await generationSubmit(chat).wait(context: .background).status == "done")
        let observed = outcome.withLock { $0 }
        #expect(observed.first == "unanswered" && observed.resumed == "done" && observed.busy)
        try await chat.harness.close(context: .background)
    }

    @Test("starts a root trace linked to its caller, as an input does: no-op carrier", .timeLimit(.minutes(1)))
    func continueNoopTelemetryStoresNoTraceCarrier() async throws {
        // v1.5.2 D5b harness-continue.test.ts:356–391; submissions.ts:89–110.
        // Swift's default NoopTelemetryPropagation.inject returns nil.
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "failed")),
                                   .message(chatAssistant("recovered"))])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat)
        #expect(try await first.wait(context: .background).reason == "model_error")
        let continued = try await chat.root.submit(.continue(), context: .background)
        #expect(try await continued.wait(context: .background).status == "done")
        #expect(try await first.status(context: .background).trace == nil)
        #expect(try await continued.status(context: .background).trace == nil)
        let tasks = try await chat.root.commit({ tx in
            try await tx.scanTasks(.init(conversationId: chat.root.id), limit: 100).items
        }, context: .background)
        #expect(tasks.allSatisfy { $0.trace == nil && $0.links == nil })
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func inputWhenIdleRejectsWithoutStorageWrite() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        await #expect(throws: ConversationIdle.self) {
            try await chat.root.submit(.inputWhenIdle(content: .text("hello")), context: .background)
        }
        #expect(try await allEntries(chat.root).isEmpty)
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func turnLimitEndsAfterToolRoundAndContinueAnswersResults() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])),
                                   .message(chatAssistant("finished"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(1)), context: .background)
        let first = try await generationSubmit(chat)
        let ended = try await first.wait(context: .background)
        #expect(ended.reason == "turn_limit")
        #expect(ended.record.stateDetailText == "1 turn")
        #expect(setup.models.state().callCount == 1)
        #expect(try await generationLive(chat)?.runFailure?.reason == .turnLimit)
        let continued = try await chat.root.submit(.continue(), context: .background)
        #expect(try await continued.wait(context: .background).status == "done")
        #expect(try await allEntries(chat.root).last?.messages()?.first.flatMap(textOf) == "finished")
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    @Test("runs onYield at the limit, and a continuation starts the count over", .timeLimit(.minutes(1)))
    func yieldContinuationResetsTurnCount() async throws {
        // v1.5.2 D5b harness-turn-limit.test.ts:108–123.
        let setup = HarnessChatSetup(), yields = Mutex(0)
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        try setup.registry.install(Extension(name: "limit-yield", hooks: [hook(GenerationHooks(onYield: { _, _, _ in
            let count = yields.withLock { value in value += 1; return value }
            return count == 1 ? GenerationYield(continue: .text("keep going")) : nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("one")),
                                   .message(try toolCalls([("echo", [:], "c2")])),
                                   .message(try toolCalls([("echo", [:], "c3")])), .message(chatAssistant("unreached"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(2)), context: .background)
        #expect(try await generationSubmit(chat).wait(context: .background).reason == "turn_limit")
        #expect(yields.withLock { $0 } == 1)
        #expect(setup.models.state().callCount == 4)
        try await chat.harness.close(context: .background)
    }

    @Test("settles a steer that joined the run at an earlier round with turn_limit too", .timeLimit(.minutes(1)))
    func earlierSteerSettlesAtTurnLimit() async throws {
        // v1.5.2 D5b harness-turn-limit.test.ts:125–158.
        let setup = HarnessChatSetup()
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in
            entered.signal(); await release.wait(); return .init(output: [])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("hold", [:], "c1")])),
                                   .message(try toolCalls([("echo", [:], "c2")])), .message(chatAssistant("unreached"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(2)), context: .background)
        let first = try await generationSubmit(chat)
        await entered.wait()
        let steer = try await chat.root.submit(.input(content: .text("also this"), whenBusy: .steer), context: .background)
        release.signal()
        for submission in [first, steer] {
            let settled = try await submission.wait(context: .background)
            #expect(settled.reason == "turn_limit" && settled.record.stateDetailText == "2 turns")
        }
        #expect(try await generationLive(chat)?.runFailure?.inputs == [first.id, steer.id])
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    @Test("applies a changed limit at the end of the round; null removes it", .timeLimit(.minutes(1)))
    func changedLimitAtRoundEndAndClear() async throws {
        // v1.5.2 D5b harness-turn-limit.test.ts:192–219.
        let setup = HarnessChatSetup()
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in
            entered.signal(); await release.wait(); return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])),
                                   .message(try toolCalls([("hold", [:], "c2")])),
                                   .message(try toolCalls([("echo", [:], "c4")])),
                                   .message(try toolCalls([("echo", [:], "c5")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        try await chat.root.configure(change: .init(maxTurns: .set(5)), context: .background)
        let first = try await generationSubmit(chat)
        await entered.wait()
        try await chat.root.configure(change: .init(maxTurns: .set(1)), context: .background)
        release.signal()
        #expect(try await first.wait(context: .background).reason == "turn_limit")
        #expect(try await generationLive(chat)?.runFailure?.detail == "2 turns")
        try await chat.root.configure(change: .init(maxTurns: .clear), context: .background)
        #expect(try await chat.root.agent(context: .background).maxTurns == nil)
        #expect(try await generationSubmit(chat, "again").wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test("is inherited by forks and children, which may set their own", .timeLimit(.minutes(1)))
    func turnLimitInheritsToForksAndChildren() async throws {
        // v1.5.2 D5b harness-turn-limit.test.ts:273–305.
        let chat = try await openChat(setup: HarnessChatSetup())
        try await chat.root.configure(change: .init(maxTurns: .set(4)), context: .background)
        let childID = try await chat.root.commit({ tx in
            let task = try await tx.createTask(TaskKind<JSONObject, JSONObject>(name: "d5b.owner", version: 1,
                initial: { _ in ["phase": "run"] }), input: [:], options: .init(ownership: .conversation()))
            return try await tx.createConversation(ownership: .task(taskId: task)).id
        }, context: .background)
        let child = try #require(await chat.harness.conversation(id: childID, context: .background))
        #expect(try await child.agent(context: .background).maxTurns == 4)
        let at = try await chat.root.commit({ tx in
            try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
        }, context: .background)
        let fork = try await chat.root.fork(at: at.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await fork.agent(context: .background).maxTurns == 4)
        let own = try await chat.harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(maxTurns: .set(2))), context: .background)
        #expect(try await own.agent(context: .background).maxTurns == 2)
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func handoffWritesResetAndContinuesSameRun() async throws {
        let setup = HarnessChatSetup()
        let gated = HarnessGatedResponse(message: chatAssistant("after handoff"))
        try installHarnessTool(harnessTestTool("handoff", execute: { _, _, _ in
            .init(output: [], control: .init(handoff: "continue here"))
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("handoff", [:], "c1")])), gated.step])
        let chat = try await openChat(setup: setup)
        let input = try await generationSubmit(chat)
        await gated.reached.wait()
        #expect(try await generationLive(chat)?.run?.turns == 1)
        let reset = try #require(await allEntries(chat.root).first { $0.kind == resetEntry.kind })
        #expect(try textOf(reset.messages()?.first) == "continue here")
        gated.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func interruptedRequestWithoutRetryStoresFailureAndReport() async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let chat = try await openChat(setup: setup)
        let seeded = try await chat.root.commit({ tx in
            let user = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(.init(content: .text("go"), timestamp: 1))])))
            let input = try await tx.createSubmission(.input(conversationId: chat.root.id, state: .placed(entry: user.id)))
            let task = try await createGeneration(tx: tx, conversationId: chat.root.id)
            let live = try await tx.doc(LiveDoc, conversationId: chat.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [input.id], first: user.id)))
            return (input.id, task, user.id)
        }, context: .background)
        try await chat.root.commit({ tx in
            let record = try #require(try await tx.task(seeded.1))
            let checkpoint = GenerationCheckpoint(phase: .request, attempt: 1,
                model: ModelRef(provider: "faux", modelId: "faux-1"), thinkingLevel: .off,
                streamOptions: .init(), cutoff: seeded.2)
            try tx.setTask(record.replacing(state: .pending(checkpoint: try JSONValue(encoding: checkpoint)), restarts: .some(1)))
        }, context: .background)
        try chat.harness.resume()
        let receipt = try #require(await chat.harness.submission(id: seeded.0, context: .background))
        #expect(try await receipt.wait(context: .background).reason == "interrupted")
        #expect(setup.models.state().callCount == 0)
        #expect(try await generationLive(chat)?.runFailure?.detail == "The host stopped while the model was answering, on attempt 1")
        try await eventually { setup.reports.infos.contains { $0.kind == "task_interrupted" } }
        try await chat.harness.close(context: .background)
    }

    @Test("answers a run interrupted by a host that died while the model answered", .timeLimit(.minutes(1)))
    func continueAfterDeadRequestUsesSameFileAndExcludesPartial() async throws {
        // v1.5.2 D5b harness-continue.test.ts:233–260. The running task and
        // committed partial are the durable image left by the dead host.
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("continue-death.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)))
        let first = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let seeded = try await first.root.commit({ tx in
            let user = try await tx.appendEntry(first.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(.init(content: .text("hi"), timestamp: 1))])))
            let input = try await tx.createSubmission(.input(conversationId: first.root.id, state: .placed(entry: user.id)))
            let task = try await createGeneration(tx: tx, conversationId: first.root.id)
            let live = try await tx.doc(LiveDoc, conversationId: first.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: task, inputs: [input.id], first: user.id)))
            let partial = try #require(EntryRecord.encodeMessages([.assistant(chatAssistant("partial", reason: .aborted))]).first?.objectValue)
            try live.set("generation", JSONValue(encoding: LiveGeneration(attempt: 1, message: partial)))
            return (input.id, task, user.id)
        }, context: .background)
        try await first.harness.close(context: .background)
        let storage = try await SqliteStorage.open(path: path.path)
        let record = try #require(await storage.task(seeded.1, context: .background))
        let checkpoint = GenerationCheckpoint(phase: .request, attempt: 1,
            model: ModelRef(provider: "faux", modelId: "faux-1"), thinkingLevel: .off,
            streamOptions: .init(), cutoff: seeded.2)
        _ = try await storage.commitOne([.task(value: record.replacing(state: .running(checkpoint: try JSONValue(encoding: checkpoint))))], context: .background)
        try await storage.close(context: .background)

        let reopened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        try reopened.harness.resume()
        let original = try #require(try await reopened.harness.submission(id: seeded.0, context: .background))
        #expect(try await original.wait(context: .background).reason == "interrupted")
        setup.models.setResponses([.factory { request, _, _, _ in
            #expect(request.messages.last?.role == "user")
            return chatAssistant("after the crash")
        }])
        let continued = try await reopened.root.submit(.continue(), context: .background)
        let settled = try await continued.wait(context: .background)
        #expect(settled.status == "done")
        let answer = try #require(await allEntries(reopened.root).first { $0.id == settled.answer })
        #expect(try textOf(answer.messages()?.first) == "after the crash")
        try await reopened.harness.close(context: .background)
    }

    @Test("records a reset that cut the run before an answer, kept by the run its queued input starts", .timeLimit(.minutes(1)))
    func resetFailureSurvivesQueuedSuccessor() async throws {
        // v1.5.2 D5b harness-run-failure.test.ts:100–137.
        let setup = HarnessChatSetup()
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in
            entered.signal(); await release.wait(); return .init(output: [])
        }), setup: setup)
        let second = HarnessGatedResponse(message: chatAssistant("unused"))
        setup.models.setResponses([.message(try toolCalls([("hold", [:], "c1")])), second.step])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "go")
        await entered.wait()
        try await chat.root.reset(context: .background)
        let followUp = try await chat.root.submit(.input(content: .text("next"), whenBusy: .followUp), context: .background)
        release.signal()
        #expect(try await first.wait(context: .background).reason == "reset")
        await second.reached.wait()
        let live = try #require(await generationLive(chat))
        #expect(live.run?.inputs == [followUp.id])
        #expect(live.runFailure?.inputs == [first.id])
        #expect(live.runFailure?.reason == .reset)
        try await chat.root.abort(context: .background)
        #expect(try await generationLive(chat)?.runFailure?.inputs == [followUp.id])
        #expect(try await generationLive(chat)?.runFailure?.reason == .aborted)
        second.release()
        try await chat.harness.close(context: .background)
    }

    @Test("keeps the failure while a run continues the queue in the same commit", .timeLimit(.minutes(1)), arguments: [AfterFailedRun.continue, .keep])
    func failureSurvivesSameCommitQueuedSuccessor(policy: AfterFailedRun) async throws {
        // v1.5.2 D5b harness-run-failure.test.ts:139–163. The tag body checks retention.
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false), afterFailedRun: policy))
        let failing = HarnessGatedResponse(message: chatAssistant("", reason: .error, error: "Invalid request"))
        let next = HarnessGatedResponse(message: chatAssistant("unused"))
        setup.models.setResponses([failing.step, next.step])
        let chat = try await openChat(setup: setup)
        let first = try await generationSubmit(chat, "first")
        await failing.reached.wait()
        let second = try await chat.root.submit(.input(content: .text("second"), whenBusy: .followUp), context: .background)
        failing.release()
        #expect(try await first.wait(context: .background).reason == "model_error")
        if policy == .continue {
            await next.reached.wait()
            #expect(try await generationLive(chat)?.run?.inputs == [second.id])
        } else {
            try await chat.root.waitForIdle(context: .background)
            #expect(try await second.status(context: .background).status == "queued")
        }
        #expect(try await generationLive(chat)?.runFailure?.inputs == [first.id])
        #expect(try await generationLive(chat)?.runFailure?.reason == .modelError)
        if policy == .continue { try await chat.root.abort(context: .background) }
        next.release()
        try await chat.harness.close(context: .background)
    }
}

private extension SubmissionRecord {
    var stateDetailText: String? {
        if case .input(_, _, _, .unanswered(_, _, let detail, _)) = self { return detail?.stringValue }
        return nil
    }
}
