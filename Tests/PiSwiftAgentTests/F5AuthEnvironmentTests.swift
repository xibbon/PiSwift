import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test(.timeLimit(.minutes(1))) func f5AgentUsesModelAuthOnceAndForwardsEnvironment() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let received = LockedState<SimpleStreamOptions?>(nil)
    let fallbackCalls = LockedState(0)
    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: { model, _, options in
        received.withLock { $0 = options }
        let stream = AssistantMessageEventStream()
        let message = AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }, getApiKey: { _ in
        fallbackCalls.withLock { $0 += 1 }
        return "fallback"
    }, getModelAuth: { _ in AgentModelAuth(apiKey: "stored", headers: ["X-Account": "scoped"], env: ["ACCOUNT": "scoped"]) }))
    try await agent.prompt("Hi")
    #expect(fallbackCalls.withLock { $0 } == 0)
    #expect(received.withLock { $0?.apiKey } == "stored")
    #expect(received.withLock { $0?.env } == ["ACCOUNT": "scoped"])
}
