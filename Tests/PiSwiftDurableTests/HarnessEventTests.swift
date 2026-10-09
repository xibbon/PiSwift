import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessEventTests {
    @Test func lifecycleAndTextDeltasRebuildCommittedAnswer() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels())
        let opened = try await openChat(setup: setup, models: models), (stream, log) = try await eventListen(opened)
        #expect(stream.snapshot.entries.isEmpty && stream.snapshot.tools.isEmpty && stream.snapshot.inbox.isEmpty)
        let partials = SessionTestLog<JSONObject>()
        let subscription = try opened.harness.subscribeCommits { publication, _ in
            for change in publication.changes {
                if case .document(let document) = change, document.record.kind == "pi.live", let partial = document.value?["generation"]?["message"]?.objectValue { partials.append(partial) }
            }
        }
        let submission = try await generationSubmit(opened)
        try await eventually { models.seen.withLock { !$0.isEmpty } }
        for text in ["hel", "hello", "hello world"] {
            generationPartial(models, text: text)
            try await eventually { clock.pendingSleeperCount > 0 }; clock.advance(by: 100)
            try await eventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == .string(text) }
        }
        generationFinal(models, text: "hello world")
        _ = try await submission.wait(context: .background); try await log.waitForDone(submission.id)
        #expect(eventCompactTypes(log) == ["message_start", "message_end", "submission", "run_start", "turn_start", "message_start", "message_update", "message_end", "turn_end", "run_end", "submission", "usage_changed"])
        var rebuilt: [JSONValue] = [], message: JSONValue?
        for event in log.events {
            if event["type"] == "message_start", event["message"]?["role"] == "assistant" { message = event["message"]; rebuilt.append(message!) }
            if event["type"] == "message_update" { message = try eventRebuild(message!, changes: event["changes"]!.arrayValue!); rebuilt.append(message!) }
        }
        #expect(rebuilt.map { $0["content"] } == partials.values.map { $0["content"] })
        subscription.cancel(); _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func toolStartsOutputAppendsAndResultPrecedesMessage() async throws {
        let setup = HarnessChatSetup(), first = HarnessChatSignal(), second = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("print", execute: { _, api, context in
            try api.output(.text("one\n"), nil); try await api.details(["step": 1], context); first.signal()
            await second.wait(); try api.output(.text("two\n"), nil); try await api.details(["step": 2], context)
            await release.wait(); return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("print", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened), input = try await generationSubmit(opened)
        await first.wait(); second.signal(); try await eventually { log.events.contains { $0["output"]?["append"] == "two\n" } }
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        let tool = log.events.filter { ($0["type"]?.stringValue ?? "").hasPrefix("tool_execution") }
        #expect(tool.first?["type"] == "tool_execution_start" && tool.first?["args"] == [:])
        let end = try #require(log.types.firstIndex(of: "tool_execution_end"))
        #expect(Array(log.types[end...].prefix(3)) == ["tool_execution_end", "message_start", "message_end"])
        #expect(log.events[end + 1]["message"]?["toolCallId"] == "c1")
        #expect(log.types.filter { $0 == "turn_start" }.count == 2 && log.types.filter { $0 == "turn_end" }.count == 2)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func queuedSubmissionsInboxAndRetries() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), held = HarnessGatedResponse(message: chatAssistant("first"))
        setup.updateSettings { $0.retry = .init(enabled: true, maxRetries: 1, baseDelayMs: 1) }
        setup.models.setResponses([held.step, .message(chatAssistant("", reason: .error, error: "503 Service Unavailable")), .message(chatAssistant("second"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        _ = try await generationSubmit(opened, "a"); await held.reached.wait(); let follow = try await generationSubmit(opened, "f")
        try await log.waitForType("inbox_update"); #expect(log.events.first { $0["type"] == "inbox_update" }?["items"] == [["id": .number(Double(follow.id.rawValue)), "mode": "followUp"]])
        held.release(); try await log.waitForType("auto_retry_start"); try await eventually { clock.pendingSleeperCount > 0 }; clock.advance(by: 100)
        _ = try await follow.wait(context: .background); try await log.waitForDone(follow.id)
        #expect(log.types.contains("auto_retry_end")); #expect(log.types.filter { $0 == "run_start" }.count == 2)
        #expect(log.events.filter { $0["type"] == "submission" }.compactMap { $0["record"]?["status"]?.stringValue } == ["placed", "queued", "done", "placed", "done"])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func overflowReplaces101PendingBatchesWithSnapshot() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
        for _ in 0..<101 { _ = try await opened.root.commit({ tx in try await tx.appendEntry(opened.root.id, value: .init(kind: "note")) }, context: .background) }
        let log = HarnessEventLog(); try log.start(stream); try await log.waitForBatches(1)
        #expect(log.batches.count == 1 && log.events.count == 1 && log.types == ["snapshot"])
        #expect(log.events[0]["entries"]?.arrayValue?.count == 101)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func thinkingTextAndArgumentChangesRebuildEveryPartial() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), (stream, log) = try await eventListen(opened)
        let partial = try eventPartial("text")
        try await eventLiveChange(opened) { try $0.set("generation", ["attempt": 1, "message": .object(partial)]) }; try await log.waitForBatches(1)
        try await eventLiveChange(opened) { live in
            let content = try live.child("generation")!.child("message")!.child("content")!
            try content.append(["type": "thinking", "thinking": "think"])
            try content.append(["type": "toolCall", "id": "c1", "name": "missing", "arguments": ["path": "a/"]])
        }; try await log.waitForBatches(2)
        try await eventLiveChange(opened) { live in
            let content = try live.child("generation")!.child("message")!.child("content")!
            try content.child(0)!.set("text", "text more")
            try content.child(1)!.set("thinking", "thinking")
            try content.child(2)!.child("arguments")!.set("path", "a/long/path")
        }; try await log.waitForBatches(3)
        var message = log.events[0]["message"]!
        for event in log.events.dropFirst() { message = try eventRebuild(message, changes: event["changes"]!.arrayValue!) }
        #expect(message["content"] == .array(try await generationLive(opened)!.generation!.message!["content"]!.arrayValue!))
        let changes = log.events.flatMap { $0["changes"]?.arrayValue ?? [] }.compactMap { $0["type"]?.stringValue }
        #expect(changes.contains("thinking_start") && changes.contains("toolcall_start") && changes.contains("thinking_delta") && changes.contains("text_delta") && changes.contains("toolcall_delta"))
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func slidingTailOutputRebuildsFromTrimAndAppend() async throws {
        let run = try await HarnessLiveDeltaDriver.open(limits: .init(maxLines: 3, retain: .tail)), (stream, log) = try await eventListen(run.opened)
        let windows = ["line 0\n", "line 0\nline 1\nline 2\n", "line 1\nline 2\nline 3\n", "line 3\nline 4\nline 5\n"]
        for (index, chunk) in ["line 0\n", "line 1\nline 2\n", "line 3\n", "line 4\nline 5\n"].enumerated() { _ = try await run.output(chunk); try await log.waitForBatches(index + 1) }
        var rebuilt = "", values: [String] = []
        for event in log.events { guard let output = event["output"] else { continue }; if let set = output["set"]?.stringValue { rebuilt = set } else { rebuilt = String(decoding: Array(rebuilt.utf16).dropFirst(output["trimStart"]?.intValue ?? 0), as: UTF16.self) + (output["append"]?.stringValue ?? "") }; values.append(rebuilt) }
        #expect(values == windows && log.events.contains { $0["output"]?["trimStart"] != nil })
        _ = try await run.finish(); _ = await stream.stop(); try await run.close()
    }

    @Test func followUpBoundaryHasOneExactBatch() async throws {
        let setup = HarnessChatSetup(), held = HarnessGatedResponse(message: chatAssistant("first")); setup.models.setResponses([held.step, .message(chatAssistant("second"))])
        let opened = try await openChat(setup: setup), input = try await generationSubmit(opened, "a"); await held.reached.wait()
        let follow = try await generationSubmit(opened, "f"), (stream, log) = try await eventListen(opened)
        held.release(); _ = try await follow.wait(context: .background); try await log.waitForDone(follow.id)
        let boundary = try #require(log.batches.first { $0.contains { $0["type"] == "run_end" } })
        #expect(boundary.compactMap { $0["type"]?.stringValue } == ["message_start", "message_end", "message_start", "message_end", "turn_end", "run_end", "submission", "submission", "inbox_update", "usage_changed", "run_start", "turn_start"])
        #expect(boundary.filter { $0["type"] == "submission" }.map { $0["record"]?["id"] } == [.number(Double(input.id.rawValue)), .number(Double(follow.id.rawValue))])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func neverOfferedCallAndAbortedToolEndBeforeResult() async throws {
        let setup = HarnessChatSetup(), entered = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("wait", execute: { _, _, context in entered.signal(); try await harnessToolAwaitAbort(context); return .init(content: []) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("ghost", [:], "c1"), ("wait", [:], "c2")]))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened), input = try await generationSubmit(opened)
        await entered.wait(); try await log.waitForType("tool_execution_start"); try await opened.root.abort(context: .background)
        _ = try await input.wait(context: .background); try await eventually { log.types.contains("run_end") }
        let tool = log.events.filter { ($0["type"]?.stringValue ?? "").hasPrefix("tool_execution") }
        #expect(tool.map { $0["type"] } == ["tool_execution_end", "tool_execution_start", "tool_execution_end"])
        #expect(tool.map { $0["toolCallId"] } == ["c1", "c2", "c2"])
        for (index, event) in log.events.enumerated() where event["type"] == "tool_execution_end" { #expect(log.events[index + 1]["type"] == "message_start" && log.events[index + 2]["type"] == "message_end") }
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func steerResetAndOtherConversations() async throws {
        let setup = HarnessChatSetup(), held = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("hold", execute: { _, _, _ in held.signal(); await release.wait(); return .init(content: []) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("hold", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        let other = try await opened.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let input = try await generationSubmit(opened); await held.wait(); _ = try await opened.root.submit(.input(content: .text("s"), whenBusy: .steer), context: .background)
        let marker = try await other.commit({ tx in try await tx.appendEntry(other.id, value: .init(kind: "other-note")) }, context: .background)
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        try await opened.root.reset(context: .background)
        try await eventually { log.batches.last?.first?["type"] == "entry_appended" }
        #expect(log.types.filter { $0 == "run_start" }.count == 1 && log.types.filter { $0 == "run_end" }.count == 1)
        #expect(log.batches.last?.compactMap { $0["type"]?.stringValue } == ["entry_appended", "submission"])
        #expect(!log.events.contains { $0["entry"]?["id"] == .number(Double(marker.id.rawValue)) })
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func cancelledAttachmentWaitsForSessionLineThenRejects() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), gate = SessionTestGate(), entered = HarnessChatSignal(), controller = AbortController()
        let blocking = settled { try await opened.root.commit({ _ in entered.signal(); await gate.wait() }, context: .background) }
        await entered.wait(); let attaching = settled { try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background.withAbortSignal(controller.signal)) }
        controller.abort(AbortError()); gate.release(); try await eventually { blocking.isSettled && attaching.isSettled }
        #expect(throws: AbortError.self) { try attaching.result!.get() }
        try await opened.harness.close(context: .background)
    }

    @Test func overflowSnapshotPartialAcceptsLaterDeltas() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background), partial = try eventPartial("hel")
        try await eventLiveChange(opened) { try $0.set("generation", ["attempt": 1, "message": .object(partial)]) }
        for _ in 0..<100 { _ = try await opened.root.commit({ tx in try await tx.appendEntry(opened.root.id, value: .init(kind: "note")) }, context: .background) }
        let log = HarnessEventLog(); try log.start(stream); try await log.waitForBatches(1)
        #expect(log.types == ["snapshot"])
        try await eventLiveChange(opened) { try $0.child("generation")!.child("message")!.child("content")!.child(0)!.set("text", "hello") }; try await log.waitForBatches(2)
        #expect(log.events.last?["changes"] == [["type": "text_delta", "contentIndex": 0, "delta": "lo"]])
        let rebuilt = try eventRebuild(log.events[0]["generation"]!["message"]!, changes: log.events.last!["changes"]!.arrayValue!)
        #expect(rebuilt["content"] == [["type": "text", "text": "hello"]])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func usageClearProgressFaultedToolsAndClockDeferredPolls() async throws {
        let clock = TestClock(now: 1), opened = try await openChat(setup: HarnessChatSetup(clock: clock)), (stream, log) = try await eventListen(opened), partial = try eventPartial("partial")
        try await eventLiveChange(opened) { try $0.set("generation", ["attempt": 1, "message": .object(partial)]) }; try await log.waitForBatches(1)
        try await eventLiveChange(opened) { try $0.child("generation")!.child("message")!.child("usage")!.set("input", 42) }; try await log.waitForBatches(2)
        #expect(log.events.last?["changes"] == [])
        let first = clock.now(); try await eventLiveChange(opened) { try $0.set("generation", ["attempt": 1, "deferred": ["pollAt": .number(Double(first))]]) }; try await log.waitForBatches(3)
        clock.advance(by: 1); let second = clock.now(); try await eventLiveChange(opened) { try $0.child("generation")!.child("deferred")!.set("pollAt", .number(Double(second))) }; try await log.waitForBatches(4)
        try await eventLiveChange(opened) { try $0.set("tools", [["callId": "c1", "name": "t", "status": "running", "details": ["n": 1], "diagnostics": []]]) }; try await log.waitForBatches(5)
        try await eventLiveChange(opened) { let slot = try $0.child("tools")!.child(0)!; try slot.remove("details"); try slot.remove("diagnostics") }; try await log.waitForBatches(6)
        #expect(log.events.last?["details"] == .null && log.events.last?["diagnostics"] == [])
        try await eventLiveChange(opened) { try $0.child("tools")!.child(0)!.set("status", "done") }; try await log.waitForBatches(7)
        #expect(log.events.last?["type"] == "tool_execution_end" && log.events.last?["entry"] == nil)
        try await opened.root.commit({ tx in try await tx.retireDoc(UsageDoc, conversationId: opened.root.id) }, context: .background); try await log.waitForBatches(8)
        try await opened.root.commit({ tx in try await tx.retireDoc(AgentDoc, conversationId: opened.root.id) }, context: .background); try await log.waitForBatches(9)
        #expect(log.types == ["message_start", "message_update", "deferred_poll", "deferred_poll", "tool_execution_start", "tool_execution_update", "tool_execution_end", "usage_changed", "agent_changed"])
        #expect(log.events[7]["usage"] == ["models": [:], "tools": [:]] && log.events[8]["agent"] == [:])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func harnessCloseEndsEventStream() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
        try await opened.harness.close(context: .background); if case .sessionClosed = await stream.closed {} else { Issue.record("Stream did not close with Session") }
    }

    @Test func firstPartialStartsOnceAndAbortEndsConvertedEntry() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels()), opened = try await openChat(setup: setup, models: models), (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened); try await eventually { models.seen.withLock { !$0.isEmpty } }; generationPartial(models)
        try await eventually { clock.pendingSleeperCount > 0 }; clock.advance(by: 100); try await log.waitForType("message_start", count: 2)
        try await opened.root.abort(context: .background); _ = try await input.wait(context: .background); try await log.waitForType("run_end")
        #expect(log.events.filter { $0["type"] == "message_start" && $0["message"]?["role"] == "assistant" }.count == 1)
        #expect(log.events.filter { $0["type"] == "message_end" && $0["entry"]?["kind"] == "pi.assistant" }.count == 1)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }

    @Test func jsonExampleMemoryRunWithToolHasFullEventTypeSequence() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("bash", execute: { _, _, _ in .init(content: [.text(TextContent(text: "sources tests docs"))]) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("bash", [:], "call-1")])), .message(chatAssistant("This directory holds the durable package sources, tests, and docs."))])
        let opened = try await openChat(storage: MemoryStorage(), setup: setup), (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened, "What is in this directory?"); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        #expect(["snapshot"] + log.types == ["snapshot", "message_start", "message_end", "submission", "run_start", "turn_start", "message_start", "message_end", "message_start", "message_end", "usage_changed", "tool_execution_start", "tool_execution_end", "message_start", "message_end", "turn_end", "turn_start", "message_start", "message_end", "turn_end", "run_end", "submission", "usage_changed"])
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }
}

@Suite struct HarnessEventLifecycleTests {
    @Test func realDeferredGenerationUsesClockPollDeadlines() async throws {
        let clock = TestClock(now: 10), setup = HarnessChatSetup(options: .init(deferred: .init(pendingFetches: 1, pollAfterMs: 20)), settings: .init(stream: .init(deferred: DeferredRequest())), clock: clock)
        setup.models.setResponses([.message(chatAssistant("ready"))]); let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened), input = try await generationSubmit(opened)
        try await eventually { clock.pendingSleeperCount > 0 }; try await log.waitForType("deferred_poll"); clock.advance(by: 20)
        try await log.waitForType("deferred_poll", count: 2); try await eventually { clock.pendingSleeperCount > 0 }; clock.advance(by: 20)
        _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        #expect(log.events.filter { $0["type"] == "deferred_poll" }.map { $0["pollAt"] } == [30, 50])
        #expect(setup.models.state().deferredFetchCount == 2); _ = await stream.stop(); try await opened.harness.close(context: .background)
    }
    @Test func lateJoinToolSnapshotMatchesViewAndLaterOutputAppends() async throws {
        let setup = HarnessChatSetup(), reached = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("count", execute: { _, api, context in
            for number in 1...5 { try api.output(.text("\(number)\n"), nil) }
            try await api.details(["count": 5], context); reached.signal(); await release.wait()
            for number in 6...10 { try api.output(.text("\(number)\n"), nil) }
            try await api.details(["count": 10], context); return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("count", [:], "call-1")])), .message(chatAssistant("Counted to ten."))])
        let opened = try await openChat(setup: setup), input = try await generationSubmit(opened); await reached.wait()
        let view = try await opened.root.viewState(context: .background), (stream, log) = try await eventListen(opened)
        let live = try JSONValue.object(view.value.docs["pi.live"]!).decode(LiveState.self)
        #expect(stream.snapshot.tools == live.tools && stream.snapshot.entries == view.value.entries)
        #expect(stream.snapshot.tools.first?.output == "1\n2\n3\n4\n5\n")
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        var output = stream.snapshot.tools.first?.output ?? ""
        for event in log.events { guard let change = event["output"] else { continue }; if let set = change["set"]?.stringValue { output = set } else { output = String(decoding: Array(output.utf16).dropFirst(change["trimStart"]?.intValue ?? 0), as: UTF16.self) + (change["append"]?.stringValue ?? "") } }
        #expect(output == "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n" && !log.types.contains("tool_execution_start"))
        view.dispose(); _ = await stream.stop(); try await opened.harness.close(context: .background)
    }
    @Test func acquisitionCancellationEndsAttachedStream() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), controller = AbortController()
        let stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background.withAbortSignal(controller.signal))
        controller.abort(); if case .cancelled = await stream.closed {} else { Issue.record("Expected cancelled stream") }
        try await opened.harness.close(context: .background)
    }
    @Test func listenerFailureEndsStream() async throws {
        let opened = try await openChat(setup: HarnessChatSetup()), stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
        try stream.start { _, _ in throw TaskDefinitionError("listener failed") }
        _ = try await opened.root.commit({ tx in try await tx.appendEntry(opened.root.id, value: .init(kind: "note")) }, context: .background)
        if case .listenerError = await stream.closed {} else { Issue.record("Expected listener failure") }
        try await opened.harness.close(context: .background)
    }
}
