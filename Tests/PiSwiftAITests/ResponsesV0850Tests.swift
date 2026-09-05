import Foundation
import Testing
@testable import PiSwiftAI

private struct Responses085HTTPClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { try await handler(request) }
}

private func responses085Model(api: Api = .openAIResponses, provider: String = "openai", id: String = "gpt-5.4", compat: OpenAICompat? = nil, reasoning: Bool = false) -> Model {
    Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.test/v1", reasoning: reasoning,
          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 400_000, maxTokens: 128_000, compat: compat)
}

private func responses085Assistant(model: Model, content: [ContentBlock]) -> AssistantMessage {
    AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
                     usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
}

private func responses085Tool(_ name: String, constrained: Bool = false) -> AITool {
    AITool(name: name, description: name, parameters: ["type": AnyCodable("object"),
        "properties": AnyCodable(["value": ["type": "string"]])],
        constrainedSampling: constrained ? .jsonSchema(strict: .prefer) : nil)
}

private func responses085Payload(model: Model, context: Context) throws -> [String: Any] {
    let query = try buildResponsesQuery(model: model, context: context, options: OpenAIResponsesOptions())
    var request = URLRequest(url: URL(string: model.baseUrl)!)
    request.httpBody = try JSONEncoder().encode(query)
    let grammar = try makeOpenAIResponsesConstrainedSamplingMiddleware(tools: context.tools,
        supportsStrictMode: model.compat?.supportsStrictMode ?? true,
        supportsOpenAIGrammarTools: model.compat?.supportsOpenAIGrammarTools ?? false)
    request = grammar.intercept(request: request)
    request = try makeResponsesReplayMiddleware(model: model, context: context).intercept(request: request)
    let requestBody = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
}

// Port of openai-responses-namespace.test.ts: function/custom namespaces supplied at done.
@Test(arguments: [false, true]) func responses085NamespaceRoundTrip(custom: Bool) async throws {
    let model = responses085Model()
    let type = custom ? "custom_tool_call" : "function_call"
    let name = custom ? "query" : "lookup"
    let field = custom ? "input" : "arguments"
    let final = custom ? "hello" : "{\"value\":\"hello\"}"
    let events: [[String: Any]] = [
        ["type": "response.output_item.added", "output_index": 0, "item": ["type": type, "id": "fc_test", "call_id": "call_test", "name": name, field: ""]],
        ["type": "response.output_item.done", "output_index": 0, "item": ["type": type, "id": "fc_test", "call_id": "call_test", "name": name, field: final, "namespace": "dynamic_tools"]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let sse = try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    let client = Responses085HTTPClient { _ in ProviderHTTPResponse(statusCode: 200, body: Data(sse.utf8)) }
    var output = responses085Assistant(model: model, content: [])
    output.stopReason = .pending
    try await processRawOpenAIResponsesStream(request: URLRequest(url: URL(string: model.baseUrl)!), model: model,
        httpClient: client, signal: nil, maxRetries: nil, maxRetryDelayMs: nil, onResponse: nil, serviceTier: nil,
        grammarToolInputProperties: custom ? ["query": "input"] : [:], stream: AssistantMessageEventStream(), output: &output)
    let call = try #require(output.content.compactMap { if case .toolCall(let value) = $0 { value } else { nil } }.first)
    #expect(call.id == "call_test|fc_test")
    #expect(call.namespace == "dynamic_tools")
    #expect(call.arguments[custom ? "input" : "value"]?.value as? String == "hello")
    #expect(output.errorMessage == nil)
    let replay = try convertCodexMessages(model: model, context: Context(messages: [.assistant(output)]),
        grammarToolInputProperties: custom ? ["query": "input"] : [:]).compactMap { $0 as? [String: Any] }
    #expect(replay.first?["namespace"] as? String == "dynamic_tools")
    #expect(replay.first?["type"] as? String == type)
    if !custom {
        let payload = try responses085Payload(model: model, context: Context(messages: [.assistant(output)]))
        #expect((payload["input"] as? [[String: Any]])?.first?["namespace"] as? String == "dynamic_tools")
    }
}

@Test func responses085DropsForeignNamespaces() throws {
    let source = responses085Model()
    let assistant = responses085Assistant(model: source, content: [
        .toolCall(ToolCall(id: "call_function|fc_test", name: "lookup", arguments: ["value": AnyCodable("hello")], namespace: "dynamic_tools")),
        .toolCall(ToolCall(id: "call_custom|ctc_test", name: "query", arguments: ["input": AnyCodable("hello")], namespace: "dynamic_tools")),
    ])
    for target in [responses085Model(id: "gpt-5.2"), responses085Model(provider: "azure-openai-responses"),
                   responses085Model(api: .openAICodexResponses, provider: "openai-codex", id: "gpt-5.3-codex-spark")] {
        let replay = try convertCodexMessages(model: target, context: Context(messages: [.assistant(assistant)]),
            grammarToolInputProperties: ["query": "input"]).compactMap { $0 as? [String: Any] }
        #expect(replay.filter { ["function_call", "custom_tool_call"].contains($0["type"] as? String ?? "") }.count == 2)
        #expect(replay.allSatisfy { $0["namespace"] == nil })
    }
}

@Test func responses085OrdinaryCallsHaveNoNamespace() throws {
    let model = responses085Model()
    let assistant = responses085Assistant(model: model, content: [.toolCall(ToolCall(id: "call_test|fc_test", name: "lookup", arguments: [:]))])
    let payload = try responses085Payload(model: model, context: Context(messages: [.assistant(assistant)]))
    let items = try #require(payload["input"] as? [[String: Any]])
    #expect(items.filter { $0["type"] as? String == "function_call" }.count == 1)
    #expect(items[0]["namespace"] == nil)
}

// Port of openai-responses-compat.test.ts additions.
@Test(arguments: [false, true]) func responses085MaxOutputTokensCompat(disabled: Bool) throws {
    let model = responses085Model(compat: disabled ? OpenAICompat(supportsMaxOutputTokens: false) : nil)
    let query = try buildResponsesQuery(model: model, context: Context(messages: []), options: OpenAIResponsesOptions(maxTokens: 1024))
    let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    #expect(payload["max_output_tokens"] as? Int == (disabled ? nil : 1024))
}

@Test func responses085StrictToolsConvertOptionalParameters() throws {
    let payload = try responses085Payload(model: responses085Model(compat: OpenAICompat(supportsStrictMode: true)),
        context: Context(messages: [], tools: [responses085Tool("ordinary"), responses085Tool("constrained", constrained: true)]))
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools[0]["strict"] as? Bool == false)
    #expect(tools[1]["strict"] as? Bool == true)
    let parameters = try #require(tools[1]["parameters"] as? [String: Any])
    #expect(parameters["required"] as? [String] == ["value"])
    let properties = try #require(parameters["properties"] as? [String: [String: Any]])
    #expect(properties["value"]?["anyOf"] != nil)
}

// Port of azure-openai-tool-choice.test.ts (both cases).
@Test func responses085AzureProviderToolChoice() throws {
    let model = responses085Model(api: .azureOpenAIResponses, provider: "azure-openai-responses")
    let query = try buildAzureResponsesQuery(model: model, context: Context(messages: [], tools: [responses085Tool("read")]),
        options: AzureOpenAIResponsesOptions(toolChoice: .required), deploymentName: "test-deployment")
    let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    #expect(payload["tool_choice"] as? String == "required")
    #expect((payload["tools"] as? [Any])?.count == 1)
}

@Test func responses085AzureSimpleToolChoice() async throws {
    let capture = LockedState<Data?>(nil)
    let client = Responses085HTTPClient { request in
        capture.withLock { $0 = request.httpBody }
        return ProviderHTTPResponse(statusCode: 200, body: Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8))
    }
    let model = responses085Model(api: .azureOpenAIResponses, provider: "azure-openai-responses")
    var options = SimpleStreamOptions(apiKey: "test-key", httpClient: client)
    options.toolChoice = ToolChoice.none
    _ = await streamSimpleAzureOpenAIResponses(model: model, context: Context(messages: [], tools: [responses085Tool("read")]), options: options).result()
    let data = try #require(capture.withLock { $0 })
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["tool_choice"] as? String == "none")
    #expect((payload["tools"] as? [Any])?.count == 1)
}

@Test(arguments: [false, true]) func responses085DeferredToolModes(additional: Bool) throws {
    let compat = OpenAICompat(supportsToolSearch: true, supportsAdditionalTools: additional)
    let model = responses085Model(compat: compat)
    let context = Context(messages: [
        .toolResult(ToolResultMessage(toolCallId: "load|fc_load", toolName: "discover", content: [.text(TextContent(text: "loaded"))], addedToolNames: ["lookup", "lookup"], isError: false)),
        .assistant(responses085Assistant(model: model, content: [.toolCall(ToolCall(id: "call|fc_call", name: "lookup", arguments: [:], namespace: "dynamic_tools"))])),
    ], tools: [responses085Tool("discover"), responses085Tool("lookup")])
    let payload = try responses085Payload(model: model, context: context)
    let tools = try #require(payload["tools"] as? [[String: Any]])
    #expect(tools.map { $0["name"] as? String } == ["discover"])
    let input = try #require(payload["input"] as? [[String: Any]])
    #expect(input[1]["type"] as? String == (additional ? "additional_tools" : "tool_search_call"))
    let loaded = try #require(input[additional ? 1 : 2]["tools"] as? [[String: Any]])
    #expect(loaded.count == 1)
    #expect(loaded[0]["name"] as? String == "lookup")
    if additional { #expect(input[1]["role"] as? String == "developer") }
    else { #expect(loaded[0]["defer_loading"] as? Bool == true) }
    #expect(input.first { $0["type"] as? String == "function_call" }?["namespace"] as? String == "dynamic_tools")
}

// Port of openai-codex-stream.test.ts EOF, end_turn and User-Agent additions.
@Test(arguments: ["response.completed", "response.done", "response.incomplete"], [false, true])
func responses085CodexTerminalEOFAndEndTurn(terminal: String, keepOpen: Bool) async throws {
    let incomplete = terminal == "response.incomplete"
    let sse = "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_test\"}}\n\n"
        + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
        + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_test\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n\n"
        + "data: {\"type\":\"\(terminal)\",\"response\":{\"status\":\"\(incomplete ? "incomplete" : "completed")\",\"end_turn\":false,\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}"
    let headers = LockedState<[String: String]>([:])
    let client = Responses085HTTPClient { request in
        headers.withLock { $0 = request.allHTTPHeaderFields ?? [:] }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data((sse + (keepOpen ? "\n\n" : "")).utf8))
            if !keepOpen { continuation.finish() }
        }
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }
    let tokenPayload = Data("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}".utf8).base64EncodedString()
    let model = responses085Model(api: .openAICodexResponses, provider: "openai-codex")
    let result = await streamOpenAICodexResponses(model: model, context: Context(messages: []),
        options: OpenAICodexResponsesOptions(apiKey: "e30.\(tokenPayload).sig", httpClient: client, transport: .sse)).result()
    #expect(result.stopReason == (incomplete ? .length : .stop))
    #expect(result.endTurn == false)
    #expect(result.content.contains { if case .text(let text) = $0 { text.text == "Hello" } else { false } })
    #expect(headers.withLock { $0.first { $0.key.lowercased() == "user-agent" }?.value } == getPiUserAgent())
}

@Test func responses085URLPathsAndXAIEncryptedReasoning() throws {
    #expect(openAIResponsesURL(baseUrl: "https://example.test").path == "/v1/responses")
    #expect(openAIResponsesURL(baseUrl: "https://example.test/api/").path == "/api/responses")
    #expect(openAIResponsesURL(baseUrl: "https://example.test", provider: "github-copilot").path == "/responses")
    #expect(openAIResponsesURL(baseUrl: "https://example.test/v1/responses").path == "/v1/responses")
    let model = responses085Model(provider: "xai", reasoning: true)
    let query = try buildResponsesQuery(model: model, context: Context(messages: []), options: OpenAIResponsesOptions())
    let payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    #expect(payload["include"] as? [String] == ["reasoning.encrypted_content"])
    #expect(payload["reasoning"] == nil)
}

@Test func responses085RawFinalizationPreservesBufferedArgumentsAndContent() async throws {
    let events: [[String: Any]] = [
        ["type": "response.output_item.added", "output_index": 0, "item": ["type": "function_call", "id": "fc", "call_id": "call", "name": "lookup"]],
        ["type": "response.function_call_arguments.delta", "output_index": 0, "delta": #"{"value":"hello"}"#],
        ["type": "response.output_item.done", "output_index": 0, "item": ["type": "function_call", "id": "fc", "call_id": "call", "name": "lookup", "arguments": ""]],
        ["type": "response.output_item.added", "output_index": 1, "item": ["type": "reasoning", "id": "rs"]],
        ["type": "response.output_item.done", "output_index": 1, "item": ["type": "reasoning", "id": "rs", "summary": [], "content": [["text": "reason"]]]],
        ["type": "response.completed", "response": ["status": "completed"]],
    ]
    let sse = try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    let model = responses085Model()
    let client = Responses085HTTPClient { _ in ProviderHTTPResponse(statusCode: 200, body: Data(sse.utf8)) }
    let result = await streamOpenAIResponses(model: model, context: Context(messages: []), options: OpenAIResponsesOptions(apiKey: "test", httpClient: client)).result()
    #expect(result.stopReason == .toolUse)
    guard case .toolCall(let call) = result.content.first, case .thinking(let thinking) = result.content.last else { Issue.record("Expected final blocks"); return }
    #expect(call.arguments["value"] == AnyCodable("hello"), "Arguments: \(call.arguments)")
    #expect(thinking.thinking == "reason")
}

@Test func responses085RawFailurePreservesCodeAndStatus() async {
    let client = Responses085HTTPClient { _ in ProviderHTTPResponse(statusCode: 200, body: Data(#"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"invalid_request","message":"details"}}}"#.utf8) + Data("\n\n".utf8)) }
    let result = await streamOpenAIResponses(model: responses085Model(), context: Context(messages: []), options: OpenAIResponsesOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
    #expect(result.stopReason == .error)
    #expect(result.rawStopReason == "failed")
    #expect(result.errorMessage?.contains("invalid_request: details") == true)
}

@Test(arguments: [0, 1, 2]) func responses085CodexThreeDeferredModes(_ mode: Int) throws {
    let model = responses085Model(api: .openAICodexResponses, provider: "openai-codex", compat: OpenAICompat(supportsToolSearch: mode == 1, supportsAdditionalTools: mode == 2))
    let context = Context(messages: [.toolResult(ToolResultMessage(toolCallId: "load|fc", toolName: "discover", content: [.text(TextContent(text: "loaded"))], addedToolNames: ["lookup"], isError: false))], tools: [responses085Tool("discover"), responses085Tool("lookup")])
    let items = try convertCodexMessages(model: model, context: context, grammarToolInputProperties: [:]).compactMap { $0 as? [String: Any] }
    let types = items.compactMap { $0["type"] as? String }
    #expect(types.contains("additional_tools") == (mode == 2))
    #expect(types.contains("tool_search_call") == (mode == 1))
    #expect(splitDeferredTools(context, enabled: responsesDeferredToolsEnabled(model)).immediate.count == (mode == 0 ? 2 : 1))
}
