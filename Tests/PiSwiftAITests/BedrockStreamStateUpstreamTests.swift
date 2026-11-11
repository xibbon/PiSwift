import Foundation
import Testing
@testable import PiSwiftAI

// Cases follow packages/ai/test/bedrock-stream-state.test.ts at v1.5.2.
private func upstreamBedrockModel() -> Model {
    Model(id: "global.anthropic.claude-test", name: "Claude Test", api: .bedrockConverseStream,
          provider: "amazon-bedrock", baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
          reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 200_000, maxTokens: 64_000)
}

private func upstreamBedrockEvent(_ type: String, _ payload: [String: Any], output: inout AssistantMessage,
                                  state: inout BedrockStreamState, stream: AssistantMessageEventStream) throws {
    try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: payload),
                              model: upstreamBedrockModel(), output: &output, state: &state, stream: stream)
}

private func upstreamBedrockOutput() -> AssistantMessage {
    let model = upstreamBedrockModel()
    return AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                            stopReason: .pending)
}

@Test("keeps stream state off partial blocks and finishes the tool call with its exact arguments")
func upstreamBedrockPartialState() throws {
    let content = String(repeating: "a", count: 5_000)
    let text = #"{"path":"/src/file.ts","content":""# + content + #""}"#
    var output = upstreamBedrockOutput()
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    try upstreamBedrockEvent("messageStart", ["role": "assistant"], output: &output, state: &state, stream: stream)
    try upstreamBedrockEvent("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["reasoningContent": ["redactedContent": "AQI="]]], output: &output, state: &state, stream: stream)
    try upstreamBedrockEvent("contentBlockStop", ["contentBlockIndex": 0], output: &output, state: &state, stream: stream)
    try upstreamBedrockEvent("contentBlockStart", ["contentBlockIndex": 1, "start": ["toolUse": ["toolUseId": "tool_1", "name": "write"]]], output: &output, state: &state, stream: stream)
    let chars = Array(text)
    var shown = 0
    for start in stride(from: 0, to: chars.count, by: 32) {
        let delta = String(chars[start..<min(start + 32, chars.count)])
        try upstreamBedrockEvent("contentBlockDelta", ["contentBlockIndex": 1, "delta": ["toolUse": ["input": delta]]], output: &output, state: &state, stream: stream)
        for block in output.content {
            let json = contentBlockToJSONObject(block)
            #expect(json["partialJson"] == nil)
            #expect(json["index"] == nil)
            #expect(json["argumentsJSON"] == nil)
            #expect(json["redactedChunks"] == nil)
        }
        if case .toolCall(let call) = output.content.last {
            let value = call.arguments["content"]?.value as? String ?? ""
            #expect(content.hasPrefix(value))
            #expect(value.utf8.count >= shown)
            #expect(call.argumentsJSON == nil)
            shown = value.utf8.count
        }
    }
    try upstreamBedrockEvent("contentBlockStop", ["contentBlockIndex": 1], output: &output, state: &state, stream: stream)
    try upstreamBedrockEvent("messageStop", ["stopReason": "tool_use"], output: &output, state: &state, stream: stream)
    finalizeBedrockBlocks(output: &output, state: &state)
    #expect(output.stopReason == .toolUse)
    #expect(shown == content.count)
    if case .toolCall(let call) = output.content.last {
        #expect(call.arguments["content"] == AnyCodable(content))
        #expect(call.argumentsJSON?.serialized(escapeSlashes: false) == text)
    } else { Issue.record("Missing final Bedrock tool call") }
    stream.end()
}

@Test("allocates linearly in the argument text", .timeLimit(.minutes(1)))
func upstreamBedrockLinearAllocationAdapted() throws {
    // V8 allocation counters are unavailable. Exercise Bedrock's decoder at two text sizes.
    func elapsed(_ size: Int) throws -> Duration {
        var output = upstreamBedrockOutput()
        var state = BedrockStreamState()
        let stream = AssistantMessageEventStream()
        try upstreamBedrockEvent("contentBlockStart", ["contentBlockIndex": 0, "start": ["toolUse": ["toolUseId": "tool", "name": "write"]]], output: &output, state: &state, stream: stream)
        let start = ContinuousClock.now
        for _ in stride(from: 0, to: size, by: 32) {
            try upstreamBedrockEvent("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["toolUse": ["input": String(repeating: "a", count: 32)]]], output: &output, state: &state, stream: stream)
        }
        try upstreamBedrockEvent("contentBlockStop", ["contentBlockIndex": 0], output: &output, state: &state, stream: stream)
        stream.end()
        return start.duration(to: .now)
    }
    let small = try elapsed(25_000)
    let large = try elapsed(250_000)
    #expect(large < .seconds(10))
    #expect(large < small * 25)
}
