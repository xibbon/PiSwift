import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct HarnessEventCodingTests {
    @Test func allEventDiscriminatorsAndPayloadsRoundTrip() throws {
        let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "note")
        let submission = SubmissionRecord.input(id: try SubmissionID(3), conversationId: rootConversationID, state: .queued())
        let task = try TaskID(4)
        let events: [DurableAgentEvent] = [
            .snapshot(.init(entries: [entry], run: .init(inputs: [submission.id]), generation: .init(attempt: 2, retry: .init(at: 40, error: "retry")))),
            .runStart(inputs: [submission.id]), .runEnd(inputs: [submission.id]), .turnStart, .turnEnd,
            .messageStart(message: ["role": "user", "content": "input"]), .messageUpdate(usage: ["input": 1], changes: []),
            .messageEnd(entry: entry), .toolExecutionStart(toolCallId: "c1", toolName: "echo", args: ["text": "hello"]),
            .toolExecutionUpdate(toolCallId: "c1", toolName: "echo", output: .delta(trimStart: 2, append: "hello"), details: .null, diagnostics: []),
            .toolExecutionUpdate(toolCallId: "c1", toolName: "echo", output: .set("reset")),
            .toolExecutionEnd(toolCallId: "c1", toolName: "echo", entry: entry),
            .toolExecutionEnd(toolCallId: "c2", toolName: "echo"),
            .inboxUpdate(items: [.init(id: submission.id, mode: .steer)]), .submission(record: submission),
            .autoRetryStart(attempt: 2, at: 50, errorMessage: "retry"), .autoRetryEnd(attempt: 2), .deferredPoll(pollAt: 60),
            .entryAppended(entry: entry), .agentChanged(agent: .init(instructions: "Use Swift")),
            .usageChanged(usage: try JSONValue(encoding: UsageState(models: ["test/model": Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, totalTokens: 10)])).objectValue!),
            .taskFailed(taskId: task, kind: "pi.tool", message: "fault"),
            .compactionStart(taskId: task, reason: .manual, blocking: true), .compactionEnd(taskId: task, reason: .manual)
        ]
        let types = ["snapshot", "run_start", "run_end", "turn_start", "turn_end", "message_start", "message_update",
            "message_end", "tool_execution_start", "tool_execution_update", "tool_execution_update", "tool_execution_end",
            "tool_execution_end", "inbox_update", "submission", "auto_retry_start", "auto_retry_end", "deferred_poll",
            "entry_appended", "agent_changed", "usage_changed", "task_failed", "compaction_start", "compaction_end"]
        for (event, type) in zip(events, types) {
            let json = try JSONValue(encoding: event)
            #expect(json["type"] == .string(type))
            #expect(try json.decode(DurableAgentEvent.self) == event)
        }
        let cleared = try JSONValue(encoding: events[9])
        #expect(cleared["details"] == .null && cleared["diagnostics"] == [])
        let absent = try JSONValue(encoding: events[10])
        #expect(absent["details"] == nil && absent["diagnostics"] == nil)
    }

    @Test func allMessageChangesHaveUpstreamJSONShape() throws {
        let block: JSONObject = ["type": "text", "text": "abc"]
        let changes: [DurableMessageChange] = [.textStart(contentIndex: 0, block: block),
            .thinkingStart(contentIndex: 1, block: ["type": "thinking", "thinking": "abc"]),
            .toolCallStart(contentIndex: 2, block: ["type": "toolCall", "arguments": [:]]),
            .textDelta(contentIndex: 0, delta: "d"), .thinkingDelta(contentIndex: 1, delta: "d"),
            .toolCallDelta(contentIndex: 2, path: ["items", 0, "text"], delta: "d"),
            .block(contentIndex: 0, block: block), .message(message: ["role": "assistant", "content": [.object(block)]])]
        #expect(changes.map(\.type) == ["text_start", "thinking_start", "toolcall_start", "text_delta", "thinking_delta", "toolcall_delta", "block", "message"])
        for change in changes { #expect(try JSONValue(encoding: change).decode(DurableMessageChange.self) == change) }
        #expect(try JSONValue(encoding: changes[5])["path"] == ["items", 0, "text"])
    }

    @Test func wholeBlockSuppressesLaterAppendAndParentReplacementSendsMessage() throws {
        let message: JSONObject = ["content": [["type": "text", "text": "final"]]]
        let prefix: Delta.Path = ["docs", "pi.live", "generation", "message"]
        let changes = try durableMessageChanges([.set(prefix + ["content", 0, "text"], "fin"),
            .append(prefix + ["content", 0, "text"], "al")], message: message)
        #expect(changes == [.block(contentIndex: 0, block: ["type": "text", "text": "final"])])
        #expect(try durableMessageChanges([.set(["docs", "pi.live", "generation"], [:])], message: message) == [.message(message: message)])
    }

    @Test func explicitNullDetailsSurviveSnapshotAndEmitUpdate() throws {
        let raw: JSONValue = ["callId": "c1", "name": "echo", "status": "running", "details": .null]
        let slot = try raw.decode(ToolSlot.self)
        #expect(slot.details == .null)
        #expect(try JSONValue(encoding: slot)["details"] == .null)
        let previous = ToolSlot(callId: "c1", name: "echo", status: .running)
        let update = try #require(durableToolUpdate([.set(["docs", "pi.live", "tools", 0, "details"], .null)], index: 0, slot: slot, previous: previous))
        #expect(update.details == .null)
        #expect(try JSONValue(encoding: DurableAgentSnapshot(tools: [slot]))["tools"]?[0]?["details"] == .null)
        #expect(durableToolUpdate([], index: 0, slot: previous, previous: previous) == nil)
    }

    @Test func duplicateOldToolSlotsUseLastValueLikeUpstreamMap() throws {
        let conversation = ConversationRecord(id: rootConversationID)
        let before = ConversationView(conversation: conversation, entries: [], docs: ["pi.live": ["tools": [
            ["callId": "c1", "name": "first", "status": "running"],
            ["callId": "c1", "name": "last", "status": "running"]]]])
        let after = ConversationView(conversation: conversation, entries: [], docs: ["pi.live": [:]])
        var held = Set<TaskID>()
        let events = try translateDurableEvents(conversationId: rootConversationID, before: before, after: after,
            viewOps: [.delete(["docs", "pi.live", "tools"])], publication: .init(seq: try Seq(1), changes: []), held: &held)
        #expect(events == [.toolExecutionEnd(toolCallId: "c1", toolName: "last")])
    }

    @Test func toolCallIDsAndOutputUseExactUnicodeUnits() throws {
        let conversation = ConversationRecord(id: rootConversationID)
        let before = ConversationView(conversation: conversation, entries: [], docs: ["pi.live": ["tools": [
            ["callId": "é", "name": "first", "status": "running"],
            ["callId": "e\u{301}", "name": "last", "status": "running"]]]])
        let after = ConversationView(conversation: conversation, entries: [], docs: ["pi.live": [:]])
        var held = Set<TaskID>()
        let events = try translateDurableEvents(conversationId: rootConversationID, before: before, after: after,
            viewOps: [.delete(["docs", "pi.live", "tools"])], publication: .init(seq: try Seq(1), changes: []), held: &held)
        #expect(events.count == 2)
        var previous = ToolSlot(callId: "c1", name: "echo", status: .running); previous.output = "é"
        var slot = previous; slot.output = "e\u{301}"
        let update = try #require(durableToolUpdate([], index: 0, slot: slot, previous: previous))
        #expect(update.output == .set("e\u{301}"))
    }

    @Test func usageEventsPreserveDistinctUnicodeKeys() throws {
        let value = try JSONValue(encoding: UsageState(models: ["test": Usage(input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3)]))["models"]!["test"]!
        let tools = JSONObject([("é", value), ("e\u{301}", value)])
        let usage: JSONObject = ["models": [:], "tools": .object(tools)]
        let view = ConversationView(conversation: .init(id: rootConversationID), entries: [], docs: ["pi.usage": usage])
        let snapshot = try durableEventSnapshot(view)
        #expect(snapshot.usage == usage)
        let event = DurableAgentEvent.usageChanged(usage: usage)
        #expect(try JSONValue(encoding: event)["usage"]?["tools"]?.objectValue?.count == 2)
        #expect(try JSONValue(encoding: event).decode(DurableAgentEvent.self) == event)
    }
}
