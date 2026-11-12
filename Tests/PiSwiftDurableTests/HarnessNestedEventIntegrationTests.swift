// v1.5.2 D4: harness-view-run.test.ts:122–173 uses live nested/tool state and stored results.
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessNestedAdmissionTests {
    /// Upstream harness-nested-tools.test.ts:432; nested state, task identity, result channel, and event order.
    /// Upstream harness-nested-tools.test.ts:134; use a fresh context so the durable abort mark rejects admission.
    @Test func abortedCallerCannotAdmitNestedCallOrCreateItsDocument() async throws {
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), marked = HarnessChatSignal()
        defer { marked.signal() }
        let caller = Mutex<TaskID?>(nil), rejected = Mutex<String?>(nil), runs = Mutex(0)
        try installHarnessTool(harnessTestTool("echo", execute: { _, _, _ in
            runs.withLock { $0 += 1 }; return .init(output: [])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("late", execute: { _, api, _ in
            caller.withLock { $0 = api.taskId }; started.signal(); await marked.wait()
            do { _ = try await api.executeTool("echo", arguments: ["text": "a"], context: .background) }
            catch { rejected.withLock { $0 = toolErrorText(error) } }
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("late", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), input = try await generationSubmit(opened)
        await started.wait()
        let id = try #require(caller.withLock { $0 })
        try await opened.root.commit({ tx in
            guard let task = try await tx.task(id) else { throw TaskDefinitionError("Missing caller") }
            try tx.setTask(task.replacing(abortRequested: true))
        }, context: .background)
        marked.signal(); _ = try await input.wait(context: .background)
        let message = try #require(rejected.withLock { $0 })
        #expect(message.contains("abort mark") || message.contains("aborted") || message.contains("has settled"))
        #expect(runs.withLock { $0 } == 0)
        #expect(try await opened.harness.snapshot(NestedCallDoc, taskId: id, key: "1", context: .background) == nil)
        #expect(try await generationLive(opened)?.nestedTools == nil)
        try await opened.harness.close(context: .background)
    }

    /// Upstream harness-nested-tools.test.ts:724, with the admission commit held at the storage boundary.
    @Test func returnedCallerWaitsForHeldAdmissionThenAbortsItsNestedCall() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup()
        let warm = HarnessChatSignal(), launch = HarnessChatSignal(), held = HarnessChatSignal(), returned = HarnessChatSignal()
        let saved = Mutex<ToolExecutionApi?>(nil)
        try installHarnessTool(harnessTestTool("echo"), setup: setup)
        try installHarnessTool(harnessTestTool("hang", execute: { _, _, context in
            try await harnessToolAwaitAbort(context); return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            _ = try await api.executeTool("echo", arguments: [:], context: context, options: .init(key: "warm"))
            saved.withLock { $0 = api }; warm.signal(); await launch.wait()
            _ = Task { _ = try await api.executeTool("hang", arguments: [:], context: context, options: .init(key: "late")) }
            await held.wait(); returned.signal(); return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(storage: storage, setup: setup), input = try await generationSubmit(opened)
        await warm.wait()
        let gate = await storage.holdCommits()
        defer { _ = Task { await gate.release() } }
        launch.signal(); await gate.waitUntilEntered(); held.signal(); await returned.wait()
        let api = try #require(saved.withLock { $0 })
        // API reports must close as soon as execute returns, even while admission cleanup waits.
        try await eventually {
            do { _ = try api.retainedOutput(); return false } catch { return true }
        }
        await gate.release()
        _ = try await input.wait(context: .background)
        let tasks = try await opened.harness.commit({ tx in
            try await tx.scanTasks(.init(conversationId: opened.root.id, kind: "pi.tool"), limit: 100).items
        }, context: .background)
        let late = try #require(tasks.first { $0.input["kind"] == "nested" && $0.input["key"] == "late" })
        #expect(late.state.status == "terminal")
        if case .terminal(let outcome, _) = late.state { #expect(outcome.status == "aborted") }
        else { Issue.record("Nested call did not end") }
        #expect(try JSONValue(encoding: await generationLive(opened)) == [:])
        try await opened.harness.close(context: .background)
    }

}
