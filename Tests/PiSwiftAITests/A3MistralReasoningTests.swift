import Foundation
import Testing
@testable import PiSwiftAI

private func a3MistralModel(
    _ id: String,
    reasoning: Bool = true,
    thinkingLevelMap: ThinkingLevelMap? = nil
) -> Model {
    Model(id: id, name: id, api: .mistralConversations, provider: "mistral",
        baseUrl: "https://example.invalid", reasoning: reasoning, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 16_384, thinkingLevelMap: thinkingLevelMap)
}

private let a3NoneHighLevels: ThinkingLevelMap = [
    .off: "none", .minimal: nil, .low: nil, .medium: nil, .high: "high", .xhigh: nil, .max: nil,
]

@Test func a3MistralReasoningUsesMapRatherThanModelID() {
    let magistral = a3MistralModel("magistral-medium-latest")
    let prompt = mapMistralSimpleOptions(model: magistral,
        options: SimpleStreamOptions(reasoning: .medium), apiKey: "test")
    #expect(prompt.promptMode == "reasoning")
    #expect(prompt.reasoningEffort == nil)
    let promptOff = mapMistralSimpleOptions(model: magistral, options: nil, apiKey: "test")
    #expect(promptOff.promptMode == nil)
    #expect(promptOff.reasoningEffort == nil)

    // Port of mistral-reasoning-mode.test.ts: #9678 removes the provider's model-ID list.
    for id in ["mistral-small-2603", "mistral-medium-latest", "zai-glm-5-2"] {
        var map = a3NoneHighLevels
        if id == "zai-glm-5-2" { map[.max] = "max" }
        let model = a3MistralModel(id, thinkingLevelMap: map)
        let high = mapMistralSimpleOptions(model: model,
            options: SimpleStreamOptions(reasoning: .high), apiKey: "test")
        #expect(high.reasoningEffort == "high")
        #expect(high.promptMode == nil)
        let clamped = mapMistralSimpleOptions(model: model,
            options: SimpleStreamOptions(reasoning: .low), apiKey: "test")
        #expect(clamped.reasoningEffort == "high")
        let off = mapMistralSimpleOptions(model: model, options: nil, apiKey: "test")
        #expect(off.reasoningEffort == "none")
        #expect(off.promptMode == nil)
    }

    var glm52Map = a3NoneHighLevels
    glm52Map[.max] = "max"
    let glm52 = mapMistralSimpleOptions(model: a3MistralModel("zai-glm-5-2", thinkingLevelMap: glm52Map),
        options: SimpleStreamOptions(reasoning: .max), apiKey: "test")
    #expect(glm52.reasoningEffort == "max")

    let glm53Map: ThinkingLevelMap = [
        .off: nil, .minimal: nil, .low: "low", .medium: nil, .high: "high", .xhigh: nil, .max: "max",
    ]
    let glm53 = a3MistralModel("zai-glm-5-3", thinkingLevelMap: glm53Map)
    for (level, expected) in [(ThinkingLevel.low, "low"), (.high, "high"), (.max, "max"), (.medium, "high")] {
        let mapped = mapMistralSimpleOptions(model: glm53,
            options: SimpleStreamOptions(reasoning: level), apiKey: "test")
        #expect(mapped.reasoningEffort == expected)
        #expect(mapped.promptMode == nil)
    }
    #expect(mapMistralSimpleOptions(model: glm53, options: nil, apiKey: "test").reasoningEffort == nil)

    let nonReasoning = mapMistralSimpleOptions(model: a3MistralModel("mistral-medium-2505", reasoning: false),
        options: SimpleStreamOptions(reasoning: .medium), apiKey: "test")
    #expect(nonReasoning.reasoningEffort == nil)
    #expect(nonReasoning.promptMode == nil)
}

@Test func a3MistralCatalogOffersOnlyMappedAPILevels() throws {
    let small = try #require(getModel(provider: "mistral", modelId: "mistral-small-2603"))
    let glm52 = try #require(getModel(provider: "mistral", modelId: "zai-glm-5-2"))
    let glm53 = try #require(getModel(provider: "mistral", modelId: "zai-glm-5-3"))
    #expect(getSupportedThinkingLevels(small) == [.off, .high])
    #expect(getSupportedThinkingLevels(glm52) == [.off, .high, .max])
    #expect(getSupportedThinkingLevels(glm53) == [.low, .high, .max])
}

private struct A3MistralSSEClient: ProviderHTTPClient {
    let body: Data

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: body)
    }
}

// Port of mistral-http-transport.test.ts, "ignores empty content deltas" (#9674).
@Test(.timeLimit(.minutes(1))) func a3MistralIgnoresEmptyContentDeltas() async throws {
    let model = a3MistralModel("zai-glm-5-3")
    let deltas: [[String: Any]] = [
        ["content": ""],
        ["content": [["type": "thinking", "thinking": [["type": "text", "text": "first part,"]]]]],
        ["content": ""],
        ["content": [["type": "text", "text": ""]]],
        ["content": [
            ["type": "thinking", "thinking": [["type": "text", "text": " second part."]]],
            ["type": "text", "text": "Reading."],
        ]],
        ["content": "", "tool_calls": [["index": 0, "id": "abc123456",
            "function": ["name": "read", "arguments": ""]]]],
        ["content": "", "tool_calls": [["index": 0,
            "function": ["name": "", "arguments": "{\"path\":"]]]],
        ["content": "", "tool_calls": [["index": 0,
            "function": ["name": "", "arguments": "\"a.txt\"}"]]]],
        ["content": ""],
    ]
    var sse = Data()
    for (index, delta) in deltas.enumerated() {
        let choice: [String: Any] = ["index": 0, "delta": delta,
            "finish_reason": index == deltas.count - 1 ? "tool_calls" : NSNull()]
        let event: [String: Any] = ["id": "response-1", "model": model.id, "choices": [choice]]
        sse.append(Data("data: ".utf8))
        sse.append(try JSONSerialization.data(withJSONObject: event))
        sse.append(Data("\n\n".utf8))
    }
    sse.append(Data("data: [DONE]\n\n".utf8))
    let message = await streamMistral(model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))])),
        options: MistralOptions(apiKey: "test", httpClient: A3MistralSSEClient(body: sse))).result()

    #expect(message.stopReason == .toolUse)
    #expect(message.content.count == 3)
    if case .thinking(let thought)? = message.content.first {
        #expect(thought.thinking == "first part, second part.")
    } else { Issue.record("Missing thinking block") }
    if case .text(let text)? = message.content.dropFirst().first {
        #expect(text.text == "Reading.")
    } else { Issue.record("Missing text block") }
    if case .toolCall(let tool)? = message.content.last {
        #expect(tool.id == "abc123456")
        #expect(tool.name == "read")
        #expect(tool.arguments["path"]?.value as? String == "a.txt")
    } else { Issue.record("Missing tool call") }
}

private struct A3MistralObserverFailure: Error, LocalizedError {
    var errorDescription: String? { "observer sentinel" }
}

@Test(.timeLimit(.minutes(1))) func a3MistralProviderObserverReceivesRawEventsAndCanFailStream() async throws {
    let model = a3MistralModel("mistral-large-latest")
    let first: [String: Any] = ["id": "response-1", "unknown_field": ["marker": "kept"],
        "choices": [["index": 0, "finish_reason": NSNull(), "delta": ["content": "first"]]]]
    let second: [String: Any] = ["id": "response-1",
        "choices": [["index": 0, "finish_reason": "stop", "delta": ["content": " second"]]]]
    var sse = Data()
    for event in [first, second] {
        sse.append(Data("data: ".utf8))
        sse.append(try JSONSerialization.data(withJSONObject: event))
        sse.append(Data("\n\n".utf8))
    }
    sse.append(Data("data: [DONE]\n\n".utf8))
    let client = A3MistralSSEClient(body: sse)
    let observed = LockedState<[AnyCodable]>([])
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))]))

    let complete = await streamMistral(model: model, context: context,
        options: MistralOptions(apiKey: "test", httpClient: client,
            onProviderStreamEvent: { event, _ in observed.withLock { $0.append(event) } })).result()
    #expect(complete.stopReason == .stop)
    let raw = observed.withLock { $0 }
    #expect(raw.count == 2)
    let firstObject = try #require(raw.first?.value as? [String: Any])
    #expect((firstObject["unknown_field"] as? [String: Any])?["marker"] as? String == "kept")

    let failed = await streamMistral(model: model, context: context,
        options: MistralOptions(apiKey: "test", httpClient: client,
            onProviderStreamEvent: { _, _ in throw A3MistralObserverFailure() })).result()
    #expect(failed.stopReason == .error)
    #expect(failed.errorMessage?.contains("observer sentinel") == true)
}
