// v1.5.2 D4: harness/view.ts:36–48 replaces nested events with pi.live state.
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

/// Upstream: harness-nested-tools.test.ts:432, 814, 861, 1009, 1093, 1187.
@Suite struct HarnessNestedStateTests {
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
