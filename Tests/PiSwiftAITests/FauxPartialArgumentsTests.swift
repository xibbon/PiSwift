import Testing
@testable import PiSwiftAI

@Test("streams thinking, text, and partial tool call deltas")
func fauxStreamsGrowingPartialToolArguments() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let registration = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model],
        sourceId: "astr-faux", minTokenSize: 1, maxTokenSize: 3, tokensPerSecond: nil)
    let content = "a long value with \\ escapes and \"quotes\""
    let call = ToolCall(id: "tool-1", name: "echo",
                        arguments: ["text": AnyCodable(content), "count": AnyCodable(12)])
    let message = AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider,
        model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse)
    registration.setResponses([.message(message)])
    let stream = fauxStream(model: model, context: normalizeContext(Context(messages: [])),
                            registration: registration, simpleOptions: nil)
    var deltas = 0
    var lastText = ""
    for await event in stream {
        guard case .toolCallDelta(_, _, let partial) = event,
              case .toolCall(let growing) = partial.content.first else { continue }
        #expect(growing.argumentsJSON == nil)
        let text = growing.arguments["text"]?.value as? String ?? ""
        #expect(text.hasPrefix(lastText))
        #expect(content.hasPrefix(text))
        lastText = text
        deltas += 1
    }
    #expect(deltas > 1)
    #expect(lastText == content)
    guard case .toolCall(let finalCall) = (await stream.result()).content.first else {
        Issue.record("Missing final tool call")
        return
    }
    #expect(finalCall.arguments["text"] == AnyCodable(content))
}
