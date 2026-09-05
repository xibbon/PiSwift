import Foundation
import Testing
@testable import PiSwiftAI

private let bedrockPortBase64 = "cnNuXzVaVnJpZjRKMGJYSXFtV2RsZWRqN1FJRmVOaWtSUWJF"

private func bedrockPortModel() -> Model {
    Model(id: "global.openai.gpt-5.6-terra", name: "GPT-5.6 Terra (Global)", api: .bedrockConverseStream,
        provider: "amazon-bedrock", baseUrl: "https://bedrock-runtime.ap-northeast-1.amazonaws.com", reasoning: true,
        input: [.text], cost: ModelCost(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        contextWindow: 400000, maxTokens: 128000)
}

private func bedrockPortOutput(content: [ContentBlock] = [], stop: StopReason = .pending) -> AssistantMessage {
    let model = bedrockPortModel()
    return AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: stop)
}

private func bedrockPortProcess(_ events: [(String, [String: Any])]) throws -> (AssistantMessage, BedrockStreamState) {
    var output = bedrockPortOutput()
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    for (type, payload) in events {
        try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: payload), model: bedrockPortModel(),
            output: &output, state: &state, stream: stream)
    }
    finalizeBedrockBlocks(output: &output, state: &state)
    stream.end()
    return (output, state)
}

private func redactedDelta(_ base64: String, index: Int = 0) -> (String, [String: Any]) {
    ("contentBlockDelta", ["contentBlockIndex": index, "delta": ["reasoningContent": ["redactedContent": base64]]])
}

@Test func bedrockRedactedReasoningPrecedesTextAndPersistsOpaquePayload() throws {
    let (output, state) = try bedrockPortProcess([
        ("messageStart", ["role": "assistant"]), redactedDelta(bedrockPortBase64),
        ("contentBlockStop", ["contentBlockIndex": 0]),
        ("contentBlockDelta", ["contentBlockIndex": 1, "delta": ["text": "done"]]),
        ("contentBlockStop", ["contentBlockIndex": 1]), ("messageStop", ["stopReason": "end_turn"]),
    ])
    #expect(output.stopReason == .stop)
    #expect(output.rawStopReason == "end_turn")
    #expect(output.content.count == 2)
    guard case .thinking(let thinking) = output.content[0], case .text(let text) = output.content[1] else {
        Issue.record("Bedrock did not preserve thinking before text")
        return
    }
    #expect(text.text == "done")
    #expect(thinking.redacted == true)
    #expect(thinking.thinkingSignature == bedrockPortBase64)
    #expect(thinking.thinking == "[Reasoning redacted]")
    #expect(state.redactedChunks.isEmpty)
    let json = contentBlockToJSONObject(output.content[0])
    #expect(json["redactedChunks"] == nil)
    #expect(json["index"] == nil)
}

@Test func bedrockFinalizesReasoningWithoutContentBlockStop() throws {
    let (output, state) = try bedrockPortProcess([
        ("messageStart", ["role": "assistant"]), redactedDelta(bedrockPortBase64),
        ("messageStop", ["stopReason": "end_turn"]),
    ])
    guard case .thinking(let thinking) = try #require(output.content.first) else { Issue.record("No thinking block"); return }
    #expect(thinking.thinkingSignature == bedrockPortBase64)
    #expect(state.redactedChunks.isEmpty)
    let json = contentBlockToJSONObject(.thinking(thinking))
    #expect(json["redactedChunks"] == nil)
    #expect(json["index"] == nil)
}

@Test func bedrockJoinsRedactedChunksAndAddsPlaceholderOnce() throws {
    let bytes = try #require(Data(base64Encoded: bedrockPortBase64))
    let (output, state) = try bedrockPortProcess([
        ("messageStart", ["role": "assistant"]),
        redactedDelta(Data(bytes.prefix(7)).base64EncodedString()), redactedDelta(Data(bytes.dropFirst(7)).base64EncodedString()),
        ("contentBlockStop", ["contentBlockIndex": 0]), ("messageStop", ["stopReason": "end_turn"]),
    ])
    guard case .thinking(let thinking) = try #require(output.content.first) else { Issue.record("No thinking block"); return }
    #expect(thinking.thinkingSignature == bedrockPortBase64)
    #expect(thinking.thinking == "[Reasoning redacted]")
    #expect(state.redactedChunks.isEmpty)
}

@Test func bedrockFinalizationAlsoWorksForErrorAndAbortCleanup() throws {
    var output = bedrockPortOutput()
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    let (type, payload) = redactedDelta(bedrockPortBase64)
    try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: payload), model: bedrockPortModel(), output: &output, state: &state, stream: stream)
    #expect(!state.redactedChunks.isEmpty)
    output.stopReason = .aborted
    finalizeBedrockBlocks(output: &output, state: &state)
    finalizeBedrockBlocks(output: &output, state: &state)
    guard case .thinking(let thinking) = try #require(output.content.first) else { Issue.record("No thinking block"); return }
    #expect(thinking.thinkingSignature == bedrockPortBase64)
    #expect(state.redactedChunks.isEmpty)
    stream.end()
}

private func bedrockPortReplay(_ assistant: AssistantMessage, toolResult: Bool = false) throws -> [[String: Any]] {
    var messages: [Message] = [.user(UserMessage(content: .text("hello"))), .assistant(assistant)]
    if toolResult {
        messages.append(.toolResult(ToolResultMessage(toolCallId: "tool-1", toolName: "read", content: [.text(TextContent(text: "file body"))], isError: false)))
    } else { messages.append(.user(UserMessage(content: .text("continue")))) }
    let data = try bedrockReplayFixture(context: Context(messages: messages), model: bedrockPortModel())
    let converted = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let message = try #require(converted.first { $0["role"] as? String == "assistant" })
    return try #require(message["content"] as? [[String: Any]])
}

@Test func bedrockReplaysRedactedReasoningBeforeText() throws {
    let content = try bedrockPortReplay(bedrockPortOutput(content: [
        .thinking(ThinkingContent(thinking: "", thinkingSignature: bedrockPortBase64, redacted: true)), .text(TextContent(text: "done")),
    ], stop: .stop))
    #expect(content.count == 2)
    #expect((content[0]["reasoningContent"] as? [String: Any])?["redactedContent"] as? String == bedrockPortBase64)
    #expect(content[1]["text"] as? String == "done")
}

@Test func bedrockReplaysRedactedReasoningBeforeItsToolCall() throws {
    let content = try bedrockPortReplay(bedrockPortOutput(content: [
        .thinking(ThinkingContent(thinking: "", thinkingSignature: bedrockPortBase64, redacted: true)),
        .toolCall(ToolCall(id: "tool-1", name: "read", arguments: ["path": AnyCodable("/tmp/a.txt")])),
    ], stop: .toolUse), toolResult: true)
    #expect(content.count == 2)
    #expect((content[0]["reasoningContent"] as? [String: Any])?["redactedContent"] as? String == bedrockPortBase64)
    let tool = try #require(content[1]["toolUse"] as? [String: Any])
    #expect(tool["toolUseId"] as? String == "tool-1")
    #expect(tool["name"] as? String == "read")
    #expect(tool["input"] as? [String: String] == ["path": "/tmp/a.txt"])
}

@Test func bedrockSanitizesEmptyDocumentKeysAtEveryDepth() throws {
    let original: [String: Any] = ["": "drop", "name": "keep", "object": ["": 1, "value": NSNull()],
        "array": [["": true, "nested": ["": "drop", "ok": "yes"]], ["": 2]], "space": [" ": "keep"]]
    let sanitized = try #require(sanitizeBedrockDocument(original) as? [String: Any])
    #expect(sanitized[""] == nil)
    #expect(sanitized["name"] as? String == "keep")
    let object = try #require(sanitized["object"] as? [String: Any])
    #expect(object[""] == nil)
    #expect(object["value"] is NSNull)
    let array = try #require(sanitized["array"] as? [[String: Any]])
    #expect(array[0][""] == nil)
    #expect(array[1].isEmpty)
    #expect(array[0]["nested"] as? [String: String] == ["ok": "yes"])
    #expect(sanitized["space"] as? [String: String] == [" ": "keep"])
    #expect(original[""] as? String == "drop")
}
