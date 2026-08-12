import Testing
import PiSwiftAI
import PiSwiftAgent

@Test func defaultState() {
    let agent = Agent()

    #expect(agent.state.systemPrompt == "")
    #expect(agent.state.thinkingLevel == .off)
    #expect(agent.state.tools.isEmpty)
    #expect(agent.state.messages.isEmpty)
    #expect(!agent.state.isStreaming)
    #expect(agent.state.streamingMessage == nil)
    #expect(agent.state.pendingToolCalls.isEmpty)
    #expect(agent.state.errorMessage == nil)
}

@Test func customInitialState() {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let customState = AgentState(systemPrompt: "You are a helpful assistant.", model: model, thinkingLevel: .low)
    let agent = Agent(AgentOptions(initialState: customState))

    #expect(agent.state.systemPrompt == "You are a helpful assistant.")
    #expect(agent.state.model.id == model.id)
    #expect(agent.state.thinkingLevel == .low)
}

@Test func subscribe() {
    let agent = Agent()
    let eventCount = LockedState(0)
    let unsubscribe = agent.subscribe { _, _ in
        eventCount.withLock { $0 += 1 }
    }

    #expect(eventCount.withLock { $0 } == 0)
    agent.systemPrompt = "Test prompt"
    #expect(eventCount.withLock { $0 } == 0)
    #expect(agent.state.systemPrompt == "Test prompt")

    unsubscribe()
    agent.systemPrompt = "Another prompt"
    #expect(eventCount.withLock { $0 } == 0)
}

@Test func stateMutators() {
    let agent = Agent()
    agent.systemPrompt = "Custom prompt"
    #expect(agent.state.systemPrompt == "Custom prompt")

    let newModel = getModel(provider: .openai, modelId: "gpt-5-mini")
    agent.model = newModel
    #expect(agent.state.model.id == newModel.id)

    agent.thinkingLevel = .high
    #expect(agent.state.thinkingLevel == .high)

    let tool = AgentTool(
        label: "Test",
        name: "test",
        description: "test tool",
        parameters: [:]
    ) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))])
    }
    agent.tools = [tool]
    #expect(agent.state.tools.count == 1)
    #expect(agent.state.tools.first?.name == "test")

    let userMessage = AgentMessage.user(UserMessage(content: .text("Hello")))
    agent.messages = [userMessage]
    #expect(agent.state.messages.count == 1)
    #expect(agent.state.messages.first?.role == "user")

    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "Hi"))],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
    agent.appendMessage(.assistant(assistant))
    #expect(agent.state.messages.count == 2)
    #expect(agent.state.messages.last?.role == "assistant")

    agent.clearMessages()
    #expect(agent.state.messages.isEmpty)
}

@Test func steerAndFollowUp() {
    let agent = Agent()
    let steerMessage = AgentMessage.user(UserMessage(content: .text("Steer message")))
    let followUpMessage = AgentMessage.user(UserMessage(content: .text("Follow-up message")))
    agent.steer(steerMessage)
    agent.followUp(followUpMessage)
    #expect(!agent.state.messages.contains { $0.role == "user" && $0.timestamp == steerMessage.timestamp })
    #expect(!agent.state.messages.contains { $0.role == "user" && $0.timestamp == followUpMessage.timestamp })
}

private func makeAssistant(stopReason: StopReason) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: "partial"))],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason
    )
}

@Test func dropTrailingErroredAssistantRemovesErroredTurn() {
    let agent = Agent()
    agent.messages = [
        .user(UserMessage(content: .text("Hello"))),
        .assistant(makeAssistant(stopReason: .error)),
    ]

    #expect(agent.dropTrailingErroredAssistant() == true)
    #expect(agent.state.messages.count == 1)
    #expect(agent.state.messages.last?.role == "user")
}

@Test func dropTrailingErroredAssistantLeavesSuccessfulTurn() {
    let agent = Agent()
    agent.messages = [
        .user(UserMessage(content: .text("Hello"))),
        .assistant(makeAssistant(stopReason: .stop)),
    ]

    #expect(agent.dropTrailingErroredAssistant() == false)
    #expect(agent.state.messages.count == 2)
    #expect(agent.state.messages.last?.role == "assistant")
}

@Test func dropTrailingErroredAssistantIgnoresTrailingUserMessage() {
    let agent = Agent()
    agent.messages = [.user(UserMessage(content: .text("Hello")))]

    #expect(agent.dropTrailingErroredAssistant() == false)
    #expect(agent.state.messages.count == 1)
}

@Test func dropTrailingErroredAssistantOnEmptyHistoryIsNoOp() {
    let agent = Agent()
    #expect(agent.dropTrailingErroredAssistant() == false)
    #expect(agent.state.messages.isEmpty)
}

@Test func hasQueuedMessages() {
    let agent = Agent()
    #expect(agent.hasQueuedMessages() == false)
    agent.steer(.user(UserMessage(content: .text("Steer"))))
    #expect(agent.hasQueuedMessages())
    agent.clearSteeringQueue()
    #expect(agent.hasQueuedMessages() == false)
    agent.followUp(.user(UserMessage(content: .text("Follow"))))
    #expect(agent.hasQueuedMessages())
    agent.clearAllQueues()
    #expect(agent.hasQueuedMessages() == false)
}

@Test func promptWhileStreamingThrows() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))
    let task = Task { try await agent.prompt("Hello") }

    var attempts = 0
    while !agent.state.isStreaming && attempts < 50 {
        attempts += 1
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(agent.state.isStreaming)

    do {
        try await agent.prompt("Second")
        #expect(Bool(false), "Expected already streaming error")
    } catch {
        #expect(
            error.localizedDescription ==
                "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
        )
    }

    _ = try await task.value
}

@Test func abort() {
    let agent = Agent()
    agent.abort()
}

@Test func forwardsSessionIdToStreamOptions() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedSessionId = LockedState<String?>(nil)
    let streamFn: StreamFn = { model, _, options in
        receivedSessionId.withLock { $0 = options.sessionId }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn, sessionId: "session-abc"))
    try await agent.prompt("Hello")
    #expect(receivedSessionId.withLock { $0 } == "session-abc")

    agent.sessionId = "session-def"
    try await agent.prompt("Hello again")
    #expect(receivedSessionId.withLock { $0 } == "session-def")
}

@Test func forwardsTransportToStreamOptions() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedTransport = LockedState<Transport?>(nil)
    let streamFn: StreamFn = { model, _, options in
        receivedTransport.withLock { $0 = options.transport }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: streamFn,
        transport: .websocket
    ))

    try await agent.prompt("Hello")
    #expect(receivedTransport.withLock { $0 } == .websocket)

    agent.transport = .auto
    try await agent.prompt("Hello again")
    #expect(receivedTransport.withLock { $0 } == .auto)
}

@Test func forwardsTimeoutsToStreamOptions() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedTimeoutMs = LockedState<Int?>(nil)
    let receivedWebSocketConnectTimeoutMs = LockedState<Int?>(nil)
    let streamFn: StreamFn = { model, _, options in
        receivedTimeoutMs.withLock { $0 = options.timeoutMs }
        receivedWebSocketConnectTimeoutMs.withLock { $0 = options.websocketConnectTimeoutMs }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: streamFn,
        timeoutMs: 12_345,
        websocketConnectTimeoutMs: 6_789
    ))

    try await agent.prompt("Hello")
    #expect(receivedTimeoutMs.withLock { $0 } == 12_345)
    #expect(receivedWebSocketConnectTimeoutMs.withLock { $0 } == 6_789)

    agent.timeoutMs = 22_000
    agent.websocketConnectTimeoutMs = nil
    try await agent.prompt("Hello again")
    #expect(receivedTimeoutMs.withLock { $0 } == 22_000)
    #expect(receivedWebSocketConnectTimeoutMs.withLock { $0 } == nil)
}

@Test func continueWhileStreamingThrows() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))
    let task = Task { try await agent.prompt("Hello") }

    var attempts = 0
    while !agent.state.isStreaming && attempts < 50 {
        attempts += 1
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(agent.state.isStreaming)

    do {
        try await agent.continue()
        #expect(Bool(false), "Expected already streaming error")
    } catch {
        #expect(error.localizedDescription == "Agent is already processing. Wait for completion before continuing.")
    }

    _ = try await task.value
}

@Test func continueUsesQueuedMessagesWhenLastIsAssistant() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let assistant = AssistantMessage(
        content: [.text(TextContent(text: "previous"))],
        api: .openAICompletions,
        provider: "openai",
        model: "gpt-4o-mini",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model, messages: [.assistant(assistant)]),
        streamFn: streamFn
    ))

    agent.steer(.user(UserMessage(content: .text("queued"))))
    try await agent.continue()

    #expect(agent.state.messages.contains { msg in
        if case .user(let user) = msg, case .text(let text) = user.content {
            return text == "queued"
        }
        return false
    })
    #expect(agent.hasQueuedMessages() == false)
}

@Test func thinkingBudgetsGetterSetter() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedBudgets = LockedState<ThinkingBudgets?>(nil)
    let streamFn: StreamFn = { model, _, options in
        receivedBudgets.withLock { $0 = options.thinkingBudgets }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let customBudgets: ThinkingBudgets = [.low: 1024, .medium: 4096]
    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn, thinkingBudgets: customBudgets))

    #expect(agent.thinkingBudgets?[.low] == 1024)
    #expect(agent.thinkingBudgets?[.medium] == 4096)

    try await agent.prompt("Hello")
    #expect(receivedBudgets.withLock { $0?[.low] } == 1024)

    // Test setter
    let newBudgets: ThinkingBudgets = [.high: 8192]
    agent.thinkingBudgets = newBudgets
    #expect(agent.thinkingBudgets?[.high] == 8192)

    try await agent.prompt("Hello again")
    #expect(receivedBudgets.withLock { $0?[.high] } == 8192)
}

@Test func getApiKeyCallback() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedApiKey = LockedState<String?>(nil)
    let providerRequested = LockedState<String?>(nil)

    let streamFn: StreamFn = { model, _, options in
        receivedApiKey.withLock { $0 = options.apiKey }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: streamFn,
        getApiKey: { provider in
            providerRequested.withLock { $0 = provider }
            return "dynamic-api-key-\(provider)"
        }
    ))

    try await agent.prompt("Hello")

    #expect(providerRequested.withLock { $0 } == "openai")
    #expect(receivedApiKey.withLock { $0 } == "dynamic-api-key-openai")
}

@Test func getModelAuthCallbackOverridesProviderAuth() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let receivedApiKey = LockedState<String?>(nil)
    let receivedHeaders = LockedState<ProviderHeaders?>(nil)
    let receivedBaseUrl = LockedState<String?>(nil)

    let streamFn: StreamFn = { model, _, options in
        receivedApiKey.withLock { $0 = options.apiKey }
        receivedHeaders.withLock { $0 = options.headers }
        receivedBaseUrl.withLock { $0 = model.baseUrl }
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "ok"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: streamFn,
        getApiKey: { provider in "provider-api-key-\(provider)" },
        getModelAuth: { _ in
            AgentModelAuth(
                apiKey: "model-api-key",
                headers: ["X-Model": "model"],
                baseUrl: "https://api.example.invalid/custom"
            )
        },
        headers: ["X-Base": "base"]
    ))

    try await agent.prompt("Hello")

    #expect(receivedApiKey.withLock { $0 } == "model-api-key")
    #expect(receivedHeaders.withLock { $0?["X-Base"] } == "base")
    #expect(receivedHeaders.withLock { $0?["X-Model"] } == "model")
    #expect(receivedBaseUrl.withLock { $0 } == "https://api.example.invalid/custom")
}

/// v0.63.2: Agent.signal exposes the active turn's cancellation token so subscribers
/// and extensions can forward cancellation into nested async work.
@Test func agentSignalExposesTurnCancellationToken() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let signalDuringTurn = LockedState<CancellationToken?>(nil)

    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))

    // Before any turn runs, signal is nil.
    #expect(agent.signal == nil)

    _ = agent.subscribe { event, signal in
        if case .turnStart = event {
            signalDuringTurn.withLock { $0 = signal }
        }
    }

    try await agent.prompt("Hello")

    // The subscriber observed a non-nil token during the turn.
    #expect(signalDuringTurn.withLock { $0 } != nil)

    // After the turn settles, signal is nil again.
    #expect(agent.signal == nil)
}

/// v0.65.0: subscribe listeners are awaited; agent.prompt() does not return until every
/// agent_end listener finishes, and state.isStreaming stays true until that settlement.
@Test func subscribeListenersAreAwaitedBeforePromptReturns() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")

    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [.text(TextContent(text: "hi"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: streamFn))

    let agentEndProcessed = LockedState(false)
    let isStreamingDuringAgentEnd = LockedState(false)

    _ = agent.subscribe { event, _ in
        if case .agentEnd = event {
            // isStreaming must still be true while this handler runs.
            isStreamingDuringAgentEnd.withLock { $0 = agent.state.isStreaming }
            // Simulate slow async work in the listener.
            try? await Task.sleep(nanoseconds: 50_000_000)
            agentEndProcessed.withLock { $0 = true }
        }
    }

    try await agent.prompt("Hello")

    // prompt() returned only after the listener finished its async work.
    #expect(agentEndProcessed.withLock { $0 })
    // While the listener was running, isStreaming was still true.
    #expect(isStreamingDuringAgentEnd.withLock { $0 })
    // After settlement, isStreaming is false.
    #expect(!agent.state.isStreaming)
}
