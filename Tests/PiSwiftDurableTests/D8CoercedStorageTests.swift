import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D8CoercedStorage")
struct D8CoercedStorageTests {
    @Test(.timeLimit(.minutes(1)))
    func invalidModelCallKeepsReceivedArgumentOrder() async throws {
        // v1.5.2 ai/src/utils/validation.ts:54-68 prints JSON.stringify of the original model arguments.
        let tool = try ToolRegistration(name: "ordered", description: "Order probe", parameters: [
            "type": "object", "properties": ["a": ["type": "integer"], "z": ["type": "integer"]]
        ]) { _, _, _ in .init(output: []) }
        let setup = HarnessChatSetup()
        try installHarnessTool(tool, setup: setup)
        var call = chatAssistant("")
        call.content = [.toolCall(ToolCall(id: "c1", name: "ordered", arguments: ["z": AnyCodable("bad"), "a": AnyCodable("bad")],
            argumentsJSON: try OrderedJSON.parse(#"{"z":"bad","a":"bad"}"#)))]
        call.stopReason = .toolUse
        setup.models.setResponses([.message(call), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let entries = try await allEntries(opened.root)
        let text = try #require(try entries.first { $0.kind == "pi.tool-result" }?.messages()?.first.flatMap(textOf))
        let received = try #require(text.range(of: "Received arguments:\n"))
        let json = String(text[received.upperBound...])
        #expect(try #require(json.range(of: "\"z\"")) .lowerBound < #require(json.range(of: "\"a\"")) .lowerBound)
        try await opened.harness.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["boolean", "integer", "array"])
    func toolReceivesAndCheckpointsCoercedArguments(_ mode: String) async throws {
        // v1.5.2 durable/src/harness/tool.ts:388-400,181-198.
        let input: JSONObject
        let expected: JSONObject
        switch mode {
        case "boolean": input = ["b": "true"]; expected = ["b": true]
        case "integer": input = ["i": "3.5"]; expected = ["i": 3]
        default: input = ["a": "1"]; expected = ["a": [1]]
        }
        let entered = HarnessChatSignal(), release = HarnessChatSignal()
        let tool = try ToolRegistration(name: "coerce", description: "Coercion probe", parameters: [
            "type": "object", "properties": [
                "b": ["type": "boolean"], "i": ["type": "integer"],
                "a": ["type": "array", "items": ["type": "number"]]
            ]
        ]) { args, _, _ in
            #expect(args == .object(expected))
            entered.signal()
            await release.wait()
            return .init(output: [])
        }
        let setup = HarnessChatSetup()
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([.message(try toolCalls([("coerce", input, "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let submitted = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await entered.wait()
        let live = try #require(await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
        let taskID = try #require(live.tools?.first?.taskId)
        let record = try #require(await opened.harness.getTask(id: taskID, context: .background))
        if case .running(let checkpoint, _) = record.state {
            #expect(checkpoint["arguments"] == .object(expected))
        } else { Issue.record("Tool intent was not stored while execution waited") }
        release.signal()
        #expect(try await submitted.wait(context: .background).status == "done")
        try await opened.harness.close(context: .background)
    }
}
