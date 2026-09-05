import Foundation
import Testing
@testable import PiSwiftAI

private actor Completions085Client: ProviderHTTPClient {
    let frames: Data
    let failAfterBody: Bool
    var requests: [URLRequest] = []

    init(frames: Data, failAfterBody: Bool = false) {
        self.frames = frames
        self.failAfterBody = failAfterBody
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        if failAfterBody {
            return ProviderHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
                continuation.yield(frames)
                continuation.finish(throwing: Completions085Error.interrupted)
            })
        }
        return ProviderHTTPResponse(statusCode: 200, body: frames)
    }

    func lastRequest() -> URLRequest? { requests.last }
}

private enum Completions085Error: Error { case interrupted }

private func completions085Model(
    compat: OpenAICompat? = nil,
    provider: String = "openrouter",
    baseUrl: String = "https://example.invalid/v1",
    headers: ProviderHeaders? = nil,
    thinkingLevelMap: ThinkingLevelMap? = nil
) -> Model {
    Model(id: "google/gemini-test", name: "Test", api: .openAICompletions, provider: provider,
          baseUrl: baseUrl, reasoning: true, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 262_144, maxTokens: 16_384, headers: headers, compat: compat, thinkingLevelMap: thinkingLevelMap)
}

private func completions085Frame(_ delta: [String: Any], finish: String? = nil, usage: [String: Any]? = nil) throws -> Data {
    var chunk: [String: Any] = [
        "id": "chatcmpl-test", "created": 0, "model": "google/gemini-test",
        "object": "chat.completion.chunk",
        "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]],
    ]
    if let usage { chunk["usage"] = usage }
    var data = Data("data: ".utf8)
    data.append(try JSONSerialization.data(withJSONObject: chunk))
    data.append(Data("\n\n".utf8))
    return data
}

private func completions085ToolFrame() throws -> Data {
    try completions085Frame(["tool_calls": [[
        "index": 0, "id": "call_1", "type": "function",
        "function": ["name": "read", "arguments": "{\"path\":\"README.md\"}"],
    ]]])
}

private func completions085Capture(
    model: Model = completions085Model(),
    messages: [Message] = [.user(UserMessage(content: .text("Hi")))],
    tools: [AITool]? = nil,
    options: OpenAICompletionsOptions = OpenAICompletionsOptions(apiKey: "test")
) async throws -> [String: Any] {
    let client = Completions085Client(frames: try completions085Frame([:], finish: "stop"))
    var options = options
    options.httpClient = client
    _ = await streamOpenAICompletions(model: model, context: Context(messages: messages, tools: tools), options: options).result()
    let request = try #require(await client.lastRequest())
    let requestBody = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
}

private func completions085Thinking(_ message: AssistantMessage) throws -> ThinkingContent {
    try #require(message.content.compactMap { block -> ThinkingContent? in
        if case .thinking(let thinking) = block { return thinking }
        return nil
    }.first)
}

private func completions085Details(_ message: AssistantMessage) throws -> [[String: AnyCodable]] {
    let signature = try #require(try completions085Thinking(message).thinkingSignature)
    return try JSONDecoder().decode([[String: AnyCodable]].self, from: Data(signature.utf8))
}

private func completions085AssistantPayload(_ message: AssistantMessage) async throws -> [String: Any] {
    let payload = try await completions085Capture(messages: [.assistant(message)])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    return try #require(messages.first { $0["role"] as? String == "assistant" })
}

@Test func completions085PreservesEncryptedReasoningInThinkingSignature() async throws {
    let detail: [String: Any] = ["type": "reasoning.encrypted", "id": "call_1", "data": "encrypted-signature"]
    let frames = try completions085Frame(["reasoning_details": [detail]]) + completions085ToolFrame() + completions085Frame([:], finish: "tool_calls")
    let client = Completions085Client(frames: frames)
    let result = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.stopReason == .toolUse)
    #expect(try completions085Thinking(result).thinking == "")
    #expect(try completions085Details(result) == [detail.mapValues(AnyCodable.init)])
    let tool = try #require(result.content.compactMap { block -> ToolCall? in
        if case .toolCall(let tool) = block { return tool }; return nil
    }.first)
    #expect(tool.thoughtSignature == nil)
    #expect(tool.arguments["path"]?.value as? String == "README.md")
    let replay = try await completions085AssistantPayload(result)
    #expect((replay["reasoning_details"] as? [[String: Any]])?.count == 1)
}

@Test func completions085ReplaysLegacyEncryptedToolSignatures() async throws {
    let signature = #"{"type":"reasoning.encrypted","id":"call_1","data":"encrypted-signature"}"#
    let model = completions085Model()
    let message = AssistantMessage(content: [.toolCall(ToolCall(id: "call_1", name: "read", arguments: [:], thoughtSignature: signature))],
        api: model.api, provider: model.provider, model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let replay = try await completions085AssistantPayload(message)
    let details = try #require(replay["reasoning_details"] as? [[String: Any]])
    #expect(details.first?["data"] as? String == "encrypted-signature")
}

@Test func completions085PreservesSignedTextAndSummaryOrder() async throws {
    let details: [[String: Any]] = [
        ["type": "reasoning.text", "text": "I should call read.", "signature": "sha256:signed-text", "id": "text-1", "format": "anthropic-claude-v1", "index": 0],
        ["type": "reasoning.encrypted", "id": "call_1", "data": "opaque"],
        ["type": "reasoning.summary", "summary": "Inspect the file.", "id": "summary-1", "format": "anthropic-claude-v1", "index": 1],
    ]
    let frames = try completions085Frame(["reasoning": "I should call read.", "reasoning_details": [details[0]]])
        + completions085Frame(["reasoning_details": Array(details.dropFirst())]) + completions085ToolFrame()
        + completions085Frame([:], finish: "tool_calls")
    let client = Completions085Client(frames: frames)
    let result = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(try completions085Thinking(result).thinking == "I should call read.")
    #expect(try completions085Details(result) == details.map { $0.mapValues(AnyCodable.init) })
    let replay = try await completions085AssistantPayload(result)
    #expect(replay["reasoning"] == nil)
    #expect((replay["reasoning_details"] as? [[String: Any]])?.count == 3)
}

@Test func completions085MergesConsecutiveReasoningDetails() async throws {
    let details: [[String: Any]] = [
        ["type": "reasoning.text", "text": "The", "index": 0],
        ["type": "reasoning.text", "text": " user wants the time.", "signature": "sha256:text", "format": "openai-responses-v1", "index": 0],
        ["type": "reasoning.summary", "summary": "Looked", "index": 0],
        ["type": "reasoning.summary", "summary": " up time.", "format": "openai-responses-v1", "index": 0],
        ["type": "reasoning.encrypted", "id": "call_1", "data": "opaque"],
        ["type": "reasoning.summary", "summary": "After encrypted block.", "format": "openai-responses-v1", "index": 0],
    ]
    var frames = Data()
    for detail in details { frames += try completions085Frame(["reasoning_details": [detail]]) }
    frames += try completions085ToolFrame() + completions085Frame([:], finish: "tool_calls")
    let client = Completions085Client(frames: frames)
    let stream = streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client))
    var ends = 0
    for await event in stream {
        if case .thinkingEnd(_, _, let partial) = event {
            ends += 1
            #expect(try completions085Details(partial).count == 4)
        }
    }
    let result = await stream.result()
    #expect(ends == 1)
    let merged = try completions085Details(result)
    #expect(merged.count == 4)
    #expect(merged[0]["text"]?.value as? String == "The user wants the time.")
    #expect(merged[0]["signature"]?.value as? String == "sha256:text")
    #expect(merged[1]["summary"]?.value as? String == "Looked up time.")
    #expect(merged[2]["type"]?.value as? String == "reasoning.encrypted")
    #expect(merged[3]["summary"]?.value as? String == "After encrypted block.")
    let replay = try await completions085AssistantPayload(result)
    #expect((replay["reasoning_details"] as? [[String: Any]])?.count == 4)
}

@Test func completions085FinalizesReasoningMetadataOnError() async throws {
    let detail: [String: Any] = ["type": "reasoning.encrypted", "data": "opaque"]
    let client = Completions085Client(frames: try completions085Frame(["reasoning_details": [detail]]), failAfterBody: true)
    let result = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.stopReason == .error)
    #expect(try completions085Details(result) == [detail.mapValues(AnyCodable.init)])
}

@Test func completions085RejectsInvalidReasoningDetailsAndRawFieldNames() async throws {
    let invalid: [Any] = [NSNull(), ["type": "reasoning.text", "text": 42],
        ["type": "reasoning.text", "text": "bad", "index": true],
        ["type": "reasoning.encrypted", "data": "bad", "format": NSNull()],
        ["type": "unknown", "text": "bad"]]
    let client = Completions085Client(frames: try completions085Frame(["reasoning_details": invalid, "content": "ok"], finish: "stop"))
    let result = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(!result.content.contains { if case .thinking = $0 { return true }; return false })
    var message = result
    message.content.insert(.thinking(ThinkingContent(thinking: "private", thinkingSignature: "arbitrary_field")), at: 0)
    let replay = try await completions085AssistantPayload(message)
    #expect(replay["arbitrary_field"] == nil)
}

@Test func completions085PriorityIsOptionalAndPreservesZero() async throws {
    for value in [10, 0, -1] {
        var compat = OpenAICompat()
        compat.vllmPriority = value
        let payload = try await completions085Capture(model: completions085Model(compat: compat))
        #expect(payload["priority"] as? Int == value)
    }
    let payload = try await completions085Capture()
    #expect(payload["priority"] == nil)
}

@Test func completions085SupportsAllThinkingBudgetFields() async throws {
    for field in [ThinkingTokenBudgetField.thinkingTokenBudget, .thinkingBudget, .thinkingBudgetTokens] {
        var compat = OpenAICompat(thinkingFormat: .qwen)
        compat.thinkingTokenBudgetField = field
        let payload = try await completions085Capture(model: completions085Model(compat: compat),
            options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .medium, thinkingBudgets: [.medium: 4096]))
        #expect(payload[field.rawValue] as? Int == 4096)
        for other in ["thinking_token_budget", "thinking_budget", "thinking_budget_tokens"] where other != field.rawValue {
            #expect(payload[other] == nil)
        }
    }
}

@Test func completions085ThinkingBudgetFieldOverridesAlias() async throws {
    var compat = OpenAICompat(thinkingFormat: .zai, supportsThinkingTokenBudget: true)
    compat.thinkingTokenBudgetField = .thinkingBudget
    let payload = try await completions085Capture(model: completions085Model(compat: compat),
        options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .medium, thinkingBudgets: [.medium: 4096]))
    #expect(payload["thinking_budget"] as? Int == 4096)
    #expect(payload["thinking_token_budget"] == nil)
}

@Test func completions085ThinkingBudgetDefaultsClampsAndOff() async throws {
    let model = completions085Model(compat: OpenAICompat(thinkingFormat: .zai, supportsThinkingTokenBudget: true))
    for level in [ThinkingLevel.xhigh, .max] {
        let payload = try await completions085Capture(model: model,
            options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: level, thinkingBudgets: [.high: 8192]))
        #expect(payload["thinking_token_budget"] as? Int == 8192)
    }
    let defaults = try await completions085Capture(model: model, options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .high))
    #expect(defaults["thinking_token_budget"] as? Int == 16384 - 1024)
    let capped = try await completions085Capture(model: model, options: OpenAICompletionsOptions(maxTokens: 4096, apiKey: "test", reasoningEffort: .high))
    #expect(capped["thinking_token_budget"] as? Int == 4096 - 1024)
    let off = try await completions085Capture(model: model)
    #expect(off["thinking_token_budget"] == nil)
    let unset = try await completions085Capture(options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .high))
    #expect(unset["thinking_token_budget"] == nil)
}

@Test func completions085ChatTemplatesUseSameBudgetAsTopLevel() async throws {
    for format in [OpenAICompatThinkingFormat.chatTemplate, .baseten] {
        let values: [String: ChatTemplateKwargValue] = [
            "enable_thinking": .variable(.thinkingEnabled), "thinking_budget": .variable(.thinkingBudget),
        ]
        var compat = OpenAICompat(thinkingFormat: format)
        compat.chatTemplateKwargs = values
        compat.chatTemplateArgs = values
        compat.thinkingTokenBudgetField = .thinkingBudgetTokens
        let model = completions085Model(compat: compat)
        let payload = try await completions085Capture(model: model,
            options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .high))
        let key = format == .baseten ? "chat_template_args" : "chat_template_kwargs"
        let template = try #require(payload[key] as? [String: Any])
        #expect(template["enable_thinking"] as? Bool == true)
        #expect(template["thinking_budget"] as? Int == 16384 - 1024)
        #expect(payload["thinking_budget_tokens"] as? Int == template["thinking_budget"] as? Int)
        let off = try await completions085Capture(model: model)
        let offTemplate = try #require(off[key] as? [String: Any])
        #expect(offTemplate["enable_thinking"] as? Bool == false)
        #expect(offTemplate["thinking_budget"] == nil)
    }
}

@Test func completions085ToolChoiceIsSentWithoutTools() async throws {
    let payload = try await completions085Capture(options: OpenAICompletionsOptions(apiKey: "test", toolChoice: OpenAIToolChoice.none))
    #expect(payload["tool_choice"] as? String == "none")
    #expect(payload["tools"] == nil)
}

@Test func completions085SimpleToolChoiceIsForwarded() async throws {
    let client = Completions085Client(frames: try completions085Frame([:], finish: "stop"))
    let result = try await streamSimple(model: completions085Model(), context: Context(messages: [.user(UserMessage(content: .text("Hi")))]),
        options: SimpleStreamOptions(apiKey: "test", httpClient: client, toolChoice: ToolChoice.none)).result()
    #expect(result.stopReason == .stop)
    let request = try #require(await client.lastRequest())
    let requestBody = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    #expect(payload["tool_choice"] as? String == "none")
    #expect(payload["tools"] == nil)
}

@Test func completions085DeepSeekUsesMaxTokensForMixedCaseURLs() async throws {
    for url in ["https://api.deepseek.com", "https://API.DeepSeek.COM"] {
        let model = completions085Model(provider: "custom-deepseek", baseUrl: url)
        let payload = try await completions085Capture(model: model, options: OpenAICompletionsOptions(maxTokens: 123, apiKey: "test"))
        #expect(payload["max_tokens"] as? Int == 123)
        #expect(payload["max_completion_tokens"] == nil)
    }
}

@Test func completions085TopLevelCachedTokensAreCacheReads() async throws {
    let client = Completions085Client(frames: try completions085Frame([:], finish: "stop",
        usage: ["prompt_tokens": 100, "completion_tokens": 5, "cached_tokens": 40]))
    let result = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.usage.input == 60)
    #expect(result.usage.cacheRead == 40)
    #expect(result.usage.totalTokens == 105)
}

@Test func completions085OpenRouterMandatoryReasoningRemainsEnabled() async throws {
    let model = completions085Model(thinkingLevelMap: [.off: nil, .low: "low", .high: "high", .max: "max"])
    let background = try await completions085Capture(model: model)
    #expect(background["reasoning"] == nil)
    let selected = try await completions085Capture(model: model, options: OpenAICompletionsOptions(apiKey: "test", reasoningEffort: .low))
    #expect((selected["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    let optional = try await completions085Capture()
    #expect((optional["reasoning"] as? [String: Any])?["effort"] as? String == "none")
}

@Test func completions085UserAgentAllowsHeaderOverridesAndDeletion() async throws {
    for override in ["custom-agent", ""] {
        let model = completions085Model(headers: ["User-Agent": "model-agent"])
        let client = Completions085Client(frames: try completions085Frame([:], finish: "stop"))
        _ = await streamOpenAICompletions(model: model, context: Context(messages: []),
            options: OpenAICompletionsOptions(apiKey: "test", httpClient: client,
                headers: ["user-agent": override.isEmpty ? nil : override])).result()
        let request = try #require(await client.lastRequest())
        #expect(request.value(forHTTPHeaderField: "User-Agent") == (override.isEmpty ? nil : override))
    }
    let client = Completions085Client(frames: try completions085Frame([:], finish: "stop"))
    _ = await streamOpenAICompletions(model: completions085Model(), context: Context(messages: []),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    let request = try #require(await client.lastRequest())
    #expect(request.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
}

@Test func completions085StrictSchemaConvertsOptionalProperties() async throws {
    let tool = AITool(name: "read", description: "Read a file", parameters: [
        "type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]]),
    ], constrainedSampling: .jsonSchema(strict: .require))
    let payload = try await completions085Capture(tools: [tool])
    let tools = try #require(payload["tools"] as? [[String: Any]])
    let function = try #require(tools.first?["function"] as? [String: Any])
    let schema = try #require(function["parameters"] as? [String: Any])
    #expect(function["strict"] as? Bool == true)
    #expect(schema["required"] as? [String] == ["path"])
    #expect(schema["additionalProperties"] as? Bool == false)
    let properties = try #require(schema["properties"] as? [String: Any])
    let path = try #require(properties["path"] as? [String: Any])
    #expect((path["anyOf"] as? [[String: Any]])?.last?["type"] as? String == "null")
}
