import Foundation
import Testing
@testable import PiSwiftAI

private struct A5ResponsesHTTPClient: ProviderHTTPClient {
    let response: ProviderHTTPResponse
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { response }
}

private func a5ResponsesModel(
    baseUrl: String = "https://api.openai.com/v1", compat: OpenAICompat? = nil
) -> Model {
    Model(
        id: "gpt-5-mini", name: "GPT-5 Mini", api: .openAIResponses,
        provider: "openai", baseUrl: baseUrl, reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 400_000, maxTokens: 128_000, compat: compat
    )
}

private func a5CaptureResponsesPayload(model: Model, apiKey: String) async throws -> [String: Any] {
    let captured = LockedState<String?>(nil)
    let client = A5ResponsesHTTPClient(response: ProviderHTTPResponse(statusCode: 500, body: Data("server error".utf8)))
    _ = await streamOpenAIResponses(
        model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("hi")))])),
        options: OpenAIResponsesOptions(
            temperature: 0.5, maxTokens: 1000, apiKey: apiKey, httpClient: client,
            cacheRetention: .long, onPayload: { snapshot in captured.withLock { $0 = snapshot.json } },
            maxRetries: 0
        )
    ).result()
    let json = try #require(captured.withLock { $0 })
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Suite("A5 ChatGPT Responses")
struct A5ChatGPTResponsesTests {
    @Test func requestOmitsUnsupportedFieldsForChatGPTToken() async throws {
        let payload = try await a5CaptureResponsesPayload(model: a5ResponsesModel(), apiKey: "chatgpt-access-token")
        #expect(payload["max_output_tokens"] == nil)
        #expect(payload["temperature"] == nil)
        #expect(payload["prompt_cache_retention"] == nil)
        #expect(payload["prompt_cache_options"] == nil)
    }

    @Test func explicitCacheOptionsOmittedOnlyForChatGPTToken() async throws {
        let model = a5ResponsesModel(compat: OpenAICompat(supportsExplicitPromptCacheMode: true))
        let tokenPayload = try await a5CaptureResponsesPayload(model: model, apiKey: "chatgpt-access-token")
        let apiKeyPayload = try await a5CaptureResponsesPayload(model: model, apiKey: "sk-test")
        #expect(tokenPayload["prompt_cache_options"] == nil)
        #expect((apiKeyPayload["prompt_cache_options"] as? [String: String])?["ttl"] == "30m")
    }

    @Test func apiKeyAndOtherEndpointKeepFields() async throws {
        let apiKeyPayload = try await a5CaptureResponsesPayload(model: a5ResponsesModel(), apiKey: "sk-test")
        let otherEndpointPayload = try await a5CaptureResponsesPayload(
            model: a5ResponsesModel(baseUrl: "https://gateway.example.com/v1"), apiKey: "gateway-key"
        )
        for payload in [apiKeyPayload, otherEndpointPayload] {
            #expect(payload["max_output_tokens"] as? Int == 1000)
            #expect(payload["temperature"] as? Double == 0.5)
            #expect(payload["prompt_cache_retention"] as? String == "24h")
        }
    }

    @Test func httpAndStreamLimitErrorsLinkToUsage() async throws {
        let body = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Usage limit reached."}}"#.utf8)
        let httpClient = A5ResponsesHTTPClient(response: ProviderHTTPResponse(statusCode: 429, body: body))
        let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("hi")))]))
        let model = a5ResponsesModel()
        let httpOutput = await streamOpenAIResponses(
            model: model, context: context,
            options: OpenAIResponsesOptions(apiKey: "chatgpt-token", httpClient: httpClient, maxRetries: 0)
        ).result()
        #expect(httpOutput.stopReason == .error)
        #expect(httpOutput.errorMessage?.contains("subscription_sharing_usage_limit_exceeded") == true)
        #expect(httpOutput.errorMessage?.contains("Check your ChatGPT usage: https://chatgpt.com/settings/usage") == true)

        let sse = "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"Usage limit reached.\"}}}\n\n"
        let streamClient = A5ResponsesHTTPClient(response: ProviderHTTPResponse(statusCode: 200, body: Data(sse.utf8)))
        let streamOutput = await streamOpenAIResponses(
            model: model, context: context,
            options: OpenAIResponsesOptions(apiKey: "chatgpt-token", httpClient: streamClient, maxRetries: 0)
        ).result()
        #expect(streamOutput.stopReason == .error)
        #expect(streamOutput.errorMessage?.contains("subscription_sharing_usage_limit_exceeded") == true)
        #expect(streamOutput.errorMessage?.contains("Check your ChatGPT usage: https://chatgpt.com/settings/usage") == true)
    }
}

@Test func a5SubscriptionRetryCodes() {
    func message(_ error: String) -> AssistantMessage {
        AssistantMessage(
            content: [], api: .openAIResponses, provider: "openai", model: "gpt-5-mini",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error, errorMessage: error
        )
    }
    #expect(!isRetryableAssistantError(message("429 subscription_sharing_usage_limit_exceeded")))
    #expect(isRetryableAssistantError(message("subscription_sharing_usage_unavailable")))
    #expect(isRetryableAssistantError(message("subscription_sharing_user_unavailable")))
}
