import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessToolLifetimeTests {
    // harness-tools.test.ts:432. Hook time must not be part of execute time.
    @Test func executeDurationExcludesBlockedCalls() async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential)), time = Mutex<Duration>(.zero)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            time.withLock { $0 += .milliseconds(30) }; return .init(content: [])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("thrower", execute: { _, _, _ in
            time.withLock { $0 += .milliseconds(45) }; throw TaskDefinitionError("boom")
        }), setup: setup)
        try setup.registry.install(Extension(name: "audit", hooks: [hook(ToolHooks(beforeTool: { call, _, _ in
            time.withLock { $0 += .milliseconds(100) }; return call.id == "blocked" ? .init(block: "no") : nil
        }, afterTool: { _, _, _, _ in time.withLock { $0 += .milliseconds(200) }; return nil }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "run"), ("thrower", [:], "thrower"), ("echo", [:], "blocked")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        opened.harness.tasks.toolServices.setExecutionTime { time.withLock { $0 } }
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let results = try harnessToolResults(await allEntries(opened.root))
        #expect(results.first { $0.toolCallId == "run" }?.durationMs == 30)
        #expect(results.first { $0.toolCallId == "thrower" }?.durationMs == 45)
        #expect(results.first { $0.toolCallId == "blocked" }?.durationMs == nil)
        #expect(results.first { $0.toolCallId == "thrower" }?.isError == true)
        try await opened.harness.close(context: .background)
    }
    // :598. An installed but deselected hook must not run.
    @Test func selectedHooks() async throws {
        let setup = HarnessChatSetup(), seen = Mutex<[ConversationID]>([])
        let tool = try harnessTestTool()
        let tools = Extension(name: "tools", tools: [tool])
        let audit = Extension(name: "audit", hooks: [hook(ToolHooks(beforeTool: { _, api, _ in seen.withLock { $0.append(api.conversationId) }; return nil }))])
        try setup.registry.install(tools); try setup.registry.install(audit)
        setup.updateSettings { $0.extensions = [tools] }
        let (opened, _) = try await runHarnessTools(setup)
        #expect(seen.withLock { $0.isEmpty })
        try await opened.root.configure(change: .init(extensions: .set(.edit(add: [audit]))), context: .background)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "again")])), .message(chatAssistant("done"))])
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(seen.withLock { $0 } == [opened.root.id])
        let owner = harnessOneStep("test.selection-owner") { _, _, _ in }
        let childId = try await opened.root.commit({ tx in
            let taskId = try await tx.createTask(owner, input: 0, options: .init(ownership: .conversation(), conversationId: opened.root.id))
            return try await tx.createConversation(ownership: .task(taskId: taskId)).id
        }, context: .background)
        let child = try #require(await opened.harness.conversation(id: childId, context: .background))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "child")])), .message(chatAssistant("done"))])
        _ = try await child.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(seen.withLock { $0 } == [opened.root.id, child.id])
        let other = try await opened.harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "other")])), .message(chatAssistant("done"))])
        _ = try await other.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(seen.withLock { $0 } == [opened.root.id, child.id])
        try await opened.harness.close(context: .background)
    }
    // :800,1102. Tool commits, memo writes and read watches are invocation-bound.
    @Test func runtimeOperationsAndLifetime() async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential)), retained = Mutex<ToolExecutionApi?>(nil)
        let cwds = Mutex<[String?]>([]), targets = Mutex<[(ConversationID, String?)]>([])
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            retained.withLock { $0 = api }; cwds.withLock { $0.append(api.env?.cwd) }
            #expect(try await api.agent(context).tools.map(\.name) == ["echo"])
            #expect(api.registry.extension(name: "tool:echo") != nil)
            let entry = try await api.commit({ tx in
                try await configure(tx: tx, conversationId: api.conversationId, change: .init(cwd: .set("/")))
                return try await tx.appendEntry(api.conversationId, value: .init(kind: "test.note", data: ["call": .string(api.callId)]))
            }, context: context)
            #expect(entry.byTaskId == api.taskId)
            let firstMemo = try await api.memo("m", 1, context), secondMemo = try await api.memo("m", 2, context)
            #expect(firstMemo == .number(1) && secondMemo == .number(1))
            return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "first"), ("echo", [:], "second")])), .message(chatAssistant("done"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
            settings: setup.settingsProvider, env: { target, _ in
                targets.withLock { $0.append((target.conversationId, target.cwd)) }; return HarnessToolEnvironment(cwd: target.cwd ?? "/tmp")
            }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")), cwd: .set("/tmp"))), context: .background)
        _ = try await root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(cwds.withLock { $0 } == ["/tmp", "/"])
        #expect(targets.withLock { $0.contains { $0.0 == root.id && $0.1 == "/tmp" } })
        #expect(targets.withLock { $0.contains { $0.0 == root.id && $0.1 == "/" } })
        let api = try #require(retained.withLock { $0 })
        await #expect(throws: (any Error).self) { _ = try await api.commit({ _ in 1 }, context: .background) }
        await #expect(throws: (any Error).self) { _ = try await api.watchDoc(LiveDoc, conversationId: api.conversationId, context: .background) }
        try await harness.close(context: .background)
    }
    // :854. Use an injected failing environment; no shell is needed.
    @Test func environmentFailure() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
            env: { _, _ in throw TaskDefinitionError("no sandbox") }, onReport: { setup.reports.append($0) }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        #expect(try await root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let result = try #require(harnessToolResults(await allEntries(root)).first)
        #expect(result.isError && harnessToolText(result) == "<harness>\n[error] no sandbox\n</harness>")
        #expect(setup.reports.values.filter { String(describing: $0).contains("no sandbox") }.count == 2)
        try await harness.close(context: .background)
    }
    // :1131,1163. Abort after output is durable; buffered output must not reach the result.
    @Test(arguments: [false, true]) func abortPreservesDurableOutput(afterHook: Bool) async throws {
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 60_000)), clock: TestClock()), reached = HarnessChatSignal()
        let pending = Mutex<Task<Void, any Error>?>(nil)
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            try api.output(.text("durable\n"), nil)
            try await eventually { try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)?.tools?.first?.output == "durable\n" }
            try api.output(.text("buffered\n"), nil)
            if afterHook {
                let task = Task { try await api.details(["pending": true], .background) }; pending.withLock { $0 = task }
                try await eventually { api.pendingDetailsCount() == 1 }
                return .init()
            }
            reached.signal()
            try await harnessToolAwaitAbort(context); throw CancellationError()
        }), setup: setup)
        if afterHook { try setup.registry.install(Extension(name: "after", hooks: [hook(ToolHooks(afterTool: { _, _, _, context in
            reached.signal(); try await harnessToolAwaitAbort(context); throw CancellationError()
        }))])) }
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await reached.wait()
        let task = try #require(await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)?.tools?.first?.taskId)
        _ = try await opened.harness.abortTask(id: task, context: .background)
        #expect(try await submission.wait(context: .background).status == "done")
        let text = harnessToolText(try #require(harnessToolResults(await allEntries(opened.root)).first))
        #expect(text == "durable\n|<harness>\n[error] Tool echo was aborted\n</harness>")
        if let pending = pending.withLock({ $0 }) { await #expect(throws: (any Error).self) { try await pending.value } }
        try await opened.harness.close(context: .background)
    }
    // :800 child tasks and :1102 detached waits and watches.
    @Test func childTaskAndDetachedWait() async throws {
        let setup = HarnessChatSetup(), detached = Mutex<Task<SettledTask, any Error>?>(nil), retainedWatch = Mutex<CommittedWatch<LiveState?>?>(nil)
        let child = harnessOneStep("test.tool-child") { task, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(Double(task.input)))) }, context: context)
        }
        let never = harnessOneStep("test.tool-never") { _, _, _ in }
        try setup.registry.install(Extension(name: "child", tasks: [child.eraseToAnyTaskDefinition()]))
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            let id = try await api.createTask(child.kind, input: 42, options: .init(ownership: .conversation()), context: context)
            #expect(try await api.waitForTask(id: id, context: context).outcome == .completed(result: .number(42)))
            let pending = try await api.createTask(never.kind, input: 0, options: .init(ownership: .conversation()), context: context)
            let wait = Task { try await api.waitForTask(id: pending, context: context) }
            detached.withLock { $0 = wait }
            retainedWatch.withLock { $0 = nil }
            let watch = try await api.watchDoc(LiveDoc, conversationId: api.conversationId, context: context)
            retainedWatch.withLock { $0 = watch }
            return .init(content: [])
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup)
        let wait = try #require(detached.withLock { $0 })
        do { _ = try await wait.value; Issue.record("Invocation-bound task wait returned") }
        catch { #expect(String(describing: error).contains("invocation has ended")) }
        let watch = try #require(retainedWatch.withLock { $0 })
        _ = await watch.closed
        try await opened.harness.close(context: .background)
    }

}
