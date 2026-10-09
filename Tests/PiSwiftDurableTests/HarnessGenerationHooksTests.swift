import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessGenerationHooksTests {
    @Test func sectionsReadConversationDocuments() async throws {
        struct State: Codable, Sendable { var cwd = "/"; var kind = "main" }
        let token = try ConversationDocToken<State>(kind: "test.generation-agent", version: 1, fork: .current, initial: { State() })
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "prompt", sections: [
            section("cwd") { input, context in try await input.read.snapshot(token, conversationId: input.conversationId, context: context)?.cwd },
            section("agents") { input, context in
                let value = try await input.read.snapshot(token, conversationId: input.conversationId, context: context)
                return value?.kind == "sub" ? nil : "Read AGENTS.md"
            }
        ]))
        setup.models.setResponses([.message(chatAssistant("a")), .message(chatAssistant("b"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.commit({ tx in let value = try await tx.doc(token, conversationId: opened.root.id); try value.set("cwd", .string("/repo")) }, context: .background)
        let child = try await opened.harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(model: .set(ModelRef(provider: "faux", modelId: "faux-1"))),
            initialize: { tx, id in let value = try await tx.doc(token, conversationId: id); try value.set("cwd", .string("/sub")); try value.set("kind", .string("sub")) }), context: .background)
        _ = try await generationSubmit(opened).wait(context: .background)
        _ = try await child.submit(.input(content: .text("two")), context: .background).wait(context: .background)
        let rootSystem = try await allEntries(opened.root).first { $0.kind == systemEntry.kind }?.model?.first?["sections"]
        let childSystem = try await allEntries(child).first { $0.kind == systemEntry.kind }?.model?.first?["sections"]
        #expect(rootSystem?["cwd"] == .string("<cwd>\n/repo\n</cwd>"))
        #expect(rootSystem?["agents"] == .string("<agents>\nRead AGENTS.md\n</agents>"))
        #expect(childSystem?["cwd"] == .string("<cwd>\n/sub\n</cwd>") && childSystem?["agents"] == nil)
        try await opened.harness.close(context: .background)
    }
    @Test func beforeRequestChainAndFirstYieldContinuation() async throws {
        let setup = HarnessChatSetup(), observed = Mutex<[String]>([]), yieldCount = Mutex(0)
        try setup.registry.install(Extension(name: "hooks", hooks: [
            hook(GenerationHooks(beforeRequest: { request, _, _ in
                var next = request; next.messages.append(.user(UserMessage(content: .text("first"), timestamp: 1))); return next
            }, afterResponse: { _, _, _ in observed.withLock { $0.append("response") } }, onYield: { _, _, _ in
                let call = yieldCount.withLock { count in count += 1; return count }
                return call == 1 ? GenerationYield(continue: .text("continue")) : nil
            })),
            hook(GenerationHooks(beforeRequest: { request, _, _ in
                #expect(textOf(request.messages.last) == "first")
                var next = request; next.messages.append(.user(UserMessage(content: .text("second"), timestamp: 1))); return next
            }, onYield: { _, _, _ in observed.withLock { $0.append("second-yield") }; return nil }))
        ]))
        let requestCount = Mutex(0)
        let step = FakeDurableResponseStep.factory { request, _, _, _ in
            #expect(textOf(request.messages.last) == "second")
            requestCount.withLock { $0 += 1 }; return chatAssistant("answer")
        }
        setup.models.setResponses([step, step])
        let opened = try await openChat(setup: setup)
        #expect(try await generationSubmit(opened).wait(context: .background).status == "done")
        #expect(requestCount.withLock { $0 } == 2)
        #expect(observed.withLock { $0 } == ["response", "response", "second-yield"])
        let users = try await allEntries(opened.root).filter { $0.kind == userEntry.kind }
        #expect(users.count == 2)
        #expect(try textOf(users.last?.messages()?.first) == "continue")
        try await opened.harness.close(context: .background)
    }
    @Test func offeredToolsCreateBlockedOwnedRoundAndUnavailableCallsGetResults() async throws {
        let tool = try ToolRegistration(name: "offered", description: "", parameters: [:]) { _, _, _ in ToolExecutionResult() }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "tools", tools: [tool]))
        var message = chatAssistant("", reason: .toolUse)
        message.content = [.toolCall(ToolCall(id: "a", name: "offered", arguments: [:])), .toolCall(ToolCall(id: "b", name: "missing", arguments: [:]))]
        setup.models.setResponses([.message(message)])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.tools?.count == 2 }
        let live = try #require(await generationLive(opened)), slots = try #require(live.tools), taskId = try #require(slots[0].taskId)
        let record = try #require(await opened.harness.getTask(id: taskId, context: .background))
        #expect(record.kind == "pi.tool" && record.input["callId"] == .string("a"))
        let ownerId = try #require(live.run?.taskId)
        #expect(record.owner == ownerId)
        #expect(record.state.status == "pending")
        if case .pending(let checkpoint, _) = record.state { #expect(checkpoint["phase"] == .string("call")) }
        #expect(slots[1].status == .done && slots[1].taskId == nil)
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.tool-result"])
        #expect(entries.last?.data?["diagnostics"]?[0]?["code"] == .string("tool_unavailable"))
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        try await opened.harness.close(context: .background)
    }
    @Test func sequentialRoundStartsOnlyFirstCallAndAbortsUnstartedCalls() async throws {
        let tool = try ToolRegistration(name: "offered", description: "", parameters: [:]) { _, _, _ in ToolExecutionResult() }
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential))
        try setup.registry.install(Extension(name: "tools", tools: [tool]))
        var message = chatAssistant("", reason: .toolUse)
        message.content = [.toolCall(ToolCall(id: "a", name: "offered", arguments: [:])), .toolCall(ToolCall(id: "b", name: "offered", arguments: [:]))]
        setup.models.setResponses([.message(message)])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.tools?.count == 2 }
        let slots = try #require(await generationLive(opened)?.tools)
        #expect(slots[0].taskId != nil && slots[1].taskId == nil)
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        let results = try await allEntries(opened.root).filter { $0.kind == toolResultEntry.kind }
        #expect(results.count == 1)
        #expect(results.first?.data?["diagnostics"]?[0]?["code"] == .string("aborted"))
        try await opened.harness.close(context: .background)
    }
    @Test(arguments: [false, true]) func finishRoundAppliesControlsInCallOrder(handoff: Bool) async throws {
        let setup = HarnessChatSetup(), seen = Mutex<[EntryID]>([])
        let old = try ToolRegistration(name: "old", description: "", parameters: [:]) { _, _, _ in ToolExecutionResult() }
        let new = try ToolRegistration(name: "new", description: "", parameters: [:]) { _, _, _ in ToolExecutionResult() }
        try setup.registry.install(Extension(name: "tools", tools: [old, new], hooks: [hook(GenerationHooks(afterTools: { _, results, _, _ in seen.withLock { $0 = results } }))]))
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(tools: .set(.exact([old]))), context: .background)
        let ids = try await opened.root.commit({ tx in
            let user = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind, model: EntryRecord.encodeMessages([.user(UserMessage(content: .text("hi"), timestamp: 1))])))
            let submission = try await tx.createSubmission(.input(conversationId: opened.root.id, state: .placed(entry: user.id)))
            let generation = try await createGeneration(tx: tx, conversationId: opened.root.id)
            let assistant = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: assistantEntry.kind, model: EntryRecord.encodeMessages([.assistant(chatAssistant("answer", reason: .toolUse))])))
            var tools: [TaskID] = [], slots: [ToolSlot] = []
            for index in 0..<2 {
                let call = ToolCall(id: "call-\(index)", name: "old", arguments: [:])
                let task = try await tx.createTask(generationToolKind, input: GenerationToolInput(assistant: assistant.id, callId: call.id), options: .init(ownership: .task(taskId: generation)))
                let result = try await appendGenerationToolError(tx: tx, conversationId: opened.root.id, call: call, code: "fixture", text: "fixture", now: 1)
                tools.append(task); slots.append(ToolSlot(callId: call.id, name: call.name, taskId: task, status: .done, entry: result.id))
            }
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: generation, inputs: [submission.id])))
            try live.set("tools", JSONValue(encoding: slots))
            return (submission.id, assistant.id, generation, tools)
        }, context: .background)
        try await opened.root.commit({ tx in
            let parent = try #require(await tx.task(ids.2))
            var records: [TaskRecord] = []
            for task in ids.3 { records.append(try #require(await tx.task(task))) }
            for (index, record) in records.enumerated() {
                let control = ToolControl(addTools: ["new"], terminate: true, handoff: handoff ? ["first", "last"][index] : nil)
                try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: .object(["control": try JSONValue(encoding: control)])))))
            }
            try tx.setTask(parent.replacing(state: generationTask.waiting(GenerationCheckpoint(phase: .tools, assistant: ids.1, tools: ids.3, pending: []), on: ids.3, policy: .allSettled)))
        }, context: .background)
        let submission = try #require(await opened.harness.submission(id: ids.0, context: .background))
        #expect(try await submission.wait(context: .background).answer == ids.1)
        #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["old", "new"])
        let entries = try await allEntries(opened.root)
        if handoff {
            let reset = try #require(entries.last { $0.kind == resetEntry.kind })
            #expect(try textOf(reset.messages()?.first) == "last")
        } else { #expect(!entries.contains { $0.kind == resetEntry.kind }) }
        #expect(seen.withLock { $0.count } == 2)
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func unavailableOnlyRoundContinuesWithoutToolTasks() async throws {
        let setup = HarnessChatSetup(), seen = Mutex<[EntryID]>([])
        try setup.registry.install(Extension(name: "hooks", hooks: [hook(GenerationHooks(afterTools: { _, results, _, _ in seen.withLock { $0 = results } }))]))
        var message = chatAssistant("", reason: .toolUse)
        message.content = [.toolCall(ToolCall(id: "missing", name: "absent", arguments: [:]))]
        setup.models.setResponses([.message(message), .message(chatAssistant("final"))])
        let opened = try await openChat(setup: setup)
        let submission = try await generationSubmit(opened).wait(context: .background)
        #expect(submission.status == "done")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant", "pi.tool-result", "pi.assistant"])
        #expect(seen.withLock { $0 } == [entries[2].id])
        #expect(submission.answer == entries[3].id)
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 10) }, context: .background)
        #expect(tasks.items.count == 2 && tasks.items.allSatisfy { $0.kind == "pi.generation" })
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    @Test func overflowCreatesOwnedBlockedCompaction() async throws {
        let setup = HarnessChatSetup(settings: .init(compaction: .init(reserveTokens: 0, keepRecentTokens: 1, backgroundTokens: 0)))
        setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "maximum context length exceeded"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.commit({ tx in
            _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(UserMessage(content: .text("old history"), timestamp: 1))])))
        }, context: .background)
        let submission = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.compactions?.first?.reason == .overflow }
        let live = try #require(await generationLive(opened)), compaction = try #require(live.compactions?.first)
        let child = try #require(await opened.harness.getTask(id: compaction.taskId, context: .background))
        #expect(child.kind == "pi.compaction" && child.owner == live.run?.taskId)
        #expect(compaction.blocking && child.state.status == "pending")
        #expect(live.generation == nil)
        try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).reason == "aborted")
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

}
