import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent

private func transcriptModel(_ id: String = "transcript") -> Model {
    Model(id: id, name: id, api: .openAIResponses, provider: "openai",
          baseUrl: "https://example.invalid", reasoning: true, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 10_000, maxTokens: 1_000)
}

private func transcriptResponse(_ model: Model, reason: StopReason = .stop,
                                content: [ContentBlock] = [.text(TextContent(text: "done"))]) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider,
                                   model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0,
                                                                 cacheWrite: 0, totalTokens: 0), stopReason: reason)
    stream.push(.done(reason: reason, message: message))
    stream.end(message)
    return stream
}

private func transcriptTool(_ name: String, description: String = "tool") -> AgentTool {
    AgentTool(label: name, name: name, description: description,
              parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "result"))])
    }
}

private func transcriptUser(_ text: String) -> AgentMessage { .user(UserMessage(content: .text(text))) }

@Test func initialTranscriptAndResetReplayCurrentSystemBaseline() throws {
    let first = transcriptTool("first")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "base", tools: [first])))
    #expect(agent.state.messages.count == 1)
    #expect(agent.state.systemPrompt == "base")
    #expect(getCurrentTools(agent.state.messages).map(\.name) == ["first"])

    agent.appendMessage(.system(SystemMessage(content: .text("patch"), toolsRemoved: [ToolReference(name: "first")])))
    agent.appendMessage(transcriptUser("discard"))
    try agent.reset()
    #expect(agent.state.messages.count == 1)
    #expect(agent.state.systemPrompt == "base\n\npatch")
    #expect(getCurrentTools(agent.state.messages).isEmpty)

    let explicit = SystemMessage(content: .text("explicit"))
    let seeded = Agent(AgentOptions(initialState: AgentState(systemPrompt: "ignored", tools: [first], messages: [.system(explicit)])))
    #expect(seeded.state.systemPrompt == "explicit")
    #expect(seeded.state.messages.count == 1)
}

@Test func continueRejectsSystemOnlyTranscript() async throws {
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "base")))
    do {
        try await agent.continue()
        Issue.record("Expected system-only continuation to fail")
    } catch {
        #expect(error.localizedDescription.contains("No messages") || error.localizedDescription.contains("no messages"))
    }
}

@Test(.timeLimit(.minutes(1))) func toolDeltaInsertsBeforeUserAndMergesLastPendingSystem() async {
    let tool = transcriptTool("lookup")
    let requested = LockedState<[[Message]]>([])
    let events = LockedState<[String]>([])
    let config = AgentLoopConfig(model: transcriptModel(), convertToLlm: { $0.compactMap(\.asMessage) })
    let streamFn: StreamFn = { model, context, _ in
        requested.withLock { $0.append(context.messages) }
        return transcriptResponse(model)
    }
    _ = await runAgentLoop(prompts: [transcriptUser("ask")], context: AgentContext(messages: [], tools: [tool]),
                           config: config, emit: { event in
        switch event {
        case .messageStart(let message): events.withLock { $0.append("start:\(message.role)") }
        case .messageEnd(let message): events.withLock { $0.append("end:\(message.role)") }
        default: break
        }
    }, streamFn: streamFn)
    let inserted = requested.withLock { $0[0] }
    #expect(inserted.map(\.role).prefix(2).elementsEqual(["system", "user"]))
    #expect(getCurrentTools(inserted).map(\.name) == ["lookup"])
    #expect(events.withLock { Array($0.prefix(4)) } == ["start:system", "end:system", "start:user", "end:user"])

    let baseline = AgentContext(messages: [.system(SystemMessage(content: .text("base")))], tools: [tool])
    let pending: [AgentMessage] = [
        .system(SystemMessage(content: .text("note"), toolsAdded: [transcriptTool("wrong").aiTool])),
        transcriptUser("ask")
    ]
    _ = await runAgentLoop(prompts: pending, context: baseline, config: config, emit: { _ in }, streamFn: streamFn)
    let merged = requested.withLock { $0[1] }
    #expect(merged.map(\.role) == ["system", "system", "user"])
    #expect(getCurrentTools(merged).map(\.name) == ["lookup"])
    if case .system(let update) = merged[1] {
        #expect(update.toolsAdded?.map(\.name) == ["lookup"])
        #expect(update.toolsRemoved == nil)
    } else { Issue.record("Expected pending system update") }
}

@Test(.timeLimit(.minutes(1))) func finishTurnRunsAfterResultsBeforeTurnEndAndEndKeepsQueues() async throws {
    let tool = transcriptTool("lookup")
    let order = LockedState<[String]>([])
    let calls = LockedState(0)
    let agent = Agent(AgentOptions(initialState: AgentState(tools: [tool]),
        streamFn: { model, _, _ in
            calls.withLock { $0 += 1 }
            return transcriptResponse(model, reason: .toolUse,
                                      content: [.toolCall(ToolCall(id: "call", name: "lookup", arguments: [:]))])
        },
        finishTurn: { turn, _ in
            #expect(turn.toolResults.count == 1)
            #expect(turn.context.messages.last?.role == "toolResult")
            order.withLock { $0.append("finish") }
            return .end
        },
        prepareNextTurn: { _ in
            order.withLock { $0.append("prepare") }
            return nil
        }
    ))
    let unsubscribe = agent.subscribe { event, _ in
        if case .turnEnd = event { order.withLock { $0.append("turnEnd") } }
    }
    defer { unsubscribe() }
    agent.followUp(transcriptUser("later"))
    try await agent.prompt("go")
    #expect(calls.withLock { $0 } == 1)
    #expect(order.withLock { $0 } == ["finish", "turnEnd"])
    #expect(agent.peekQueuedMessages().count == 1)
}

@Test(.timeLimit(.minutes(1))) func continuationUsesOneContextOnlyRequestAndPrepareRequestSeesPreparedMessages() async {
    let calls = LockedState(0)
    let preparations = LockedState<[String]>([])
    let eventRoles = LockedState<[String]>([])
    let config = AgentLoopConfig(model: transcriptModel(), convertToLlm: { $0.compactMap(\.asMessage) },
        finishTurn: { _, _ in calls.withLock { $0 } == 1 ? .continue : nil },
        prepareRequest: { request, _ in
            preparations.withLock { $0.append(request.context.messages.last?.role ?? "") }
            if preparations.withLock({ $0.count }) == 1 {
                return AgentRequestUpdate(model: transcriptModel("replacement"), thinkingLevel: .high)
            }
            return nil
        },
        prepareNextTurn: { _ in AgentLoopTurnUpdate(messages: [transcriptUser("prepared")]) }
    )
    let streamFn: StreamFn = { model, context, options in
        let count = calls.withLock { $0 += 1; return $0 }
        #expect(model.id == "replacement")
        #expect(options.reasoning == .high)
        if count == 2 { #expect(context.messages.last?.role == "user") }
        return transcriptResponse(model)
    }
    _ = await runAgentLoop(prompts: [transcriptUser("first")], context: AgentContext(messages: []),
                           config: config, emit: { event in
        if case .messageEnd(let message) = event { eventRoles.withLock { $0.append(message.role) } }
    }, streamFn: streamFn)
    #expect(calls.withLock { $0 } == 2)
    #expect(preparations.withLock { $0 } == ["user", "user"])
    #expect(eventRoles.withLock { $0 } == ["user", "assistant", "user", "assistant"])
}

@Test func peekQueuedMessagesSelectsSteeringWithoutDraining() {
    let agent = Agent(AgentOptions(steeringMode: .oneAtATime, followUpMode: .all))
    agent.followUp(transcriptUser("follow"))
    agent.followUp(transcriptUser("follow again"))
    agent.steer(transcriptUser("one"))
    agent.steer(transcriptUser("two"))
    #expect(agent.peekQueuedMessages().count == 1)
    if case .user(let user)? = agent.peekQueuedMessages().first,
       case .text(let text) = user.content {
        #expect(text == "one")
    } else { Issue.record("Expected first steering message") }
    #expect(agent.peekQueuedMessages().count == 1)
    #expect(agent.hasQueuedMessages())
    agent.clearSteeringQueue()
    #expect(agent.peekQueuedMessages().count == 2)
    #expect(agent.peekQueuedMessages().count == 2)
}

@Test(.timeLimit(.minutes(1))) func naturalToolResultRequestSatisfiesContinuation() async {
    let calls = LockedState(0)
    let tool = transcriptTool("lookup")
    let config = AgentLoopConfig(model: transcriptModel(), convertToLlm: { $0.compactMap(\.asMessage) },
        finishTurn: { _, _ in calls.withLock { $0 } == 1 ? .continue : nil })
    let streamFn: StreamFn = { model, _, _ in
        let count = calls.withLock { $0 += 1; return $0 }
        return count == 1
            ? transcriptResponse(model, reason: .toolUse,
                                 content: [.toolCall(ToolCall(id: "call", name: "lookup", arguments: [:]))])
            : transcriptResponse(model)
    }
    _ = await runAgentLoop(prompts: [transcriptUser("go")],
                           context: AgentContext(messages: [], tools: [tool]), config: config,
                           emit: { _ in }, streamFn: streamFn)
    #expect(calls.withLock { $0 } == 2)
}

@Test(.timeLimit(.minutes(1)), arguments: [StopReason.error, .aborted])
func finishTurnObservesHardExitBeforeTurnEnd(_ reason: StopReason) async {
    let order = LockedState<[String]>([])
    let config = AgentLoopConfig(model: transcriptModel(), convertToLlm: { $0.compactMap(\.asMessage) },
        finishTurn: { turn, _ in
            #expect(turn.message.stopReason == reason)
            #expect(turn.context.messages.last?.role == "assistant")
            order.withLock { $0.append("finish") }
            return .continue
        })
    _ = await runAgentLoop(prompts: [transcriptUser("go")], context: AgentContext(messages: []),
                           config: config, emit: { event in
        if case .turnEnd = event { order.withLock { $0.append("turnEnd") } }
    }, streamFn: { model, _, _ in transcriptResponse(model, reason: reason) })
    #expect(order.withLock { $0 } == ["finish", "turnEnd"])
}
