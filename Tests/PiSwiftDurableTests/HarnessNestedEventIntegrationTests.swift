import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessNestedEventIntegrationTests {
    /// Upstream harness-nested-tools.test.ts:432; nested state, task identity, result channel, and event order.
    @Test func liveNestedEventsCarryParentAndResultBeforeParentEnd() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        let ids = Mutex<[TaskID]>([])
        try installHarnessTool(harnessTestTool("slow", execute: { _, api, context in
            ids.withLock { $0.append(api.taskId) }
            try api.output(.text("working\n"), nil)
            try await api.details(["step": 1], context)
            running.signal(); await release.wait()
            return .init(output: [.text(.init(text: "slow done"))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            ids.withLock { $0.append(api.taskId) }
            let result = try await api.executeTool("slow", arguments: [:], context: context)
            return .init(output: [.text(.init(text: result.structuredOutput?.stringValue ?? "missing"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "model/opaque/id")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        #expect(stream.snapshot.nestedTools.isEmpty)
        let input = try await generationSubmit(opened)
        await running.wait(); try await log.waitForType("tool_execution_update")
        let live = try #require(await generationLive(opened)), slot = try #require(live.nestedTools?.first)
        #expect(slot.callId == "model/opaque/id/1" && slot.parentCallId == "model/opaque/id")
        #expect(slot.status == .running && slot.output == "working\n" && slot.details == ["step": 1])
        #expect(slot.parentTaskId == ids.withLock { $0[0] } && slot.taskId == ids.withLock { $0[1] })
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        let toolEvents = log.events.filter { $0["type"] == "tool_execution_start" || $0["type"] == "tool_execution_end" }
        #expect(toolEvents.compactMap { $0["toolCallId"]?.stringValue } == ["model/opaque/id", "model/opaque/id/1", "model/opaque/id/1", "model/opaque/id"])
        let end = try #require(toolEvents.first { $0["type"] == "tool_execution_end" && $0["toolCallId"] == "model/opaque/id/1" })
        #expect(end["parentTaskId"] == .number(Double(slot.parentTaskId.rawValue)) && end["taskId"] == .number(Double(slot.taskId.rawValue)))
        #expect(end["result"]?["structuredOutput"] == "slow done" && end["entry"] == nil)
        #expect(log.events.contains { $0["type"] == "tool_execution_update" && $0["toolCallId"] == "model/opaque/id/1" && $0["parentToolCallId"] == "model/opaque/id" })
        let results = try harnessToolResults(await allEntries(opened.root))
        #expect(results.count == 1 && results[0].toolCallId == "model/opaque/id" && harnessToolText(results[0]) == "slow done")
        #expect(try JSONValue(encoding: await generationLive(opened)) == [:])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    /// Upstream harness-nested-tools.test.ts:861; acquire live slots, then match each update to its current index.
    @Test func lateWatchGetsBothNestedSlotsAndSecondOutputFirst() async throws {
        let setup = HarnessChatSetup(), first = HarnessChatSignal(), second = HarnessChatSignal()
        let writeFirst = HarnessChatSignal(), writeSecond = HarnessChatSignal(), release = HarnessChatSignal()
        defer { writeFirst.signal(); writeSecond.signal(); release.signal() }
        try installHarnessTool(harnessTestTool("slow", execute: { args, api, context in
            let name = args["text"]?.stringValue ?? ""
            if name == "one" { first.signal(); await writeFirst.wait() }
            else { second.signal(); await writeSecond.wait() }
            try api.output(.text(name + "\n"), nil)
            try await api.details(["name": .string(name)], context)
            await release.wait(); return .init(output: [])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            async let a = api.executeTool("slow", arguments: ["text": "one"], context: context, options: .init(key: "a"))
            async let b = api.executeTool("slow", arguments: ["text": "two"], context: context, options: .init(key: "b"))
            _ = try await (a, b); return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), input = try await generationSubmit(opened)
        await first.wait(); await second.wait()
        let (stream, log) = try await eventListen(opened)
        #expect(Set(stream.snapshot.nestedTools.map(\.callId)) == ["c1/a", "c1/b"])
        writeSecond.signal(); try await log.waitForType("tool_execution_update")
        writeFirst.signal(); try await log.waitForType("tool_execution_update", count: 2)
        let updates = log.events.filter { $0["type"] == "tool_execution_update" && $0["output"] != nil }
        #expect(updates.compactMap { $0["toolCallId"]?.stringValue } == ["c1/b", "c1/a"])
        #expect(updates.compactMap { $0["output"]?["set"]?.stringValue } == ["two\n", "one\n"])
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    /// Upstream harness-nested-tools.test.ts:920; suppress stored progress while the program receives the result.
    @Test func progressFalseKeepsOnlyStatusAndReturnsOutputDetailsAndDiagnostics() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal(), release = HarnessChatSignal()
        defer { release.signal() }
        let returned = Mutex<NestedToolExecutionResult?>(nil)
        try installHarnessTool(harnessTestTool("chatty", execute: { _, api, context in
            try api.output(.text("line\n"), nil)
            try api.diagnostic(.init(severity: .info, message: "note"))
            try await api.details(["step": 1], context)
            running.signal(); await release.wait(); return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            let result = try await api.executeTool("chatty", arguments: [:], context: context, options: .init(progress: false))
            returned.withLock { $0 = result }; return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened); await running.wait()
        let slot = try #require(await generationLive(opened)?.nestedTools?.first)
        #expect(slot.status == .running && slot.output == nil && slot.details == nil && slot.diagnostics == nil)
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        let result = try #require(returned.withLock { $0 })
        #expect(result.structuredOutput == "line\n" && result.details == ["step": 1])
        #expect(result.diagnostics == [.init(severity: .info, message: "note")])
        #expect(!log.events.contains { $0["type"] == "tool_execution_update" && $0["toolCallId"] == "c1/1" })
        #expect(try log.events.first { $0["type"] == "tool_execution_end" && $0["toolCallId"] == "c1/1" }?["result"]?.decode(NestedToolExecutionResult.self) == result)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    /// Upstream harness-nested-tools.test.ts:968; the abort result cannot restore progress that was never stored.
    @Test func progressFalseAbortHasNoOutputOrDetailsAndEndsBeforeParent() async throws {
        let setup = HarnessChatSetup(), running = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("chatty", execute: { _, api, context in
            try api.output(.text("line\n"), nil)
            try api.diagnostic(.init(severity: .info, message: "note"))
            try await api.details(["step": 1], context)
            running.signal(); try await harnessToolAwaitAbort(context); return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("batch", execute: { _, api, context in
            _ = Task { _ = try await api.executeTool("chatty", arguments: [:], context: context, options: .init(progress: false)) }
            await running.wait(); return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("batch", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened); _ = try await input.wait(context: .background)
        try await log.waitForDone(input.id)
        let ends = log.events.filter { $0["type"] == "tool_execution_end" }
        #expect(ends.compactMap { $0["toolCallId"]?.stringValue } == ["c1/1", "c1"])
        let result = try #require(try ends.first?["result"]?.decode(NestedToolExecutionResult.self))
        #expect(result.isError && result.structuredOutput == nil && result.details == nil)
        #expect(result.diagnostics.compactMap(\.code) == ["aborted"])
        #expect(try JSONValue(encoding: await generationLive(opened)) == [:])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }
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
