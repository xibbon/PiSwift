import Foundation
import Testing
@testable import PiSwiftAI

private func a2EstimateModel(api: Api = .openAIResponses) -> Model {
    Model(id: "a2-estimate", name: "Estimate", api: api, provider: api == .mistralConversations ? "mistral" : "test",
          baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text, .image],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 10_000, maxTokens: 8_000)
}

private func a2UsageMessage(timestamp: Int64 = 100, tokens: Int = 0, error: String? = nil) -> AssistantMessage {
    AssistantMessage(content: [fauxText("kept")], api: .openAIResponses, provider: "test", model: "test",
        usage: Usage(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: tokens),
        stopReason: error == nil ? .stop : .error, errorMessage: error, timestamp: timestamp)
}

@Suite struct A2RetryEstimateV110Tests {
    @Test(arguments: ["server_busy", "servers are currently busy", "SeRvEr_BuSy", "SERVERS ARE CURRENTLY BUSY"])
    func busyErrorsAreRetryable(text: String) {
        #expect(isRetryableAssistantError(a2UsageMessage(error: text)))
    }

    // Upstream mistral-raw-stop-reason.test.ts, #10487.
    @Test(arguments: ["error", "unmapped_error"])
    func mistralStopReasonRetryPolicy(reason: String) async {
        let client = A2MistralStopClient(reason: reason)
        let model = a2EstimateModel(api: .mistralConversations)
        let message = await streamMistral(model: model, context: normalizeContext(Context(messages: [])),
            options: MistralOptions(apiKey: "test", httpClient: client)).result()
        #expect(message.rawStopReason == reason)
        #expect(message.stopReason == .error)
        #expect(isRetryableAssistantError(message) == (reason == "error"))
        #expect(message.errorMessage == (reason == "error"
            ? "Provider stopped with: error (server error)" : "Provider stopped with: unmapped_error"))
    }

    // Upstream provider-retry.test.ts: the same status still retries by default.
    @Test(arguments: [false, true])
    func excludedStatusesFailAtOnce(exclude: Bool) async {
        let attempts = LockedState(0)
        do {
            let _: String = try await retryProviderRequest(maxRetries: 2, noRetryStatuses: exclude ? [504] : []) {
                attempts.withLock { $0 += 1 }
                throw StreamError.providerRequest(statusCode: 504,
                    headers: ["retry-after-ms": "0", "x-should-retry": "true"], message: "gateway timeout")
            }
            Issue.record("Expected the provider error")
        } catch let error as StreamError {
            guard case .providerRequest(let status, _, let message) = error else {
                Issue.record("Expected the original provider error")
                return
            }
            #expect(status == 504)
            #expect(message == "gateway timeout")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(attempts.withLock { $0 } == (exclude ? 1 : 3))
    }

    // Upstream context-estimate.test.ts, #10497.
    @Test func reservesThreePointFiveCharactersPerToken() {
        let context = normalizeContext(Context(messages: [
            .assistant(a2UsageMessage(tokens: 2_000)),
            .user(UserMessage(content: .text(String(repeating: "x", count: 3_500)), timestamp: 200)),
        ]))
        #expect(estimateContextTokens(context) == 3_000)
        #expect(clampSimpleMaxTokensToContext(model: a2EstimateModel(), context: context, maxTokens: 8_000) == 2_904)
    }

    @Test func ignoresStaleUsageAfterInsertedMessage() {
        let context = normalizeContext(Context(systemPrompt: "system", messages: [
            .user(UserMessage(content: .text("summary"), timestamp: 200)),
            .assistant(a2UsageMessage(tokens: 9_500)),
            .user(UserMessage(content: .text(String(repeating: "x", count: 4_000)), timestamp: 300)),
        ]))
        #expect(estimateContextTokens(context) == 1_149)
        #expect(clampSimpleMaxTokensToContext(model: a2EstimateModel(), context: context, maxTokens: 8_000) == 4_755)
    }

    @Test func usesUsageAfterResponseToInsertedContext() {
        let context = normalizeContext(Context(messages: [
            .user(UserMessage(content: .text("summary"), timestamp: 200)),
            .assistant(a2UsageMessage(tokens: 9_500)),
            .user(UserMessage(content: .text("new prompt"), timestamp: 300)),
            .assistant(a2UsageMessage(timestamp: 400, tokens: 2_000)),
            .user(UserMessage(content: .text("tail"), timestamp: 500)),
        ]))
        #expect(estimateContextTokens(context) == 2_002)
        #expect(clampSimpleMaxTokensToContext(model: a2EstimateModel(), context: context, maxTokens: 8_000) == 3_902)
    }

    @Test func keepsImageCharacterEstimate() {
        let context = normalizeContext(Context(messages: [.user(UserMessage(content: .blocks([
            .image(ImageContent(data: "abcd", mimeType: "image/png")), .text(TextContent(text: "abc")),
        ])))]))
        #expect(estimateContextTokens(context) == 1_373) // ceil((4_800 + 3) / 3.5)
    }

}

// Use the existing serial suite for tests that use the provider registry.
extension ApiRegistryTests {
    // Upstream openai-completions-empty-tools.test.ts: default and explicit limits.
    @Test(arguments: [nil, 7_000] as [Int?])
    func A2CompletionPayloadClampsOutput(maxTokens: Int?) async throws {
        let request = LockedState<URLRequest?>(nil)
        let client = A2CompletionsClient(request: request)
        let model = a2EstimateModel(api: .openAICompletions)
        let context = Context(messages: [.user(UserMessage(content: .text(String(repeating: "x", count: 8_000))))], tools: [])
        // Use the public registry path to apply the context clamp before option mapping.
        let result = try await completeSimple(model: model, context: context,
            options: SimpleStreamOptions(maxTokens: maxTokens, apiKey: "test", httpClient: client))
        #expect(result.stopReason == .stop)
        let body = try #require(request.withLock { $0?.httpBody })
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["max_completion_tokens"] as? Int == 3_618)
        #expect(payload["max_tokens"] == nil)
        #expect(payload["tools"] == nil)
    }
}

private struct A2MistralStopClient: ProviderHTTPClient {
    let reason: String

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let json = "{\"id\":\"a2-mistral\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}"
        return ProviderHTTPResponse(statusCode: 200, body: Data("data: \(json)\n\ndata: [DONE]\n\n".utf8))
    }
}

private struct A2CompletionsClient: ProviderHTTPClient {
    let request: LockedState<URLRequest?>

    func send(_ value: URLRequest) async throws -> ProviderHTTPResponse {
        request.withLock { $0 = value }
        let json = "{\"id\":\"a2-completions\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
        return ProviderHTTPResponse(statusCode: 200, body: Data("data: \(json)\n\ndata: [DONE]\n\n".utf8))
    }
}
