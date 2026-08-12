import Foundation
import Testing
@testable import PiSwiftAI

private struct WorkOrderHTTPClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await handler(request)
    }
}

private func workOrderModel(
    api: Api,
    provider: Provider,
    id: String,
    baseUrl: String = "https://provider.example/v1",
    reasoning: Bool = false,
    compat: OpenAICompat? = nil
) -> Model {
    Model(
        id: id,
        name: id,
        api: api,
        provider: provider,
        baseUrl: baseUrl,
        reasoning: reasoning,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_000,
        maxTokens: 4_096,
        compat: compat
    )
}

@Test func anthropicCapturesContentFromBlockStart() async {
    let sse = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_initial","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"initial text"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":"initial thought","signature":"initial-signature"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}

    event: message_stop
    data: {"type":"message_stop"}

    """
    let client = WorkOrderHTTPClient { _ in
        ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data(sse.utf8))
    }
    let model = workOrderModel(api: .anthropicMessages, provider: "anthropic-test", id: "claude-test")
    let result = await streamAnthropic(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: AnthropicOptions(apiKey: "test-key", httpClient: client)
    ).result()

    #expect(result.stopReason == .stop)
    #expect(result.content.contains { if case .text(let text) = $0 { return text.text == "initial text" }; return false })
    #expect(result.content.contains {
        if case .thinking(let thought) = $0 {
            return thought.thinking == "initial thought" && thought.thinkingSignature == "initial-signature"
        }
        return false
    })
}

@Test func openRouterAnthropicCacheAdvancesThroughToolResultsAndAliases() throws {
    let alias = getModel(provider: .openrouter, modelId: "~anthropic/claude-sonnet-latest")
    #expect(alias.compat?.cacheControlFormat == .anthropic)

    let payload: [String: Any] = [
        "messages": [
            ["role": "user", "content": "question"],
            ["role": "assistant", "content": "calling"],
            ["role": "tool", "content": "latest tool result"],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let updatedData = try #require(applyOpenAICompatCacheControl(
        data: data,
        cacheControl: ["type": "ephemeral"],
        supportsCacheControlOnTools: false
    ))
    let updated = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
    let messages = try #require(updated["messages"] as? [[String: Any]])
    let toolContent = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(toolContent.first?["cache_control"] != nil)
}

@Test func googleReplayPreservesSignedEmptyBlocksAndGemini3ToolCallIds() throws {
    let model = workOrderModel(api: .googleGenerativeAI, provider: "google-test", id: "gemini-3.1-test", reasoning: true)
    let assistant = AssistantMessage(
        content: [
            .text(TextContent(text: "", textSignature: "QUJDRA==")),
            .thinking(ThinkingContent(thinking: "", thinkingSignature: "RUZHSA==")),
            .toolCall(ToolCall(id: "call_replay_1", name: "lookup", arguments: ["q": AnyCodable("swift")], thoughtSignature: "SUprTA==")),
        ],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .toolUse
    )
    let converted = convertGoogleMessages(model: model, context: Context(messages: [.assistant(assistant)]))
    let parts = try #require(converted.first?["parts"] as? [[String: Any]])

    #expect(parts.contains { ($0["text"] as? String) == "" && ($0["thoughtSignature"] as? String) == "QUJDRA==" })
    #expect(parts.contains { ($0["thought"] as? Bool) == true && ($0["text"] as? String) == "" && ($0["thoughtSignature"] as? String) == "RUZHSA==" })
    let functionCall = try #require(parts.compactMap { $0["functionCall"] as? [String: Any] }.first)
    #expect(functionCall["id"] as? String == "call_replay_1")
}

@Test func googleRequestsRetryTransientProviderFailures() async throws {
    let attempts = LockedState(0)
    let client = WorkOrderHTTPClient { _ in
        let attempt = attempts.withLock { value -> Int in value += 1; return value }
        if attempt == 1 {
            return ProviderHTTPResponse(statusCode: 503, headers: ["retry-after-ms": "1"], body: Data("retry".utf8))
        }
        return ProviderHTTPResponse(statusCode: 200, body: Data("ok".utf8))
    }
    let response = try await retryGoogleRequest(
        URLRequest(url: URL(string: "https://google.example/generate")!),
        httpClient: client,
        maxRetries: 1,
        maxRetryDelayMs: 10,
        signal: nil
    )
    #expect(response.statusCode == 200)
    #expect(attempts.withLock { $0 } == 2)
}

@Test func codexWebSocketCacheSeparatesAccounts() {
    let first = codexWebSocketCacheKey(sessionId: "session", accountId: "account-a")
    let second = codexWebSocketCacheKey(sessionId: "session", accountId: "account-b")
    #expect(first != second)
}

@Test func codexMissingContinuationRetriesOnlyOnce() {
    var retried = false
    let error = OpenAICodexStreamError.codedApiError(
        code: "previous_response_not_found",
        message: "missing"
    )
    #expect(shouldRetryMissingCodexContinuation(error, retried: &retried))
    #expect(!shouldRetryMissingCodexContinuation(error, retried: &retried))
}

@Test func recoverableLengthDetectionIsBoundedByRequestedOutput() {
    let message = AssistantMessage(
        content: [],
        api: .openAIResponses,
        provider: "openai",
        model: "test",
        usage: Usage(input: 10, output: 20, cacheRead: 0, cacheWrite: 0, totalTokens: 30),
        stopReason: .length
    )
    #expect(isRecoverableLength(message, desiredMaxOutput: 100))
    #expect(!isRecoverableLength(message, desiredMaxOutput: 20))
}

@Test func completionsKeepsFunctionArgumentsWhenCustomPayloadIsEmpty() async {
    let payload = """
    data: {"id":"chatcmpl-tool","object":"chat.completion.chunk","created":0,"model":"test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"custom","function":{"name":"lookup","arguments":"{\\"value\\":42}"},"custom":{}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
    let client = WorkOrderHTTPClient { _ in ProviderHTTPResponse(statusCode: 200, body: Data(payload.utf8)) }
    let model = workOrderModel(api: .openAICompletions, provider: "compatible", id: "test")
    let result = await streamOpenAICompletions(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAICompletionsOptions(apiKey: "key", httpClient: client)
    ).result()
    let tool = result.content.compactMap { if case .toolCall(let tool) = $0 { return tool }; return nil }.first
    #expect(tool?.name == "lookup")
    #expect(tool?.arguments["value"]?.value as? Int == 42)
}

@Test func crossProviderDuplicateCallIdsRemainUnique() {
    let model = workOrderModel(api: .openAICompletions, provider: "compatible", id: "test")
    let first = normalizeCompletionsToolCallId("shared-call|item-a", model: model)
    let second = normalizeCompletionsToolCallId("shared-call|item-b", model: model)
    #expect(first != second)
    #expect(first.hasPrefix("shared-call"))
    #expect(second.hasPrefix("shared-call"))
}

@Test func zaiAndCompatibleEndpointsUseMaxTokens() throws {
    let payload = try JSONSerialization.data(withJSONObject: ["max_completion_tokens": 321, "model": "test"])
    let updatedData = applyOpenAICompletionsMaxTokensField(data: payload, field: .maxTokens)
    let updated = try #require(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
    #expect(updated["max_tokens"] as? Int == 321)
    #expect(updated["max_completion_tokens"] == nil)
    let custom = workOrderModel(
        api: .openAICompletions,
        provider: "custom-zai",
        id: "test",
        baseUrl: "https://open.bigmodel.cn/api/paas/v4"
    )
    #expect(detectedOpenAICompletionsMaxTokensField(model: custom) == .maxTokens)
}

@Test func cacheRetentionNoneDisablesOpenAIAndCodexImplicitCaches() throws {
    let body = try JSONSerialization.data(withJSONObject: ["model": "gpt-5.4", "input": []])
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
    request.httpBody = body
    let updated = OpenAIResponsesCacheMiddleware(
        sessionId: "session",
        cacheRetention: .none,
        promptCacheRetention: nil,
        sessionAffinityFormat: .openai,
        supportsExplicitPromptCacheMode: true
    ).intercept(request: request)
    let updatedBody = try #require(updated.httpBody)
    let payload = try #require(try JSONSerialization.jsonObject(with: updatedBody) as? [String: Any])
    let cacheOptions = try #require(payload["prompt_cache_options"] as? [String: Any])
    #expect(cacheOptions["mode"] as? String == "explicit")
    #expect(payload["prompt_cache_key"] == nil)
    #expect(codexCacheSessionId("session", cacheRetention: CacheRetention.none) == nil)
}

@Test func bedrockFailureDiagnosticsPreserveStructuredMetadata() throws {
    let diagnostic = try #require(bedrockFailureDiagnostic(for: BedrockStreamError.responseFailure(
        message: "throttled",
        status: 429,
        errorCode: "ThrottlingException",
        requestId: "request-123"
    )))
    #expect(diagnostic.type == "bedrock_response_failure")
    #expect(diagnostic.details["status"]?.value as? Int == 429)
    #expect(diagnostic.details["errorCode"]?.value as? String == "ThrottlingException")
    #expect(diagnostic.details["requestId"]?.value as? String == "request-123")
}

private final class WorkOrderClassBody {
    var state = "internal"
}

@Test func providerErrorBodyRejectsArraysAndClassInstances() {
    let array = normalizeProviderErrorBody(message: "real array error", candidate: [["noise": true]])
    #expect(array.body == nil)
    #expect(array.message == "real array error")
    let instance = normalizeProviderErrorBody(message: "real class error", candidate: WorkOrderClassBody())
    #expect(instance.body == nil)
    #expect(instance.message == "real class error")
}

@Test func anyOfAndOneOfPreserveNullBeforeCoercion() throws {
    for unionKeyword in ["anyOf", "oneOf"] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "value": [
                    unionKeyword: [
                        ["type": "string"],
                        ["type": "null"],
                    ],
                ],
            ],
            "required": ["value"],
        ]
        let tool = AITool(name: "union", description: "union", parameters: schema.mapValues(AnyCodable.init))
        let call = ToolCall(id: "call", name: "union", arguments: ["value": AnyCodable(NSNull())])
        let result = try validateToolArguments(tool: tool, toolCall: call)
        #expect(result["value"]?.value is NSNull)
    }
}

@Test func copilotPolicyFallbackRestoresIndividualAccountModels() throws {
    let raw: [String: Any] = [
        "data": [
            ["id": "policy-model", "model_picker_enabled": false, "policy": ["state": "enabled"], "capabilities": ["supports": ["tool_calls": true]]],
            ["id": "no-tools", "model_picker_enabled": false, "policy": ["state": "enabled"], "capabilities": ["supports": ["tool_calls": false]]],
        ],
    ]
    #expect(try parseAvailableCopilotModelIds(raw, allowPolicyFallback: true) == ["policy-model"])
    #expect(try parseAvailableCopilotModelIds(raw, allowPolicyFallback: false).isEmpty)
}
