import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func structuredEventTasks(_ chat: OpenChatResult) async throws -> [TaskRecord] {
    try await chat.root.commit({ tx in
        try await tx.scanTasks(.init(conversationId: chat.root.id), limit: 100).items
    }, context: .background)
}
private func structuredLabels(_ log: HarnessEventLog) -> [String] {
    log.events.compactMap { event in
        if event["type"] == "tool_execution_end", let id = event["toolCallId"]?.stringValue {
            return "end:\(id):\(event["entry"] != nil)"
        }
        if event["type"] == "message_end", let message = event["entry"]?["model"]?[0],
           message["role"] == "toolResult", let id = message["toolCallId"]?.stringValue {
            return "result:\(id)"
        }
        return nil
    }
}

@Suite struct HarnessStructuredEventTests {
    // upstream harness-structured.test.ts:1091 and :1599.
    @Test func turnEndsAtGenerationHoldAndDoesNotRepeatForALateStream() async throws {
        let clock = TestClock(now: 0), setup = HarnessChatSetup(clock: clock)
        let reference = Mutex<Harness?>(nil), childIDs = SessionTestLog<TaskID>()
        let child = harnessOneStep("test.event-hooked") { _, runtime, context in
            try await runtime.sleep(until: 100, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        try setup.registry.install(Extension(name: "event-children", tasks: [AnyTaskDefinition(child)]))
        try installHarnessTool(harnessTestTool("noop"), setup: setup)
        try setup.registry.install(Extension(name: "event-hooks", hooks: [hook(GenerationHooks(afterTools: { _, _, api, context in
            let harness = try #require(reference.withLock { $0 })
            let id = try await harness.commit({ tx in
                try await tx.createTask(child, input: 0,
                    options: .init(ownership: .task(taskId: api.taskId), conversationId: api.conversationId))
            }, context: context)
            childIDs.append(id)
        }))]))
        setup.models.setResponses([.message(try toolCalls([("noop", [:], "c1")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        reference.withLock { $0 = chat.harness }
        let (early, earlyLog) = try await eventListen(chat)
        let submission = try await chat.root.submit(.input(content: .text("go")), context: .background)
        #expect(try await submission.wait(context: .background).status == "done")
        let generations = try await structuredEventTasks(chat).filter { $0.kind == "pi.generation" }.sorted { $0.id < $1.id }
        let first = try #require(generations.first)
        #expect(generations.count == 2 && first.state.status == "completing")
        try await earlyLog.waitForType("turn_end", count: 2)
        #expect(earlyLog.types.filter { $0.hasPrefix("turn_") } == ["turn_start", "turn_end", "turn_start", "turn_end"])
        let (late, lateLog) = try await eventListen(chat)
        clock.advance(by: 100)
        #expect(try await chat.harness.waitForTask(id: first.id, context: .background).outcome.status == "completed")
        #expect(try await chat.harness.waitForTask(id: #require(childIDs.values.first), context: .background).outcome.status == "completed")
        _ = try await chat.root.commit({ tx in try await tx.appendEntry(chat.root.id, value: .init(kind: "note")) }, context: .background)
        try await lateLog.waitForType("entry_appended")
        await early.waitUntilIdle(); await late.waitUntilIdle()
        #expect(earlyLog.types.filter { $0 == "turn_end" }.count == 2)
        #expect(!lateLog.types.contains("turn_end"))
        _ = await early.stop(); _ = await late.stop()
        try await chat.harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:1574.
    @Test func abortedSequentialRoundEndsEveryCallImmediatelyBeforeItsResult() async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential)), started = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("one", execute: { _, _, context in
            started.signal()
            try await harnessToolAwaitAbort(context)
            return .init(content: [])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("two", execute: { _, _, _ in
            Issue.record("An unstarted sequential call ran")
            return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("one", [:], "c1"), ("two", [:], "c2"), ("two", [:], "c3")]))])
        let chat = try await openChat(setup: setup), (stream, log) = try await eventListen(chat)
        let submission = try await chat.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let live = try #require(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background))
        #expect(live.tools?.map { $0.taskId != nil } == [true, false, false])
        _ = try await chat.harness.abortTask(id: #require(live.run?.taskId), context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        try await eventually { structuredLabels(log).contains("result:c3") }
        #expect(structuredLabels(log) == ["end:c1:true", "result:c1", "end:c2:true", "result:c2", "end:c3:true", "result:c3"])
        _ = await stream.stop()
        try await chat.harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:1636 and :1673.
    // Swift cannot put a function in JSON. Nonfinite Usage rejects the final commit instead.
    @Test(arguments: [false, true])
    func ownedWorkHoldsToolSettlementAndFaultEvents(_ fault: Bool) async throws {
        let clock = TestClock(now: 0), setup = HarnessChatSetup(clock: clock)
        let abortEntered = HarnessChatSignal(), releaseAbort = SessionTestGate(), childIDs = SessionTestLog<TaskID>()
        defer { releaseAbort.release() }
        let child = harnessOneStep("test.event-owned", run: { _, runtime, context in
            try await runtime.sleep(until: 100, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }, abort: { _, runtime, context in
            abortEntered.signal(); await releaseAbort.wait()
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
        })
        try setup.registry.install(Extension(name: "event-owned", tasks: [AnyTaskDefinition(child)]))
        try installHarnessTool(harnessTestTool(fault ? "broken" : "delegate", execute: { _, api, context in
            let id: TaskID
            if fault {
                id = try await api.createTask(child, input: 0, options: .init(ownership: .task(taskId: api.taskId)), context: context)
            } else {
                id = try await api.commit({ tx in
                    let conversation = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                    return try await tx.createTask(child, input: 0,
                        options: .init(ownership: .conversation(), conversationId: conversation.id))
                }, context: context)
            }
            childIDs.append(id)
            // Reserve and launch child work before a fault can request its abort.
            try await eventually { clock.pendingSleeperCount == 1 }
            if fault {
                var usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
                usage.cost.total = .nan
                return .init(content: [], usage: usage)
            }
            return .init(content: [.text(TextContent(text: "started"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([(fault ? "broken" : "delegate", [:], "c1")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup), (stream, log) = try await eventListen(chat)
        let submission = try await chat.root.submit(.input(content: .text("go")), context: .background)
        if fault { await abortEntered.wait() }
        try await eventually { try await structuredEventTasks(chat).contains { $0.kind == "pi.tool" && $0.state.status == "completing" } }
        let tool = try #require(try await structuredEventTasks(chat).first { $0.kind == "pi.tool" })
        let live = try #require(try await chat.harness.snapshot(LiveDoc, conversationId: chat.root.id, context: .background))
        let slot = try #require(live.tools?.first)
        if fault {
            guard case .completing(let outcome, _) = tool.state else { Issue.record("Expected held fault"); return }
            #expect(outcome.status == "faulted" && slot.status != .done && slot.entry == nil)
            await stream.waitUntilIdle()
            #expect(!log.types.contains("task_failed"))
            releaseAbort.release()
        } else {
            #expect(slot.status == .done && slot.entry != nil)
            #expect(try await chat.harness.getTask(id: #require(live.run?.taskId), context: .background)?.state.status == "waiting")
            try await eventually { structuredLabels(log).contains("end:c1:true") }
            #expect(try await submission.status(context: .background).status == "placed")
            clock.advance(by: 100)
        }
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await chat.harness.waitForTask(id: tool.id, context: .background).outcome.status == (fault ? "faulted" : "completed"))
        if fault {
            try await log.waitForType("task_failed")
            #expect(structuredLabels(log).contains("end:c1:false"))
        }
        _ = await stream.stop()
        try await chat.harness.close(context: .background)
    }
}
