import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func integrationChild(_ api: ToolExecutionApi, _ context: PiSwiftChord.Context) async throws -> ConversationID {
    try await api.commit({ tx in
        let child = try await tx.createConversation(ownership: .task(taskId: api.taskId))
        try await configure(tx: tx, conversationId: child.id, change: .init(model: .set(.init(provider: "faux", modelId: "faux-1"))))
        return child.id
    }, context: context)
}
private func integrationTasks(_ chat: OpenChatResult) async throws -> [TaskRecord] {
    try await chat.root.commit({ tx in try await tx.scanTasks(.init(conversationId: chat.root.id), limit: 100).items }, context: .background)
}
private func integrationWaitForAbort(_ context: PiSwiftChord.Context) async throws {
    let stopped = HarnessChatSignal()
    let registration = context.abortSignal?.addAbortListener { _ in stopped.signal() }
    defer { if let registration { context.abortSignal?.removeAbortListener(registration) } }
    if context.abortSignal?.aborted == true { stopped.signal() }
    await stopped.wait()
    try context.abortSignal?.throwIfAborted()
}

private final class IntegrationUsageModels: DurableModels {
    let base: FakeDurableModels
    let partial: HarnessManualModels
    private let partialMode = Mutex(false)
    init(_ base: FakeDurableModels) { self.base = base; partial = HarnessManualModels(base: base) }
    func usePartialStream(_ enabled: Bool = true) { partialMode.withLock { $0 = enabled } }
    func getModel(provider: String, modelId: String) -> Model? { base.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        if partialMode.withLock({ $0 }) { return partial.streamSimple(model: model, context: context, options: options) }
        return base.streamSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await base.fetchDeferred(model: model, handle: handle, options: options)
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}

@Suite struct HarnessToolIntegrationTests {
    // structured:1014. Result task ownership and successor generation are durable.
    @Test func generationOwnsToolsAndSuccessorBelongsToConversation() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(), setup: setup)
        let (chat, entries) = try await runHarnessTools(setup)
        let tasks = try await integrationTasks(chat)
        let tool = try #require(tasks.first { $0.kind == "pi.tool" })
        let generations = tasks.filter { $0.kind == "pi.generation" }
        #expect(generations.count == 2)
        #expect(generations.contains { $0.id == tool.owner })
        #expect(generations.allSatisfy { $0.owner == nil })
        #expect(tasks.allSatisfy { $0.state.status == "terminal" })
        #expect(try harnessToolResults(entries).count == 1)
        try await chat.harness.close(context: .background)
    }

    // structured:1041,1061,1574. H9 event ordering remains outside this test.
    @Test(arguments: [ToolExecutionMode.parallel, .sequential])
    func abortRoundWritesEveryResultAndJoinsTools(_ mode: ToolExecutionMode) async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: mode))
        let starts = SessionTestLog<String>()
        for name in ["a", "b", "c"] {
            try installHarnessTool(harnessTestTool(name, execute: { _, _, context in
                starts.append(name)
                try await integrationWaitForAbort(context)
                return .init(content: [])
            }), setup: setup)
        }
        setup.models.setResponses([.message(try toolCalls([("a", [:], "a"), ("b", [:], "b"), ("c", [:], "c")]))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        try await eventually { starts.count == (mode == .parallel ? 3 : 1) }
        try await chat.root.abort(context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        let results = try harnessToolResults(await allEntries(chat.root))
        #expect(Set(results.map(\.toolCallId)) == Set(["a", "b", "c"]))
        #expect(results.allSatisfy { $0.isError })
        if mode == .sequential { #expect(results.map(\.toolCallId) == ["a", "b", "c"]) }
        let tasks = try await integrationTasks(chat)
        #expect(tasks.allSatisfy { $0.state.status == "terminal" })
        #expect(tasks.filter { $0.kind == "pi.tool" }.count == (mode == .parallel ? 3 : 1))
        try await chat.harness.close(context: .background)
    }

    // structured:1636,1673. H9 tool-end/task-failed event assertions are deferred.
    @Test(arguments: [false, true])
    func toolSlotEndsAtHoldButGenerationWaitsForOwnedWork(_ fail: Bool) async throws {
        let setup = HarnessChatSetup()
        let runGate = SessionTestGate(), abortGate = SessionTestGate(), started = HarnessChatSignal()
        defer { runGate.release(); abortGate.release() }
        let childIDs = SessionTestLog<TaskID>()
        let child = harnessOneStep("test.integration-child", run: { _, runtime, context in
            started.signal(); await runGate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }, abort: { _, runtime, context in
            await abortGate.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        try setup.registry.install(Extension(name: "children", tasks: [AnyTaskDefinition(child)]))
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            if fail {
                childIDs.append(try await api.createTask(child, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context))
            } else {
                childIDs.append(try await api.commit({ tx in
                    let owned = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                    return try await tx.createTask(child, input: 0, options: .init(ownership: .conversation(), conversationId: owned.id))
                }, context: context))
            }
            await started.wait()
            if fail {
                var invalid = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
                invalid.cost.total = .nan
                return .init(content: [], usage: invalid)
            }
            return .init(content: [.text(TextContent(text: "held result"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        try await eventually {
            let tasks = try await integrationTasks(chat)
            return tasks.contains { $0.kind == "pi.tool" && $0.state.status == "completing" }
        }
        let tool = try #require(try await integrationTasks(chat).first { $0.kind == "pi.tool" })
        #expect(tool.endedAt == nil)
        #expect(try await input.status(context: .background).status == "placed")
        #expect(setup.models.state().callCount == 1)
        let slot = try #require(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.tools?.first)
        #expect(fail ? slot.status != .done && slot.entry == nil : slot.status == .done && slot.entry != nil)
        if fail { abortGate.release() }
        runGate.release()
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await chat.harness.waitForTask(id: tool.id, context: .background).outcome.status == (fail ? "faulted" : "completed"))
        #expect(try await chat.harness.waitForTask(id: childIDs.values[0], context: .background).outcome.status == (fail ? "aborted" : "completed"))
        try await chat.harness.close(context: .background)
    }

    // lifecycle:150. Close joins execution and hooks even when they ignore cancellation.
    @Test(arguments: ["execute", "beforeTool", "afterTool"])
    func closeJoinsToolAndHooksThatIgnoreCancellation(_ held: String) async throws {
        let setup = HarnessChatSetup(), entered = HarnessChatSignal(), release = HarnessChatSignal(), exited = HarnessChatSignal()
        defer { release.signal() }
        let pause: @Sendable () async -> Void = { entered.signal(); await release.wait(); exited.signal() }
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            if held == "execute" { await pause() }
            return .init(content: [])
        }), setup: setup)
        try setup.registry.install(Extension(name: "held-hooks", hooks: [hook(ToolHooks(beforeTool: { _, _, _ in
            if held == "beforeTool" { await pause() }; return nil
        }, afterTool: { _, _, _, _ in
            if held == "afterTool" { await pause() }; return nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")]))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("go")), context: .background)
        await entered.wait()
        let close = settled { try await chat.harness.close(context: .background) }
        try await eventually { chat.harness.tasks.closing }
        #expect(!close.isSettled && !exited.isSignalled)
        release.signal()
        try await eventually { close.isSettled }
        _ = try #require(close.result).get()
        #expect(exited.isSignalled)
    }

    // ownership:592. Saved handles expire; the submission remains durable.
    @Test func invocationBoundHandleExpiresWithoutRemovingSubmission() async throws {
        let setup = HarnessChatSetup()
        let handles = SessionTestLog<ConversationHandle>(), submissions = SessionTestLog<Submission>()
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            let id = try await integrationChild(api, context)
            #expect(try await api.conversation(id: try ConversationID(99_999), context: context) == nil)
            let handle = try #require(try await api.conversation(id: id, context: context))
            handles.append(handle)
            let submission = try await handle.submit(.input(content: .text("child"), requestId: "stable"), context: context)
            submissions.append(submission)
            #expect(try await submission.wait(context: context).status == "done")
            return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("child answer")), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let handle = handles.values[0], submission = submissions.values[0]
        await #expect(throws: (any Error).self) { try await handle.submit(.input(content: .text("late")), context: .background) }
        await #expect(throws: (any Error).self) { try await handle.waitForIdle(context: .background) }
        await #expect(throws: (any Error).self) { try await handle.abort(context: .background) }
        await #expect(throws: (any Error).self) { try await submission.wait(context: .background) }
        let durable = try #require(try await chat.harness.submission(id: submission.id, context: .background))
        #expect(try await durable.status(context: .background).status == "done")
        let child = try #require(try await chat.harness.conversation(id: handle.id, context: .background))
        #expect(try await allEntries(child).filter { $0.kind == "pi.user" }.count == 1)
        try await chat.harness.close(context: .background)
    }

    // ownership:701,751.
    @Test(arguments: [false, true])
    func subagentAbortPropagatesOrToolCanAbortChildAndContinue(_ childOnly: Bool) async throws {
        let setup = HarnessChatSetup(), childRun = HarnessUnanswered(), rejected = HarnessChatSignal()
        let children = SessionTestLog<ConversationID>()
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            let id = try await integrationChild(api, context); children.append(id)
            let handle = try #require(try await api.conversation(id: id, context: context))
            let submission = try await handle.submit(.input(content: .text("child")), context: context)
            if childOnly { await childRun.reached.wait(); try await handle.abort(context: context) }
            do {
                let answer = try await submission.wait(context: context)
                #expect(childOnly && answer.reason == "aborted")
                return .init(content: [.text(TextContent(text: "child aborted"))])
            } catch { rejected.signal(); throw error }
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), childRun.step, .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        await childRun.reached.wait()
        if !childOnly { try await chat.root.abort(context: .background) }
        #expect(try await input.wait(context: .background).status == (childOnly ? "done" : "unanswered"))
        if !childOnly { #expect(rejected.isSignalled) }
        let child = try #require(try await chat.harness.conversation(id: children.values[0], context: .background))
        try await child.waitForIdle(context: .background)
        #expect(try await chat.harness.snapshot(LiveDoc, conversationId: child.id, context: .background) == LiveState())
        try await chat.harness.close(context: .background)
    }

    // inbox:203,554. Follow-ups stay queued until the final boundary.
    @Test(arguments: [QueueMode.oneAtATime, .all])
    func postToolsSelectsSteersBeforeFinalFollowUps(_ mode: QueueMode) async throws {
        let setup = HarnessChatSetup(settings: .init(steeringMode: mode))
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in entered.signal(); await release.wait(); return .init(content: []) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("after tools")), .message(chatAssistant("follow up"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await entered.wait()
        let s1 = try await chat.root.submit(.input(content: .text("s1"), whenBusy: .steer), context: .background)
        let follow = try await chat.root.submit(.input(content: .text("f")), context: .background)
        let s2 = mode == .all ? try await chat.root.submit(.input(content: .text("s2"), whenBusy: .steer), context: .background) : nil
        release.signal()
        let answered = try await input.wait(context: .background)
        #expect(try await s1.wait(context: .background).answer == answered.answer)
        if let s2 { #expect(try await s2.wait(context: .background).answer == answered.answer) }
        #expect(try await follow.wait(context: .background).answer != answered.answer)
        let kinds = try await allEntries(chat.root).map(\.kind)
        #expect(kinds == (mode == .all ? ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.user", "pi.user", "pi.assistant", "pi.user", "pi.assistant"] : ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.user", "pi.assistant", "pi.user", "pi.assistant"]))
        try await chat.harness.close(context: .background)
    }

    // inbox:231,345,604,627.
    @Test(arguments: ["reset", "handoff", "terminate", "last-handoff"])
    func controlsAndResetApplyBeforeFollowUpContext(_ mode: String) async throws {
        let setup = HarnessChatSetup(), entered = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        let requests = SessionTestLog<[String]>()
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            entered.signal(); await release.wait()
            return .init(content: [], control: mode == "terminate" ? .init(terminate: true) : mode.contains("handoff") ? .init(handoff: "one") : nil)
        }), setup: setup)
        if mode == "last-handoff" {
            try installHarnessTool(harnessTestTool("later", execute: { _, _, _ in .init(content: [], control: .init(handoff: "two")) }), setup: setup)
        }
        let calls: [(String, JSONObject, String)] = mode == "last-handoff" ? [("echo", [:], "c1"), ("later", [:], "c2")] : [("echo", [:], "c1")]
        setup.models.setResponses([.message(try toolCalls(calls)), .factory { request, _, _, _ in
            requests.append(request.messages.filter { if case .system = $0 { return false }; return true }.map { textOf($0) ?? "" })
            return chatAssistant("fresh")
        }])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("a")), context: .background); await entered.wait()
        let follow = mode == "handoff" ? nil : try await chat.root.submit(.input(content: .text("f")), context: .background)
        if mode == "reset" { try await chat.root.reset(context: .background) }
        if mode == "last-handoff" {
            try await eventually { try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background)?.tools?.last?.status == .done }
        }
        release.signal()
        let original = try await input.wait(context: .background)
        #expect(original.status == (mode == "reset" ? "unanswered" : "done"))
        if mode == "reset" { #expect(original.reason == "reset") }
        if let follow { #expect(try await follow.wait(context: .background).status == "done") }
        let entries = try await allEntries(chat.root)
        if mode != "terminate" {
            let reset = try #require(entries.first { $0.kind == "pi.reset" })
            #expect(reset.head == reset.id)
            if mode.contains("handoff") { #expect(textOf(try reset.messages()?.first) == (mode == "last-handoff" ? "two" : "one")) }
            #expect(try await chat.root.context(context: .background).entries.first?.id == reset.id)
        } else { #expect(!entries.contains { $0.kind == "pi.reset" }) }
        #expect(setup.models.state().callCount == (mode == "handoff" ? 1 : 2))
        if mode == "reset" { #expect(requests.values == [["f"]]) }
        if mode == "last-handoff" { #expect(requests.values == [["two", "f"]]) }
        if mode == "terminate" { #expect(original.answer == entries.first { $0.kind == "pi.assistant" }?.id) }
        try await chat.harness.close(context: .background)
    }

    // inbox:773,818. Tool replacement, retry usage, and converted partial usage are recorded.
    @Test(arguments: [false, true])
    func toolUsageUsesAfterToolReplacementAndSessionSum(_ replacement: Bool) async throws {
        let setup = HarnessChatSetup(settings: .init(retry: .init(maxRetries: 1, baseDelayMs: 0)))
        let models = IntegrationUsageModels(setup.models)
        let spent = Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 10,
                          cost: .init(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1))
        let replaced = Usage(input: 5, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 5)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in .init(content: [], usage: spent) }), setup: setup)
        if replacement {
            try setup.registry.install(Extension(name: "usage", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
                var result = result; result.usage = replaced; return result
            }))]))
        }
        let toolMessage = try toolCalls([("echo", [:], "c1")])
        var steps: [FakeDurableResponseStep] = [.message(toolMessage), .message(chatAssistant("done"))]
        if replacement { steps.insert(.message(chatAssistant("", reason: .error, error: "503 Service Unavailable")), at: 0) }
        setup.models.setResponses(steps)
        let chat = try await openChat(setup: setup, models: models)
        #expect(try await chat.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        if replacement {
            models.usePartialStream()
            let aborted = try await chat.root.submit(.input(content: .text("partial")), context: .background)
            try await eventually { models.partial.seen.withLock { !$0.isEmpty } }
            var partial = chatAssistant("partial", reason: .pending)
            partial.usage = Usage(input: 7, output: 11, cacheRead: 0, cacheWrite: 0, totalTokens: 18)
            models.partial.stream.push(.textDelta(contentIndex: 0, delta: "partial", partial: partial))
            try await eventually { try await generationLive(chat)?.generation?.message != nil }
            try await chat.root.abort(context: .background)
            #expect(try await aborted.wait(context: .background).reason == "aborted")
        }
        let entries = try await allEntries(chat.root)
        let assistants = try entries.flatMap { entry -> [AssistantMessage] in
            try entry.messages()?.compactMap { if case .assistant(let message) = $0 { return message }; return nil } ?? []
        }
        if replacement { #expect(assistants.map(\.stopReason) == [.error, .toolUse, .stop, .aborted]) }
        let expected = replacement ? replaced : spent
        let ledger = try #require(try await chat.harness.snapshot(UsageDoc, conversationId: chat.root.id, context: .background))
        let modelUsage = try #require(ledger.models["faux/faux-1"])
        #expect(modelUsage.input == assistants.reduce(0) { $0 + $1.usage.input })
        #expect(modelUsage.output == assistants.reduce(0) { $0 + $1.usage.output })
        #expect(modelUsage.totalTokens == assistants.reduce(0) { $0 + $1.usage.totalTokens })
        let recorded = try #require(ledger.tools["echo"])
        #expect(recorded.input == expected.input && recorded.output == expected.output)
        #expect(recorded.totalTokens == expected.totalTokens && recorded.cost.total == expected.cost.total)
        #expect(recorded.cacheRead == expected.cacheRead && recorded.cacheWrite == expected.cacheWrite)
        #expect(recorded.cost.input == expected.cost.input && recorded.cost.output == expected.cost.output)
        #expect(recorded.cost.cacheRead == expected.cost.cacheRead && recorded.cost.cacheWrite == expected.cost.cacheWrite)
        let resultUsage = try #require(try harnessToolResults(entries).first?.usage)
        #expect(resultUsage.input == expected.input && resultUsage.output == expected.output)
        #expect(resultUsage.totalTokens == expected.totalTokens && resultUsage.cost.total == expected.cost.total)
        #expect(resultUsage.cacheRead == expected.cacheRead && resultUsage.cacheWrite == expected.cacheWrite)
        #expect(resultUsage.cost.input == expected.cost.input && resultUsage.cost.output == expected.cost.output)
        #expect(resultUsage.cost.cacheRead == expected.cost.cacheRead && resultUsage.cost.cacheWrite == expected.cost.cacheWrite)
        let fork = try await chat.root.fork(at: try #require(entries.last).id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await chat.harness.snapshot(UsageDoc, conversationId: fork.id, context: .background)?.tools.isEmpty == true)
        models.usePartialStream(false)
        setup.models.setResponses([.message(chatAssistant("fork answer"))])
        _ = try await fork.submit(.input(content: .text("fork")), context: .background).wait(context: .background)
        let total = try await chat.harness.usage(context: .background)
        let forkUsage = try #require(try await chat.harness.snapshot(UsageDoc, conversationId: fork.id, context: .background)?.models["faux/faux-1"])
        #expect(total.models["faux/faux-1"]?.output == modelUsage.output + forkUsage.output)
        let totalUsage = try #require(total.tools["echo"])
        #expect(totalUsage.input == expected.input && totalUsage.output == expected.output)
        #expect(totalUsage.totalTokens == expected.totalTokens && totalUsage.cost.total == expected.cost.total)
        #expect(totalUsage.cacheRead == expected.cacheRead && totalUsage.cacheWrite == expected.cacheWrite)
        #expect(totalUsage.cost.input == expected.cost.input && totalUsage.cost.output == expected.cost.output)
        #expect(totalUsage.cost.cacheRead == expected.cost.cacheRead && totalUsage.cost.cacheWrite == expected.cost.cacheWrite)
        try await chat.harness.close(context: .background)
    }
}

extension HarnessToolIntegrationTests {
    // ownership:647. Admission queued after a durable abort mark must fail.
    @Test func queuedHandleSubmissionRejectsAfterAbortMark() async throws {
        let setup = HarnessChatSetup(), ready = HarnessChatSignal(), go = HarnessChatSignal(), queued = HarnessChatSignal()
        defer { go.signal() }
        let children = SessionTestLog<ConversationID>(), owners = SessionTestLog<TaskID>()
        let operations = SessionTestLog<Task<Submission, any Error>>()
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            let child = try await integrationChild(api, context)
            children.append(child); owners.append(api.taskId)
            let handle = try #require(try await api.conversation(id: child, context: context))
            ready.signal(); await go.wait()
            let submitting = Task { try await handle.submit(.input(content: .text("late")), context: .background) }
            operations.append(submitting)
            queued.signal()
            try await integrationWaitForAbort(context)
            return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("go")), context: .background)
        await ready.wait()
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        let holding = Task { try await chat.root.commit({ _ in entered.signal(); await release.wait() }, context: .background) }
        await entered.wait()
        let aborting = Task { try await chat.harness.abortTask(id: owners.values[0], context: .background) }
        try await eventually { chat.harness.session.line.queuedCount >= 1 }
        go.signal(); await queued.wait()
        try await eventually { chat.harness.session.line.queuedCount >= 2 }
        release.signal(); try await holding.value; _ = try await aborting.value
        await #expect(throws: (any Error).self) { try await operations.values[0].value }
        #expect(try await input.wait(context: .background).status == "done")
        let child = try #require(try await chat.harness.conversation(id: children.values[0], context: .background))
        #expect(try await allEntries(child).isEmpty)
        #expect(try await chat.harness.inspect(context: .background).submissions.allSatisfy { $0.conversationId != child.id })
        try await chat.harness.close(context: .background)
    }

    // ownership:785. Both an execution throw and unsafe restart cancel owned work.
    @Test(arguments: [false, true])
    func failedOrInterruptedToolCancelsOwnedConversationAndRunContinues(_ restart: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-child.sqlite").path
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), children = SessionTestLog<TaskID>()
        let child = harnessOneStep("test.integration-cascade", run: { _, runtime, context in
            try await runtime.sleep(until: Int64.max / 2, context: context)
        })
        try setup.registry.install(Extension(name: "cascade", tasks: [AnyTaskDefinition(child)]))
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            children.append(try await api.commit({ tx in
                let conversation = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                return try await tx.createTask(child, input: 0, options: .init(ownership: .conversation(), conversationId: conversation.id))
            }, context: context))
            running.signal()
            if restart { try await integrationWaitForAbort(context) }
            throw TaskDefinitionError("spawn failed")
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let input = try await first.root.submit(.input(content: .text("go")), context: .background)
        await running.wait()
        let chat: OpenChatResult
        if restart {
            try await first.harness.close(context: .background)
            setup.models.setResponses([.message(chatAssistant("after interruption"))])
            chat = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        } else { chat = first }
        let durable = try #require(try await chat.harness.submission(id: input.id, context: .background))
        #expect(try await durable.wait(context: .background).status == "done")
        #expect(try await chat.harness.waitForTask(id: children.values[0], context: .background).outcome.status == "aborted")
        let tool = try #require(try await integrationTasks(chat).first { $0.kind == "pi.tool" })
        #expect(try await chat.harness.waitForTask(id: tool.id, context: .background).outcome.status == "failed")
        #expect(try harnessToolResults(await allEntries(chat.root)).first?.isError == true)
        try await chat.harness.close(context: .background)
    }

    // ownership:845. Child ownership lookup and request ID make safe replay idempotent.
    @Test func replaySafeSubagentKeepsChildAndSubmissionAcrossRestart() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("safe-subagent.sqlite").path
        let setup = HarnessChatSetup(), children = SessionTestLog<ConversationID>(), submissions = SessionTestLog<SubmissionID>()
        var tool = try harnessTestTool(execute: { _, api, context in
            let child = try await api.commit({ tx in
                if let existing = try await tx.scanConversations(.init(ownerTaskId: api.taskId), limit: 1).items.first { return existing.id }
                let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                try await configure(tx: tx, conversationId: created.id, change: .init(model: .set(.init(provider: "faux", modelId: "faux-1"))))
                return created.id
            }, context: context)
            children.append(child)
            let handle = try #require(try await api.conversation(id: child, context: context))
            let input = try await handle.submit(.input(content: .text("child"), requestId: "subagent:\(api.taskId.rawValue)"), context: context)
            submissions.append(input.id)
            let answer = try await input.wait(context: context)
            return .init(content: [.text(TextContent(text: answer.status))])
        })
        tool.replay = .safe
        try installHarnessTool(tool, setup: setup)
        let held = HarnessUnanswered()
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), held.step])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let input = try await first.root.submit(.input(content: .text("go")), context: .background)
        await held.reached.wait()
        try await first.harness.close(context: .background)
        setup.models.setResponses([.message(chatAssistant("child answer")), .message(chatAssistant("done"))])
        let chat = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let durable = try #require(try await chat.harness.submission(id: input.id, context: .background))
        #expect(try await durable.wait(context: .background).status == "done")
        #expect(children.count == 2 && children.values[0] == children.values[1])
        #expect(submissions.count == 2 && submissions.values[0] == submissions.values[1])
        let child = try #require(try await chat.harness.conversation(id: children.values[0], context: .background))
        #expect(try await allEntries(child).filter { $0.kind == "pi.user" }.count == 1)
        #expect(try harnessToolResults(await allEntries(chat.root)).map(\.isError) == [false])
        try await chat.harness.close(context: .background)
    }
}
