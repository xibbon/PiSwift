import Foundation
import Testing
@testable import PiSwiftAI

private actor AWireCaptureClient: ProviderHTTPClient {
    private var captured: URLRequest?

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        captured = request
        let frame = "data: {\"id\":\"test\",\"created\":0,\"model\":\"test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(frame.utf8))
    }

    func request() -> URLRequest? { captured }
}

private func aWireModel(compat: OpenAICompat? = nil, window: Int = 1_048_576) -> Model {
    Model(id: "test", name: "Test", api: .openAICompletions, provider: "custom",
          baseUrl: "https://proxy.example/v1", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: window, maxTokens: 943_718, compat: compat)
}

private func aWireHistory() -> [Message] {
    let assistant = AssistantMessage(
        content: [.toolCall(ToolCall(id: "t1", name: "noop", arguments: [:]))],
        api: .openAICompletions, provider: "custom", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse)
    return [.user(UserMessage(content: .text("Run tool"))), .assistant(assistant),
            .toolResult(ToolResultMessage(toolCallId: "t1", toolName: "noop",
                                          content: [.text(TextContent(text: "done"))], isError: false)),
            .user(UserMessage(content: .text("Continue")))]
}

private func aWireCompletionsPayload(compat: OpenAICompat?, tools: [AITool]? = nil,
                                     messages: [Message] = aWireHistory()) async throws -> [String: Any] {
    let client = AWireCaptureClient()
    let options = OpenAICompletionsOptions(apiKey: "test", httpClient: client)
    _ = await streamOpenAICompletions(model: aWireModel(compat: compat),
        context: normalizeContext(Context(messages: messages, tools: tools)), options: options).result()
    let request = try #require(await client.request())
    let body = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Suite struct AWireProviderTests {
    // openai-completions-empty-tools.test.ts:288,298, #11843.
    @Test func omitsToolsByDefault() async throws {
        for tools in [nil, []] as [[AITool]?] {
            let payload = try await aWireCompletionsPayload(compat: nil, tools: tools)
            #expect(payload["tools"] == nil)
        }
    }

    @Test func sendsToolsWhenRequiredByToolHistory() async throws {
        for tools in [nil, []] as [[AITool]?] {
            let payload = try await aWireCompletionsPayload(
                compat: OpenAICompat(requiresToolsWithToolHistory: true), tools: tools)
            #expect((payload["tools"] as? [[String: Any]])?.isEmpty == true)
        }
    }

    // openai-completions-non-null-assistant-content.test.ts:86,94,107.
    @Test func nonNullAssistantContentUsesEmptyStringOnlyWhenSelected() async throws {
        let defaultPayload = try await aWireCompletionsPayload(compat: nil)
        let selectedPayload = try await aWireCompletionsPayload(
            compat: OpenAICompat(requiresNonNullAssistantContent: true))
        let defaultMessages = try #require(defaultPayload["messages"] as? [[String: Any]])
        let selectedMessages = try #require(selectedPayload["messages"] as? [[String: Any]])
        #expect(defaultMessages.first { $0["role"] as? String == "assistant" }?["content"] is NSNull)
        #expect(selectedMessages.first { $0["role"] as? String == "assistant" }?["content"] as? String == "")
        #expect(selectedMessages.map { $0["role"] as? String } == ["user", "assistant", "tool", "user"])
        let afterTool = try await aWireCompletionsPayload(
            compat: OpenAICompat(requiresAssistantAfterToolResult: true))
        let afterMessages = try #require(afterTool["messages"] as? [[String: Any]])
        #expect(afterMessages.map { $0["role"] as? String } == ["user", "assistant", "tool", "assistant", "user"])
    }

    // openai-completions-prompt-cache.test.ts:187,207,218,228.
    @Test func proxyPromptCacheKeyMode() throws {
        let body = try JSONSerialization.data(withJSONObject: ["model": "test"])
        func payload(_ mode: PromptCacheKeyMode, retention: CacheRetention, session: String? = "session") throws -> [String: Any] {
            let data = try #require(applyOpenAICompletionsPromptCache(
                data: body, baseUrl: "https://proxy.example/v1", sessionId: session,
                cacheRetention: retention, supportsLongCacheRetention: true, promptCacheKeyMode: mode))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try payload(.enabled, retention: .short)["prompt_cache_key"] as? String == "session")
        #expect(try payload(.enabled, retention: .none)["prompt_cache_key"] == nil)
        #expect(try payload(.enabled, retention: .short, session: nil)["prompt_cache_key"] == nil)
        #expect(try payload(.disabled, retention: .long)["prompt_cache_key"] == nil)
        #expect(try payload(.disabled, retention: .long)["prompt_cache_retention"] as? String == "24h")
        #expect(try payload(.enabled, retention: .short, session: String(repeating: "😀", count: 70))["prompt_cache_key"] as? String == String(repeating: "😀", count: 64))
    }

    // openai-responses-compat.test.ts:47,301,440,467; xai-responses.test.ts:182.
    @Test func responsesSessionHeaderUsesHyphenAndPreservesCallerHeader() throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "test", "input": []])
        request.setValue("caller", forHTTPHeaderField: "session-id")
        let middleware = OpenAIResponsesCacheMiddleware(sessionId: "generated", cacheRetention: .short,
            promptCacheRetention: nil, sessionAffinityFormat: .openai)
        let updated = middleware.intercept(request: request)
        #expect(updated.value(forHTTPHeaderField: "session-id") == "caller")
        #expect(updated.value(forHTTPHeaderField: "session_id") == nil)
        #expect(updated.value(forHTTPHeaderField: "x-client-request-id") == "generated")
    }

    @Test func responsesPromptCacheKeyModeDisabled() throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "test", "input": []])
        let middleware = OpenAIResponsesCacheMiddleware(sessionId: "session", cacheRetention: .short,
            promptCacheRetention: nil, sessionAffinityFormat: .openai, promptCacheKeyMode: .disabled)
        let body = try #require(middleware.intercept(request: request).httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["prompt_cache_key"] == nil)
    }

    // azure-openai-responses.ts:207 uses the key even without a retention option.
    @Test func azureResponsesPromptCacheKeyMode() throws {
        var request = URLRequest(url: URL(string: "https://azure.example/openai/responses")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "test", "input": []])
        for (mode, expected) in [(PromptCacheKeyMode.auto, "session"), (.enabled, "session"), (.disabled, nil)] {
            let middleware = OpenAIResponsesCacheMiddleware(sessionId: "session", cacheRetention: .none,
                promptCacheRetention: nil, sessionAffinityFormat: .openai,
                promptCacheKeyMode: mode, sendPromptCacheKeyWithoutRetention: true)
            let body = try #require(middleware.intercept(request: request).httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["prompt_cache_key"] as? String == expected)
        }
    }

    // retry.test.ts:100 and the v1.5.2 Zhipu 1308 case.
    @Test func retryClassifiesCutShortAndZhipuLimit() {
        func failed(_ text: String) -> AssistantMessage {
            AssistantMessage(content: [], api: .openAIResponses, provider: "test", model: "test",
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .error, errorMessage: text)
        }
        #expect(isRetryableAssistantError(failed("Claude Code's stream from Anthropic was cut short after the reply had begun")))
        #expect(!isRetryableAssistantError(failed(#"429 {"code":"1308","message":"limit"}"#)))
        #expect(!isRetryableAssistantError(failed(#"429 {"code":1308,"message":"limit"}"#)))
        #expect(isRetryableAssistantError(failed(#"429 {"code":"13080","message":"temporary"}"#)))
        #expect(isContextOverflow(failed("litellm.ContextWindowExceededError: Context Window exceeded for given call.")))
    }

    // error-body.test.ts:257,267,274, #11695.
    @Test func connectionErrorIncludesDeepestCause() {
        let inner = POSIXError(.ECONNREFUSED)
        let middle = URLError(.networkConnectionLost, userInfo: [NSUnderlyingErrorKey: inner])
        let outer = URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: middle])
        let message = providerErrorWithCause(outer)
        #expect(message.hasPrefix(outer.localizedDescription + ": "))
        #expect(message.contains("(61)"))
        #expect(providerErrorWithCause(URLError(.cannotConnectToHost)) == URLError(.cannotConnectToHost).localizedDescription)
    }

    // google-shared-convert-tools.test.ts:249,291.
    @Test func googleRewritesOnlySchemaConstValues() throws {
        let parameters: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "origin": ["type": "string", "const": "zq-src-7"],
                "flag": ["type": "boolean", "const": true],
                "list": ["type": "array", "items": ["const": "x"]],
            ] as [String: Any]),
            "const": AnyCodable(["literal": "value"]),
        ]
        let tool = AITool(name: "lookup", description: "lookup", parameters: parameters)
        let declarations = try #require(convertGoogleTools([tool]))
        let functions = try #require(declarations[0]["functionDeclarations"] as? [[String: Any]])
        let schema = try #require(functions[0]["parametersJsonSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let origin = try #require(properties["origin"] as? [String: Any])
        let flag = try #require(properties["flag"] as? [String: Any])
        #expect(origin["enum"] as? [String] == ["zq-src-7"])
        #expect(flag["const"] as? Bool == true)
        #expect(schema["const"] as? [String: String] == ["literal": "value"])
    }
}

@Suite struct AWireClampTests {
    private func context(input: Int) -> TranscriptContext {
        let assistant = AssistantMessage(content: [.text(TextContent(text: "ok"))],
            api: .openAICompletions, provider: "openai", model: "test",
            usage: Usage(input: input, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: input),
            stopReason: .stop, timestamp: 2)
        return normalizeContext(Context(messages: [
            .user(UserMessage(content: .text("hi"), timestamp: 1)), .assistant(assistant)
        ]))
    }

    // clamp-max-tokens.test.ts:37-68, all seven upstream cases.
    @Test func leaves15PercentOfTheInputUnused() {
        let model = aWireModel()
        #expect(clampSimpleMaxTokensToContext(model: model, context: context(input: 220_815),
            maxTokens: 943_718) == 1_048_576 - 220_815 - 33_123)
    }

    @Test func leavesAtLeast4096TokensUnusedForSmallInputs() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(), context: context(input: 10_000),
            maxTokens: 1_048_576) == 1_048_576 - 10_000 - 4_096)
    }

    @Test func keepsModelOutputLimitWhenItFits() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(), context: context(input: 100_000),
            maxTokens: 64_000) == 64_000)
    }

    @Test func sendsUpTo32768WhenProportionalMarginLeavesNoRoom() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(), context: context(input: 912_000),
            maxTokens: 943_718) == 32_768)
    }

    @Test func usesRealRoomMinus4096WhenLessThan32768Fit() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(), context: context(input: 1_030_000),
            maxTokens: 943_718) == 1_048_576 - 1_030_000 - 4_096)
    }

    @Test func keepsOnlyFixedMarginForSmallWindows() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(window: 32_768),
            context: context(input: 20_000), maxTokens: 32_768) == 32_768 - 20_000 - 4_096)
    }

    @Test func sendsOneTokenWhenInputExceedsWindow() {
        #expect(clampSimpleMaxTokensToContext(model: aWireModel(), context: context(input: 1_050_000),
            maxTokens: 943_718) == 1)
    }
}
