import Foundation
import OpenAI
import Testing
@testable import PiSwiftAI

private typealias Model = PiSwiftAI.Model

private actor EffortResponsesClient: ProviderHTTPClient {
    let body: Data
    private var requestBody: Data?

    init(withToolCall: Bool) throws {
        let item: [String: Any] = withToolCall
            ? ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "lookup", "arguments": "{}", "status": "completed"]
            : ["type": "message", "id": "msg_resp_1", "role": "assistant", "status": "completed",
               "content": [["type": "output_text", "text": "answer", "annotations": []]]]
        let events: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.output_item.added", "output_index": 0, "item": item],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": ["id": "resp_1", "status": "completed"]],
        ]
        body = Data(try events.map {
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n"
        }.joined().utf8)
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requestBody = request.httpBody
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }

    func payload() -> Data? { requestBody }
}

private struct EffortPayload: Decodable, Sendable {
    let input: [[String: AnyCodable]]
    let reasoning: [String: String]?
}

private func effortModel(
    compat: OpenAICompat? = OpenAICompat(supportsMidConvoEffort: true),
    provider: String = "openai", baseUrl: String = "https://api.openai.com/v1",
    map: ThinkingLevelMap? = [.off: "none", .minimal: nil, .low: "low", .medium: "medium", .high: "high", .xhigh: "xhigh", .max: "max"]
) -> Model {
    Model(id: "gpt-6-luna", name: "GPT-6 Luna", api: .openAIResponses, provider: provider,
          baseUrl: baseUrl, reasoning: true, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 272_000,
          maxTokens: 128_000, compat: compat, thinkingLevelMap: map)
}

private func effortUser(_ text: String) -> Message {
    .user(UserMessage(content: .text(text), timestamp: 0))
}

private func effortUpdate(_ effort: String) -> [String: AnyCodable] {
    ["type": AnyCodable("configuration_update"), "reasoning": AnyCodable(["effort": effort])]
}

private func runEffortResponses(
    _ messages: [Message], effort: ThinkingLevel?, model: Model = effortModel(),
    apiKey: String = "sk-test", withToolCall: Bool = false
) async throws -> (payload: EffortPayload, message: AssistantMessage) {
    let client = try EffortResponsesClient(withToolCall: withToolCall)
    let snapshot = LockedState<String?>(nil)
    let result = await streamOpenAIResponses(
        model: model, context: normalizeContext(Context(messages: messages)),
        options: OpenAIResponsesOptions(apiKey: apiKey, httpClient: client, reasoningEffort: effort,
            onPayload: { value in snapshot.withLock { $0 = value.json }; return nil }, maxRetries: 0)
    ).result()
    #expect(result.stopReason == (withToolCall ? .toolUse : .stop))
    let data = try #require(await client.payload())
    let payload = try JSONDecoder().decode(EffortPayload.self, from: data)
    let snapshotJSON = try #require(snapshot.withLock { $0 })
    let captured = try JSONDecoder().decode(EffortPayload.self, from: Data(snapshotJSON.utf8))
    #expect(captured.input == payload.input)
    #expect(captured.reasoning == payload.reasoning)
    return (payload, result)
}

// v1.3.0 openai-responses-mid-convo-effort.test.ts:93.
@Test(.timeLimit(.minutes(1))) func responsesEffortChangePreservesInputPrefix() async throws {
    var history = [effortUser("one")]
    let first = try await runEffortResponses(history, effort: .high)
    history += [.assistant(first.message), effortUser("two")]
    let second = try await runEffortResponses(history, effort: .high)
    history += [.assistant(second.message), effortUser("three")]
    let third = try await runEffortResponses(history, effort: .low)

    #expect(first.payload.input.count == 2)
    #expect(first.payload.input[0]["role"] == AnyCodable("user"))
    // The SDK encodes a text user message as a string.
    #expect(first.payload.input[0]["content"] == AnyCodable("one"))
    #expect(first.payload.input[1] == effortUpdate("high"))
    #expect(Array(second.payload.input.prefix(first.payload.input.count)) == first.payload.input)
    #expect(Array(third.payload.input.prefix(second.payload.input.count)) == second.payload.input)
    for request in [first, second, third] { #expect(request.payload.reasoning?["effort"] == "medium") }
    #expect(third.payload.input.filter { $0["type"] == AnyCodable("configuration_update") }
        == [effortUpdate("high"), effortUpdate("high"), effortUpdate("low")])
    #expect(third.payload.input.last == effortUpdate("low"))
    #expect([first.message.providerThinkingLevel, second.message.providerThinkingLevel, third.message.providerThinkingLevel]
        == ["high", "high", "low"])
}

// v1.3.0 openai-responses-mid-convo-effort.test.ts:123.
@Test(.timeLimit(.minutes(1))) func responsesEffortChangeDuringToolLoop() async throws {
    let history = [effortUser("one")]
    let toolCall = try await runEffortResponses(history, effort: .high, withToolCall: true)
    let result = Message.toolResult(ToolResultMessage(toolCallId: "call_1|fc_1", toolName: "lookup",
        content: [.text(TextContent(text: "result"))], isError: false, timestamp: 0))
    let afterTool = try await runEffortResponses(history + [.assistant(toolCall.message), result], effort: .low)
    #expect(Array(afterTool.payload.input.prefix(toolCall.payload.input.count)) == toolCall.payload.input)
    let ending = Array(afterTool.payload.input.suffix(2))
    #expect(ending[0]["type"] == AnyCodable("function_call_output"))
    #expect(ending[0]["call_id"] == AnyCodable("call_1"))
    #expect(ending[1] == effortUpdate("low"))
    #expect(afterTool.message.providerThinkingLevel == "low")
}

// v1.3.0 openai-responses-mid-convo-effort.test.ts:137. Also check an API change and empty output.
@Test(.timeLimit(.minutes(1))) func responsesEffortUpdatesRequireRecordedSameModelOutput() async throws {
    let unstamped = try await runEffortResponses([effortUser("one")], effort: .high,
        model: effortModel(compat: OpenAICompat())).message
    var otherProvider = unstamped
    otherProvider.provider = "opencode"
    otherProvider.providerThinkingLevel = "high"
    var otherModel = unstamped
    otherModel.model = "gpt-6-sol"
    otherModel.providerThinkingLevel = "high"
    var otherAPI = unstamped
    otherAPI.api = .openAICompletions
    otherAPI.providerThinkingLevel = "high"
    var recorded = unstamped
    recorded.providerThinkingLevel = "high"
    var empty = recorded
    empty.content = []
    let response = try await runEffortResponses([
        effortUser("one"), .assistant(unstamped), effortUser("two"), .assistant(otherProvider),
        effortUser("three"), .assistant(otherModel), effortUser("four"), .assistant(otherAPI),
        effortUser("five"), .assistant(empty), effortUser("six"), .assistant(recorded), effortUser("seven"),
    ], effort: .low)
    #expect(response.payload.input.map { $0["type"] ?? $0["role"] } == [
        "message", "message", "message", "message", "message", "message", "message", "message",
        "message", "message", "configuration_update", "message", "message", "configuration_update",
    ].map(AnyCodable.init))
    #expect(response.payload.input.filter { $0["type"] == AnyCodable("configuration_update") }
        == [effortUpdate("high"), effortUpdate("low")])
}

// v1.3.0 openai-responses-mid-convo-effort.test.ts:193.
@Test(.timeLimit(.minutes(1)), arguments: ["chatgpt", "flag-off", "thinking-off", "flag-missing"])
func responsesEffortOldRequestPath(_ scenario: String) async throws {
    let model = effortModel(compat: scenario == "flag-off" ? OpenAICompat(supportsMidConvoEffort: false)
        : scenario == "flag-missing" ? nil : OpenAICompat(supportsMidConvoEffort: true))
    let apiKey = scenario == "chatgpt" ? "chatgpt-access-token" : "sk-test"
    let first = try await runEffortResponses([effortUser("one")], effort: .high, model: model, apiKey: apiKey)
    let second = try await runEffortResponses([effortUser("one"), .assistant(first.message), effortUser("two")],
        effort: scenario == "thinking-off" ? nil : .low, model: model, apiKey: apiKey)
    #expect(second.payload.reasoning?["effort"] == (scenario == "thinking-off" ? "none" : "low"))
    #expect(!second.payload.input.contains { $0["type"] == AnyCodable("configuration_update") })
    #expect(second.message.providerThinkingLevel == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: [ThinkingLevel.xhigh, .max, .minimal])
func responsesEffortMappingDoesNotChangeFixedRequestEffort(_ effort: ThinkingLevel) async throws {
    let model = effortModel(map: [.off: "none", .minimal: nil, .xhigh: "max", .max: "xhigh"])
    let response = try await runEffortResponses([effortUser("one")], effort: effort, model: model)
    let expected = effort == .xhigh ? "max" : effort == .max ? "xhigh" : "minimal"
    #expect(response.payload.reasoning?["effort"] == "medium")
    #expect(response.payload.input.last == effortUpdate(expected))
    #expect(response.message.providerThinkingLevel == expected)
}

@Test(.timeLimit(.minutes(1)), arguments: ["proxy", "trailing-slash", "other-provider"])
func responsesEffortChatGPTExceptionUsesExactEndpointAndProvider(_ scenario: String) async throws {
    let model = effortModel(provider: scenario == "other-provider" ? "opencode" : "openai",
        baseUrl: scenario == "proxy" ? "https://proxy.invalid/v1"
            : scenario == "trailing-slash" ? "https://api.openai.com/v1/" : "https://api.openai.com/v1")
    let response = try await runEffortResponses([effortUser("one")], effort: .low,
        model: model, apiKey: "non-sk-proxy-token")
    #expect(response.payload.input.last == effortUpdate("low"))
    #expect(response.payload.reasoning?["effort"] == "medium")
    #expect(response.message.providerThinkingLevel == "low")
}

@Test func responsesEffortAbsentCredentialDoesNotDisableUpdates() {
    #expect(responsesConfigurationUpdateEffort(model: effortModel(),
        options: OpenAIResponsesOptions(reasoningEffort: .low)) == "low")
}

@Test(.timeLimit(.minutes(1))) func responsesEffortSaveDecodeResumePreservesCachePrefix() async throws {
    let user = effortUser("one")
    let first = try await runEffortResponses([user], effort: .xhigh)
    let saved = try JSONSerialization.data(withJSONObject: messageToJSONObject(.assistant(first.message)))
    let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    let restored = try #require(messageFromJSONObject(object))
    guard case .assistant(let assistant) = restored else { Issue.record("Expected an assistant message"); return }
    #expect(assistant.providerThinkingLevel == "xhigh")
    let resumed = try await runEffortResponses([user, restored, effortUser("two")], effort: .low)
    #expect(Array(resumed.payload.input.prefix(first.payload.input.count)) == first.payload.input)
    #expect(resumed.payload.input.filter { $0["type"] == AnyCodable("configuration_update") }
        == [effortUpdate("xhigh"), effortUpdate("low")])
    #expect(resumed.message.providerThinkingLevel == "low")
}

@Test func responsesEffortTypedQueryKeepsFixedEffort() throws {
    let model = effortModel()
    let context = Context(messages: [effortUser("one")])
    let options = OpenAIResponsesOptions(apiKey: "sk-test", reasoningEffort: .max)
    let query = try buildResponsesQuery(model: model, context: context, options: options)
    #expect(query.reasoning?.effort == .medium)
    var request = URLRequest(url: URL(string: "https://example.invalid/responses")!)
    request.httpBody = try JSONEncoder().encode(query)
    request = try makeResponsesReplayMiddleware(model: model, context: context,
        configurationUpdateEffort: responsesConfigurationUpdateEffort(model: model, options: options)).intercept(request: request)
    let payload = try JSONDecoder().decode(EffortPayload.self, from: #require(request.httpBody))
    #expect(payload.input.last == effortUpdate("max"))
}
