import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test(.timeLimit(.minutes(1)))
func agentForwardsContinuationControl() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let observed = LockedState<[Bool?]>([])
    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: { model, _, options in
            observed.withLock { $0.append(options.disableContinuation) }
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(TextContent(text: "answer"))],
                api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        },
        disableContinuation: true
    ))
    try await agent.prompt("hello")
    agent.disableContinuation = false
    try await agent.prompt("again")
    #expect(observed.withLock { $0 } == [true, false])
}

@Test(arguments: [nil, false, true] as [Bool?])
func proxyPreservesContinuationControl(_ disabled: Bool?) throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let context = normalizeContext(Context(messages: [.user(UserMessage(content: .text("hello")))]))
    let data = try encodeProxyRequestPayload(model: model, context: context,
        options: ProxyStreamOptions(authToken: "test", proxyUrl: "https://example.invalid", disableContinuation: disabled))
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let options = try #require(body["options"] as? [String: Any])
    #expect(options["disableContinuation"] as? Bool == disabled)
}
