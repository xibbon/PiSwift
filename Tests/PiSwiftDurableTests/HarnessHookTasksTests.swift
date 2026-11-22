import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private enum DecisionHook { case afterTools, onYield }

private struct DecisionPlan: Sendable {
    var result: JSONValue
    var steer: String? = nil
    var gate: HarnessChatSignal? = nil
}

private let reviewWakeSchema: JSONValue = ["type": "object", "properties": [:]]

private struct ReviewParkCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case park, done }
    var phase: Phase = .park
}

private func decisionTool(_ name: String = "noop") throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name, parameters: reviewWakeSchema.objectValue ?? [:],
        execute: { _, _, _ in ToolExecutionResult() })
}

private func decisionCall(_ name: String = "noop", id: String = "c1") -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    message.content = [.toolCall(ToolCall(id: id, name: name, arguments: [:]))]
    return message
}

private func decisionSetup(_ kind: DecisionHook, _ plan: DecisionPlan,
                           seen: SessionTestLog<EntryID?> = SessionTestLog()) throws -> HarnessChatSetup {
    let setup = HarnessChatSetup(), calls = SessionTestLog<Bool>()
    let task = harnessOneStep("test.decider") { _, runtime, context in
        if let gate = plan.gate {
            let signal = context.abortSignal
            let listener = signal?.addAbortListener { _ in gate.signal() }
            defer { if let listener { signal?.removeAbortListener(listener) } }
            if signal?.aborted == true { gate.signal() }
            await gate.wait()
            try signal?.throwIfAborted()
        }
        let live = try await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId, context: context)
        seen.append(live?.run?.yield?.answer)
        let handle = try #require(await runtime.conversation(runtime.conversationId, context: context))
        try await runtime.commit({ tx, _ in
            if let steer = plan.steer {
                _ = try await handle.submit(tx, .input(content: .text(steer), whenBusy: .steer))
            }
            return .terminal(outcome: .completed(result: plan.result))
        }, context: context)
    }
    let hooks: GenerationHooks
    switch kind {
    case .afterTools:
        hooks = GenerationHooks(afterTools: { _, _, _, _ in
            calls.append(true)
            guard calls.count == 1 else { return nil }
            return AfterToolsResult(tasks: [try hookTask(task, input: 0)])
        })
    case .onYield:
        hooks = GenerationHooks(onYield: { _, _, _ in
            calls.append(true)
            guard calls.count == 1 else { return nil }
            return GenerationYield(tasks: [try hookTask(task, input: 0)])
        })
    }
    try setup.registry.install(Extension(name: "deciders", tools: [try decisionTool()],
        hooks: [hook(hooks)], tasks: [AnyTaskDefinition(task)]))
    return setup
}

private func openDecisionChat(_ setup: HarnessChatSetup, storage: any DurableStorage = MemoryStorage()) async throws -> OpenChatResult {
    let chat = try await openChat(storage: storage, setup: setup)
    try chat.harness.resume()
    return chat
}

private func decisionTexts(_ chat: OpenChatResult) async throws -> [String] {
    try await allEntries(chat.root).compactMap { textOf(try $0.messages()?.first) }
}

private func reviewAnswer(_ chat: OpenChatResult) async throws -> EntryID {
    try await harnessEventually { try await generationLive(chat)?.run?.yield != nil }
    return try #require(await generationLive(chat)?.run?.yield?.answer)
}

private func withDecisionDatabase(_ body: (String) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("session.sqlite").path)
}

private typealias ParkingDecider = TaskDefinition<Int, ReviewParkCheckpoint, JSONValue, NoTaskHooks>

private func parkingDecider(_ wake: SignalToken<JSONValue>, result: JSONValue) -> ParkingDecider {
    ParkingDecider(name: "test.parking-decider", version: 1, initial: { _ in ReviewParkCheckpoint() },
        phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .park:
                try await runtime.sleep(signals: [wake.key("go")],
                    checkpoint: JSONValue(encoding: ReviewParkCheckpoint(phase: .done)), context: context)
            case .done:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: result)) }, context: context)
            }
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
}

private func parkingReviewSetup() throws -> HarnessChatSetup {
    let setup = HarnessChatSetup()
    let wake: SignalToken<JSONValue> = try defineSignal(name: "test.go", version: 1, schema: reviewWakeSchema)
    let task = parkingDecider(wake, result: ["continue": "never"])
    try setup.registry.install(Extension(name: "deciders", hooks: [hook(GenerationHooks(onYield: { _, _, _ in
        GenerationYield(tasks: [try hookTask(task, input: 0)])
    }))], tasks: [AnyTaskDefinition(task)]))
    setup.models.setResponses([.message(chatAssistant("first"))])
    return setup
}

@Suite(.timeLimit(.minutes(1)))
struct HarnessHookTasksTests {
    // v1.6.0 harness-hook-tasks.test.ts:106.
    @Test func endsTheRunWithTerminateAsARoundWhoseCallsAllAskedToTerminate() async throws {
        let setup = try decisionSetup(.afterTools, DecisionPlan(result: ["terminate": true]))
        setup.models.setResponses([.message(decisionCall())])
        let chat = try await openDecisionChat(setup)
        let settled = try await generationSubmit(chat, "go").wait(context: .background)
        let assistant = try await allEntries(chat.root).first { $0.kind == "pi.assistant" }
        #expect(settled.status == "done")
        #expect(settled.answer == assistant?.id)
        #expect(setup.models.state().callCount == 1)
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:120.
    @Test func answersTheRunWithASteerTheNextRequestSees() async throws {
        let setup = try decisionSetup(.afterTools, DecisionPlan(result: .null, steer: "also check the tests"))
        setup.models.setResponses([.message(decisionCall()), .message(chatAssistant("checked"))])
        let chat = try await openDecisionChat(setup)
        #expect(try await generationSubmit(chat, "go").wait(context: .background).status == "done")
        #expect(try await decisionTexts(chat) == ["go", "also check the tests", "checked"])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:131.
    @Test func reportsAResultThatIsNoAfterToolsDecisionAndGoesOn() async throws {
        let setup = try decisionSetup(.afterTools, DecisionPlan(result: ["continue": "x"]))
        setup.models.setResponses([.message(decisionCall()), .message(chatAssistant("done"))])
        let chat = try await openDecisionChat(setup)
        #expect(try await generationSubmit(chat, "go").wait(context: .background).status == "done")
        #expect(setup.reports.infos.contains { $0.kind == "extension_error" && $0.extension == "deciders" })
        #expect(setup.reports.values.contains { String(describing: $0).contains("(test.decider) completed with no AfterToolsDecision") })
        #expect(setup.models.state().callCount == 2)
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:145.
    @Test func keepsInputsOpenWhileDecidingAndContinuesTheRun() async throws {
        let gate = HarnessChatSignal(), seen = SessionTestLog<EntryID?>()
        let setup = try decisionSetup(.onYield, DecisionPlan(result: ["continue": "review: add a test"], gate: gate), seen: seen)
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("second"))])
        let chat = try await openDecisionChat(setup)
        let submission = try await generationSubmit(chat, "go")
        let first = try await reviewAnswer(chat)
        #expect(try await submission.status(context: .background).status == "placed")
        #expect(try await decisionTexts(chat) == ["go", "first"])
        gate.signal()
        let settled = try await submission.wait(context: .background)
        let second = try await allEntries(chat.root).last
        #expect(try await decisionTexts(chat) == ["go", "first", "review: add a test", "second"])
        #expect(settled.status == "done")
        #expect(settled.answer == second?.id)
        #expect(seen.values == [first])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:166.
    @Test(arguments: [JSONValue.number(5), .array([]), [["type": "text"]], [["type": "image", "data": "x"]]])
    func ignoresAContinuationThatHoldsNoValidUserInput(_ input: JSONValue) async throws {
        let setup = try decisionSetup(.onYield, DecisionPlan(result: ["continue": input]))
        setup.models.setResponses([.message(chatAssistant("first"))])
        let chat = try await openDecisionChat(setup)
        #expect(try await generationSubmit(chat, "go").wait(context: .background).status == "done")
        #expect(try await decisionTexts(chat) == ["go", "first"])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:179.
    @Test func letsAnAnswerThatStandsRunItsAfterRunHooksWithoutRunYield() async throws {
        let setup = try decisionSetup(.onYield, DecisionPlan(result: .null))
        let asked = SessionTestLog<Bool>()
        try setup.registry.install(Extension(name: "after-run", hooks: [hook(GenerationHooks(afterRun: { _, api, context in
            asked.append(try await api.read.snapshot(LiveDoc, conversationId: api.conversationId, context: context)?.run?.yield != nil)
            return nil
        }))]))
        setup.models.setResponses([.message(chatAssistant("first"))])
        let chat = try await openDecisionChat(setup)
        #expect(try await generationSubmit(chat, "go").wait(context: .background).status == "done")
        try await chat.root.waitForIdle(context: .background)
        #expect(asked.values == [false])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:205.
    @Test func letsTheAnswerStandWithoutAContinuation() async throws {
        let setup = try decisionSetup(.onYield, DecisionPlan(result: .null))
        setup.models.setResponses([.message(chatAssistant("first"))])
        let chat = try await openDecisionChat(setup)
        #expect(try await generationSubmit(chat, "go").wait(context: .background).status == "done")
        #expect(try await decisionTexts(chat) == ["go", "first"])
        #expect(try await generationLive(chat)?.run == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:216.
    @Test func losesItsContinuationToAUserMessageQueuedMeanwhile() async throws {
        let gate = HarnessChatSignal()
        let setup = try decisionSetup(.onYield, DecisionPlan(result: ["continue": "review: add a test"], gate: gate))
        setup.models.setResponses([.message(chatAssistant("first")), .message(chatAssistant("to you"))])
        let chat = try await openDecisionChat(setup)
        let submission = try await generationSubmit(chat, "go")
        let first = try await reviewAnswer(chat)
        let queued = try await chat.root.submit(.input(content: .text("a question"), whenBusy: .followUp), context: .background)
        #expect(try await queued.status(context: .background).status == "queued")
        gate.signal()
        try #require(try await submission.wait(context: .background).answer == first)
        #expect(try await queued.wait(context: .background).status == "done")
        #expect(try await decisionTexts(chat) == ["go", "first", "a question", "to you"])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:233.
    @Test func settlesInputsDoneWithTheAnswerWhenTheRunIsAbortedWhileDeciding() async throws {
        let setup = try decisionSetup(.onYield, DecisionPlan(result: ["continue": "never"], gate: HarnessChatSignal()))
        setup.models.setResponses([.message(chatAssistant("first"))])
        let chat = try await openDecisionChat(setup)
        let submission = try await generationSubmit(chat, "go")
        let answer = try await reviewAnswer(chat)
        try await chat.root.abort(context: .background)
        let settled = try await submission.wait(context: .background)
        #expect(settled.status == "done")
        #expect(settled.answer == answer)
        let live = try await generationLive(chat)
        #expect(live?.run == nil)
        #expect(live?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 harness-hook-tasks.test.ts:273.
    @Test func asksAfterToolsHooksAgainAfterACrashBeforeTheirTasksExist() async throws {
        try await withDecisionDatabase { path in
            let setup = HarnessChatSetup(), calls = Mutex(0), reached = HarnessChatSignal()
            let wake: SignalToken<JSONValue> = try defineSignal(name: "test.go", version: 1, schema: reviewWakeSchema)
            let task = parkingDecider(wake, result: .null)
            try setup.registry.install(Extension(name: "deciders", tools: [try decisionTool()], hooks: [hook(GenerationHooks(afterTools: { _, _, _, context in
                let call = calls.withLock { count in count += 1; return count }
                if call == 1 {
                    reached.signal()
                    try await harnessToolAwaitAbort(context)
                }
                return AfterToolsResult(tasks: [try hookTask(task, input: 0)])
            }))], tasks: [AnyTaskDefinition(task)]))
            setup.models.setResponses([.message(decisionCall()), .message(chatAssistant("done"))])
            let first = try await openDecisionChat(setup, storage: SqliteStorage.open(path: path))
            let id = try await generationSubmit(first, "go").id
            await reached.wait()
            try await first.harness.close(context: .background)
            let second = try await openDecisionChat(setup, storage: SqliteStorage.open(path: path))
            try await harnessEventually {
                try await second.harness.inspect(context: .background).tasks.contains {
                    $0.record.kind == task.name && $0.record.state.status == "sleeping"
                }
            }
            let tasks = try await second.harness.inspect(context: .background).tasks
            let child = try #require(tasks.first { $0.record.kind == task.name }?.record.id)
            #expect(calls.withLock { $0 } == 2)
            try await second.harness.close(context: .background)
            let third = try await openDecisionChat(setup, storage: SqliteStorage.open(path: path))
            _ = try await third.harness.signal(taskId: child, token: wake, key: "go", value: [:], context: .background)
            let submission = try #require(await third.harness.submission(id: id, context: .background))
            #expect(try await submission.wait(context: .background).status == "done")
            #expect(calls.withLock { $0 } == 2)
            try await third.harness.close(context: .background)
        }
    }

    // v1.6.0 harness-hook-tasks.test.ts:328.
    @Test func settlesYieldInputsDoneWithTheAnswerAtTheRestartLimitWithoutRunFailure() async throws {
        try await withDecisionDatabase { path in
            let setup = try parkingReviewSetup()
            let first = try await openDecisionChat(setup, storage: SqliteStorage.open(path: path))
            let id = try await generationSubmit(first, "go").id
            let answer = try await reviewAnswer(first)
            let generation = try #require(await generationLive(first)?.run?.taskId)
            try await first.harness.close(context: .background)

            let storage = try await SqliteStorage.open(path: path)
            let record = try #require(await storage.task(generation, context: .background))
            let checkpoint = try #require(record.state.checkpoint)
            let running = TaskRecord(id: record.id, conversationId: record.conversationId, kind: record.kind,
                version: record.version, input: record.input, state: .running(checkpoint: checkpoint),
                owner: record.owner, background: record.background, abortRequested: record.abortRequested,
                abortReason: record.abortReason, abandonOnRestart: record.abandonOnRestart, startedAt: record.startedAt,
                endedAt: record.endedAt, memos: record.memos, restarts: 5, trace: record.trace, links: record.links,
                extensionFields: record.extensionFields)
            _ = try await storage.commitOne([.task(value: running)], context: .background)
            let reopened = try await openDecisionChat(setup, storage: storage)
            let submission = try #require(await reopened.harness.submission(id: id, context: .background))
            let settled = try await submission.wait(context: .background)
            #expect(settled.status == "done")
            #expect(settled.answer == answer)
            let live = try await generationLive(reopened)
            #expect(live?.run == nil)
            #expect(live?.runFailure == nil)
            try await reopened.harness.close(context: .background)
        }
    }

    // v1.6.0 harness-hook-tasks.test.ts:364.
    @Test func settlesYieldInputsDoneWithTheAnswerWhenTheSchedulerEndsTheGeneration() async throws {
        let setup = try parkingReviewSetup()
        let chat = try await openDecisionChat(setup)
        let submission = try await generationSubmit(chat, "go")
        let answer = try await reviewAnswer(chat)
        let generationID = try #require(await generationLive(chat)?.run?.taskId)
        let record = try #require(await chat.harness.getTask(id: generationID, context: .background))
        try await chat.harness.commit({ tx in
            try await settleSchedulerOutcome(tx: tx, record: record, outcome: .faulted(error: .init(message: "broken")))
        }, context: .background)
        let settled = try await submission.wait(context: .background)
        #expect(settled.status == "done")
        #expect(settled.answer == answer)
        #expect(try await generationLive(chat)?.runFailure == nil)
        try await chat.harness.close(context: .background)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct UpstreamHookTaskExamplesTests {
    // v1.6.0 examples/45-review-on-yield.ts.
    @Test func example45ReviewOnYield() async throws {
        let setup = HarnessChatSetup(), started = SessionTestLog<EntryID>()
        let gates = (0..<4).map { _ in HarnessChatSignal() }
        let task = harnessOneStep("example.review") { _, runtime, context in
            let answer = try #require(await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId,
                context: context)?.run?.yield?.answer)
            let index = started.count
            started.append(answer)
            await gates[index].wait()
            let entry = try await runtime.entry(answer, context: context)
            let text = try #require(textOf(try entry?.messages()?.first))
            let decision: JSONValue = text.count < 20 ? ["continue": "Too short: explain your reasoning."] : [:]
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: decision)) }, context: context)
        }
        try setup.registry.install(Extension(name: "reviewer", hooks: [hook(GenerationHooks(onYield: { _, _, _ in
            GenerationYield(tasks: [try hookTask(task, input: 0)])
        }))], tasks: [AnyTaskDefinition(task)]))
        setup.models.setResponses([
            .message(chatAssistant("Yes.")),
            .message(chatAssistant("Yes: the build passed and the tests are green, so it can ship.")),
            .message(chatAssistant("No.")),
            .message(chatAssistant("Answering the queued question instead.")),
        ])
        let chat = try await openDecisionChat(setup)
        let first = try await generationSubmit(chat, "Can we ship?")
        try await harnessEventually { started.count == 1 }
        #expect(try await first.status(context: .background).status == "placed")
        gates[0].signal()
        try await harnessEventually { started.count == 2 }
        gates[1].signal()
        #expect(try await first.wait(context: .background).answer == started.values[1])

        let second = try await generationSubmit(chat, "Is it Friday?")
        try await harnessEventually { started.count == 3 }
        let followUp = try await chat.root.submit(
            .input(content: .text("Skip that: what is 2 + 2?"), whenBusy: .followUp), context: .background)
        gates[2].signal()
        #expect(try await second.wait(context: .background).answer == started.values[2])
        try await harnessEventually { started.count == 4 }
        gates[3].signal()
        #expect(try await followUp.wait(context: .background).answer == started.values[3])
        #expect(try await decisionTexts(chat) == [
            "Can we ship?", "Yes.", "Too short: explain your reasoning.",
            "Yes: the build passed and the tests are green, so it can ship.",
            "Is it Friday?", "No.", "Skip that: what is 2 + 2?", "Answering the queued question instead.",
        ])
        try await chat.harness.close(context: .background)
    }

    // v1.6.0 examples/46-after-tools-terminate.ts.
    @Test func example46AfterToolsTerminate() async throws {
        let setup = HarnessChatSetup(), asking = SessionTestLog<TaskID>()
        let schema: JSONValue = ["type": "object", "properties": ["choice": ["enum": ["go on", "stop"]]],
            "required": ["choice"]]
        let choice: SignalToken<JSONValue> = try defineSignal(name: "example.go-on", version: 1, schema: schema)
        let ask = ParkingDecider(name: "example.ask-to-go-on", version: 1,
            initial: { _ in ReviewParkCheckpoint() }, phase: { task, runtime, context in
                switch task.checkpoint.phase {
                case .park:
                    asking.append(runtime.taskId)
                    try await runtime.sleep(signals: [choice.key("choice")],
                        checkpoint: JSONValue(encoding: ReviewParkCheckpoint(phase: .done)), context: context)
                case .done:
                    let signal = try await runtime.readSignal(choice, key: "choice", context: context)
                    let handle = try #require(await runtime.conversation(runtime.conversationId, context: context))
                    try await runtime.commit({ tx, _ in
                        guard case .value(let value)? = signal, value["choice"] == "go on" else {
                            return .terminal(outcome: .completed(result: ["terminate": true]))
                        }
                        _ = try await handle.submit(tx,
                            .input(content: .text("The person says: go on."), whenBusy: .steer))
                        return .terminal(outcome: .completed(result: .null))
                    }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
            })
        let step = try ToolRegistration(name: "step", description: "Do one step of the work",
            parameters: ["type": "object", "properties": ["what": ["type": "string"]], "required": ["what"]],
            execute: { args, _, _ in
                let what = try #require(args["what"]?.stringValue)
                return ToolExecutionResult(output: [.text(TextContent(text: "did " + what))])
            })
        try setup.registry.install(Extension(name: "checkpoints", tools: [step], hooks: [hook(GenerationHooks(
            afterTools: { _, _, _, _ in AfterToolsResult(tasks: [try hookTask(ask, input: 0)]) }
        ))], tasks: [AnyTaskDefinition(ask)]))
        let call: (String, String) -> AssistantMessage = { id, what in
            var message = chatAssistant("", reason: .toolUse)
            message.content = [.toolCall(ToolCall(id: id, name: "step", arguments: ["what": AnyCodable(what)]))]
            return message
        }
        setup.models.setResponses([
            .message(call("step-1", "step 1")), .message(call("step-2", "step 2")), .message(chatAssistant("Not reached.")),
        ])
        let chat = try await openDecisionChat(setup)
        let submission = try await generationSubmit(chat, "Do the work, step by step")
        for (index, answer) in ["go on", "stop"].enumerated() {
            try await harnessEventually {
                guard let child = asking.values.dropFirst(index).first else { return false }
                return try await chat.harness.getTask(id: child, context: .background)?.state.status == "sleeping"
            }
            let child = asking.values[index]
            #expect(try await submission.status(context: .background).status == "placed")
            _ = try await chat.harness.signal(taskId: child, token: choice, key: "choice",
                value: ["choice": .string(answer)], context: .background)
        }
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(setup.models.state().callCount == 2)
        #expect(try await decisionTexts(chat) == [
            "Do the work, step by step", "did step 1", "The person says: go on.", "did step 2",
        ])
        try await chat.harness.close(context: .background)
    }
}
