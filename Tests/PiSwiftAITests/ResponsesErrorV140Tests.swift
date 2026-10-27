import Foundation
import Testing
@testable import PiSwiftAI

private actor V140ErrorHTTPClient: ProviderHTTPClient {
    let response: ProviderHTTPResponse
    private(set) var requestCount = 0

    init(status: Int, body: String) {
        response = ProviderHTTPResponse(statusCode: status, body: Data(body.utf8))
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requestCount += 1
        return response
    }
}

private func v140ResponsesModel(provider: String = "openai") -> Model {
    Model(
        id: "test-model", name: "Test model", api: .openAIResponses,
        provider: provider, baseUrl: "https://example.invalid/v1", reasoning: true,
        input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1_000_000, maxTokens: 128_000
    )
}

private func v140ResponsesFailure(model: Model, client: V140ErrorHTTPClient) async -> AssistantMessage {
    await streamOpenAIResponses(
        model: model,
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("Continue")))])),
        options: OpenAIResponsesOptions(apiKey: "test-key", httpClient: client, maxRetries: 0)
    ).result()
}

@Suite struct ResponsesErrorV140Tests {
    // openai-responses.ts:40,267: use the exact workspace admin hint for HTTP and SSE.
    @Test(arguments: [false, true])
    func businessWorkspaceLimitHint(_ streamed: Bool) async throws {
        let code = "subscription_sharing_workplace_individual_usage_limit_exceeded"
        let error = #"{"code":"\#(code)","message":"Usage limit reached."}"#
        let body = streamed
            ? #"data: {"type":"response.failed","response":{"status":"failed","error":\#(error)}}"# + "\n\n"
            : #"{"error":\#(error)}"#
        let client = V140ErrorHTTPClient(status: streamed ? 200 : 429, body: body)
        let output = await v140ResponsesFailure(model: v140ResponsesModel(), client: client)
        let message = try #require(output.errorMessage)
        #expect(output.stopReason == .error)
        #expect(message.contains(code))
        #expect(message.hasSuffix("\nYou've reached your ChatGPT workspace's usage limit. Ask your workspace admin to increase it at admin.openai.com → Workspace → Usage limits."))
        #expect(!isRetryableAssistantError(output))
        #expect(await client.requestCount == 1)
    }

    @Test func sharedUsageLimitKeepsExistingLink() {
        let message = "subscription_sharing_usage_limit_exceeded: Usage limit reached."
        #expect(chatGPTUsageLimitMessage(message) == "\(message)\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage")
    }

    // github-copilot-request-size-overflow.test.ts:21: use the provider's HTTP error path.
    @Test(arguments: [413, 400], [false, true])
    func copilotRequestSizeNormalization(_ status: Int, _ nested: Bool) async throws {
        let error = #"{"message":"failed to parse request","code":""}"#
        let body = nested ? #"{"error":\#(error)}"# : error
        let client = V140ErrorHTTPClient(status: status, body: body)
        let model = v140ResponsesModel(provider: "github-copilot")
        let output = await v140ResponsesFailure(model: model, client: client)
        let message = try #require(output.errorMessage)
        #expect(await client.requestCount == 1)
        #expect(output.provider == "github-copilot")
        #expect(output.stopReason == .error)
        #expect(output.usage.totalTokens == 0)
        #expect(message.hasPrefix("github-copilot API error (\(status)): "))
        #expect(message.contains("failed to parse request"))
        #expect(isContextOverflow(output, contextWindow: model.contextWindow) == (status == 413))
    }
}
