import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent

@Test func agentLoopEmitsEvents() async {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let userPrompt = createUserMessage("Hello")

    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Hi there!"))])
        return makeStream(done: message)
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)

    for await event in stream {
        events.append(event)
    }

    let messages = await stream.result()
    #expect(messages.count == 2)
    #expect(messages.first?.role == "user")
    #expect(messages.last?.role == "assistant")

    let eventTypes = events.map { event in
        switch event {
        case .agentStart: return "agent_start"
        case .turnStart: return "turn_start"
        case .messageStart: return "message_start"
        case .messageEnd: return "message_end"
        case .turnEnd: return "turn_end"
        case .agentEnd: return "agent_end"
        case .messageUpdate: return "message_update"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        }
    }

    #expect(eventTypes.contains("agent_start"))
    #expect(eventTypes.contains("turn_start"))
    #expect(eventTypes.contains("message_start"))
    #expect(eventTypes.contains("message_end"))
    #expect(eventTypes.contains("turn_end"))
    #expect(eventTypes.contains("agent_end"))
}

@Test func customMessagesWithConverter() async {
    let notification = AgentMessage.custom(AgentCustomMessage(role: "notification", payload: AnyCodable("note")))

    let context = AgentContext(systemPrompt: "You are helpful.", messages: [notification], tools: [])
    let userPrompt = createUserMessage("Hello")

    let converted = LockedState<[Message]>([])
    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: { messages in
            let result = messages.compactMap { message -> Message? in
                if case .custom(let custom) = message, custom.role == "notification" {
                    return nil
                }
                return message.asMessage
            }
            converted.withLock { $0 = result }
            return result
        }
    )

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    #expect(converted.withLock { $0.count } == 1)
    #expect(converted.withLock { $0.first?.role } == "user")
}

@Test func transformContextBeforeConvert() async {
    let context = AgentContext(
        systemPrompt: "You are helpful.",
        messages: [
            createUserMessage("old message 1"),
            AgentMessage.assistant(createAssistantMessage(content: [.text(TextContent(text: "old response 1"))])),
            createUserMessage("old message 2"),
            AgentMessage.assistant(createAssistantMessage(content: [.text(TextContent(text: "old response 2"))]))
        ],
        tools: []
    )

    let userPrompt = createUserMessage("new message")

    let transformed = LockedState<[AgentMessage]>([])
    let converted = LockedState<[Message]>([])

    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: { messages in
            let result = messages.compactMap { message -> Message? in
                message.asMessage
            }
            converted.withLock { $0 = result }
            return result
        },
        transformContext: { messages, _ in
            let result = Array(messages.suffix(2))
            transformed.withLock { $0 = result }
            return result
        }
    )

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    #expect(transformed.withLock { $0.count } == 2)
    #expect(converted.withLock { $0.count } == 2)
}

@Test func toolCallsAndResults() async {
    let executed = LockedState<[String]>([])
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        executed.withLock { $0.append(value) }
        return AgentToolResult(content: [.text(TextContent(text: "echoed: \(value)"))], details: AnyCodable(["value": value]))
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("echo something")
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        let index = callIndex.withLock { $0 }
        if index == 0 {
            let toolCall = ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable("hello")])
            let message = createAssistantMessage(content: [.toolCall(toolCall)], stopReason: .toolUse)
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
        } else {
            let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        callIndex.withLock { $0 += 1 }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    #expect(executed.withLock { $0 } == ["hello"])

    let toolStart = events.first { if case .toolExecutionStart = $0 { return true } else { return false } }
    let toolEnd = events.first { if case .toolExecutionEnd = $0 { return true } else { return false } }
    #expect(toolStart != nil)
    #expect(toolEnd != nil)

    if case .toolExecutionEnd(_, _, _, let isError) = toolEnd {
        #expect(!isError)
    }
}

/// v0.61.1 behavior: steering messages are delivered AFTER all tool calls
/// complete in the current turn (they no longer skip remaining tools).
@Test func steeringMessagesDeliveredAfterAllToolCalls() async {
    let executed = LockedState<[String]>([])
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        executed.withLock { $0.append(value) }
        return AgentToolResult(content: [.text(TextContent(text: "ok:\(value)"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let steeringUserMessage = createUserMessage("interrupt")

    let steeringDelivered = LockedState(false)
    let callIndex = LockedState(0)
    let sawInterruptInContext = LockedState(false)

    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: identityConverter,
        getSteeringMessages: {
            // Deliver steering after first turn's tools complete
            let executedCount = executed.withLock { $0.count }
            let shouldDeliver = steeringDelivered.withLock { delivered in
                if executedCount >= 1 && !delivered {
                    delivered = true
                    return true
                }
                return false
            }
            if shouldDeliver {
                return [steeringUserMessage]
            }
            return []
        }
    )

    let streamFn: StreamFn = { _, ctx, _ in
        let index = callIndex.withLock { $0 }
        if index == 1 {
            let sawInterrupt = ctx.messages.contains { message in
                if case .user(let user) = message, case .text(let text) = user.content {
                    return text == "interrupt"
                }
                return false
            }
            sawInterruptInContext.withLock { $0 = sawInterrupt }
        }

        let stream = AssistantMessageEventStream()
        if index == 0 {
            let first = ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable("first")])
            let second = ToolCall(id: "tool-2", name: "echo", arguments: ["value": AnyCodable("second")])
            let message = createAssistantMessage(content: [.toolCall(first), .toolCall(second)], stopReason: .toolUse)
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
        } else {
            let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        callIndex.withLock { $0 += 1 }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    // Both tools should execute (steering no longer skips remaining tools).
    // Parallel execution order is non-deterministic, so check membership instead of order.
    #expect(executed.withLock { Set($0) } == ["first", "second"])

    let toolEnds = events.compactMap { event -> (AgentToolResult, Bool)? in
        if case .toolExecutionEnd(_, _, let result, let isError) = event {
            return (result, isError)
        }
        return nil
    }
    #expect(toolEnds.count == 2)
    #expect(toolEnds[0].1 == false)
    #expect(toolEnds[1].1 == false) // second tool also succeeds

    // Steering message should still appear in next turn's context
    let steeringEvent = events.first { event in
        if case .messageStart(let message) = event {
            if case .user(let user) = message, case .text(let text) = user.content {
                return text == "interrupt"
            }
        }
        return false
    }
    #expect(steeringEvent != nil)
    #expect(sawInterruptInContext.withLock { $0 })
}

@Test func agentLoopContinueValidations() {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    do {
        _ = try agentLoopContinue(context: context, config: config)
        #expect(Bool(false), "Expected error for empty context")
    } catch {
        #expect(error.localizedDescription == "Cannot continue: no messages in context")
    }

    let assistant = createAssistantMessage(content: [.text(TextContent(text: "Hi"))])
    let contextWithAssistant = AgentContext(systemPrompt: "You are helpful.", messages: [.assistant(assistant)], tools: [])
    do {
        _ = try agentLoopContinue(context: contextWithAssistant, config: config)
        #expect(Bool(false), "Expected error for assistant last message")
    } catch {
        #expect(error.localizedDescription == "Cannot continue from message role: assistant")
    }
}

@Test func runAgentLoopContinueValidationThrowsInsteadOfCrashing() async {
    let emptyContext = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    do {
        _ = try await runAgentLoopContinue(context: emptyContext, config: config, emit: { _ in })
        #expect(Bool(false), "Expected error for empty context")
    } catch {
        #expect(error.localizedDescription == "Cannot continue: no messages in context")
    }

    let assistant = createAssistantMessage(content: [.text(TextContent(text: "Hi"))])
    let assistantContext = AgentContext(systemPrompt: "You are helpful.", messages: [.assistant(assistant)], tools: [])

    do {
        _ = try await runAgentLoopContinue(context: assistantContext, config: config, emit: { _ in })
        #expect(Bool(false), "Expected error for assistant last message")
    } catch {
        #expect(error.localizedDescription == "Cannot continue from message role: assistant")
    }
}

@Test func agentLoopContinueWithExistingContext() async throws {
    let userMessage = createUserMessage("Hello")
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [userMessage], tools: [])
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response"))])
        return makeStream(done: message)
    }

    var events: [AgentEvent] = []
    let stream = try agentLoopContinue(context: context, config: config, streamFn: streamFn)

    for await event in stream {
        events.append(event)
    }

    let messages = await stream.result()
    #expect(messages.count == 1)
    #expect(messages.first?.role == "assistant")

    let messageEnds = events.filter { event in
        if case .messageEnd = event { return true }
        return false
    }
    #expect(messageEnds.count == 1)
}

private func createUsage() -> Usage {
    Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
}

private func createModel() -> Model {
    Model(
        id: "mock",
        name: "mock",
        api: .openAIResponses,
        provider: "openai",
        baseUrl: "https://example.invalid",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192,
        maxTokens: 2048
    )
}

private func createAssistantMessage(content: [ContentBlock], stopReason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAIResponses,
        provider: "openai",
        model: "mock",
        usage: createUsage(),
        stopReason: stopReason
    )
}

private func createUserMessage(_ text: String) -> AgentMessage {
    AgentMessage.user(UserMessage(content: .text(text)))
}

private func identityConverter(messages: [AgentMessage]) async -> [Message] {
    messages.compactMap { $0.asMessage }
}

private func makeStream(done message: AssistantMessage, reason: StopReason = .stop) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    Task {
        stream.push(.done(reason: reason, message: message))
        stream.end(message)
    }
    return stream
}

@Test func agentLoopContinueWithCustomMessageAsLast() async throws {
    // Custom message that will be converted to user message by convertToLlm
    let customMessage = AgentMessage.custom(AgentCustomMessage(role: "hook", payload: AnyCodable("Hook content")))

    let context = AgentContext(systemPrompt: "You are helpful.", messages: [customMessage], tools: [])

    let converted = LockedState<[Message]>([])
    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: { messages in
            // Convert custom messages to user messages
            let result = messages.compactMap { message -> Message? in
                if case .custom(let custom) = message {
                    // Convert custom to user message
                    let text = (custom.payload?.value as? String) ?? ""
                    return .user(UserMessage(content: .text(text), timestamp: custom.timestamp))
                }
                return message.asMessage
            }
            converted.withLock { $0 = result }
            return result
        }
    )

    let streamFn: StreamFn = { _, _, _ in
        let message = createAssistantMessage(content: [.text(TextContent(text: "Response to custom message"))])
        return makeStream(done: message)
    }

    // Should not throw - the custom message will be converted to user message by convertToLlm
    let stream = try agentLoopContinue(context: context, config: config, streamFn: streamFn)

    var events: [AgentEvent] = []
    for await event in stream {
        events.append(event)
    }

    let messages = await stream.result()
    #expect(messages.count == 1)
    #expect(messages.first?.role == "assistant")

    // Verify the custom message was converted
    #expect(converted.withLock { $0.count } == 1)
    #expect(converted.withLock { $0.first?.role } == "user")
}

@Test func followUpMessagesProcessed() async {
    let context = AgentContext(systemPrompt: "", messages: [], tools: [])
    let userPrompt = createUserMessage("start")

    let followUpDelivered = LockedState(false)
    let callIndex = LockedState(0)

    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: identityConverter,
        getFollowUpMessages: {
            let index = callIndex.withLock { $0 }
            // Return follow-up after first turn completes
            let shouldDeliver = followUpDelivered.withLock { delivered in
                if index == 1 && !delivered {
                    delivered = true
                    return true
                }
                return false
            }
            if shouldDeliver {
                return [createUserMessage("follow-up")]
            }
            return []
        }
    )

    let sawFollowUpInContext = LockedState(false)
    let streamFn: StreamFn = { _, ctx, _ in
        let index = callIndex.withLock { $0 }
        if index == 1 {
            // Check if follow-up message is in context on second call
            let sawFollowUp = ctx.messages.contains { message in
                if case .user(let user) = message, case .text(let text) = user.content {
                    return text == "follow-up"
                }
                return false
            }
            sawFollowUpInContext.withLock { $0 = sawFollowUp }
        }

        let stream = AssistantMessageEventStream()
        if index == 0 {
            // First call: return response, no tool calls
            let message = createAssistantMessage(content: [.text(TextContent(text: "first response"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        } else {
            // Second call: return final response
            let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
        }
        callIndex.withLock { $0 += 1 }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    // Should have processed the follow-up message
    #expect(sawFollowUpInContext.withLock { $0 })

    // Should have two turn_start events (first turn + follow-up turn)
    let turnStarts = events.filter { if case .turnStart = $0 { return true } else { return false } }
    #expect(turnStarts.count == 2)

    // Follow-up message should appear in events
    let followUpEvent = events.first { event in
        if case .messageStart(let message) = event {
            if case .user(let user) = message, case .text(let text) = user.content {
                return text == "follow-up"
            }
        }
        return false
    }
    #expect(followUpEvent != nil)
}

@Test func shouldStopAfterTurnSkipsQueuedFollowUps() async {
    let context = AgentContext(systemPrompt: "", messages: [], tools: [])
    let userPrompt = createUserMessage("start")

    let followUpPolled = LockedState(false)
    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: identityConverter,
        getFollowUpMessages: {
            followUpPolled.withLock { $0 = true }
            return [createUserMessage("follow-up")]
        },
        shouldStopAfterTurn: {
            true
        }
    )

    let llmCallCount = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        llmCallCount.withLock { $0 += 1 }
        let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
        return makeStream(done: message)
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    #expect(llmCallCount.withLock { $0 } == 1)
    #expect(!followUpPolled.withLock { $0 })

    let followUpEvent = events.first { event in
        if case .messageStart(let message) = event,
           case .user(let user) = message,
           case .text(let text) = user.content {
            return text == "follow-up"
        }
        return false
    }
    #expect(followUpEvent == nil)
}

// MARK: - v0.54.0→v0.61.1 new tests

/// Parallel tool execution: tools execute concurrently but results emit in source order.
@Test func parallelToolExecutionEmitsResultsInSourceOrder() async {
    let firstReleased = LockedState(false)
    let parallelObserved = LockedState(false)
    let firstContinuation = LockedState<CheckedContinuation<Void, Never>?>(nil)

    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        if value == "first" {
            // Block first tool until released
            await withCheckedContinuation { continuation in
                firstContinuation.withLock { $0 = continuation }
            }
            firstReleased.withLock { $0 = true }
        }
        if value == "second" && !firstReleased.withLock({ $0 }) {
            parallelObserved.withLock { $0 = true }
        }
        return AgentToolResult(content: [.text(TextContent(text: "echoed:\(value)"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("go")
    let config = AgentLoopConfig(
        model: createModel(),
        toolExecution: .parallel,
        convertToLlm: identityConverter
    )

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { $0 }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 0 {
                let first = ToolCall(id: "tool-1", name: "echo", arguments: ["value": AnyCodable("first")])
                let second = ToolCall(id: "tool-2", name: "echo", arguments: ["value": AnyCodable("second")])
                let message = createAssistantMessage(content: [.toolCall(first), .toolCall(second)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
                // Release first tool after a brief delay to let parallel execution start
                try? await Task.sleep(nanoseconds: 20_000_000)
                firstContinuation.withLock { $0?.resume() }
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
            callIndex.withLock { $0 += 1 }
        }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    // Second tool should have started while first was blocked (parallel execution)
    #expect(parallelObserved.withLock { $0 })

    // tool_execution_end is emitted in completion order, while persisted tool-result
    // messages stay in assistant source order.
    let toolExecutionEndIds = events.compactMap { event -> String? in
        if case .toolExecutionEnd(let id, _, _, _) = event {
            return id
        }
        return nil
    }
    #expect(toolExecutionEndIds == ["tool-2", "tool-1"])

    let toolResultIds = events.compactMap { event -> String? in
        if case .messageEnd(let message) = event, case .toolResult(let tr) = message {
            return tr.toolCallId
        }
        return nil
    }
    #expect(toolResultIds == ["tool-1", "tool-2"])
}

@Test func afterToolCallThrowBecomesErrorToolResult() async {
    struct HookFailure: LocalizedError {
        var errorDescription: String? { "after hook failed" }
    }

    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        toolExecution: .parallel,
        afterToolCall: { _, _ in
            throw HookFailure()
        },
        convertToLlm: identityConverter
    )

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { count -> Int in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 1 {
                let call = ToolCall(id: "t-1", name: "echo", arguments: [:])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    var toolEnd: (AgentToolResult, Bool)?
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        if case .toolExecutionEnd(_, _, let result, let isError) = event {
            toolEnd = (result, isError)
        }
    }

    #expect(toolEnd?.1 == true)
    if case .text(let text) = toolEnd?.0.content.first {
        #expect(text.text == "after hook failed")
    } else {
        #expect(Bool(false), "Expected after hook error text")
    }
}

@Test func lateToolProgressAfterResultIsSuppressed() async {
    let capturedUpdate = LockedState<AgentToolUpdateCallback?>(nil)
    let tool = AgentTool(
        label: "Reporter",
        name: "reporter",
        description: "Reports progress",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, onUpdate in
        capturedUpdate.withLock { $0 = onUpdate }
        onUpdate?(AgentToolResult(content: [.text(TextContent(text: "during"))]))
        return AgentToolResult(content: [.text(TextContent(text: "final"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        toolExecution: .sequential,
        afterToolCall: { _, _ in
            capturedUpdate.withLock { $0 }?(AgentToolResult(content: [.text(TextContent(text: "late"))]))
            return nil
        },
        convertToLlm: identityConverter
    )

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { count -> Int in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 1 {
                let call = ToolCall(id: "tool-1", name: "reporter", arguments: [:])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    var updates: [String] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        if case .toolExecutionUpdate(_, _, _, let partialResult) = event,
           case .text(let text)? = partialResult.content.first {
            updates.append(text.text)
        }
    }

    #expect(updates == ["during"])
}

/// beforeToolCall hook can block tool execution.
@Test func beforeToolCallBlocksExecution() async {
    let executed = LockedState<[String]>([])
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        executed.withLock { $0.append(value) }
        return AgentToolResult(content: [.text(TextContent(text: "ok:\(value)"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        toolExecution: .sequential,
        beforeToolCall: { context, _ in
            // Block "dangerous" tool calls
            if let value = context.args["value"]?.value as? String, value == "blocked" {
                return BeforeToolCallResult(block: true, reason: "This tool call was blocked")
            }
            return nil
        },
        convertToLlm: identityConverter
    )

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { $0 }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 0 {
                let allowed = ToolCall(id: "t-1", name: "echo", arguments: ["value": AnyCodable("allowed")])
                let blocked = ToolCall(id: "t-2", name: "echo", arguments: ["value": AnyCodable("blocked")])
                let message = createAssistantMessage(content: [.toolCall(allowed), .toolCall(blocked)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
            callIndex.withLock { $0 += 1 }
        }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    // Only "allowed" should have executed
    #expect(executed.withLock { $0 } == ["allowed"])

    // Blocked tool should show error
    let toolEnds = events.compactMap { event -> (String, Bool)? in
        if case .toolExecutionEnd(let id, _, _, let isError) = event {
            return (id, isError)
        }
        return nil
    }
    #expect(toolEnds.count == 2)
    #expect(toolEnds[0] == ("t-1", false))
    #expect(toolEnds[1] == ("t-2", true))
}

/// afterToolCall hook can override tool result content.
@Test func afterToolCallOverridesResult() async {
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, params, _, _ in
        let value = params["value"]?.value as? String ?? ""
        return AgentToolResult(content: [.text(TextContent(text: "original:\(value)"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        afterToolCall: { context, _ in
            // Override content for all tool results
            return AfterToolCallResult(
                content: [.text(TextContent(text: "overridden"))],
                isError: nil
            )
        },
        convertToLlm: identityConverter
    )

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { $0 }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 0 {
                let call = ToolCall(id: "t-1", name: "echo", arguments: ["value": AnyCodable("hello")])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
            callIndex.withLock { $0 += 1 }
        }
        return stream
    }

    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await event in stream {
        events.append(event)
    }

    // Tool result should have overridden content
    let toolEnd = events.compactMap { event -> AgentToolResult? in
        if case .toolExecutionEnd(_, _, let result, _) = event { return result }
        return nil
    }.first
    #expect(toolEnd != nil)
    if case .text(let text) = toolEnd?.content.first {
        #expect(text.text == "overridden")
    } else {
        #expect(Bool(false), "Expected text content in tool result")
    }
}

@Test func steeringMessagesAtLoopStart() async {
    // Test that steering messages are checked at the start of the loop
    let context = AgentContext(systemPrompt: "", messages: [], tools: [])
    let userPrompt = createUserMessage("start")
    let steeringMessage = createUserMessage("early steering")

    // Pre-queue a steering message before the loop starts
    let steeringDelivered = LockedState(false)
    let config = AgentLoopConfig(
        model: createModel(),
        convertToLlm: identityConverter,
        getSteeringMessages: {
            let shouldDeliver = steeringDelivered.withLock { delivered in
                if !delivered {
                    delivered = true
                    return true
                }
                return false
            }
            if shouldDeliver {
                return [steeringMessage]
            }
            return []
        }
    )

    let sawSteeringInContext = LockedState(false)
    let streamFn: StreamFn = { _, ctx, _ in
        // Check if steering message is in context
        let sawSteering = ctx.messages.contains { message in
            if case .user(let user) = message, case .text(let text) = user.content {
                return text == "early steering"
            }
            return false
        }
        sawSteeringInContext.withLock { $0 = sawSteering }

        let stream = AssistantMessageEventStream()
        let message = createAssistantMessage(content: [.text(TextContent(text: "response"))])
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    // Steering message should have been included in context for the LLM call
    #expect(sawSteeringInContext.withLock { $0 })
}

/// v0.64.0: AgentTool.prepareArguments runs before schema validation and can rewrite raw args.
@Test func prepareArgumentsRewritesArgsBeforeValidation() async {
    let receivedValue = LockedState<String?>(nil)
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "value": ["type": "string"]
            ]),
            "required": AnyCodable(["value"])
        ],
        execute: { _, params, _, _ in
            let value = params["value"]?.value as? String ?? ""
            receivedValue.withLock { $0 = value }
            return AgentToolResult(content: [.text(TextContent(text: "ok:\(value)"))])
        },
        prepareArguments: { raw in
            // Legacy single-edit shape: rewrite "oldValue" → "value" before validation runs.
            if let legacy = raw["oldValue"]?.value as? String {
                return ["value": AnyCodable(legacy)]
            }
            return nil
        }
    )

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let callIndex = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = callIndex.withLock { $0 }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 0 {
                let call = ToolCall(id: "t-1", name: "echo", arguments: ["oldValue": AnyCodable("hello")])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "done"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
            callIndex.withLock { $0 += 1 }
        }
        return stream
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    // Tool received the rewritten argument, not the legacy key.
    #expect(receivedValue.withLock { $0 } == "hello")
}

/// v0.69.0: when every finalized result in a tool batch sets terminate=true,
/// the loop skips the automatic follow-up LLM turn.
@Test func terminateHintSkipsFollowUpTurn() async {
    let tool = AgentTool(
        label: "Final",
        name: "final",
        description: "Terminating tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        afterToolCall: { _, _ in
            AfterToolCallResult(terminate: true)
        },
        convertToLlm: identityConverter
    )

    let llmCallCount = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = llmCallCount.withLock { count -> Int in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 1 {
                let call = ToolCall(id: "t-1", name: "final", arguments: [:])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                // This branch must NOT run if terminate works correctly.
                let message = createAssistantMessage(content: [.text(TextContent(text: "should-not-run"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    // Exactly one LLM call: the initial turn that emitted the tool call.
    // No follow-up turn after the terminating tool batch.
    #expect(llmCallCount.withLock { $0 } == 1)
}

@Test func toolResultTerminateHintSkipsFollowUpTurn() async {
    let tool = AgentTool(
        label: "Final",
        name: "final",
        description: "Terminating tool",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))], terminate: true)
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(model: createModel(), convertToLlm: identityConverter)

    let llmCallCount = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = llmCallCount.withLock { count -> Int in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 1 {
                let call = ToolCall(id: "t-1", name: "final", arguments: [:])
                let message = createAssistantMessage(content: [.toolCall(call)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = createAssistantMessage(content: [.text(TextContent(text: "should-not-run"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    #expect(llmCallCount.withLock { $0 } == 1)
}

/// v0.69.0: terminate is only honored when EVERY finalized result opts in.
/// One non-terminating result keeps the follow-up turn.
@Test func terminateRequiresAllResultsToOptIn() async {
    let tool = AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: ["type": AnyCodable("object")]
    ) { id, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: id))])
    }

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])
    let userPrompt = createUserMessage("start")
    let config = AgentLoopConfig(
        model: createModel(),
        afterToolCall: { ctx, _ in
            // Only the second tool call opts in to terminate.
            if ctx.toolCall.id == "t-2" {
                return AfterToolCallResult(terminate: true)
            }
            return nil
        },
        convertToLlm: identityConverter
    )

    let llmCallCount = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = llmCallCount.withLock { count -> Int in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 1 {
                let call1 = ToolCall(id: "t-1", name: "echo", arguments: [:])
                let call2 = ToolCall(id: "t-2", name: "echo", arguments: [:])
                let message = createAssistantMessage(content: [.toolCall(call1), .toolCall(call2)], stopReason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                // Follow-up turn must run because at least one result did not terminate.
                let message = createAssistantMessage(content: [.text(TextContent(text: "follow-up"))])
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    let stream = agentLoop(prompts: [userPrompt], context: context, config: config, streamFn: streamFn)
    for await _ in stream {}

    // Two LLM calls: initial tool-emitting turn + the follow-up turn.
    #expect(llmCallCount.withLock { $0 } == 2)
}
