import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

/// Upstream: harness-nested-tools.test.ts:432, 814, 861, 1009, 1093, 1187.
@Suite struct HarnessNestedEventTests {
    private func slot(_ task: Int, parent: Int = 10, call: String = "opaque/child", parentCall: String = "opaque", status: String = "running", output: String? = nil) -> JSONValue {
        var value: JSONObject = ["callId": .string(call), "name": "echo", "parentCallId": .string(parentCall),
            "parentTaskId": .number(Double(parent)), "taskId": .number(Double(task)), "arguments": ["text": "final"], "status": .string(status)]
        if let output { value["output"] = .string(output) }
        return .object(value)
    }
    private func view(_ nested: [JSONValue], tools: [JSONValue] = []) -> ConversationView {
        .init(conversation: .init(id: rootConversationID), entries: [],
            docs: ["pi.live": ["nestedTools": .array(nested), "tools": .array(tools)]])
    }
    private func translate(_ before: ConversationView, _ after: ConversationView, ops: [Delta.Op] = [.set(["docs", "pi.live"], [:])], changes: [CommitChange] = []) throws -> [DurableAgentEvent] {
        var held = Set<TaskID>()
        return try translateDurableEvents(conversationId: rootConversationID, before: before, after: after,
            viewOps: ops, publication: .init(seq: try Seq(2), changes: changes), held: &held)
    }
    private func resultChange(task: Int, result: NestedToolExecutionResult?, retired: Bool = false, conversation: ConversationID = rootConversationID) throws -> CommitChange {
        let record = DocumentRecord(id: try DocumentID(Int64(task)), kind: NestedCallDoc.definition.kind,
            scope: .task(taskId: try TaskID(10)), createdAt: try Seq(1), key: "key", retiredAt: retired ? try Seq(2) : nil)
        let value = try JSONValue(encoding: NestedCallState(taskId: try TaskID(Int64(task)), result: result)).objectValue!
        return .document(.init(record: record, conversationId: conversation, version: 1, value: retired ? nil : value))
    }

    @Test func nestedEventFieldsAndResultRoundTrip() throws {
        let id = try TaskID(11), parent = try TaskID(10)
        let result = NestedToolExecutionResult(taskId: id, structuredOutput: .null, isError: false, diagnostics: [], durationMs: 4)
        let events: [DurableAgentEvent] = [
            .toolExecutionStart(toolCallId: "unrelated", toolName: "echo", args: ["text": "final"], taskId: id, parentToolCallId: "parent/with/slashes", parentTaskId: parent),
            .toolExecutionUpdate(toolCallId: "unrelated", toolName: "echo", output: .set("out"), details: .null, taskId: id, parentToolCallId: "parent/with/slashes", parentTaskId: parent),
            .toolExecutionEnd(toolCallId: "unrelated", toolName: "echo", taskId: id, parentToolCallId: "parent/with/slashes", parentTaskId: parent, result: result)
        ]
        for event in events {
            let value = try JSONValue(encoding: event)
            #expect(value["taskId"] == 11 && value["parentTaskId"] == 10)
            #expect(value["parentToolCallId"] == "parent/with/slashes")
            #expect(try value.decode(DurableAgentEvent.self) == event)
            #expect(value["entry"] == nil)
        }
        #expect(try JSONValue(encoding: events[2])["result"]?["structuredOutput"] == .null)
    }

    @Test func snapshotIncludesNestedSlotsAndExplicitNullDetails() throws {
        var raw = slot(11).objectValue!; raw["details"] = .null
        let snapshot = try durableEventSnapshot(view([.object(raw)]))
        #expect(snapshot.nestedTools.count == 1)
        #expect(snapshot.nestedTools[0].details == .null)
        let value = try JSONValue(encoding: snapshot)
        #expect(value["nestedTools"]?[0]?["details"] == .null)
        #expect(try value.decode(DurableAgentSnapshot.self) == snapshot)
        #expect(try durableEventSnapshot(view([])).nestedTools.isEmpty)
    }

    @Test func startsUseFinalArgumentsAndOpaqueParentIDs() throws {
        let pending = slot(11, call: "not/a/parent/key", parentCall: "different/id", status: "pending")
        let running = slot(11, call: "not/a/parent/key", parentCall: "different/id")
        let events = try translate(view([pending]), view([running]))
        #expect(events == [.toolExecutionStart(toolCallId: "not/a/parent/key", toolName: "echo", args: ["text": "final"],
            taskId: try TaskID(11), parentToolCallId: "different/id", parentTaskId: try TaskID(10))])
    }

    @Test func updatesUseEachNestedSlotIndexAndClearProgress() throws {
        let first = slot(11, output: "one"), second = slot(12, call: "second", output: "two")
        let changed = slot(12, call: "second", output: "two\n")
        let events = try translate(view([first, second]), view([first, changed]),
            ops: [.append(["docs", "pi.live", "nestedTools", 1, "output"], "\n")])
        #expect(events == [.toolExecutionUpdate(toolCallId: "second", toolName: "echo", output: .delta(append: "\n"),
            taskId: try TaskID(12), parentToolCallId: "opaque", parentTaskId: try TaskID(10))])
        var progress = first.objectValue!; progress["details"] = .null
        progress["diagnostics"] = [["severity": "info", "message": "note"]]
        let cleared = try translate(view([.object(progress)]), view([slot(11)]))
        #expect(cleared == [.toolExecutionUpdate(toolCallId: "opaque/child", toolName: "echo", output: .set(""), details: .null,
            diagnostics: [], taskId: try TaskID(11), parentToolCallId: "opaque", parentTaskId: try TaskID(10))])
    }

    @Test func nestedResultsSurviveRetirementAndChildrenEndBeforeParents() throws {
        let parent: JSONValue = ["callId": "model/id", "name": "batch", "taskId": 10, "status": "running"]
        let child = slot(11, call: "child", parentCall: "model/id")
        let grandchild = slot(12, parent: 11, call: "grandchild", parentCall: "child")
        let result = NestedToolExecutionResult(taskId: try TaskID(12), structuredOutput: "value", isError: false, diagnostics: [])
        let changes = [try resultChange(task: 12, result: result), try resultChange(task: 12, result: nil, retired: true)]
        let events = try translate(view([child, grandchild], tools: [parent]), view([]), changes: changes)
        #expect(events == [
            .toolExecutionEnd(toolCallId: "grandchild", toolName: "echo", taskId: try TaskID(12), parentToolCallId: "child", parentTaskId: try TaskID(11), result: result),
            .toolExecutionEnd(toolCallId: "child", toolName: "echo", taskId: try TaskID(11), parentToolCallId: "model/id", parentTaskId: try TaskID(10)),
            .toolExecutionEnd(toolCallId: "model/id", toolName: "batch", taskId: try TaskID(10))
        ])
        #expect(events.allSatisfy { $0.type == "tool_execution_end" })
    }

    @Test func newlyDoneNestedCallsEndOnceAndForeignResultsDoNotAttach() throws {
        let result = NestedToolExecutionResult(taskId: try TaskID(11), isError: false, diagnostics: [])
        let done = slot(11, status: "done")
        let events = try translate(view([]), view([done]), changes: [try resultChange(task: 11, result: result, conversation: ConversationID(99))])
        #expect(events == [.toolExecutionEnd(toolCallId: "opaque/child", toolName: "echo", taskId: try TaskID(11), parentToolCallId: "opaque", parentTaskId: try TaskID(10))])
        #expect(try translate(view([done]), view([])).isEmpty)
    }

    // Upstream v1.4.0 types.ts:78 / documents.ts:89: the checkpoint policy is required.
    @Test func liveCheckpointWaitsForNestedWork() throws {
        for (status, expected) in [("pending", true), ("running", false), ("done", true)] {
            let value = view([slot(11, status: status)]).docs["pi.live"]!
            #expect(try LiveDoc.definition.checkpointWhen(value, [], .init(deltasSinceBase: 1000)) == expected)
        }
    }

    @Test func summaryUsesErrorsThenTextAndBoundsErrorLength() throws {
        let id = try TaskID(11), output: [ContentBlock] = [.text(.init(text: "output"))]
        let success = NestedToolExecutionResult(taskId: id, isError: false, diagnostics: [], durationMs: 4)
        #expect(summaryOf(result: success, output: output) == .init(isError: false, durationMs: 4))
        let errors = NestedToolExecutionResult(taskId: id, isError: true,
            diagnostics: [.init(severity: .warn, message: "warning"), .init(severity: .error, message: String(repeating: "e", count: 600))])
        #expect(summaryOf(result: errors, output: output).error == String(repeating: "e", count: 500))
        let fallback = NestedToolExecutionResult(taskId: id, isError: true, diagnostics: [])
        #expect(summaryOf(result: fallback, output: output).error == "output")
    }
    @Test func lookupAndRemovalUseTaskIDsAfterMiddleSlotsDisappear() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let slots = [slot(11, call: "a"), slot(12, parent: 11, call: "no/shared/prefix"),
            slot(13, parent: 12, call: "deep"), slot(14, call: "b"), slot(15, parent: 14, call: "c")]
        let values = try await opened.root.commit({ tx -> [JSONValue] in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("nestedTools", .array(slots))
            try removeNestedSlots(live: live, taskId: TaskID(11))
            var found: [JSONValue] = []
            for id in [11, 14, 15] {
                let value = try toolSlot(live: live, taskId: TaskID(Int64(id)))?.get("callId") ?? .null
                found.append(value)
            }
            return found
        }, context: .background)
        #expect(values == ["a", "b", "c"])
        let live = try #require(await generationLive(opened))
        #expect(live.nestedTools?.map { $0.taskId.rawValue } == [11, 14, 15])
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try removeNestedSlots(live: live, taskId: TaskID(10))
        }, context: .background)
        #expect(try await generationLive(opened)?.nestedTools == nil)
        try await opened.harness.close(context: .background)
    }

    @Test func endRunRemovesAllNestedState() async throws {
        let opened = try await openChat(setup: HarnessChatSetup())
        let nested = slot(11)
        try await opened.root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: opened.root.id)
            try live.set("nestedTools", .array([nested]))
            try live.set("tools", [])
            try live.set("generation", ["attempt": 1])
            try endRun(tx: tx, live: live, taskId: TaskID(10), settlement: .unanswered(reason: "test"))
        }, context: .background)
        let state = try #require(await generationLive(opened))
        #expect(try JSONValue(encoding: state) == [:])
        try await opened.harness.close(context: .background)
    }

}
