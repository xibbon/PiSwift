import Foundation
import Testing
@testable import PiSwiftAI

private struct A5ProviderHTTPClient: ProviderHTTPClient {
    let body: Data
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private let a5ProviderAPIs: [Api] = [
    .anthropicMessages, .openAICompletions, .mistralConversations,
    .openAIResponses, .azureOpenAIResponses, .openAICodexResponses,
]
private let a5MalformedArguments = [
    #"{"path":"README.md"} trailing"#,
    #"{"path":"README.md","mode":.5}"#,
    #"{"path":"README.md""#,
    "[]", "null", "1",
]

private func a5ProviderModel(_ api: Api) -> Model {
    Model(id: "test-model", name: "Test", api: api, provider: "test",
          baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 8192, maxTokens: 1024)
}

private func a5ProviderOutput(_ model: Model) -> AssistantMessage {
    AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                     usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                     stopReason: .pending)
}

private func a5ProviderSSE(_ events: [[String: Any]], anthropic: Bool = false) throws -> Data {
    Data(try events.map { event in
        let prefix = anthropic ? "event: \(event["type"] as? String ?? "")\n" : ""
        return prefix + "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined().utf8)
}

private func a5ProviderEvents(api: Api, finalArguments: String) -> [[String: Any]] {
    switch api {
    case .anthropicMessages:
        return [
            ["type": "message_start", "message": ["type": "message", "role": "assistant", "content": [], "id": "msg", "model": "test-model", "usage": ["input_tokens": 1, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call", "name": "edit", "input": [:]]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": finalArguments]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]],
            ["type": "message_stop"],
        ]
    case .openAICompletions:
        return [["id": "chunk", "created": 0, "model": "test-model", "object": "chat.completion.chunk",
                 "choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call", "type": "function", "function": ["name": "edit", "arguments": finalArguments]]]], "finish_reason": "tool_calls"]]]]
    case .mistralConversations:
        return [["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": "edit", "arguments": finalArguments]]]], "finish_reason": "tool_calls"]]]]
    default:
        // A complete streamed object must not replace the final arguments text.
        let item: [String: Any] = ["type": "function_call", "id": "item", "call_id": "call", "name": "edit", "arguments": finalArguments, "status": "completed"]
        var start = item
        start["arguments"] = ""
        start["status"] = "in_progress"
        return [
            ["type": "response.output_item.added", "output_index": 0, "item": start],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item", "delta": #"{"path":"README.md","content":"updated"}"#],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": ["id": "response", "status": "completed", "output": [item]]],
        ]
    }
}

private func a5ProviderStream(api: Api, arguments: String) throws -> AssistantMessageEventStream {
    let model = a5ProviderModel(api)
    let context = normalizeContext(Context(messages: []))
    let client = A5ProviderHTTPClient(body: try a5ProviderSSE(a5ProviderEvents(api: api, finalArguments: arguments), anthropic: api == .anthropicMessages))
    switch api {
    case .anthropicMessages:
        return streamAnthropic(model: model, context: context, options: AnthropicOptions(apiKey: "test", httpClient: client))
    case .openAICompletions:
        return streamOpenAICompletions(model: model, context: context, options: OpenAICompletionsOptions(apiKey: "test", httpClient: client))
    case .mistralConversations:
        return streamMistral(model: model, context: context, options: MistralOptions(apiKey: "test", httpClient: client))
    case .azureOpenAIResponses:
        var options = AzureOpenAIResponsesOptions(apiKey: "test", httpClient: client)
        options.azureBaseUrl = "https://azure.example.invalid"
        options.azureApiVersion = "v1"
        options.azureDeploymentName = "test"
        return streamAzureOpenAIResponses(model: model, context: context, options: options)
    case .openAICodexResponses:
        let token = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test"}}"#.utf8).base64EncodedString()
        return streamOpenAICodexResponses(model: model, context: context,
                                         options: OpenAICodexResponsesOptions(apiKey: "e30.\(token).sig", httpClient: client, transport: .sse))
    default:
        return streamOpenAIResponses(model: model, context: context, options: OpenAIResponsesOptions(apiKey: "test", httpClient: client))
    }
}

private func a5ProviderCall(_ message: AssistantMessage) throws -> ToolCall {
    #expect(message.stopReason != .error, "\(message.errorMessage ?? "")")
    return try #require(message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }
        return nil
    }.first)
}

private func a5ExpectInvalid(_ call: ToolCall, raw: String) {
    #expect(call.arguments.isEmpty)
    #expect(call.argumentsJSON == nil)
    #expect(call.argumentsError?.hasSuffix("\n\nReceived arguments:\n" + raw) == true)
}

// Port of the malformed-final case in openai-responses-partial-json-cleanup.test.ts.
// Each provider must use final parsing at the end of a function call.
@Test(.timeLimit(.minutes(1)), arguments: a5ProviderAPIs, a5MalformedArguments)
func a5ProvidersRejectMalformedFinalArguments(api: Api, raw: String) async throws {
    let stream = try a5ProviderStream(api: api, arguments: raw)
    var endedCalls: [ToolCall] = []
    for await event in stream {
        if case .toolCallEnd(_, let call, _) = event { endedCalls.append(call) }
    }
    let call = try a5ProviderCall(await stream.result())
    a5ExpectInvalid(call, raw: raw)
    #expect(endedCalls.count == 1)
    a5ExpectInvalid(try #require(endedCalls.first), raw: raw)
}

@Test(.timeLimit(.minutes(1)), arguments: a5ProviderAPIs, ["", " \n\t"])
func a5ProvidersAcceptBlankFinalArguments(api: Api, raw: String) async throws {
    let call = try a5ProviderCall(await a5ProviderStream(api: api, arguments: raw).result())
    if raw.isEmpty && [.openAIResponses, .azureOpenAIResponses, .openAICodexResponses].contains(api) {
        #expect(call.arguments["path"]?.value as? String == "README.md")
        #expect(call.arguments["content"]?.value as? String == "updated")
    } else {
        #expect(call.arguments.isEmpty)
    }
    #expect(call.argumentsError == nil)
}

@Test(.timeLimit(.minutes(1)), arguments: a5ProviderAPIs)
func a5ProvidersKeepRepairedFinalArgumentOrder(api: Api) async throws {
    let call = try a5ProviderCall(await a5ProviderStream(api: api, arguments: #"{"z":"\usepackage","a":2}"#).result())
    #expect(call.arguments["z"]?.value as? String == #"\usepackage"#)
    #expect(orderedToolArguments(call).map(\.key) == ["z", "a"])
    #expect(call.argumentsError == nil)
}

@Test(arguments: a5MalformedArguments)
func a5BedrockRejectsMalformedFinalArguments(raw: String) throws {
    let model = a5ProviderModel(.bedrockConverseStream)
    var output = a5ProviderOutput(model)
    var state = BedrockStreamState()
    for (type, payload) in [
        ("contentBlockStart", ["contentBlockIndex": 0, "start": ["toolUse": ["toolUseId": "call", "name": "edit"]]] as [String: Any]),
        ("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["toolUse": ["input": raw]]]),
        ("contentBlockStop", ["contentBlockIndex": 0]),
    ] {
        try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: payload), model: model,
                                  output: &output, state: &state, stream: AssistantMessageEventStream())
    }
    a5ExpectInvalid(try a5ProviderCall(output), raw: raw)
}

// Grammar input is text. It does not use the function-argument JSON parser.
@Test(.timeLimit(.minutes(1)))
func a5RawResponsesKeepsGrammarInputAsText() async throws {
    let raw = #"{"incomplete":.5"#
    let item: [String: Any] = ["type": "custom_tool_call", "id": "item", "call_id": "call", "name": "write", "input": raw]
    let client = A5ProviderHTTPClient(body: try a5ProviderSSE([
        ["type": "response.output_item.added", "output_index": 0, "item": item],
        ["type": "response.output_item.done", "output_index": 0, "item": item],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]))
    let model = a5ProviderModel(.openAIResponses)
    var output = a5ProviderOutput(model)
    try await processRawOpenAIResponsesStream(request: URLRequest(url: URL(string: model.baseUrl)!), model: model,
        httpClient: client, signal: nil, maxRetries: 0, maxRetryDelayMs: nil, onResponse: nil,
        serviceTier: nil, grammarToolInputProperties: ["write": "value"], stream: AssistantMessageEventStream(), output: &output)
    let call = try a5ProviderCall(output)
    #expect(call.arguments["value"]?.value as? String == raw)
    #expect(call.argumentsError == nil)
}

// Port of the two-text fixture in openai-responses-message-id.test.ts.
@Test func a5ResponsesUsesUniqueFallbackIDsForTwoTextBlocks() throws {
    let model = a5ProviderModel(.openAIResponses)
    let assistant = AssistantMessage(content: [.text(TextContent(text: "first answer")), .text(TextContent(text: "visible answer"))],
        api: .anthropicMessages, provider: "anthropic", model: "claude-test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let context = Context(messages: [.user(UserMessage(content: .text("hello"))), .assistant(assistant)])
    let input = convertResponsesMessages(model: model, context: context, allowedToolCallProviders: ["openai", "openai-codex", "opencode"])
    let items = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [[String: Any]])
    let ids = items.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }.compactMap { $0["id"] as? String }
    #expect(ids == ["msg_pi_1", "msg_pi_1_1"])
    #expect(Set(ids).count == ids.count)
}

@Test(.timeLimit(.minutes(1)))
func a5RawResponsesFinalArgumentsClearStreamedState() async throws {
    let raw = #"{"path":"README.md","content":"updated","mode":.5}"#
    var events = a5ProviderEvents(api: .openAIResponses, finalArguments: raw)
    events.insert(["type": "response.function_call_arguments.done", "output_index": 0, "arguments": raw], at: 2)
    let client = A5ProviderHTTPClient(body: try a5ProviderSSE(events))
    let model = a5ProviderModel(.openAIResponses)
    var output = a5ProviderOutput(model)
    let stream = AssistantMessageEventStream()
    try await processRawOpenAIResponsesStream(request: URLRequest(url: URL(string: model.baseUrl)!), model: model,
        httpClient: client, signal: nil, maxRetries: 0, maxRetryDelayMs: nil, onResponse: nil,
        serviceTier: nil, grammarToolInputProperties: [:], stream: stream, output: &output)
    stream.end(output)
    var endedCalls: [ToolCall] = []
    for await event in stream {
        if case .toolCallEnd(_, let call, _) = event { endedCalls.append(call) }
    }
    a5ExpectInvalid(try a5ProviderCall(output), raw: raw)
    #expect(endedCalls.count == 1)
    a5ExpectInvalid(try #require(endedCalls.first), raw: raw)
    let encoded = contentBlockToOrderedJSON(.toolCall(try a5ProviderCall(output))).serialized()
    #expect(!encoded.contains("partialJson"))
    #expect(!encoded.contains("partialInput"))
    #expect(encoded.contains("argumentsError"))
}

// The upstream fixture targets Codex. Exercise its separate request body conversion.
@Test(.timeLimit(.minutes(1)))
func a5CodexRequestUsesUniqueFallbackIDsForTwoTextBlocks() async throws {
    let model = getModel(provider: .openaiCodex, modelId: "gpt-6.1-sol")
    let assistant = AssistantMessage(content: [.text(TextContent(text: "first answer")), .text(TextContent(text: "visible answer"))],
        api: .anthropicMessages, provider: "anthropic", model: "claude-opus-4-8",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    let context = Context(systemPrompt: "You are concise.", messages: [.user(UserMessage(content: .text("hello"))), .assistant(assistant)])
    let converted = try #require(convertCodexMessages(model: model, context: context) as? [[String: Any]])
    let convertedMessages = converted.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }
    let ids = convertedMessages.compactMap { $0["id"] as? String }
    #expect(ids == ["msg_pi_1", "msg_pi_1_1"])
    #expect(Set(ids).count == ids.count)
    let payload = LockedState<String?>(nil)
    let client = A5ProviderHTTPClient(body: try a5ProviderSSE([
        ["type": "response.completed", "response": ["status": "completed"]],
    ]))
    let token = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test"}}"#.utf8).base64EncodedString()
    let result = await streamOpenAICodexResponses(model: model, context: normalizeContext(context),
        options: OpenAICodexResponsesOptions(apiKey: "e30.\(token).sig", httpClient: client, transport: .sse,
            onPayload: { snapshot in payload.withLock { $0 = snapshot.json }; return nil })).result()
    #expect(result.stopReason == .stop, "\(result.errorMessage ?? "")")
    let json = try #require(payload.withLock { $0 })
    let body = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let items = try #require(body["input"] as? [[String: Any]])
    let messages = items.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }
    // The existing Codex request transformer removes item IDs after conversion.
    #expect(messages.allSatisfy { $0["id"] == nil })
    let texts = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }
    #expect(texts == ["first answer", "visible answer"])
}
