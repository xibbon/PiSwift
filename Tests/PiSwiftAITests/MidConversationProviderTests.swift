import Foundation
import Testing
@testable import PiSwiftAI

private actor MidConversationCapture: ProviderHTTPClient {
    private var data: Data?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        data = request.httpBody
        return ProviderHTTPResponse(statusCode: 500, body: Data("captured".utf8))
    }
    func payload() -> Data? { data }
}
private enum MidConversationCaptureError: Error { case missingPayload }
private func midModel(_ api: Api, compat: OpenAICompat? = nil) -> Model {
    Model(id: "mid-test", name: "Mid test", api: api, provider: api == .anthropicMessages ? "anthropic" : "openai",
          baseUrl: "https://example.invalid/v1", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 32_000,
          maxTokens: 100, compat: compat)
}
private func midTool(_ name: String, description: String? = nil) -> AITool {
    AITool(name: name, description: description ?? name, parameters: ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())])
}
private func midContext(_ updates: [Message] = []) -> TranscriptContext {
    normalizeContext(Context(systemPrompt: "Base", messages: [.user(UserMessage(content: .text("hello")))] + updates,
                             tools: [midTool("read")]))
}
private func midSystem(_ text: String = "Later", added: [AITool]? = nil, removed: [ToolReference]? = nil) -> Message {
    .system(SystemMessage(content: .text(text), toolsAdded: added, toolsRemoved: removed, timestamp: 1))
}
private func captureMidBody(_ api: Api, compat: OpenAICompat?, context: TranscriptContext) async throws -> [String: Any] {
    let client = MidConversationCapture()
    let model = midModel(api, compat: compat)
    switch api {
    case .anthropicMessages:
        _ = await streamAnthropic(model: model, context: context,
            options: AnthropicOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
    case .openAICompletions:
        _ = await streamOpenAICompletions(model: model, context: context,
            options: OpenAICompletionsOptions(apiKey: "test", httpClient: client, cacheRetention: .short, maxRetries: 0)).result()
    case .openAIResponses:
        _ = await streamOpenAIResponses(model: model, context: context,
            options: OpenAIResponsesOptions(apiKey: "test", httpClient: client, cacheRetention: .short, maxRetries: 0)).result()
    case .mistralConversations:
        _ = await streamMistral(model: model, context: context,
            options: MistralOptions(apiKey: "test", httpClient: client, maxRetries: 0)).result()
    default: throw MidConversationCaptureError.missingPayload
    }
    let data = try #require(await client.payload())
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.openAICompletions, .openAIResponses, .mistralConversations])
func midConversationSystemReplayByCompat(_ api: Api) async throws {
    let context = midContext([midSystem("Later")])
    let collapsed = try await captureMidBody(api, compat: nil, context: context)
    let off = try await captureMidBody(api, compat: OpenAICompat(supportsMidConvoSystemMessages: false), context: context)
    let on = try await captureMidBody(api, compat: OpenAICompat(supportsMidConvoSystemMessages: true), context: context)
    let key = api == .openAIResponses ? "input" : "messages"
    let collapsedMessages = try #require(collapsed[key] as? [[String: Any]])
    let offMessages = try #require(off[key] as? [[String: Any]])
    let onMessages = try #require(on[key] as? [[String: Any]])
    #expect(try JSONSerialization.data(withJSONObject: collapsedMessages, options: [.sortedKeys]) ==
            JSONSerialization.data(withJSONObject: offMessages, options: [.sortedKeys]))
    #expect(onMessages.count == collapsedMessages.count + 1)
    #expect((onMessages.last?["content"] as? String)?.contains("Later") == true)
    #expect((collapsedMessages.first?["content"] as? String)?.contains("Base\n\nLater") == true)
}

@Test(.timeLimit(.minutes(1)), arguments: [Api.anthropicMessages, .openAICompletions, .openAIResponses, .mistralConversations])
func midConversationSectionUpdateFraming(_ api: Api) async throws {
    let update = Message.system(SystemMessage(content: .text("Later"),
        sections: SystemPromptSections([("rules", "New rule"), ("old", nil)]), timestamp: 1))
    let body = try await captureMidBody(api,
        compat: OpenAICompat(supportsMidConvoSystemMessages: true), context: midContext([update]))
    let messages = try #require(body[api == .openAIResponses ? "input" : "messages"] as? [[String: Any]])
    let text: String?
    if api == .anthropicMessages {
        text = (messages.last?["content"] as? [[String: Any]])?.first?["text"] as? String
    } else {
        text = messages.last?["content"] as? String
    }
    #expect(text == "Later\n\nUpdated system prompt section \"rules\":\n\nNew rule\n\nRemoved system prompt section \"old\".")
}

@Test(.timeLimit(.minutes(1))) func midConversationCompletionsToolPlacementAndFallback() async throws {
    let compat = OpenAICompat(supportsMidConvoSystemMessages: true, supportsMidConvoToolAdditions: true)
    let added = try await captureMidBody(.openAICompletions, compat: compat,
        context: midContext([midSystem("Later", added: [midTool("search")])]))
    let messages = try #require(added["messages"] as? [[String: Any]])
    #expect((added["tools"] as? [[String: Any]])?.count == 1)
    #expect(messages.contains { ($0["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any] != nil })
    let removed = try await captureMidBody(.openAICompletions, compat: compat,
        context: midContext([midSystem("", added: [midTool("search")]), midSystem("", removed: [ToolReference(name: "read")])]))
    #expect((removed["tools"] as? [[String: Any]])?.count == 1)
    let redefined = try await captureMidBody(.openAICompletions, compat: compat,
        context: midContext([midSystem("", added: [midTool("read", description: "new")])]))
    #expect((redefined["tools"] as? [[String: Any]])?.count == 1)
}

@Test(.timeLimit(.minutes(1))) func midConversationMistralUsesCurrentTools() async throws {
    let context = midContext([
        midSystem("", added: [midTool("search")]),
        midSystem("", removed: [ToolReference(name: "read")])
    ])
    let body = try await captureMidBody(.mistralConversations,
        compat: OpenAICompat(supportsMidConvoSystemMessages: true), context: context)
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "search")
    #expect(tools.count == 1)
}

@Test(.timeLimit(.minutes(1))) func midConversationResponsesToolPlacementAndFallback() async throws {
    let compat = OpenAICompat(supportsMidConvoSystemMessages: true, supportsAdditionalTools: true)
    let added = try await captureMidBody(.openAIResponses, compat: compat,
        context: midContext([midSystem("Later", added: [midTool("search")])]))
    let input = try #require(added["input"] as? [[String: Any]])
    #expect((added["tools"] as? [[String: Any]])?.count == 1)
    #expect(input.contains { $0["type"] as? String == "additional_tools" })
    let removed = try await captureMidBody(.openAIResponses, compat: compat,
        context: midContext([midSystem("", added: [midTool("search")]), midSystem("", removed: [ToolReference(name: "read")])]))
    let removedInput = try #require(removed["input"] as? [[String: Any]])
    #expect((removed["tools"] as? [[String: Any]])?.count == 1)
    #expect(!removedInput.contains { $0["type"] as? String == "additional_tools" })

    let search = try await captureMidBody(.openAIResponses,
        compat: OpenAICompat(supportsMidConvoSystemMessages: true, supportsToolSearch: true),
        context: midContext([midSystem("", added: [midTool("search")])]))
    let searched = try #require(search["input"] as? [[String: Any]])
    #expect(searched.contains { $0["type"] as? String == "tool_search_call" })
    #expect(searched.contains { $0["type"] as? String == "tool_search_output" })
}

@Test(.timeLimit(.minutes(1))) func midConversationAnthropicNativeToolBlocksAndFallback() async throws {
    let compat = OpenAICompat(supportsMidConvoSystemMessages: true, supportsMidConvoToolChanges: true)
    let context = midContext([
        midSystem("Later", added: [midTool("search")], removed: [ToolReference(name: "read")])
    ])
    let body = try await captureMidBody(.anthropicMessages, compat: compat, context: context)
    let tools = try #require(body["tools"] as? [[String: Any]])
    // b271b0a52: Later tools use inline definitions.
    #expect(tools.map { $0["name"] as? String } == ["read", "__pi_deferred_placeholder__"])
    #expect(tools[1]["defer_loading"] as? Bool == true)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let update = try #require(messages.last)
    #expect(update["role"] as? String == "system")
    let blocks = try #require(update["content"] as? [[String: Any]])
    #expect(blocks.map { $0["type"] as? String } == ["text", "tool_removal", "tool_addition"])
    #expect(blocks[0]["text"] as? String == "Later")
    #expect((blocks[1]["tool"] as? [String: Any])?["type"] as? String == "tool_reference")
    #expect((blocks[1]["tool"] as? [String: Any])?["name"] as? String == "read")
    let addition = try #require(blocks[2]["tool"] as? [String: Any])
    let definition = try #require(addition["definition"] as? [String: Any])
    // b271b0a52: Add the definition by value.
    #expect(addition["type"] as? String == "tool_definition")
    // b271b0a52: The inline definition identifies the new tool.
    #expect(definition["name"] as? String == "search")
    // b271b0a52: Cache control belongs to the addition block.
    #expect(blocks[2]["cache_control"] != nil)
    // b271b0a52: Inline definitions have no cache control.
    #expect(definition["cache_control"] == nil)
    // b271b0a52: Inline definitions are not deferred.
    #expect(definition["defer_loading"] == nil)

    let flagOff = try await captureMidBody(.anthropicMessages, compat: nil, context: context)
    let explicitOff = try await captureMidBody(.anthropicMessages,
        compat: OpenAICompat(supportsMidConvoSystemMessages: false, supportsMidConvoToolChanges: false), context: context)
    #expect(try JSONSerialization.data(withJSONObject: flagOff, options: [.sortedKeys]) ==
            JSONSerialization.data(withJSONObject: explicitOff, options: [.sortedKeys]))
    let offMessages = try #require(flagOff["messages"] as? [[String: Any]])
    #expect(offMessages.count == 1)
    #expect((flagOff["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["search"])

    let redefined = try await captureMidBody(.anthropicMessages, compat: compat,
        // b271b0a52: Replace the same name in one system message.
        context: midContext([midSystem("", added: [midTool("read", description: "new")], removed: [ToolReference(name: "read")])]))
    let redefinedTools = try #require(redefined["tools"] as? [[String: Any]])
    // b271b0a52: Keep the initial definition and placeholder.
    #expect(redefinedTools.map { $0["name"] as? String } == ["read", "__pi_deferred_placeholder__"])
    // b271b0a52: Preserve the cached initial description.
    #expect(redefinedTools[0]["description"] as? String == "read")
    let redefinedBlocks = try #require((redefined["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
    // b271b0a52: A redefinition needs one addition and no removal.
    #expect(redefinedBlocks.map { $0["type"] as? String } == ["tool_addition"])
    let replacement = try #require((redefinedBlocks[0]["tool"] as? [String: Any])?["definition"] as? [String: Any])
    // b271b0a52: Send the replacement description inline.
    #expect(replacement["description"] as? String == "new")
}

@Test(.timeLimit(.minutes(1))) func midConversationSystemWaitsForToolResultsOnWire() async throws {
    let model = midModel(.openAICompletions)
    let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: "call", name: "read", arguments: [:]))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let context = normalizeContext(Context(systemPrompt: "Base", messages: [
        .assistant(assistant), midSystem("After result"),
        .toolResult(ToolResultMessage(toolCallId: "call", toolName: "read", content: [.text(TextContent(text: "done"))], isError: false))
    ], tools: [midTool("read")]))
    let body = try await captureMidBody(.openAICompletions,
        compat: OpenAICompat(supportsMidConvoSystemMessages: true), context: context)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["system", "assistant", "tool", "system"])
    #expect(messages.last?["content"] as? String == "After result")
}
