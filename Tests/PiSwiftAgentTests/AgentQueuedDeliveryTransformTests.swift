import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

private func queuedDeliveryAgent() -> Agent {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let previous = AssistantMessage(content: [.text(TextContent(text: "previous"))],
                                    api: model.api, provider: model.provider, model: model.id,
                                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                                    stopReason: .stop)
    return Agent(AgentOptions(initialState: AgentState(model: model, messages: [.assistant(previous)]),
                              streamFn: { model, _, _ in
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: AssistantMessage(
            content: [.text(TextContent(text: "ok"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop)))
        return stream
    }))
}

// Swift-only value-message hook for v1.5.2 C-SESS 4cf69332c delivery semantics.
@Test(arguments: [false, true]) func queuedTransformRunsOnDeliveryForSteeringAndFollowUp(_ followUp: Bool) async throws {
    let agent = queuedDeliveryAgent()
    let original = AgentMessage.user(UserMessage(content: .text("original")))
    let transformed = LockedState(0)
    agent.transformQueuedMessage = { message in
        transformed.withLock { $0 += 1 }
        guard case .user(var user) = message else { return message }
        user.content = .text("delivered")
        return .user(user)
    }
    if followUp { agent.followUp(original) } else { agent.steer(original) }
    guard case .user(let pending)? = agent.peekQueuedMessages().first,
          case .text(let text) = pending.content else { throw AgentError.emptyContext }
    #expect(text == "original")
    #expect(transformed.withLock { $0 } == 0)
    try await agent.continue()
    #expect(transformed.withLock { $0 } == 1)
    #expect(agent.state.messages.contains { message in
        if case .user(let user) = message, case .text(let text) = user.content { return text == "delivered" }
        return false
    })
}

@Test func queuedTransformDefaultPreservesMessage() async throws {
    let agent = queuedDeliveryAgent()
    agent.steer(.user(UserMessage(content: .text("original"))))
    try await agent.continue()
    #expect(agent.state.messages.contains { message in
        if case .user(let user) = message, case .text(let text) = user.content { return text == "original" }
        return false
    })
}
