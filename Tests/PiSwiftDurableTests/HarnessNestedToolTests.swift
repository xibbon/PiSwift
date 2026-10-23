import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

func d4bToolTasks(_ harness: Harness) async throws -> [TaskRecord] {
    try await harness.storage.scanTasks(.init(), limit: 1000, cursor: nil, context: .background).items.filter { $0.kind == "pi.tool" }.sorted { $0.id < $1.id }
}

@Suite struct HarnessNestedToolTests {
    // harness-nested-tools:99,172,216,298,321,648. Each key has its own family member.
    @Test func keyedCallsHaveOwnTasksSmallReceiptsAndNoTranscript() async throws {
        let setup = HarnessChatSetup(), runs = Mutex(0), captured = Mutex<[NestedToolExecutionResult]>([])
        let parentID = Mutex<TaskID?>(nil)
        try installHarnessTool(harnessTestTool("pair", execute: { _, _, _ in
            runs.withLock { $0 += 1 }; return .init(output: [.text(.init(text: "pair"))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            parentID.withLock { $0 = api.taskId }
            async let a = api.executeTool("pair", arguments: ["a": 1, "b": 2], context: context, options: .init(key: "same"))
            async let b = api.executeTool("pair", arguments: ["b": 2, "a": 1], context: context, options: .init(key: "same"))
            let values = try await [a, b]
            #expect(values[0] == values[1])
            let again = try await api.executeTool("pair", arguments: ["b": 2, "a": 1], context: context, options: .init(key: "same"))
            #expect(again == values[0])
            let other = try await api.executeTool("pair", arguments: [:], context: context)
            let state = try #require(try await api.snapshot(NestedCallDoc, taskId: api.taskId, key: "same", context: context))
            #expect(state.taskId == again.taskId && state.result == again)
            #expect(try await api.getTask(id: api.taskId, context: context)?.memos?["pi.tool.madeNestedCalls"] == true)
            captured.withLock { $0 = [again, other] }
            do {
                _ = try await api.executeTool("pair", arguments: ["a": 3], context: context, options: .init(key: "same"))
                Issue.record("A key conflict must throw")
            } catch { #expect(String(describing: error).contains("already made with another tool or other arguments")) }
            return .init(output: [.text(.init(text: "parent"))])
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup, calls: [("batch", [:], "opaque/parent")])
        let tasks = try await d4bToolTasks(opened.harness)
        #expect(runs.withLock { $0 } == 2)
        #expect(tasks.count == 3)
        let parent = try #require(parentID.withLock { $0 })
        for child in tasks.dropFirst() {
            #expect(child.owner == parent)
            #expect(child.input["kind"] == "nested")
            #expect(child.input["parentCallId"] == "opaque/parent")
            #expect(child.abandonOnRestart == true)
            guard case .terminal(.completed(let value, _), _) = child.state else { Issue.record("Expected child receipt"); continue }
            #expect(value == ["kind": "nested"])
        }
        #expect(captured.withLock { $0 }.allSatisfy { $0.structuredOutput == "pair" && !$0.isError && $0.durationMs != nil })
        #expect(try harnessToolResults(entries).count == 1)
        #expect(try harnessToolText(#require(harnessToolResults(entries).first)) == "parent")
        #expect(try await opened.harness.snapshot(NestedCallDoc, taskId: parent, key: "same", context: .background) == nil)
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    // :242,278. Hooks receive the immediate parent; rejected calls do not execute.
    @Test func hooksSeeParentAndCallsValidateBeforeExecution() async throws {
        let setup = HarnessChatSetup(), parents = Mutex<[ToolHookParent?]>([]), results = Mutex<[NestedToolExecutionResult]>([]), runs = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in runs.withLock { $0 += 1 }; return .init() }), setup: setup)
        try setup.registry.install(Extension(name: "nested-hooks", hooks: [hook(ToolHooks(beforeTool: { call, _, _ in
            parents.withLock { $0.append(call.parent) }
            return call.parent != nil && call.arguments["text"]?.value as? String == "secret" ? .init(block: "no secrets") : nil
        }, afterTool: { call, result, _, _ in
            guard call.parent != nil else { return nil }
            var replacement = result; replacement.output = [.text(.init(text: "rewritten"))]; return replacement
        }))]))
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            var values: [NestedToolExecutionResult] = []
            let calls: [(String, JSONObject)] = [("echo", ["text": "secret"]), ("echo", ["text": "public"]), ("missing", [:]), ("echo", ["text": [:]])]
            for (name, args) in calls {
                values.append(try await api.executeTool(name, arguments: args, context: context))
            }
            results.withLock { $0 = values }; return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let values = results.withLock { $0 }
        #expect(values.map { $0.diagnostics.first?.code } == ["blocked", nil, "tool_unavailable", "invalid_arguments"])
        #expect(values[1].structuredOutput == "rewritten")
        #expect(runs.withLock { $0 } == 1)
        let seen = parents.withLock { $0 }
        #expect(seen.count == 3 && seen[0] == nil)
        let parent = try #require(try await d4bToolTasks(opened.harness).first)
        #expect(seen.dropFirst().allSatisfy { $0?.callId == "c1" && $0?.taskId == parent.id })
        try await opened.harness.close(context: .background)
    }

    // :614. An aborted wait leaves the admitted call running and allows reattachment.
    @Test func waitCancellationKeepsChildAndKeyResult() async throws {
        let setup = HarnessChatSetup(), cancel = AbortController(), release = HarnessChatSignal(), values = Mutex<[NestedToolExecutionResult]>([]), runs = Mutex(0)
        try installHarnessTool(harnessTestTool("slow", execute: { _, _, _ in
            runs.withLock { $0 += 1 }; cancel.abort(D2TestError("cancelled")); await release.wait()
            return .init(output: [.text(.init(text: "slow done"))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            do {
                _ = try await api.executeTool("slow", arguments: [:], context: context.withAbortSignal(cancel.signal), options: .init(key: "same"))
                Issue.record("The first wait must abort")
            } catch { #expect(cancel.signal.aborted) }
            release.signal()
            let value = try await api.executeTool("slow", arguments: [:], context: context, options: .init(key: "same"))
            values.withLock { $0.append(value) }; return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        #expect(runs.withLock { $0 } == 1)
        #expect(values.withLock { $0.first?.structuredOutput } == "slow done")
        #expect(try await d4bToolTasks(opened.harness).count == 2)
        try await opened.harness.close(context: .background)
    }

    // :351,510,542,750. Abort all owned nested calls before waiting for one.
    @Test(arguments: ["return", "throw", "abort"])
    func callerSettlementStopsLeftoverCalls(mode: String) async throws {
        let setup = HarnessChatSetup(), startedA = HarnessChatSignal(), startedB = HarnessChatSignal(), bAborted = HarnessChatSignal()
        let requests = Mutex<[Task<NestedToolExecutionResult, any Error>]>([])
        try installHarnessTool(harnessTestTool("a", execute: { _, _, _ in
            startedA.signal(); await bAborted.wait(); return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("b", execute: { _, api, context in
            try await api.details(["step": 1], context)
            startedB.signal()
            do { try await harnessToolAwaitAbort(context) } catch { bAborted.signal(); throw error }
            return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            let a = Task { try await api.executeTool("a", arguments: [:], context: context, options: .init(key: "a")) }
            let b = Task { try await api.executeTool("b", arguments: [:], context: context, options: .init(key: "b")) }
            requests.withLock { $0 = [a, b] }
            await startedA.wait(); await startedB.wait()
            if mode == "throw" { throw D2TestError("caller failed") }
            if mode == "abort" { try await harnessToolAwaitAbort(context) }
            return .init(output: [.text(.init(text: "returned early"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let submission = try await generationSubmit(opened)
        await startedA.wait(); await startedB.wait()
        if mode == "abort" { try await opened.root.abort(context: .background) }
        let settled = try await submission.wait(context: .background)
        #expect(settled.status == (mode == "abort" ? "unanswered" : "done"))
        let tasks = try await d4bToolTasks(opened.harness)
        #expect(tasks.count == 3)
        #expect(tasks.dropFirst().allSatisfy { $0.state.status == "terminal" })
        let b = try #require(tasks.first { $0.input["call"]?["name"] == "b" })
        guard case .terminal(let outcome, _) = b.state else { Issue.record("No terminal B"); return }
        #expect(outcome.status == "aborted")
        for task in requests.withLock({ $0 }) { _ = await task.result }
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    // :788. Explicit keys cannot overlap the implicit positive integer keys.
    @Test func checksExplicitKeysAndEndsSavedApi() async throws {
        let setup = HarnessChatSetup(), saved = Mutex<ToolExecutionApi?>(nil)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            saved.withLock { $0 = api }
            for key in ["", "a/b", "__proto__", "7", "12345"] {
                do { _ = try await api.executeTool("missing", arguments: [:], context: context, options: .init(key: key)); Issue.record("Invalid key accepted") }
                catch { #expect(String(describing: error).contains("must be non-empty, without")) }
            }
            for key in ["0", "01", "-1", "named", "😀"] {
                let result = try await api.executeTool("missing", arguments: [:], context: context, options: .init(key: key))
                #expect(result.diagnostics.first?.code == "tool_unavailable")
            }
            return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let api = try #require(saved.withLock { $0 })
        await #expect(throws: (any Error).self) { try await api.executeTool("missing", arguments: [:], context: .background) }
        #expect(try await d4bToolTasks(opened.harness).count == 6)
        try await opened.harness.close(context: .background)
    }

    // :406,814,1093,1187. Removing grandchildren does not break later sibling slot lookup.
    @Test func grandchildrenRetireBeforeSiblingsAndUsageIsRecordedOnce() async throws {
        let setup = HarnessChatSetup(), captured = Mutex<[NestedToolSlot]>([])
        let usage = Usage(input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3, cost: .init(input: 0.1, output: 0.2, total: 0.3))
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in .init(output: [.text(.init(text: "leaf"))], usage: usage) }), setup: setup)
        try installHarnessTool(harnessTestTool("inner", execute: { _, api, context in
            _ = try await api.executeTool("echo", arguments: [:], context: context)
            _ = try await api.executeTool("echo", arguments: [:], context: context)
            return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            for name in ["echo", "inner", "echo", "echo"] { _ = try await api.executeTool(name, arguments: [:], context: context) }
            let slots = try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)?.nestedTools ?? []
            captured.withLock { $0 = slots }; return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let slots = captured.withLock { $0 }
        #expect(slots.map(\.callId) == ["c1/1", "c1/2", "c1/3", "c1/4"])
        #expect(slots.allSatisfy { $0.status == .done && $0.summary?.isError == false && $0.output == nil && $0.details == nil })
        let total = try await opened.harness.snapshot(UsageDoc, conversationId: opened.root.id, context: .background)?.tools["echo"]
        #expect(total?.input == 5 && total?.output == 10)
        #expect(slots[0].summary?.usage?.input == 1)
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    // :1009,1065. The input keeps admitted arguments; the slot shows final, unbounded arguments.
    @Test func repairedAndHookArgumentsReachSlotAndCheckpoint() async throws {
        let setup = HarnessChatSetup(), pending = HarnessChatSignal(), release = HarnessChatSignal(), running = HarnessChatSignal(), finish = HarnessChatSignal()
        let large = String(repeating: "x", count: 65536), seen = Mutex<JSONValue?>(nil)
        try installHarnessTool(harnessTestTool("repaired", prepare: { _ in [:] }, execute: { args, _, _ in
            seen.withLock { $0 = args }; running.signal(); await finish.wait(); return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "repair-hook", hooks: [hook(ToolHooks(beforeTool: { call, _, _ in
            guard call.parent != nil else { return nil }; pending.signal(); await release.wait()
            return .init(arguments: ["text": .string(large)])
        }))]))
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            _ = try await api.executeTool("repaired", arguments: ["text": "asked"], context: context); return .init()
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), submission = try await generationSubmit(opened)
        await pending.wait()
        #expect(try await generationLive(opened)?.nestedTools?.first?.arguments == ["text": "asked"])
        release.signal(); await running.wait()
        let slot = try #require(try await generationLive(opened)?.nestedTools?.first)
        #expect(slot.arguments == ["text": .string(large)])
        #expect(seen.withLock { $0 } == ["text": .string(large)])
        let task = try #require(try await opened.harness.getTask(id: slot.taskId, context: .background))
        #expect(task.input["call"]?["arguments"] == ["text": "asked"])
        finish.signal(); _ = try await submission.wait(context: .background)
        try await opened.harness.close(context: .background)
    }

    // :1133,1161. Faulted children get a diagnostic fallback; thrown tools retain streamed text.
    @Test(arguments: [false, true])
    func thrownAndFaultedChildrenReturnProgramErrors(fault: Bool) async throws {
        let setup = HarnessChatSetup(), result = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(harnessTestTool("bad", execute: { _, api, _ in
            if fault { return .init(details: .number(.infinity)) }
            try api.output(.text("half way\n"), nil); throw D2TestError("broke")
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            let value = try await api.executeTool("bad", arguments: [:], context: context)
            result.withLock { $0 = value }; return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let value = try #require(result.withLock { $0 })
        #expect(value.isError)
        #expect(value.diagnostics.first?.code == (fault ? "faulted" : "tool_error"))
        #expect(value.structuredOutput == (fault ? nil : "half way\n"))
        if fault { #expect(value.details == nil && value.durationMs == nil) }
        try await opened.harness.close(context: .background)
    }
}

@Suite struct HarnessNestedToolDocumentTests {
    // :99 and :1065. Each member has a fixed call key and is changed only for that child.
    @Test func eachCallWritesOneMemberAndPreparedArgumentsCanOmitOptionalFields() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup(), seen = Mutex<[JSONValue]>([])
        try installHarnessTool(harnessTestTool("repaired", prepare: { _ in [:] }, execute: { args, _, _ in
            seen.withLock { $0.append(args) }; return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            _ = try await api.executeTool("repaired", arguments: ["text": "a"], context: context)
            _ = try await api.executeTool("repaired", arguments: ["text": "b"], context: context, options: .init(key: "named"))
            return .init()
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(storage: storage, setup: setup)
        _ = try await generationSubmit(opened).wait(context: .background)
        let writes = await storage.commits
        let members = writes.flatMap { $0 }.compactMap { write -> DocumentCreate? in
            if case .documentCreate(let record, _, _) = write, record.kind == NestedCallDoc.definition.kind { return record }; return nil
        }
        #expect(members.map(\.key) == ["1", "named"])
        #expect(seen.withLock { $0 } == [[:], [:]])
        let ids = Set(members.map(\.id))
        for batch in writes {
            let changed = batch.compactMap { write -> DocumentID? in
                if case .documentChange(let id, _, _) = write, ids.contains(id) { return id }; return nil
            }
            #expect(changed.count <= 1)
        }
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }

    // :1187. Finished slots retain small summaries until the caller settles.
    @Test func finishedSlotsKeepBoundedDiagnosticAndMixedOutputSummaries() async throws {
        let setup = HarnessChatSetup(), slots = Mutex<[NestedToolSlot]>([])
        try installHarnessTool(harnessTestTool("verbose", execute: { _, _, _ in
            .init(output: [.text(.init(text: "ignored"))], isError: true,
                  diagnostics: [.init(severity: .error, message: String(repeating: "e", count: 600))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("mixed", execute: { _, _, _ in
            .init(output: [.text(.init(text: "bad image")), .image(.init(data: "AAAA", mimeType: "image/png"))], isError: true)
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            let result = try await api.executeTool("verbose", arguments: [:], context: context)
            #expect(result.diagnostics.first?.message.count == 600)
            let mixed = try await api.executeTool("mixed", arguments: [:], context: context)
            #expect(mixed.structuredOutput?.arrayValue?.count == 2)
            let live = try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)
            slots.withLock { $0 = live?.nestedTools ?? [] }; return .init()
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        let captured = slots.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured[0].summary?.error == String(repeating: "e", count: 500))
        #expect(captured[1].summary?.error == "bad image")
        #expect(captured.allSatisfy { $0.status == .done && $0.summary?.durationMs != nil && $0.output == nil && $0.diagnostics == nil })
        #expect(try await generationLive(opened) == LiveState())
        try await opened.harness.close(context: .background)
    }
}

extension HarnessNestedToolDocumentTests {
    // generation.ts:640. A nested receipt cannot terminate, hand off, or add model tools.
    @Test func generationIgnoresControlInNestedReceipts() async throws {
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("continued"))])
        let opened = try await openChat(setup: setup)
        let seeded = try await opened.root.commit({ tx in
            let user = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(.init(content: .text("go"), timestamp: 1))])))
            let submission = try await tx.createSubmission(.input(conversationId: opened.root.id, state: .placed(entry: user.id)))
            let generation = try await createGeneration(tx: tx, conversationId: opened.root.id)
            let assistant = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: assistantEntry.kind,
                model: EntryRecord.encodeMessages([.assistant(chatAssistant("round", reason: .toolUse))])))
            let child = try await tx.createTask(toolTask, input: .model(assistant: assistant.id, callId: "synthetic"),
                options: .init(ownership: .task(taskId: generation)))
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: generation, inputs: [submission.id])))
            try live.set("tools", JSONValue(encoding: [ToolSlot(callId: "synthetic", name: "synthetic", taskId: child, status: .done)]))
            return (submission.id, generation, child, assistant.id)
        }, context: .background)
        try await opened.root.commit({ tx in
            let record = try #require(try await tx.task(seeded.2))
            let parent = try #require(try await tx.task(seeded.1))
            let receipt: JSONValue = ["kind": "nested", "control": ["terminate": true, "handoff": "ignored", "addTools": ["unavailable"]]]
            try tx.setTask(record.replacing(state: .terminal(outcome: .completed(result: receipt))))
            try tx.setTask(parent.replacing(state: generationTask.waiting(.init(phase: .tools, assistant: seeded.3,
                tools: [seeded.2], pending: []), on: [seeded.2], policy: .allSettled)))
        }, context: .background)
        let submission = try #require(try await opened.harness.submission(id: seeded.0, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        let entries = try await allEntries(opened.root)
        #expect(try textOf(entries.last?.messages()?.first) == "continued")
        #expect(!entries.contains { $0.kind == resetEntry.kind })
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.modelTools == nil)
        #expect(setup.reports.values.isEmpty)
        try await opened.harness.close(context: .background)
    }
}

extension HarnessNestedToolDocumentTests {
    @Test(arguments: [ToolReplay.safe, .unsafe])
    func toolCreatedTaskDefaultsFollowCallerReplayAndKeepExplicitPolicies(replay: ToolReplay) async throws {
        let setup = HarnessChatSetup(), saved = Mutex<[Bool]>([])
        let child = harnessOneStep("test.nested-defaults", run: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        })
        try setup.registry.install(Extension(name: "task-defaults", tasks: [child.eraseToAnyTaskDefinition()]))
        var caller = try harnessTestTool("batch", execute: { _, api, context in
            let policies: [Bool?] = [nil, false, true]
            var marks: [Bool] = []
            for policy in policies {
                let id = try await api.createTask(child, input: 1,
                    options: .init(ownership: .task(taskId: api.taskId), abandonOnRestart: policy), context: context)
                let record = try #require(try await api.getTask(id: id, context: context))
                marks.append(record.abandonOnRestart ?? false)
            }
            let independent = try await api.createTask(child, input: 2, options: .init(ownership: .conversation()), context: context)
            marks.append(try await api.getTask(id: independent, context: context)?.abandonOnRestart ?? false)
            saved.withLock { $0 = marks }
            return .init()
        })
        caller.replay = replay
        try installHarnessTool(caller, setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("batch", [:], "c1")])
        #expect(saved.withLock { $0 } == [replay == .unsafe, false, true, false])
        try await opened.harness.close(context: .background)
    }
}
