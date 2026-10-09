import Foundation
import Testing
import PiSwiftAI

private func a0MessageUsage() -> Usage {
    Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, cacheWrite1h: 1,
          reasoning: 1, totalTokens: 10,
          cost: UsageCost(input: 0.1, output: 0.2, cacheRead: 0.3, cacheWrite: 0.4, total: 1.1))
}

private func a0CheckMessageRoundTrip(_ message: Message, expected: String) throws {
    let ordered = messageToOrderedJSON(message)
    #expect(ordered.serialized() == expected)
    let decoded = try #require(messageFromJSONObject(messageToJSONObject(message), ordered: ordered))
    #expect(decoded.role == message.role)
    // Message has no Equatable conformance. Compare every encoded field and its order.
    #expect(messageToOrderedJSON(decoded).serialized() == expected)
    let object = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any])
    let fromText = try #require(messageFromJSONObject(object, ordered: try OrderedJSON.parse(expected)))
    #expect(messageToOrderedJSON(fromText).serialized() == expected)
}

@Suite struct A0MessageCodingTests {
    @Test func systemRoundTripKeepsSectionsAndToolChanges() throws {
        let system = SystemMessage(
            content: .blocks([TextContent(text: "rules", textSignature: "sig")]),
            sections: SystemPromptSections([(name: "z", value: "last"), (name: "a", value: nil)]),
            toolsAdded: [AITool(name: "read", description: "Read", parameters: ["type": AnyCodable("object")], constrainedSampling: .disabled)],
            toolsRemoved: [ToolReference(name: "old")], timestamp: 10)
        try a0CheckMessageRoundTrip(.system(system), expected: #"{"role":"system","content":[{"type":"text","text":"rules","textSignature":"sig"}],"sections":{"z":"last","a":null},"toolsAdded":[{"name":"read","description":"Read","parameters":{"type":"object"},"constrainedSampling":false}],"toolsRemoved":[{"name":"old"}],"timestamp":10}"#)
        guard case .system(let decoded) = try #require(messageFromJSONObject(messageToJSONObject(.system(system)), ordered: messageToOrderedJSON(.system(system)))) else {
            Issue.record("Expected system message")
            return
        }
        #expect(decoded.sections == system.sections)
        #expect(decoded.toolsRemoved == system.toolsRemoved)
    }

    @Test func userTextRoundTrip() throws {
        try a0CheckMessageRoundTrip(.user(UserMessage(content: .text("hello"), timestamp: 20)),
                                  expected: #"{"content":"hello","role":"user","timestamp":20}"#)
    }

    @Test func userBlocksRoundTrip() throws {
        let user = UserMessage(content: .blocks([
            .text(TextContent(text: "hello", textSignature: "sig")),
            .image(ImageContent(data: "AA==", mimeType: "image/png")),
        ]), timestamp: 20)
        try a0CheckMessageRoundTrip(.user(user), expected: #"{"content":[{"text":"hello","textSignature":"sig","type":"text"},{"data":"AA==","mimeType":"image\/png","type":"image"}],"role":"user","timestamp":20}"#)
    }

    @Test func assistantRoundTripKeepsArgumentsAndMetadata() throws {
        let arguments = try OrderedJSON.parse(#"{"z":1,"a":2}"#)
        let assistant = AssistantMessage(content: [
            .text(TextContent(text: "answer", textSignature: "sig")),
            .thinking(ThinkingContent(thinking: "reason", thinkingSignature: "think", redacted: true)),
            .toolCall(ToolCall(id: "call", name: "read", arguments: ["z": AnyCodable(1), "a": AnyCodable(2)], argumentsJSON: arguments)),
        ], api: .openAIResponses, provider: "openai", model: "test", responseModel: "served", responseId: "response",
           usage: a0MessageUsage(), stopReason: .toolUse, timestamp: 30, rawStopReason: "tools",
           diagnostics: [AssistantMessageDiagnostic(type: "trace", timestamp: 31, details: ["value": AnyCodable(1)])],
           providerThinkingLevel: "high", thinkingLevel: .high, endTurn: false, durationMs: 12)
        try a0CheckMessageRoundTrip(.assistant(assistant), expected: #"{"api":"openai-responses","content":[{"text":"answer","textSignature":"sig","type":"text"},{"redacted":true,"thinking":"reason","thinkingSignature":"think","type":"thinking"},{"arguments":{"z":1,"a":2},"id":"call","name":"read","type":"toolCall"}],"diagnostics":[{"details":{"value":1},"timestamp":31,"type":"trace"}],"endTurn":false,"model":"test","provider":"openai","providerThinkingLevel":"high","rawStopReason":"tools","responseId":"response","responseModel":"served","role":"assistant","stopReason":"toolUse","thinkingLevel":"high","timestamp":30,"usage":{"cacheRead":3,"cacheWrite":4,"cacheWrite1h":1,"cost":{"cacheRead":0.3,"cacheWrite":0.4,"input":0.1,"output":0.2,"total":1.1},"input":1,"output":2,"reasoning":1,"totalTokens":10},"durationMs":12}"#)
    }

    @Test func toolResultRoundTripKeepsNestedArgumentsAndDuration() throws {
        let nested = NestedToolCalls(calls: [NestedToolCallRecord(id: "nested", name: "read",
            arguments: ["z": AnyCodable(1), "a": AnyCodable(2)], argumentsBytes: 13, status: .ok,
            durationMs: 1.5, argumentsJSON: try OrderedJSON.parse(#"{"z":1,"a":2}"#))], complete: true)
        let result = ToolResultMessage(toolCallId: "call", toolName: "read", content: [.text(TextContent(text: "done"))],
            details: AnyCodable(["value": 1]), usage: a0MessageUsage(), nestedCalls: nested,
            isError: false, timestamp: 40, durationMs: 7)
        try a0CheckMessageRoundTrip(.toolResult(result), expected: #"{"content":[{"text":"done","type":"text"}],"details":{"value":1},"isError":false,"nestedCalls":{"calls":[{"arguments":{"z":1,"a":2},"argumentsBytes":13,"durationMs":1.5,"id":"nested","name":"read","status":"ok"}],"complete":true},"role":"toolResult","timestamp":40,"toolCallId":"call","toolName":"read","usage":{"cacheRead":3,"cacheWrite":4,"cacheWrite1h":1,"cost":{"cacheRead":0.3,"cacheWrite":0.4,"input":0.1,"output":0.2,"total":1.1},"input":1,"output":2,"reasoning":1,"totalTokens":10},"durationMs":7}"#)
    }

    @Test func deferredAssistantRoundTripKeepsAllHandleFields() throws {
        let handle = DeferredHandle(provider: "faux", modelId: "test", api: "openai-responses", id: "deferred-test",
                                    expiresAt: 200, pollAfterMs: 25, data: AnyCodable(["token": "value"]))
        let assistant = AssistantMessage(content: [], api: .openAIResponses, provider: "faux", model: "test",
            usage: a0MessageUsage(), stopReason: .deferred, timestamp: 50, deferred: handle)
        let message = Message.assistant(assistant)
        guard case .assistant(let decoded) = try #require(messageFromJSONObject(messageToJSONObject(message), ordered: messageToOrderedJSON(message))) else {
            Issue.record("Expected assistant message")
            return
        }
        #expect(decoded.stopReason == .deferred)
        #expect(decoded.content.isEmpty)
        #expect(decoded.deferred == handle)
        #expect(messageToOrderedJSON(.assistant(decoded)).serialized() == messageToOrderedJSON(message).serialized())
    }

    @Test func unknownAndMissingRolesReturnNil() {
        #expect(messageFromJSONObject(["role": "custom", "content": "text"]) == nil)
        #expect(messageFromJSONObject(["content": "text"]) == nil)
        #expect(messageFromJSONObject(["role": 1]) == nil)
    }
}
