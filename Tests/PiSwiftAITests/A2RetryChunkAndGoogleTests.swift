import Foundation
import Testing
@testable import PiSwiftAI

@Test(arguments: [
    "The service is temporarily unavailable. Please retry later.",
    "Service unavailable: The service is temporarily unavailable.",
    "The upstream provider returned an error",
    "Unable to forward upstream stream",
    "SERVICE IS TEMPORARILY UNAVAILABLE",
])
func a2RetryMatchesNewProviderTexts(_ text: String) {
    var message = AssistantMessage(content: [], api: .openAIResponses, provider: "openai", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .error, errorMessage: text)
    #expect(isRetryableAssistantError(message))
    message.errorMessage = "quota exceeded: \(text)"
    #expect(!isRetryableAssistantError(message))
    message.errorMessage = "billing: \(text)"
    #expect(!isRetryableAssistantError(message))
    message.stopReason = .stop; message.errorMessage = text
    #expect(!isRetryableAssistantError(message))
}

private actor A2ChunkHTTPClient: ProviderHTTPClient {
    let body: Data
    var request: URLRequest?
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private func a2ChunkModel(api: Api = .openAICompletions, id: String = "test") -> Model {
    Model(id: id, name: id, api: api, provider: "test", baseUrl: "https://example.invalid/v1",
        reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 4096)
}

private func a2ChunkFrame(
    _ delta: [String: Any], finish: String? = "stop", id: String = "chunk-test", usage: [String: Any]? = nil
) throws -> Data {
    var object: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": 0,
        "model": "test", "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
    if let usage { object["usage"] = usage }
    return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: object)) + Data("\n\n".utf8)
}

@Test(.timeLimit(.minutes(1)), arguments: ["reasoning_content", "reasoning", "reasoning_text", "reasoning_details"])
func a2CompletionsThinkingPrecedesTextInOneChunk(_ field: String) async throws {
    var delta: [String: Any] = ["content": "answer"]
    if field == "reasoning_details" { delta[field] = [["type": "reasoning.encrypted", "data": "opaque"]] }
    else { delta[field] = "thinking" }
    let client = A2ChunkHTTPClient(body: try a2ChunkFrame(delta))
    let stream = streamOpenAICompletions(model: a2ChunkModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client))
    var starts: [String] = []
    for await event in stream {
        if case .thinkingStart = event { starts.append("thinking") }
        if case .textStart = event { starts.append("text") }
    }
    let result = await stream.result()
    #expect(result.stopReason == .stop)
    #expect(starts == ["thinking", "text"])
    #expect(result.content.count == 2)
    guard case .thinking(let thinking) = result.content.first else { Issue.record("Expected thinking first"); return }
    guard case .text(let text) = result.content.last else { Issue.record("Expected text last"); return }
    #expect(text.text == "answer")
    if field == "reasoning_details" { #expect(thinking.thinkingSignature?.contains("opaque") == true) }
    else { #expect(thinking.thinking == "thinking"); #expect(thinking.thinkingSignature == field) }
}

@Test(.timeLimit(.minutes(1))) func a2CompletionsMixedChunkKeepsSixBlockOrder() async throws {
    // Port the A9 six-block order from openai-completions-tool-choice.test.ts:1108-1114.
    let names = ["read", "grep", "list", "write"]
    let calls: [[String: Any]] = names.enumerated().map { index, name in
        ["index": index, "id": "call_\(index)", "type": "function", "function": ["name": name, "arguments": "{}"]]
    }
    let client = A2ChunkHTTPClient(body: try a2ChunkFrame(["reasoning_content": "think 1 think 2", "content": "answer 1 answer 2\n", "tool_calls": calls], finish: "tool_calls"))
    let result = await streamOpenAICompletions(model: a2ChunkModel(), context: normalizeContext(Context(messages: [])),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.stopReason == .toolUse)
    #expect(result.content.count == 6)
    guard result.content.count == 6 else { return }
    guard case .thinking(let thinking) = result.content[0], case .text(let text) = result.content[1] else { Issue.record("Expected thinking then text"); return }
    #expect(thinking.thinking == "think 1 think 2")
    #expect(thinking.thinkingSignature == "reasoning_content")
    #expect(text.text == "answer 1 answer 2\n")
    #expect(result.content.dropFirst(2).compactMap { if case .toolCall(let tool) = $0 { return tool.name }; return nil } == names)
}

@Test(.timeLimit(.minutes(1))) func a2CompletionsInterleavedDeltasRetainSixBlocksAndToolArguments() async throws {
    // Port of v1.3.0 openai-completions-tool-choice.test.ts:921-1150.
    let first: [String: Any] = [
        "content": "answer 1",
        "reasoning_content": "think 1",
        "tool_calls": [
            ["index": 0, "id": "tc_read_initial", "type": "function",
                "function": ["name": "read", "arguments": #"{"path":"README"#]],
            ["index": 1, "id": "tc_grep_initial", "type": "function",
                "function": ["name": "grep", "arguments": #"{"pattern":"TODO"#]],
            ["id": "tc_list_no_index", "type": "function",
                "function": ["name": "list", "arguments": #"{"path":"packages"#]],
            ["id": "tc_write_no_index", "type": "function",
                "function": ["name": "write", "arguments": #"{"path":"out"#]],
        ],
    ]
    let second: [String: Any] = [
        "content": " answer 2",
        "tool_calls": [
            ["index": 1, "id": "tc_grep_changed", "type": "function",
                "function": ["arguments": #"","path":"src"#]],
            ["id": "tc_write_no_index", "type": "function",
                "function": ["arguments": #".txt","content":"ok"}"#]],
            ["id": "tc_list_no_index", "type": "function",
                "function": ["arguments": #"/ai"}"#]],
        ],
    ]
    let third: [String: Any] = [
        "content": "\n",
        "reasoning_content": " think 2",
        "tool_calls": [
            ["index": 0, "id": "tc_read_changed", "type": "function",
                "function": ["arguments": #".md"}"#]],
            ["index": 1, "type": "function", "function": ["arguments": #""}"#]],
        ],
    ]
    var body = try a2ChunkFrame(first, finish: nil, id: "chatcmpl-mixed-deltas")
    body += try a2ChunkFrame(second, finish: nil, id: "chatcmpl-mixed-deltas")
    body += try a2ChunkFrame(third, finish: "tool_calls", id: "chatcmpl-mixed-deltas", usage: [
        "prompt_tokens": 10, "completion_tokens": 8,
        "prompt_tokens_details": ["cached_tokens": 0],
        "completion_tokens_details": ["reasoning_tokens": 2],
    ])
    let toolDefinitions: [(String, String, [String])] = [
        ("read", "Read a file", ["path"]),
        ("grep", "Search a file", ["pattern", "path"]),
        ("list", "List a directory", ["path"]),
        ("write", "Write a file", ["path", "content"]),
    ]
    let tools = toolDefinitions.map { name, description, properties in
        AITool(name: name, description: description, parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(Dictionary(uniqueKeysWithValues: properties.map { ($0, ["type": "string"]) })),
            "required": AnyCodable(properties),
        ])
    }
    let client = A2ChunkHTTPClient(body: body)
    let context = normalizeContext(Context(
        messages: [.user(UserMessage(content: .text("Think, answer, and use tools.")))], tools: tools
    ))
    let stream = streamOpenAICompletions(model: a2ChunkModel(), context: context,
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client))
    var eventCounts: [String: Int] = [:]
    var toolEventsByContentIndex: [Int: [String]] = [:]
    for await event in stream {
        let eventType: String
        var toolContentIndex: Int?
        switch event {
        case .start: eventType = "start"
        case .textStart: eventType = "text_start"
        case .textDelta: eventType = "text_delta"
        case .textEnd: eventType = "text_end"
        case .thinkingStart: eventType = "thinking_start"
        case .thinkingDelta: eventType = "thinking_delta"
        case .thinkingEnd: eventType = "thinking_end"
        case .toolCallStart(let index, _): eventType = "toolcall_start"; toolContentIndex = index
        case .toolCallDelta(let index, _, _): eventType = "toolcall_delta"; toolContentIndex = index
        case .toolCallEnd(let index, _, _): eventType = "toolcall_end"; toolContentIndex = index
        case .done: eventType = "done"
        case .error: eventType = "error"
        }
        eventCounts[eventType, default: 0] += 1
        if let index = toolContentIndex { toolEventsByContentIndex[index, default: []].append(eventType) }
    }
    let response = await stream.result()
    #expect(response.stopReason == .toolUse)
    #expect(eventCounts["text_start"] == 1)
    #expect(eventCounts["text_delta"] == 3)
    #expect(eventCounts["text_end"] == 1)
    #expect(eventCounts["thinking_start"] == 1)
    #expect(eventCounts["thinking_delta"] == 2)
    #expect(eventCounts["thinking_end"] == 1)
    #expect(eventCounts["toolcall_start"] == 4)
    #expect(eventCounts["toolcall_delta"] == 9)
    #expect(eventCounts["toolcall_end"] == 4)
    #expect(toolEventsByContentIndex[2] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])
    #expect(toolEventsByContentIndex[3] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_delta", "toolcall_end"])
    #expect(toolEventsByContentIndex[4] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])
    #expect(toolEventsByContentIndex[5] == ["toolcall_start", "toolcall_delta", "toolcall_delta", "toolcall_end"])
    #expect(response.content.count == 6)
    guard response.content.count == 6 else { return }
    #expect(NSDictionary(dictionary: contentBlockToJSONObject(response.content[0])).isEqual(to: [
        "type": "thinking", "thinking": "think 1 think 2", "thinkingSignature": "reasoning_content",
    ]))
    #expect(NSDictionary(dictionary: contentBlockToJSONObject(response.content[1])).isEqual(to: [
        "type": "text", "text": "answer 1 answer 2\n",
    ]))
    let expectedCalls: [(String, String, [String: AnyCodable])] = [
        ("tc_read_initial", "read", ["path": AnyCodable("README.md")]),
        ("tc_grep_initial", "grep", ["pattern": AnyCodable("TODO"), "path": AnyCodable("src")]),
        ("tc_list_no_index", "list", ["path": AnyCodable("packages/ai")]),
        ("tc_write_no_index", "write", ["path": AnyCodable("out.txt"), "content": AnyCodable("ok")]),
    ]
    for (offset, expected) in expectedCalls.enumerated() {
        let block = response.content[offset + 2]
        guard case .toolCall(let call) = block else { Issue.record("Expected toolCall content"); continue }
        #expect(call.id == expected.0)
        #expect(call.name == expected.1)
        #expect(call.arguments == expected.2)
        #expect(call.argumentsError == nil)
        let json = contentBlockToJSONObject(block)
        #expect(json["streamIndex"] == nil)
        #expect(json["partialArgs"] == nil)
    }
}

@Test func a2GoogleThinkingLevelRecognizesFourAndLater() {
    for id in ["gemini-4-argon", "gemini-4.1-flash", "gemini-9-test", "gemini-10-pro", "gemini-27-pro", "gemini-100-pro", "gemini-3.8-flash", "gemini-3-pro"] {
        #expect(usesGoogleThinkingLevel(model: a2ChunkModel(id: id)))
    }
    for id in ["gemini-2.5-flash", "gemini-3-argon", "gemini-3.1-argon"] {
        #expect(!usesGoogleThinkingLevel(model: a2ChunkModel(id: id)))
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func a2GeminiFourSendsThinkingLevelOnGeminiAndVertex(_ vertex: Bool) async throws {
    let event: [String: Any] = ["candidates": [["content": ["parts": [["text": "done"]]], "finishReason": "STOP"]]]
    let body = Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
    let client = A2ChunkHTTPClient(body: body)
    let model = a2ChunkModel(api: vertex ? .googleVertex : .googleGenerativeAI, id: "gemini-4-argon")
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("Hello")))]))
    let simple = SimpleStreamOptions(httpClient: client, reasoning: .medium)
    let result: AssistantMessage
    if vertex {
        var options = try mapGoogleVertexSimpleOptionsValidated(model: model, options: simple, apiKey: "test")
        options.project = "test-project"; options.location = "us-central1"
        result = await streamGoogleVertex(model: model, context: context, options: options).result()
    } else {
        let options = try mapGoogleSimpleOptionsValidated(model: model, options: simple, apiKey: "test")
        result = await streamGoogle(model: model, context: context, options: options).result()
    }
    #expect(result.stopReason == .stop)
    let request = try #require(await client.request)
    let data = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let config = try #require((payload["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])
    #expect(NSDictionary(dictionary: config).isEqual(to: ["includeThoughts": true, "thinkingLevel": "MEDIUM"]))
}
