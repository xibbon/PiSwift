import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessEventTaskIDTests {
    @Test func toolEventJSONRetainsOptionalTaskIDs() throws {
        let task = try TaskID(42)
        let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "pi.toolResult")
        let events: [DurableAgentEvent] = [
            .toolExecutionStart(toolCallId: "call", toolName: "echo", args: [:], taskId: task),
            .toolExecutionUpdate(toolCallId: "call", toolName: "echo", output: .set("out"), taskId: task),
            .toolExecutionEnd(toolCallId: "call", toolName: "echo", entry: entry, taskId: task),
            .toolExecutionStart(toolCallId: "call", toolName: "echo", args: [:]),
            .toolExecutionUpdate(toolCallId: "call", toolName: "echo", output: .set("out")),
            .toolExecutionEnd(toolCallId: "call", toolName: "echo", entry: entry)
        ]
        for (index, event) in events.enumerated() {
            let json = try JSONValue(encoding: event)
            #expect(json["taskId"] == (index < 3 ? .number(42) : nil))
            #expect(try json.decode(DurableAgentEvent.self) == event)
            if event.type == "tool_execution_end" {
                #expect(try json["entry"]?.decode(EntryRecord.self) == entry)
            }
        }
    }

    @Test func toolEndsUseCurrentOrRemovedSlotTaskID() throws {
        let conversation = ConversationRecord(id: rootConversationID)
        let task = try TaskID(42)
        let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "pi.toolResult")
        func view(_ slots: [JSONValue]) -> ConversationView {
            ConversationView(conversation: conversation, entries: [], docs: ["pi.live": ["tools": .array(slots)]])
        }
        let pending: JSONValue = ["callId": "call", "name": "echo", "status": "pending"]
        let running: JSONValue = ["callId": "call", "name": "echo", "status": "running", "taskId": 42]
        let done: JSONValue = ["callId": "call", "name": "echo", "status": "done", "taskId": 42, "entry": 2]
        let absent: JSONValue = ["callId": "call", "name": "echo", "status": "done", "entry": 2]
        for (before, after, expectedTask, expectedEntry) in [
            (view([pending]), view([done]), task as TaskID?, entry as EntryRecord?),
            (view([running]), view([]), task as TaskID?, nil as EntryRecord?),
            (view([]), view([done]), task as TaskID?, entry as EntryRecord?),
            (view([]), view([absent]), nil as TaskID?, entry as EntryRecord?)
        ] {
            var held = Set<TaskID>()
            let events = try translateDurableEvents(conversationId: rootConversationID, before: before, after: after,
                viewOps: [.set(["docs", "pi.live", "tools"], [])],
                publication: .init(seq: try Seq(1), changes: [.entry(entry)]), held: &held)
            let ends = events.filter { $0.type == "tool_execution_end" }
            #expect(ends == [.toolExecutionEnd(toolCallId: "call", toolName: "echo", entry: expectedEntry, taskId: expectedTask)])
        }
    }

    @Test func realToolEventsUseInvocationTaskID() async throws {
        let setup = HarnessChatSetup(), reached = HarnessChatSignal(), release = HarnessChatSignal()
        let taskId = Mutex<TaskID?>(nil)
        try installHarnessTool(harnessTestTool("echo", execute: { _, api, context in
            taskId.withLock { $0 = api.taskId }
            try api.output(.text("output"), nil)
            try await api.details(["ready": true], context)
            reached.signal(); await release.wait()
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("missing", [:], "missing-call"), ("echo", [:], "call")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened)
        await reached.wait(); try await log.waitForType("tool_execution_update")
        release.signal(); _ = try await input.wait(context: .background); try await log.waitForDone(input.id)
        let id = try #require(taskId.withLock { $0 })
        let toolEvents = log.events.filter { $0["toolCallId"] == "call" }
        let types = toolEvents.compactMap { $0["type"]?.stringValue }
        #expect(types.contains("tool_execution_start"))
        #expect(types.contains("tool_execution_update"))
        #expect(types.contains("tool_execution_end"))
        #expect(toolEvents.allSatisfy { $0["taskId"] == .number(Double(id.rawValue)) })
        let end = try #require(toolEvents.first { $0["type"] == "tool_execution_end" })
        #expect(end["entry"]?["model"]?[0]?["toolCallId"] == "call")
        let missing = try #require(log.events.first { $0["type"] == "tool_execution_end" && $0["toolCallId"] == "missing-call" })
        #expect(missing["taskId"] == nil && missing["entry"] != nil)
        _ = await stream.stop(); try await opened.harness.close(context: .background)
    }
}
