import Testing
import PiSwiftAI
import PiSwiftAgent

// v0.99.0 packages/agent/test/agent.test.ts: "forwards provider stream event observers through AgentOptions".
@Test func agentForwardsProviderStreamEventObserver() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let observed = LockedState<[(AnyCodable, String)]>([])
    let streamFn: StreamFn = { model, _, options in
        let stream = AssistantMessageEventStream()
        Task {
            try? await options.onProviderStreamEvent?(AnyCodable(["request_cost": 0.01]), model)
            let message = a3AssistantMessage(model: model, stopReason: .stop)
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        return stream
    }

    let agent = Agent(AgentOptions(
        initialState: AgentState(model: model),
        streamFn: streamFn,
        onProviderStreamEvent: { event, model in
            observed.withLock { $0.append((event, model.id)) }
        }
    ))

    try await agent.prompt("hello")

    let events = observed.withLock { $0 }
    #expect(events.count == 1)
    #expect(events.first?.0 == AnyCodable(["request_cost": 0.01]))
    #expect(events.first?.1 == model.id)
}

private enum A3TerminalStyle: CaseIterable, Sendable {
    case done
    case error
    case endWithoutTerminalEvent
}

// v0.99.0 packages/agent/src/agent-loop.ts records the requested level from response.result().
@Test func agentLoopRecordsRequestedThinkingLevelForEveryTerminalPath() async {
    let requestedLevels: [(ReasoningEffort?, ModelThinkingLevel)] = [(.high, .high), (nil, .off)]
    let scenarios = requestedLevels.flatMap { request in
        A3TerminalStyle.allCases.map { (request.0, request.1, $0) }
    }
    for (reasoning, expectedLevel, style) in scenarios {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let context = testAgentContext(systemPrompt: "", messages: [], tools: [])
        let config = AgentLoopConfig(
            model: model,
            reasoning: reasoning,
            convertToLlm: { $0.compactMap(\.asMessage) }
        )
        let streamFn: StreamFn = { _, _, _ in
            let stream = AssistantMessageEventStream()
            let stopReason: StopReason = style == .error ? .error : .stop
            let message = a3AssistantMessage(model: model, stopReason: stopReason)
            switch style {
            case .done:
                stream.push(.done(reason: .stop, message: message))
            case .error:
                stream.push(.error(reason: .error, error: message))
            case .endWithoutTerminalEvent:
                break
            }
            stream.end(message)
            return stream
        }

        let stream = agentLoop(
            prompts: [.user(UserMessage(content: .text("hello")))],
            context: context,
            config: config,
            streamFn: streamFn
        )
        let ended = LockedState<[ModelThinkingLevel?]>([])
        for await event in stream {
            if case .messageEnd(.assistant(let message)) = event {
                ended.withLock { $0.append(message.thinkingLevel) }
            }
        }

        let messages = await stream.result()
        guard case .some(.assistant(let finalMessage)) = messages.last else {
            Issue.record("Expected an assistant message for \(style)")
            continue
        }
        #expect(finalMessage.thinkingLevel == expectedLevel)
        #expect(ended.withLock { $0 } == [expectedLevel])
    }
}

private func a3AssistantMessage(model: Model, stopReason: StopReason) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: "ok"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason
    )
}
