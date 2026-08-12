import Testing
import PiSwiftAI
import PiSwiftAgent

private func v0841Model() -> Model {
    Model(
        id: "v0841-mock",
        name: "v0841-mock",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://example.invalid",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8_192,
        maxTokens: 2_048
    )
}

private func v0841Usage(input: Int = 0, output: Int = 0, totalTokens: Int = 0) -> Usage {
    Usage(input: input, output: output, cacheRead: 0, cacheWrite: 0, totalTokens: totalTokens)
}

private func v0841Assistant(
    _ content: [ContentBlock],
    stopReason: StopReason,
    usage: Usage = v0841Usage()
) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAIResponses,
        provider: "openai",
        model: "v0841-mock",
        usage: usage,
        stopReason: stopReason
    )
}

private func v0841Stream(_ message: AssistantMessage) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

private func blockedToolCallRun(terminate: Bool) async -> (calls: Int, result: ToolResultMessage?) {
    let tool = AgentTool(
        label: "Blocked",
        name: "blocked",
        description: "Must not run",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        Issue.record("Blocked tool executed")
        return AgentToolResult(content: [.text(TextContent(text: "unexpected"))])
    }
    let config = AgentLoopConfig(
        model: v0841Model(),
        toolExecution: .sequential,
        beforeToolCall: { _, _ in
            BeforeToolCallResult(block: true, reason: "blocked by policy", terminate: terminate)
        },
        convertToLlm: { $0.compactMap(\.asMessage) }
    )
    let callCount = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let call = callCount.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 {
            return v0841Stream(v0841Assistant(
                [.toolCall(ToolCall(id: "blocked-1", name: "blocked", arguments: [:]))],
                stopReason: .toolUse
            ))
        }
        return v0841Stream(v0841Assistant(
            [.text(TextContent(text: "follow-up"))],
            stopReason: .stop
        ))
    }

    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("start")))],
        context: AgentContext(systemPrompt: "", messages: [], tools: [tool]),
        config: config,
        streamFn: streamFn
    )
    var result: ToolResultMessage?
    for await event in stream {
        if case .messageEnd(let message) = event, case .toolResult(let toolResult) = message {
            result = toolResult
        }
    }
    return (callCount.withLock { $0 }, result)
}

@Test func blockedToolTerminateControlsBatchEarlyTermination() async {
    let terminating = await blockedToolCallRun(terminate: true)
    #expect(terminating.calls == 1)
    #expect(terminating.result?.isError == true)

    let continuing = await blockedToolCallRun(terminate: false)
    #expect(continuing.calls == 2)
    #expect(continuing.result?.isError == true)
}

@Test func toolUsageIsEmittedAndExcludedFromAssistantUsageAccounting() async {
    let executedUsage = v0841Usage(input: 40, output: 2, totalTokens: 42)
    let finalizedUsage = v0841Usage(input: 90, output: 9, totalTokens: 99)
    let tool = AgentTool(
        label: "Usage",
        name: "usage",
        description: "Reports tool usage",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        AgentToolResult(
            content: [.text(TextContent(text: "tool output"))],
            usage: executedUsage
        )
    }
    let config = AgentLoopConfig(
        model: v0841Model(),
        afterToolCall: { _, _ in AfterToolCallResult(usage: finalizedUsage) },
        convertToLlm: { $0.compactMap(\.asMessage) }
    )
    let secondCallToolUsage = LockedState<Usage?>(nil)
    let callCount = LockedState(0)
    let streamFn: StreamFn = { _, context, _ in
        let call = callCount.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 {
            return v0841Stream(v0841Assistant(
                [.toolCall(ToolCall(id: "usage-1", name: "usage", arguments: [:]))],
                stopReason: .toolUse,
                usage: v0841Usage(input: 2, output: 3, totalTokens: 5)
            ))
        }
        for message in context.messages {
            if case .toolResult(let result) = message {
                secondCallToolUsage.withLock { $0 = result.usage }
            }
        }
        return v0841Stream(v0841Assistant(
            [.text(TextContent(text: "done"))],
            stopReason: .stop,
            usage: v0841Usage(input: 5, output: 8, totalTokens: 13)
        ))
    }

    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("start")))],
        context: AgentContext(systemPrompt: "", messages: [], tools: [tool]),
        config: config,
        streamFn: streamFn
    )
    for await _ in stream {}
    let messages = await stream.result()

    let emittedUsage = messages.compactMap { message -> Usage? in
        guard case .toolResult(let result) = message else { return nil }
        return result.usage
    }.first
    #expect(emittedUsage?.totalTokens == 99)
    #expect(secondCallToolUsage.withLock { $0?.totalTokens } == 99)

    let assistantTotal = messages.reduce(into: 0) { total, message in
        guard case .assistant(let assistant) = message else { return }
        total += assistant.usage.totalTokens
    }
    #expect(assistantTotal == 18)
}

@Test func agentOptionStopsAfterTurnAndLeavesFollowUpQueued() async throws {
    let callCount = LockedState(0)
    let sawExpectedContext = LockedState(false)
    let sawSignal = LockedState(false)
    let streamFn: StreamFn = { _, _, _ in
        callCount.withLock { $0 += 1 }
        return v0841Stream(v0841Assistant(
            [.text(TextContent(text: "complete"))],
            stopReason: .stop
        ))
    }
    let agent = Agent(AgentOptions(
        initialState: AgentState(model: v0841Model()),
        streamFn: streamFn,
        shouldStopAfterTurn: { context, signal in
            sawExpectedContext.withLock {
                $0 = context.message.stopReason == .stop
                    && context.toolResults.isEmpty
                    && context.context.messages.count == 2
                    && context.newMessages.count == 2
            }
            sawSignal.withLock { $0 = signal != nil }
            return true
        }
    ))
    agent.followUp(.user(UserMessage(content: .text("queued follow-up"))))

    try await agent.prompt("start")

    #expect(callCount.withLock { $0 } == 1)
    #expect(sawExpectedContext.withLock { $0 })
    #expect(sawSignal.withLock { $0 })
    #expect(agent.hasQueuedMessages())
    #expect(agent.state.messages.count == 2)
}

@Test func resetRejectsActiveRunThenSucceedsWhenIdle() async throws {
    let release = LockedState<CheckedContinuation<Void, Never>?>(nil)
    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            await withCheckedContinuation { continuation in
                release.withLock { $0 = continuation }
            }
            let message = v0841Assistant(
                [.text(TextContent(text: "done"))],
                stopReason: .stop
            )
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }
    let agent = Agent(AgentOptions(
        initialState: AgentState(model: v0841Model()),
        streamFn: streamFn
    ))
    let promptTask = Task { try await agent.prompt("start") }

    while !agent.state.isStreaming {
        await Task.yield()
    }

    do {
        try agent.reset()
        Issue.record("reset() succeeded during an active run")
    } catch {
        #expect(error.localizedDescription == "Agent is already processing. Wait for completion before resetting.")
    }

    while release.withLock({ $0 == nil }) {
        await Task.yield()
    }
    let continuation = release.withLock { value -> CheckedContinuation<Void, Never>? in
        defer { value = nil }
        return value
    }
    continuation?.resume()
    try await promptTask.value

    try agent.reset()
    #expect(agent.state.messages.isEmpty)
    #expect(!agent.state.isStreaming)
}
