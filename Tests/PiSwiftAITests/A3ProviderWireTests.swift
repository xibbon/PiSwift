import Foundation
import Testing
@testable import PiSwiftAI

private actor A3WireClient: ProviderHTTPClient {
    private let body: Data
    private(set) var requests: [URLRequest] = []

    init(body: Data = Data()) { self.body = body }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: 200, body: body)
    }

    func payloadData() -> Data? { requests.first?.httpBody }
}

private func a3Payload(_ client: A3WireClient) async throws -> [String: Any] {
    let data = try #require(await client.payloadData())
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func a3Model(api: Api, provider: String, baseUrl: String, compat: OpenAICompat? = nil) -> Model {
    Model(id: "a3-test", name: "A3 test", api: api, provider: provider, baseUrl: baseUrl,
        reasoning: true, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 16_000, maxTokens: 1_000, compat: compat)
}

private func a3Context(tools: [AITool]? = nil) -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "Follow instructions.", messages: [
        .user(UserMessage(content: .text("Hi"), timestamp: 1)),
    ], tools: tools))
}

private func a3CompletionsPayload(_ model: Model, client: A3WireClient) async throws -> [String: Any] {
    _ = await streamOpenAICompletions(model: model, context: a3Context(),
        options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
    return try await a3Payload(client)
}

@Suite("A3 provider wire rules")
struct A3ProviderWireTests {
    // openai-completions-tool-choice.test.ts:1173–1205, #10741.
    @Test("uses system messages for reasoning model instructions on other OpenAI-compatible hosts")
    func completionsInstructionRoles() async throws {
        let cases: [(String, String, OpenAICompat?, String)] = [
            ("openai", "https://another.example/v1", nil, "developer"),
            ("alias", "https://api.openai.com/v1", nil, "developer"),
            ("azure", "https://resource.openai.azure.com/openai/v1", nil, "system"),
            ("groq", "https://api.groq.com/openai/v1", nil, "system"),
            ("openrouter", "https://openrouter.ai/api/v1", nil, "system"),
            ("custom", "https://custom.example/v1", nil, "system"),
            ("openai", "https://api.openai.com/v1", OpenAICompat(supportsDeveloperRole: false), "system"),
            ("groq", "https://api.groq.com/openai/v1", OpenAICompat(supportsDeveloperRole: true), "developer"),
        ]
        for (provider, baseUrl, compat, role) in cases {
            let client = A3WireClient()
            let model = a3Model(api: .openAICompletions, provider: provider, baseUrl: baseUrl, compat: compat)
            let payload = try await a3CompletionsPayload(model, client: client)
            let messages = try #require(payload["messages"] as? [[String: Any]])
            #expect(messages.first?["role"] as? String == role, "\(provider): \(baseUrl)")
            #expect(messages.first?["content"] as? String == "Follow instructions.")
            #expect(messages.map { $0["role"] as? String ?? "" } == [role, "user"])
        }
    }

    @Test("uses the resolved instruction role for mid-conversation system messages")
    func completionsMidConversationRole() async throws {
        for (provider, role) in [("openai", "developer"), ("groq", "system")] {
            let compat = OpenAICompat(supportsMidConvoSystemMessages: true)
            let model = a3Model(api: .openAICompletions, provider: provider,
                baseUrl: "https://\(provider).example/v1", compat: compat)
            let context = normalizeContext(Context(systemPrompt: "Follow instructions.", messages: [
                .user(UserMessage(content: .text("Hi"), timestamp: 1)),
                .system(SystemMessage(content: .text("Update."), timestamp: 2)),
                .user(UserMessage(content: .text("Again"), timestamp: 3)),
            ]))
            let client = A3WireClient()
            _ = await streamOpenAICompletions(model: model, context: context,
                options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
            let messages = try #require(try await a3Payload(client)["messages"] as? [[String: Any]])
            #expect(messages.map { $0["role"] as? String ?? "" } == [role, "user", role, "user"])
        }
    }

    // openai-completions-tool-choice.test.ts:1751, #12019.
    @Test("reads top-level reasoning_tokens when completion_tokens_details has none")
    func topLevelReasoningTokens() async throws {
        for (details, expected) in [(nil, 30), (7, 7), (0, 30)] as [(Int?, Int)] {
            var usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 40, "reasoning_tokens": 30]
            if let details { usage["completion_tokens_details"] = ["reasoning_tokens": details] }
            let event: [String: Any] = ["id": "chatcmpl-a3", "object": "chat.completion.chunk",
                "created": 0, "model": "a3-test",
                "choices": [["index": 0, "delta": ["content": "OK"], "finish_reason": "stop"]], "usage": usage]
            let json = try JSONSerialization.data(withJSONObject: event)
            let client = A3WireClient(body: Data("data: \(String(decoding: json, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8))
            let model = a3Model(api: .openAICompletions, provider: "github-copilot", baseUrl: "https://copilot.example/v1")
            let result = await streamOpenAICompletions(model: model, context: a3Context(),
                options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
            #expect(result.usage.reasoning == expected)
            #expect(result.usage.output == 40)
        }
    }

    @Test("reads top-level reasoning_tokens from a final usage chunk and choice usage")
    func finalAndChoiceReasoningTokens() async throws {
        let usage: [String: Any] = ["prompt_tokens": 10, "completion_tokens": 40,
            "reasoning_tokens": 30, "completion_tokens_details": ["reasoning_tokens": 7]]
        for choiceUsage in [false, true] {
            let first: [String: Any] = ["id": "chatcmpl-a3", "object": "chat.completion.chunk",
                "created": 0, "model": "a3-test",
                "choices": [["index": 0, "delta": ["content": "OK"], "finish_reason": "stop"]]]
            let final: [String: Any] = ["id": "chatcmpl-a3", "object": "chat.completion.chunk",
                "created": 0, "model": "a3-test", "choices": choiceUsage
                    ? [["index": 0, "delta": [String: Any](), "finish_reason": NSNull(), "usage": usage]]
                    : [], "usage": choiceUsage ? NSNull() : usage]
            let events = try [first, final].map {
                "data: \(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self))\n\n"
            }.joined() + "data: [DONE]\n\n"
            let client = A3WireClient(body: Data(events.utf8))
            let model = a3Model(api: .openAICompletions, provider: "github-copilot",
                baseUrl: "https://copilot.example/v1")
            let result = await streamOpenAICompletions(model: model, context: a3Context(),
                options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
            #expect(result.usage.reasoning == 7)
            #expect(result.usage.output == 40)
        }
    }

    // mistral-tool-schema.test.ts:66, #12148.
    @Test("does not send strict tools unless the model enables strict mode")
    func mistralStrictOptIn() async throws {
        let tool = AITool(name: "read", description: "Read a file", parameters: [
            "type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]]),
            "required": AnyCodable(["path"]),
        ], constrainedSampling: .jsonSchema(strict: .prefer))
        let context = a3Context(tools: [tool])
        for (compat, strict) in [(nil, false), (OpenAICompat(supportsStrictMode: true), true)] {
            let client = A3WireClient()
            let model = compat.map {
                a3Model(api: .mistralConversations, provider: "mistral",
                    baseUrl: "https://api.mistral.ai", compat: $0)
            } ?? getModel(provider: .mistral, modelId: "mistral-large-4")
            _ = await streamMistral(model: model, context: context,
                options: MistralOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
            let payload = try await a3Payload(client)
            let function = try #require((payload["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
            #expect(function["strict"] as? Bool == strict)
            let parameters = try #require(function["parameters"] as? [String: Any])
            #expect(parameters["required"] as? [String] == ["path"])
        }
        let required = AITool(name: "read", description: "Read a file", parameters: tool.parameters,
            constrainedSampling: .jsonSchema(strict: .require))
        let client = A3WireClient()
        let model = getModel(provider: .mistral, modelId: "mistral-large-4")
        let result = await streamMistral(model: model, context: a3Context(tools: [required]),
            options: MistralOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("Tool \"read\" requires JSON-schema constrained sampling, but strict tools are unsupported.") == true)
        #expect(await client.requests.isEmpty)
        #expect(model.mistralConversationsCompat?.supportsStrictMode == nil)
        let typed = Model(id: "a3-test", name: "A3 test", api: .mistralConversations,
            provider: "mistral", baseUrl: "https://api.mistral.ai", reasoning: true, input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 16_000, maxTokens: 1_000,
            compat: MistralConversationsCompat(supportsStrictMode: true))
        #expect(typed.mistralConversationsCompat?.supportsStrictMode == true)
        let typedClient = A3WireClient()
        _ = await streamMistral(model: typed, context: context,
            options: MistralOptions(apiKey: "test", httpClient: typedClient, maxRetries: 0)).result()
        let typedPayload = try await a3Payload(typedClient)
        #expect(((typedPayload["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["strict"] as? Bool == true)
    }

    // anthropic-strict-tool-schema.test.ts:81, #12067.
    @Test("keeps root additionalProperties in non-strict schemas")
    func anthropicRootAdditionalProperties() async throws {
        for additionalProperties in [false, true] {
            let client = A3WireClient()
            let model = a3Model(api: .anthropicMessages, provider: "alias", baseUrl: "https://gateway.example/v1")
            let tool = AITool(name: "lookup", description: "Look up", parameters: [
                "type": AnyCodable("object"), "properties": AnyCodable(["key": ["type": "string"]]),
                "required": AnyCodable(["key"]), "additionalProperties": AnyCodable(additionalProperties),
                "anyOf": AnyCodable([["type": "object"]]),
            ])
            _ = await streamAnthropic(model: model, context: a3Context(tools: [tool]),
                options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
            let payload = try await a3Payload(client)
            let schema = try #require((payload["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])
            #expect(schema["additionalProperties"] as? Bool == additionalProperties)
            #expect(schema["anyOf"] == nil)
            #expect(schema["required"] as? [String] == ["key"])
        }
    }
}
