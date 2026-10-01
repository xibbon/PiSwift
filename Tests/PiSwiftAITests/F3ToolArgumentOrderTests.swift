import Foundation
import Testing
@testable import PiSwiftAI

private let f3ArgumentsText = #"{"z":{"last":1,"first":2},"a":3}"#

private struct F3HTTPClient: ProviderHTTPClient {
    let body: Data
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func f3Model(_ api: Api) -> Model {
    Model(id: "test-model", name: "Test", api: api, provider: "test",
          baseUrl: api == .googleGeminiCli ? "http://cloudcode-pa.googleapis.com" : "https://example.invalid/v1", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 8192, maxTokens: 1024)
}

private func f3SSE(_ events: [[String: Any]], anthropic: Bool = false) throws -> Data {
    Data(try events.map { event in
        let prefix = anthropic ? "event: \(event["type"] as? String ?? "")\n" : ""
        return prefix + "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined().utf8)
}

private func f3AssertCall(_ message: AssistantMessage) throws {
    #expect(message.stopReason != .error, "\(message.errorMessage ?? "")")
    let call = try #require(message.content.compactMap { block -> ToolCall? in
        if case .toolCall(let call) = block { return call }; return nil
    }.first)
    #expect(call.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
    #expect(orderedToolArguments(call).map(\.key) == ["z", "a"])
    #expect(toolArgumentsToOrderedJSON(call.arguments, argumentsJSON: call.argumentsJSON).serialized() == f3ArgumentsText)
}

@Test func f3HelperUsesJavaScriptArrayIndicesAndStoredOrder() throws {
    let text = #"{"z":1,"10":10,"01":1,"2":2,"4294967295":1,"a":1,"0":0,"4294967294":1,"z":9}"#
    var call = ToolCall(id: "id", name: "test", arguments: [:])
    call.setArguments(from: text)
    #expect(orderedToolArguments(call).map(\.key) == ["0", "2", "10", "4294967294", "z", "01", "4294967295", "a"])
    let fallback = ToolCall(id: "id", name: "test", arguments: call.arguments.mapValues { AnyCodable($0.value) })
    #expect(fallback.argumentsJSON == nil)
    #expect(orderedToolArguments(fallback).map(\.key) == ["0", "2", "10", "4294967294", "01", "4294967295", "a", "z"])
    call.arguments.removeValue(forKey: "z")
    call.arguments["new"] = AnyCodable(1)
    call.arguments["extra"] = AnyCodable(2)
    #expect(orderedToolArguments(call).map(\.key) == ["0", "2", "10", "4294967294", "01", "4294967295", "a", "extra", "new"])
    call.argumentsJSON = try OrderedJSON.parse(#"{"a":0,"missing":0,"a":1}"#, allowDuplicateKeys: true)
    #expect(orderedToolArguments(call).first?.key == "a")
}

@Test func f3MessageCodingKeepsNestedOrderAndCurrentValues() throws {
    var call = ToolCall(id: "id", name: "test", arguments: [:])
    call.setArguments(from: #"{"z":{"b":1,"a":[{"y":2,"x":3}]},"a":3}"#)
    call.arguments["z"] = AnyCodable(["b": 4, "a": [["y": 5, "x": 6]]])
    let encoded = contentBlockToOrderedJSON(.toolCall(call)).serialized()
    #expect(!encoded.contains("argumentsJSON"))
    let data = Data(encoded.utf8)
    let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    guard case .toolCall(let result) = contentBlockFromJSONObject(decoded, ordered: try OrderedJSON.parse(encoded)) else { Issue.record("Missing call"); return }
    #expect(orderedToolArguments(result).map(\.key) == ["z", "a"])
    #expect(toolArgumentsToOrderedJSON(result.arguments, argumentsJSON: result.argumentsJSON).serialized() == #"{"z":{"b":4,"a":[{"y":5,"x":6}]},"a":3}"#)
    let legacy: [String: Any] = ["type": "toolCall", "id": "old", "name": "test", "arguments": ["z": 1, "a": 2]]
    guard case .toolCall(let old) = contentBlockFromJSONObject(legacy) else { Issue.record("Missing old call"); return }
    #expect(old.argumentsJSON == nil)
    #expect(orderedToolArguments(old).map(\.key) == ["a", "z"])
}

@Test func f3ParserKeepsCompletePrefixAndRejectsIncompleteArguments() {
    var call = ToolCall(id: "id", name: "test", arguments: [:])
    call.setArguments(from: f3ArgumentsText + " trailing text")
    #expect(orderedToolArguments(call).map(\.key) == ["z", "a"])
    call.setArguments(from: #"{"z":1,"a":"#)
    #expect(call.arguments.isEmpty)
    #expect(call.argumentsJSON == nil)
    call.setArguments(from: "{}")
    #expect(call.argumentsJSON?.objectEntries?.isEmpty == true)
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.openAICompletions, .anthropicMessages, .openAIResponses, .azureOpenAIResponses, .openAICodexResponses, .mistralConversations])
func f3ProvidersRetainFinalArgumentTextOrder(api: Api) async throws {
    let model = f3Model(api)
    let context = normalizeContext(Context(messages: []))
    let events: [[String: Any]]
    switch api {
    case .openAICompletions:
        events = [["id": "chunk", "created": 0, "model": model.id, "object": "chat.completion.chunk",
                   "choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "id": "call", "type": "function",
                       "function": ["name": "test", "arguments": f3ArgumentsText]]]], "finish_reason": "tool_calls"]]]]
    case .anthropicMessages:
        events = [["type": "message_start", "message": ["type": "message", "role": "assistant", "content": [], "id": "msg", "model": model.id, "usage": ["input_tokens": 1, "output_tokens": 0]]],
                  ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call", "name": "test", "input": [:]]],
                  ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": f3ArgumentsText]],
                  ["type": "content_block_stop", "index": 0],
                  ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]], ["type": "message_stop"]]
    case .mistralConversations:
        events = [["choices": [["delta": ["tool_calls": [["index": 0, "id": "call", "function": ["name": "test", "arguments": f3ArgumentsText]]]], "finish_reason": "tool_calls"]]]]
    default:
        let item: [String: Any] = ["type": "function_call", "id": "item", "call_id": "call", "name": "test", "arguments": f3ArgumentsText, "status": "completed"]
        var start = item; start["arguments"] = ""; start["status"] = "in_progress"
        events = [["type": "response.output_item.added", "output_index": 0, "item": start],
                  ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item", "delta": f3ArgumentsText],
                  ["type": "response.output_item.done", "output_index": 0, "item": item],
                  ["type": "response.completed", "response": ["id": "response", "status": "completed", "output": [item]]]]
    }
    let client = F3HTTPClient(body: try f3SSE(events, anthropic: api == .anthropicMessages))
    let result: AssistantMessage
    switch api {
    case .openAICompletions: result = await streamOpenAICompletions(model: model, context: context, options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    case .anthropicMessages: result = await streamAnthropic(model: model, context: context, options: AnthropicOptions(apiKey: "test", httpClient: client)).result()
    case .openAIResponses: result = await streamOpenAIResponses(model: model, context: context, options: OpenAIResponsesOptions(apiKey: "test", httpClient: client)).result()
    case .azureOpenAIResponses:
        var options = AzureOpenAIResponsesOptions(apiKey: "test", httpClient: client)
        options.azureBaseUrl = "https://azure.example.invalid"; options.azureApiVersion = "v1"; options.azureDeploymentName = "test"
        result = await streamAzureOpenAIResponses(model: model, context: context, options: options).result()
    case .openAICodexResponses:
        let token = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test"}}"#.utf8).base64EncodedString()
        result = await streamOpenAICodexResponses(model: model, context: context, options: OpenAICodexResponsesOptions(apiKey: "e30.\(token).sig", httpClient: client, transport: .sse)).result()
    case .mistralConversations: result = await streamMistral(model: model, context: context, options: MistralOptions(apiKey: "test", httpClient: client)).result()
    default: throw OrderedJSONError.invalid
    }
    try f3AssertCall(result)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func f3GoogleProvidersCaptureObjectOrderBeforeTypedDecoding(vertex: Bool) async throws {
    let model = f3Model(vertex ? .googleVertex : .googleGenerativeAI)
    let payload = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"test\",\"args\":\(f3ArgumentsText)}}]},\"finishReason\":\"STOP\"}]}\n\n"
    let client = F3HTTPClient(body: Data(payload.utf8))
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("run")))]))
    let result: AssistantMessage
    if vertex {
        result = await streamGoogleVertex(model: model, context: context, options: GoogleVertexOptions(apiKey: "test", httpClient: client, project: "project", location: "us-central1")).result()
    } else {
        result = await streamGoogle(model: model, context: context, options: GoogleOptions(apiKey: "test", httpClient: client)).result()
    }
    try f3AssertCall(result)
}

@Test(.timeLimit(.minutes(1))) func f3RawResponsesRetainFinalOrder() async throws {
    let model = f3Model(.openAIResponses)
    let item: [String: Any] = ["type": "function_call", "id": "item", "call_id": "call", "name": "test", "arguments": f3ArgumentsText]
    let client = F3HTTPClient(body: try f3SSE([
        ["type": "response.output_item.added", "output_index": 0, "item": item],
        ["type": "response.output_item.done", "output_index": 0, "item": item],
        ["type": "response.completed", "response": ["status": "completed"]]
    ]))
    var output = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    try await processRawOpenAIResponsesStream(request: URLRequest(url: URL(string: model.baseUrl)!), model: model,
        httpClient: client, signal: nil, maxRetries: 0, maxRetryDelayMs: nil, onResponse: nil,
        serviceTier: nil, grammarToolInputProperties: [:], stream: AssistantMessageEventStream(), output: &output)
    try f3AssertCall(output)
}

@Test func f3BedrockRetainsStreamedArgumentOrder() throws {
    let model = f3Model(.bedrockConverseStream)
    var output = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    for (type, event) in [
        ("contentBlockStart", ["contentBlockIndex": 0, "start": ["toolUse": ["toolUseId": "call", "name": "test"]]] as [String: Any]),
        ("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["toolUse": ["input": f3ArgumentsText]]]),
        ("contentBlockStop", ["contentBlockIndex": 0])
    ] {
        try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: event), model: model, output: &output, state: &state, stream: stream)
    }
    try f3AssertCall(output)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func f3ObjectValuedProviderArgumentsKeepWireOrder(codex: Bool) async throws {
    let model = f3Model(codex ? .openAICodexResponses : .mistralConversations)
    let payload: String
    if codex {
        payload = "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"test\"}}\n\n"
            + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"test\",\"arguments\":\(f3ArgumentsText)}}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
    } else {
        payload = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call\",\"function\":{\"name\":\"test\",\"arguments\":\(f3ArgumentsText)}}]},\"finish_reason\":\"tool_calls\"}]}\n\n"
    }
    let client = F3HTTPClient(body: Data(payload.utf8))
    let result: AssistantMessage
    if codex {
        let token = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"test"}}"#.utf8).base64EncodedString()
        result = await streamOpenAICodexResponses(model: model, context: normalizeContext(Context(messages: [])),
            options: OpenAICodexResponsesOptions(apiKey: "e30.\(token).sig", httpClient: client, transport: .sse)).result()
    } else {
        result = await streamMistral(model: model, context: normalizeContext(Context(messages: [])), options: MistralOptions(apiKey: "test", httpClient: client)).result()
    }
    try f3AssertCall(result)
}

@Test(.timeLimit(.minutes(1))) func f3GeminiCliKeepsRawObjectOrder() async throws {
    try await codexRequestLock.withLock {
        GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "text/event-stream"]))
            let payload = "data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"test\",\"args\":\(f3ArgumentsText)}}]},\"finishReason\":\"STOP\"}]}}\n\n"
            return (response, Data(payload.utf8))
        } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiRetryMockURLProtocol.self]
        let session = URLSession(configuration: config)
        setGoogleGeminiCliSessionOverrideForTesting(session)
        defer {
            setGoogleGeminiCliSessionOverrideForTesting(nil)
            session.invalidateAndCancel()
            GeminiRetryMockURLProtocol.requestHandler.withLock { $0 = nil }
        }
        let model = f3Model(.googleGeminiCli)
        var options = GoogleGeminiCliOptions(apiKey: #"{"token":"test","projectId":"project"}"#)
        options.maxRetries = 0
        let result = await streamGoogleGeminiCli(model: model, context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("run")))])), options: options).result()
        try f3AssertCall(result)
    }
}

@Test(.timeLimit(.minutes(1))) func f3FauxProviderKeepsOrderInFinalMessageAndEndEvent() async throws {
    let model = f3Model(.openAICompletions)
    let registration = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model],
        sourceId: "f3", minTokenSize: 1, maxTokenSize: 3, tokensPerSecond: nil)
    var call = ToolCall(id: "call", name: "test", arguments: [:]); call.setArguments(from: f3ArgumentsText)
    let message = AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    registration.setResponses([.message(message)])
    let stream = fauxStream(model: model, context: normalizeContext(Context(messages: [])), registration: registration, simpleOptions: nil)
    var ends = 0
    for await event in stream {
        if case .toolCallEnd(_, let call, _) = event {
            ends += 1; #expect(call.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
        }
    }
    #expect(ends == 1)
    try f3AssertCall(await stream.result())
}

@Test func f3FrameTextRoundTripKeepsOrderWithoutMetadata() throws {
    var call = ToolCall(id: "id", name: "test", arguments: [:])
    call.setArguments(from: f3ArgumentsText)
    let message = AssistantMessage(content: [.toolCall(call)], api: .openAIResponses, provider: "test", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let frames: [AssistantMessageFrame] = [.start(partial: message), .toolCallStart(contentIndex: 0, toolCall: call), .toolCallEnd(contentIndex: 0, toolCall: call)]
    for frame in frames {
        let text = encodeAssistantMessageFrameJSON(frame)
        #expect(!text.contains("argumentsJSON"))
        let decoded = try decodeAssistantMessageFrameJSON(text)
        switch decoded {
        case .start(let partial): try f3AssertCall(partial)
        case .toolCallStart(_, let tool), .toolCallEnd(_, let tool):
            #expect(orderedToolArguments(tool).map(\.key) == ["z", "a"])
        default: Issue.record("Unexpected frame")
        }
    }
}

@Test func f3FrameReaderAcceptsRepeatedArgumentKeys() throws {
    let text = #"{"type":"toolcall_end","contentIndex":0,"id":"id","name":"test","arguments":{"z":1,"a":2,"z":3}}"#
    guard case .toolCallEnd(_, let call) = try decodeAssistantMessageFrameJSON(text) else {
        Issue.record("Missing final frame call"); return
    }
    #expect(orderedToolArguments(call).map(\.key) == ["z", "a"])
    #expect(call.argumentsJSON?["z"]?.serialized() == "3")
    // Argument values keep the existing dictionary decoder's behavior.
    let dictionaryFrame = try JSONDecoder().decode(AssistantMessageFrame.self, from: Data(text.utf8))
    if case .toolCallEnd(_, let dictionaryCall) = dictionaryFrame { #expect(call.arguments == dictionaryCall.arguments) }
}
