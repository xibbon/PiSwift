import Testing
import PiSwiftAI
import PiSwiftAgent

private func identityTestStream(_ received: LockedState<[ClientIdentity?]>) -> StreamFn {
    { model, _, options in
        received.withLock { $0.append(options.identity) }
        let message = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }
}

@Test(.timeLimit(.minutes(1))) func agentUsesDefaultClientAttribution() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let agent = Agent(AgentOptions(streamFn: identityTestStream(received)))

    #expect(agent.identity == nil)
    try await agent.prompt("Hello")

    #expect(received.withLock { $0 } == [ClientIdentity(attribution: .value(PI_ATTRIBUTION))])
}

@Test(.timeLimit(.minutes(1))) func agentUsesConfiguredClientAttribution() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let identity = ClientIdentity(
        userAgent: .short,
        attribution: .value(ClientAttribution(name: "acme", url: "https://acme.example"))
    )
    let agent = Agent(AgentOptions(streamFn: identityTestStream(received), identity: identity))

    #expect(agent.identity == identity)
    try await agent.prompt("Hello")

    #expect(received.withLock { $0 } == [identity])
}

@Test(.timeLimit(.minutes(1))) func agentKeepsDefaultAttributionWithUserAgentOverride() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let agent = Agent(AgentOptions(
        streamFn: identityTestStream(received),
        identity: ClientIdentity(userAgent: .custom("example-client"))
    ))

    try await agent.prompt("Hello")

    #expect(received.withLock { $0 } == [ClientIdentity(
        userAgent: .custom("example-client"),
        attribution: .value(PI_ATTRIBUTION)
    )])
}

@Test(.timeLimit(.minutes(1))) func agentCanDisableClientAttribution() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let identity = ClientIdentity(attribution: .disabled)
    let agent = Agent(AgentOptions(streamFn: identityTestStream(received), identity: identity))

    try await agent.prompt("Hello")

    #expect(received.withLock { $0 } == [identity])
}

@Test(.timeLimit(.minutes(1))) func agentReadsChangedIdentityBetweenPrompts() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let agent = Agent(AgentOptions(streamFn: identityTestStream(received)))
    let custom = ClientIdentity(
        userAgent: .short,
        attribution: .value(ClientAttribution(name: "acme", url: "https://acme.example"))
    )

    try await agent.prompt("Hello")
    agent.identity = custom
    try await agent.prompt("Hello again")
    agent.identity = ClientIdentity(userAgent: .short)
    try await agent.prompt("Continue")
    agent.identity = nil
    try await agent.prompt("Continue again")

    #expect(received.withLock { $0 } == [
        ClientIdentity(attribution: .value(PI_ATTRIBUTION)),
        custom,
        ClientIdentity(userAgent: .short, attribution: .value(PI_ATTRIBUTION)),
        ClientIdentity(attribution: .value(PI_ATTRIBUTION)),
    ])
}

@Test(.timeLimit(.minutes(1))) func agentReadsChangedIdentityDuringOneRun() async throws {
    let received = LockedState<[ClientIdentity?]>([])
    let firstTurn = LockedState(true)
    let initial = ClientIdentity(userAgent: .short, attribution: .disabled)
    let agent = Agent(AgentOptions(streamFn: identityTestStream(received), identity: initial))
    let unsubscribe = agent.subscribe { [weak agent] event, _ in
        guard case .turnEnd = event else { return }
        let changeIdentity = firstTurn.withLock { first in
            defer { first = false }
            return first
        }
        if changeIdentity {
            agent?.identity = nil
            agent?.followUp(.user(UserMessage(content: .text("Continue"))))
        }
    }
    defer { unsubscribe() }

    try await agent.prompt("Hello")

    #expect(received.withLock { $0 } == [
        initial,
        ClientIdentity(attribution: .value(PI_ATTRIBUTION)),
    ])
}

@Test(.timeLimit(.minutes(1))) func agentLoopUsesConfiguredClientIdentity() async {
    let received = LockedState<[ClientIdentity?]>([])
    let identity = ClientIdentity(userAgent: .detailed, attribution: .disabled)
    let config = AgentLoopConfig(
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"),
        identity: identity,
        convertToLlm: { messages in messages.compactMap { $0.asMessage } }
    )

    _ = await runAgentLoop(
        prompts: [.user(UserMessage(content: .text("Hello")))],
        context: AgentContext(messages: [], tools: []),
        config: config,
        emit: { _ in },
        streamFn: identityTestStream(received)
    )

    #expect(received.withLock { $0 } == [identity])
}
