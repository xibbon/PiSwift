import Foundation
import Testing
@testable import PiSwiftAI

@Suite struct A1ResponsesRetryOverflowTests {
    // Port of constrained-sampling.test.ts: foreign grammar-call item ids.
    @Test(arguments: [false, true])
    func grammarReplayDropsForeignItemId(_ azure: Bool) throws {
        try checkReplay(azure: azure, source: "foreign", sourceModel: "gpt-other", itemId: "ctc_1", grammar: true, expectedId: nil)
    }

    @Test(arguments: [false, true])
    func grammarReplayKeepsSameModelCustomItemId(_ azure: Bool) throws {
        try checkReplay(azure: azure, source: nil, sourceModel: "gpt-test", itemId: "ctc_1", grammar: true, expectedId: "ctc_1")
    }

    @Test(arguments: [false, true])
    func replayDropsMismatchedAndDifferentModelIds(_ azure: Bool) throws {
        try checkReplay(azure: azure, source: nil, sourceModel: "gpt-other", itemId: "ctc_1", grammar: true, expectedId: nil)
        try checkReplay(azure: azure, source: nil, sourceModel: "gpt-test", itemId: "ctc_1", grammar: false, expectedId: nil)
        try checkReplay(azure: azure, source: nil, sourceModel: "gpt-test", itemId: "fc_1", grammar: true, expectedId: nil)
        try checkReplay(azure: azure, source: nil, sourceModel: "gpt-test", itemId: "fc_1", grammar: false, expectedId: "fc_1")
    }

    private func checkReplay(
        azure: Bool, source: String?, sourceModel: String, itemId: String,
        grammar: Bool, expectedId: String?
    ) throws {
        let model = Model(
            id: "gpt-test", name: "Test", api: azure ? .azureOpenAIResponses : .openAIResponses,
            provider: azure ? "azure-openai-responses" : "openai", baseUrl: "https://example.test/v1",
            reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 8192, maxTokens: 1024, compat: OpenAICompat(supportsOpenAIGrammarTools: true)
        )
        let tool = AITool(name: "sample_tool", description: "Sample", parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["payload": ["type": "string"]] as [String: Any]),
            "required": AnyCodable(["payload"]),
        ], constrainedSampling: grammar ? .grammar(variants: [.openAILark: "start: /[a-z]+/"]) : nil)
        let callId = "call_1|\(itemId)"
        let context = Context(messages: [
            .assistant(AssistantMessage(
                content: [.toolCall(ToolCall(id: callId, name: tool.name, arguments: ["payload": AnyCodable("abc")]))],
                api: source == nil ? model.api : .openAICompletions, provider: source ?? model.provider, model: sourceModel,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse
            )),
            .toolResult(ToolResultMessage(toolCallId: callId, toolName: tool.name,
                                          content: [.text(TextContent(text: "done"))], isError: false)),
        ], tools: [tool])
        let query = try azure
            ? buildAzureResponsesQuery(model: model, context: context, options: AzureOpenAIResponsesOptions(), deploymentName: model.id)
            : buildResponsesQuery(model: model, context: context, options: OpenAIResponsesOptions())
        var request = URLRequest(url: URL(string: model.baseUrl)!)
        request.httpBody = try JSONEncoder().encode(query)
        let middleware = try makeOpenAIResponsesConstrainedSamplingMiddleware(
            tools: [tool], supportsStrictMode: true, supportsOpenAIGrammarTools: true
        )
        let updated = middleware.intercept(request: request)
        let payload = try #require(JSONSerialization.jsonObject(with: updated.httpBody!) as? [String: Any])
        let input = try #require(payload["input"] as? [[String: Any]])
        let call = try #require(input.first { $0["type"] as? String == (grammar ? "custom_tool_call" : "function_call") })
        #expect(call["id"] as? String == expectedId)
        #expect(call["call_id"] as? String == "call_1")
        if grammar {
            #expect(call["input"] as? String == "abc")
            #expect(input.contains { $0["type"] as? String == "custom_tool_call_output" })
        }
    }

    @Test func zaiCNPromptExceedsMaxLengthIsOverflow() {
        let message = AssistantMessage(
            content: [], api: .openAICompletions, provider: "zai", model: "test",
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .error, errorMessage: #"400 {"code":"1261","message":"Prompt exceeds max length"}"#
        )
        #expect(isContextOverflow(message, contextWindow: 1_048_576))
    }

    @Test(arguments: [["retry-after": "not a date"], ["retry-after-ms": "Infinity"]])
    func invalidServerRetryDelayUsesExponentialBackoff(_ headers: [String: String]) throws {
        let error = StreamError.providerRequest(statusCode: 429, headers: headers, message: "retry")
        for index in [0, 1, 4] {
            let delay = try getRetryDelayMs(error: error, retryIndex: index, maxRetryDelayMs: 1)
            let base = min(500 * pow(2, Double(index)), 8000)
            #expect(delay >= base * 0.75 && delay <= base)
        }
    }
}
