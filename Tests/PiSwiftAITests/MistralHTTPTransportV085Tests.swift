import Foundation
import Testing
@testable import PiSwiftAI

private actor Mistral085Client: ProviderHTTPClient {
    let response: ProviderHTTPResponse
    var requests: [URLRequest] = []

    init(chunks: [Data], status: Int = 200, headers: [String: String] = [:], keepOpen: Bool = false) {
        response = ProviderHTTPResponse(statusCode: status, headers: headers, body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if !keepOpen { continuation.finish() }
        })
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> URLRequest? { requests.last }
}

private func mistral085Model(headers: ProviderHeaders? = nil) -> Model {
    Model(id: "mistral-large-latest", name: "Mistral", api: .mistralConversations,
        provider: "mistral", baseUrl: "https://api.mistral.ai", reasoning: true, input: [.text, .image],
        cost: ModelCost(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 4096, headers: headers)
}

private func mistral085Event(
    _ delta: [String: Any] = [:], finish: String? = nil, usage: [String: Any]? = nil
) -> [String: Any] {
    var event: [String: Any] = ["id": "response-1", "model": "mistral-large-latest",
        "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
    if let usage { event["usage"] = usage }
    return event
}

private func mistral085SSE(_ events: [[String: Any]], delimiter: String = "\r\n\r\n", done: Bool = true) throws -> Data {
    var result = Data()
    for event in events {
        result.append(Data("data: ".utf8))
        result.append(try JSONSerialization.data(withJSONObject: event))
        result.append(Data(delimiter.utf8))
    }
    if done { result.append(Data("data: [DONE]\(delimiter)".utf8)) }
    return result
}

private func mistral085Payload(_ client: Mistral085Client) async throws -> [String: Any] {
    let request = try #require(await client.lastRequest())
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test func mistral085SerializesNativeWirePayloadAndResponseHeaders() async throws {
    let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop")])],
        headers: ["content-type": "text/event-stream", "x-request-id": "request-1"])
    let context = Context(systemPrompt: "Be precise", messages: [.user(UserMessage(content: .blocks([
        .text(TextContent(text: "describe")), .image(ImageContent(data: "aGVsbG8=", mimeType: "image/png")),
    ])))], tools: [AITool(name: "lookup", description: "Look something up", parameters: [
        "type": AnyCodable("object"), "properties": AnyCodable(["query": ["type": "string"]]),
        "required": AnyCodable(["query"]),
    ])])
    let payloadSnapshot = LockedState<String?>(nil)
    let responseSnapshot = LockedState<ResponseSnapshot?>(nil)
    let message = await streamMistral(model: mistral085Model(), context: context,
        options: MistralOptions(maxTokens: 123, apiKey: "secret", httpClient: client,
            toolChoice: AnyCodable(["type": "function", "function": ["name": "lookup"]] as [String: Any]),
            promptMode: "reasoning", reasoningEffort: "high", sessionId: "session-1", headers: ["x-custom": "value"],
            onPayload: { snapshot in payloadSnapshot.withLock { $0 = snapshot.json } },
            onResponse: { snapshot in responseSnapshot.withLock { $0 = snapshot } })).result()
    #expect(message.stopReason == .stop)
    let request = try #require(await client.lastRequest())
    #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
    #expect(request.timeoutInterval == 60)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
    #expect(request.value(forHTTPHeaderField: "x-affinity") == "session-1")
    #expect(request.value(forHTTPHeaderField: "x-custom") == "value")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == getPiUserAgent())
    let payload = try await mistral085Payload(client)
    #expect(payload["max_tokens"] as? Int == 123)
    #expect(payload["prompt_mode"] as? String == "reasoning")
    #expect(payload["reasoning_effort"] as? String == "high")
    #expect(payload["prompt_cache_key"] as? String == "session-1")
    #expect((payload["tool_choice"] as? [String: Any])?["type"] as? String == "function")
    #expect(payload["maxTokens"] == nil)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages[0]["content"] as? String == "Be precise")
    let userContent = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(userContent[1]["image_url"] as? String == "data:image/png;base64,aGVsbG8=")
    let snapshot = try #require(responseSnapshot.withLock { $0 })
    #expect(snapshot.statusCode == 200)
    #expect(snapshot.headers == ["content-type": "text/event-stream", "x-request-id": "request-1"])
    let callbackData = Data(try #require(payloadSnapshot.withLock { $0 }).utf8)
    let callbackPayload = try #require(JSONSerialization.jsonObject(with: callbackData) as? [String: Any])
    #expect(callbackPayload["max_tokens"] as? Int == 123)
}

@Test func mistral085SerializesThinkingToolCallsAndResultsForReplay() async throws {
    let model = mistral085Model()
    let assistant = AssistantMessage(content: [
        .thinking(ThinkingContent(thinking: "reason")), .text(TextContent(text: "answer")),
        .toolCall(ToolCall(id: "abc123456", name: "lookup", arguments: ["query": AnyCodable("pi")])),
    ], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let toolResult = ToolResultMessage(toolCallId: "abc123456", toolName: "lookup", content: [
        .text(TextContent(text: "found")), .image(ImageContent(data: "aGVsbG8=", mimeType: "image/png")),
    ], isError: false)
    let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop")])])
    _ = await streamMistral(model: model, context: Context(messages: [.assistant(assistant), .toolResult(toolResult)]),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    let payload = try await mistral085Payload(client)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages[0]["prefix"] as? Bool == false)
    let calls = try #require(messages[0]["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["id"] as? String == "abc123456")
    #expect(calls[0]["index"] as? Int == 0)
    #expect((calls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"query":"pi"}"#)
    let assistantContent = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(assistantContent[0]["type"] as? String == "thinking")
    #expect(assistantContent[1]["text"] as? String == "answer")
    #expect(messages[1]["tool_call_id"] as? String == "abc123456")
    let toolContent = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(toolContent[0]["text"] as? String == "found")
    #expect(toolContent[1]["image_url"] as? String == "data:image/png;base64,aGVsbG8=")
}

@Test func mistral085ParsesNativeContentFragmentedToolsAndCacheUsage() async throws {
    let events = [
        mistral085Event(["content": [["type": "thinking", "thinking": [["type": "text", "text": "reason"]]]]]),
        mistral085Event(["content": [["type": "text", "text": "answer"]]]),
        mistral085Event(["tool_calls": [["id": "abc123456", "index": 0,
            "function": ["name": "lookup", "arguments": "{\"query\":"]]]]),
        mistral085Event(["tool_calls": [["index": 0, "function": ["name": "", "arguments": "\"pi\"}"]]]],
            finish: "tool_calls", usage: ["prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14,
                "prompt_tokens_details": ["cached_tokens": 3]]),
    ]
    let client = Mistral085Client(chunks: [try mistral085SSE(events)])
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(message.stopReason == .toolUse)
    #expect(message.rawStopReason == "tool_calls")
    #expect(message.responseId == "response-1")
    #expect(message.content.count == 3)
    if case .thinking(let thinking)? = message.content.first { #expect(thinking.thinking == "reason") }
    else { Issue.record("Missing thinking block") }
    if case .text(let text)? = message.content.dropFirst().first { #expect(text.text == "answer") }
    else { Issue.record("Missing text block") }
    if case .toolCall(let tool)? = message.content.last {
        #expect(tool.id == "abc123456")
        #expect(tool.name == "lookup")
        #expect(tool.arguments["query"]?.value as? String == "pi")
    } else { Issue.record("Missing tool call") }
    #expect(message.usage.input == 7)
    #expect(message.usage.output == 4)
    #expect(message.usage.cacheRead == 3)
    #expect(message.usage.cacheWrite == 0)
    #expect(message.usage.totalTokens == 14)
}

@Test func mistral085ParsesBytewiseSSEAndUTF8() async throws {
    let frame = try mistral085SSE([mistral085Event(["content": "héllo 🌍"], finish: "stop")])
    let client = Mistral085Client(chunks: frame.map { Data([$0]) })
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(message.stopReason == .stop)
    if case .text(let text)? = message.content.first { #expect(text.text == "héllo 🌍") }
    else { Issue.record("Missing UTF-8 text") }
}

@Test func mistral085HonorsHeaderOverridesAndAffinitySuppression() async throws {
    let model = mistral085Model(headers: ["Authorization": "Bearer model-key", "X-Affinity": "model-affinity"])
    let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop")])])
    _ = await streamMistral(model: model, context: Context(messages: []), options: MistralOptions(apiKey: "request-key",
        httpClient: client, sessionId: "automatic-affinity", headers: [
            "authorization": nil, "x-affinity": nil, "User-Agent": "custom-agent",
        ])).result()
    let request = try #require(await client.lastRequest())
    #expect(request.value(forHTTPHeaderField: "authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "x-affinity") == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "custom-agent")
}

@Test func mistral085AbortsWhileWaitingForSSEChunk() async throws {
    let token = CancellationToken()
    let client = Mistral085Client(chunks: [], keepOpen: true)
    let stream = streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(signal: token, apiKey: "test", httpClient: client))
    for await event in stream {
        if case .start = event { token.cancel() }
    }
    let message = await stream.result()
    #expect(message.stopReason == .aborted)
}

@Test func mistral085TimeoutAppliesWhileWaitingForSSEChunk() async throws {
    let client = Mistral085Client(chunks: [], keepOpen: true)
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client, timeoutMs: 5)).result()
    #expect(message.stopReason == .error)
    #expect(message.errorMessage?.lowercased().contains("timeout") == true)
}

@Test func mistral085PreservesHTTPStatusAndResponseBody() async throws {
    let client = Mistral085Client(chunks: [Data(#"{"message":"blocked by gateway"}"#.utf8)], status: 403)
    let capturedStatus = LockedState<Int?>(nil)
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client,
            onResponse: { snapshot in capturedStatus.withLock { $0 = snapshot.statusCode } })).result()
    #expect(message.stopReason == .error)
    #expect(message.errorMessage == #"Mistral API error (403): {"message":"blocked by gateway"}"#)
    #expect(capturedStatus.withLock { $0 } == 403)
}

@Test func mistral085PreservesRawStopReasons() async throws {
    for reason in ["stop", "error", "unmapped_error"] {
        let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: reason)])])
        let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
            options: MistralOptions(apiKey: "test", httpClient: client)).result()
        #expect(message.rawStopReason == reason)
        #expect(message.responseId == "response-1")
        #expect(message.stopReason == (reason == "stop" ? .stop : .error))
        if reason != "stop" { #expect(message.errorMessage == "Provider stopped with: \(reason)") }
    }
}

@Test func mistral085ParsesAllFrameBoundariesAndMultilineData() async throws {
    for delimiter in ["\r\n\r\n", "\r\n\r", "\r\n\n", "\r\r\n", "\n\r\n", "\r\r", "\n\r", "\n\n"] {
        let frame = try mistral085SSE([mistral085Event(["content": "ok"], finish: "stop")], delimiter: delimiter)
        let client = Mistral085Client(chunks: [frame])
        let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
            options: MistralOptions(apiKey: "test", httpClient: client)).result()
        #expect(message.stopReason == .stop)
    }
    let data = Data("data: {\"id\":\"multi\",\ndata: \"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)
    let client = Mistral085Client(chunks: [data])
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(message.stopReason == .stop)
    #expect(message.responseId == "multi")
}

@Test func mistral085ParsesResidualEOFAndStopsAtDone() async throws {
    let event = mistral085Event(["content": "ok"], finish: "stop")
    let raw = try JSONSerialization.data(withJSONObject: event)
    let client = Mistral085Client(chunks: [Data("data: ".utf8) + raw])
    let result = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.stopReason == .stop)
    let afterDone = try mistral085SSE([event]) + Data("data: this is invalid json\n\n".utf8)
    let doneClient = Mistral085Client(chunks: [afterDone], keepOpen: true)
    let doneResult = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: doneClient, timeoutMs: 1000)).result()
    #expect(doneResult.stopReason == .stop)
}

@Test func mistral085CacheNoneDisablesAutomaticAffinityAndPromptKey() async throws {
    let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop")])])
    _ = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client, sessionId: "session", cacheRetention: CacheRetention.none)).result()
    let payload = try await mistral085Payload(client)
    #expect(payload["prompt_cache_key"] == nil)
    let request = try #require(await client.lastRequest())
    #expect(request.value(forHTTPHeaderField: "x-affinity") == nil)
    let mapped = mapMistralSimpleOptions(model: mistral085Model(),
        options: SimpleStreamOptions(cacheRetention: CacheRetention.none, toolChoice: ToolChoice.none), apiKey: "test")
    #expect(mapped.cacheRetention == CacheRetention.none)
    #expect(mapped.toolChoice?.value as? String == "none")
}

@Test func mistral085SeparatesToolsWithoutIndicesByID() async throws {
    let events = [mistral085Event(["tool_calls": [
        ["id": "abc123456", "function": ["name": "first", "arguments": "{}"]],
        ["id": "def123456", "function": ["name": "second", "arguments": "{}"]],
    ]], finish: "tool_calls")]
    let client = Mistral085Client(chunks: [try mistral085SSE(events)])
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(message.content.count == 2)
}

@Test func mistral085RejectsInvalidStreamingEvents() async throws {
    let client = Mistral085Client(chunks: [Data("data: {\"usage\":{}}\n\n".utf8)])
    let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
        options: MistralOptions(apiKey: "test", httpClient: client)).result()
    #expect(message.stopReason == .error)
    #expect(message.errorMessage == "Invalid Mistral streaming event")
}

@Test func mistral085CacheAliasesAndBounds() async throws {
    let details: [[String: Any]] = [
        ["promptTokensDetails": ["cachedTokens": 3]],
        ["prompt_tokens_details": ["cached_tokens": 3]],
        ["promptTokenDetails": ["cachedTokens": 3]],
        ["prompt_token_details": ["cached_tokens": 3]],
        ["numCachedTokens": 3], ["num_cached_tokens": 3],
        ["promptTokensDetails": ["cachedTokens": NSNull()], "num_cached_tokens": 3],
    ]
    for fields in details {
        var usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 4]
        usage.merge(fields) { _, value in value }
        let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop", usage: usage)])])
        let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
            options: MistralOptions(apiKey: "test", httpClient: client)).result()
        #expect(message.usage.cacheRead == 3)
        #expect(message.usage.input == 7)
    }
    for value in [-5, 20] {
        let usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 4, "num_cached_tokens": value]
        let client = Mistral085Client(chunks: [try mistral085SSE([mistral085Event(finish: "stop", usage: usage)])])
        let message = await streamMistral(model: mistral085Model(), context: Context(messages: []),
            options: MistralOptions(apiKey: "test", httpClient: client)).result()
        #expect(message.usage.cacheRead == min(10, max(0, value)))
    }
}
