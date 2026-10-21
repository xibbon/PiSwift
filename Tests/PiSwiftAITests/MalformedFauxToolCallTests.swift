import Testing
@testable import PiSwiftAI

@Test(.timeLimit(.minutes(1))) func fauxFinalToolCallKeepsArgumentError() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let registration = FauxProviderRegistration(api: model.api, provider: model.provider, models: [model],
        sourceId: "malformed-faux", minTokenSize: 1, maxTokenSize: 3, tokensPerSecond: nil)
    var call = ToolCall(id: "invalid-call", name: "optional", arguments: [:])
    call.finalizeArguments(from: #"{"z":1,"a":"#)
    let diagnostic = try #require(call.argumentsError)
    let message = AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    registration.setResponses([.message(message)])
    let stream = fauxStream(model: model, context: normalizeContext(Context(messages: [])),
        registration: registration, simpleOptions: nil)
    var endCount = 0
    for await event in stream {
        if case .toolCallEnd(_, let restored, let partial) = event {
            endCount += 1
            #expect(restored.argumentsError == diagnostic)
            #expect(restored.arguments.isEmpty)
            #expect(restored.argumentsJSON == nil)
            guard case .toolCall(let copied) = partial.content.first else {
                Issue.record("The partial message has no tool call")
                continue
            }
            #expect(copied.argumentsError == diagnostic)
            #expect(copied.argumentsJSON == nil)
        }
    }
    #expect(endCount == 1)
    let result = await stream.result()
    guard case .toolCall(let restored) = result.content.first else {
        Issue.record("The final message has no tool call")
        return
    }
    #expect(restored.argumentsError == diagnostic)
    #expect(restored.arguments.isEmpty)
    #expect(restored.argumentsJSON == nil)
}
