import Foundation
import Testing
@testable import PiSwiftAI

private func resumeGrammarTool(property: String = "payload") -> AITool {
    AITool(name: "sample_tool", description: "Sample", parameters: [
        "type": AnyCodable("object"),
        "properties": AnyCodable([property: ["type": "string"]]),
        "required": AnyCodable([property]),
    ], constrainedSampling: .grammar(variants: [.openAILark: "start: /[a-z]+/"]))
}

private func resumeGrammarPayload(
    api: Api, topLevel: [AITool]?, transcript: [AITool]?
) throws -> [String: Any] {
    let model = Model(id: "grammar-test", name: "Grammar test", api: api,
        provider: api == .azureOpenAIResponses ? "azure" : "openai", baseUrl: "https://example.invalid/v1",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192, maxTokens: 1024, compat: OpenAICompat(supportsOpenAIGrammarTools: true,
            supportsMidConvoSystemMessages: true, supportsAdditionalTools: transcript != nil))
    var messages: [Message] = [
        .system(SystemMessage(content: .text("Base"))),
        .user(UserMessage(content: .text("Use the tool"))),
    ]
    if let transcript {
        messages.append(.system(SystemMessage(content: .text(""), toolsAdded: transcript)))
    }
    messages += [
        .assistant(AssistantMessage(content: [.toolCall(ToolCall(id: "call_1|ctc_1", name: "sample_tool",
            arguments: ["payload": AnyCodable("abc")]))], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)),
        .toolResult(ToolResultMessage(toolCallId: "call_1|ctc_1", toolName: "sample_tool",
            content: [.text(TextContent(text: "done"))], isError: false)),
    ]
    let context = Context(messages: messages, tools: topLevel)
    if api == .openAICodexResponses {
        return ["input": convertCodexMessages(model: model, context: context)]
    }
    let query = try api == .azureOpenAIResponses
        ? buildAzureResponsesQuery(model: model, context: context, options: AzureOpenAIResponsesOptions(), deploymentName: model.id)
        : buildResponsesQuery(model: model, context: context, options: OpenAIResponsesOptions())
    var request = URLRequest(url: URL(string: model.baseUrl)!)
    request.httpBody = try JSONEncoder().encode(query)
    let constrained = try makeOpenAIResponsesConstrainedSamplingMiddleware(
        tools: responsesToolDeclarations(context), supportsStrictMode: true, supportsOpenAIGrammarTools: true)
    request = constrained.intercept(request: request)
    request = try makeResponsesReplayMiddleware(model: model, context: context).intercept(request: request)
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func expectResumeGrammarCall(_ payload: [String: Any]) throws -> [[String: Any]] {
    let input = try #require(payload["input"] as? [[String: Any]])
    let call = try #require(input.first { $0["type"] as? String == "custom_tool_call" })
    #expect(call["id"] as? String == "ctc_1")
    #expect(call["call_id"] as? String == "call_1")
    #expect(call["input"] as? String == "abc")
    #expect(input.contains { $0["type"] as? String == "custom_tool_call_output" })
    return input
}

// Upstream openai-responses-shared.ts:363-381 keeps matching custom call IDs.
@Suite struct A2GrammarReplayResumeTests {
    @Test(arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
    func transcriptOnlyGrammarToolKeepsCustomItemId(_ api: Api) throws {
        let payload = try resumeGrammarPayload(api: api, topLevel: nil, transcript: [resumeGrammarTool()])
        let input = try expectResumeGrammarCall(payload)
        #expect(payload["tools"] == nil)
        let batch = try #require(input.first { $0["type"] as? String == "additional_tools" })
        let tools = try #require(batch["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "sample_tool")
        #expect(tools.first?["type"] as? String == "custom")
    }

    @Test(arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
    func topLevelOnlyGrammarToolKeepsCustomItemId(_ api: Api) throws {
        let payload = try resumeGrammarPayload(api: api, topLevel: [resumeGrammarTool()], transcript: nil)
        let input = try expectResumeGrammarCall(payload)
        #expect(!input.contains { $0["type"] as? String == "additional_tools" })
    }

    @Test(arguments: [Api.openAIResponses, .azureOpenAIResponses, .openAICodexResponses])
    func transcriptDefinitionReplacesTopLevelGrammarDefinition(_ api: Api) throws {
        let payload = try resumeGrammarPayload(api: api, topLevel: [resumeGrammarTool(property: "oldPayload")],
            transcript: [resumeGrammarTool()])
        _ = try expectResumeGrammarCall(payload)
    }
}
