import Testing
import PiSwiftAI
import PiSwiftAgent

private func durationModel() -> Model {
    Model(
        id: "duration-test", name: "Duration test", api: .openAIResponses,
        provider: "openai", baseUrl: "https://example.invalid", reasoning: false,
        input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192, maxTokens: 2048
    )
}

private func durationAssistant(_ content: [ContentBlock] = [], reason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: content, api: .openAIResponses, provider: "openai", model: "duration-test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: reason
    )
}

private func durationCall(_ id: String, name: String = "echo") -> ToolCall {
    ToolCall(id: id, name: name, arguments: ["value": AnyCodable(id)])
}

private func durationTool() -> AgentTool {
    AgentTool(
        label: "Echo", name: "echo", description: "Echo tool",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["value": ["type": "string"]]),
            "required": AnyCodable(["value"]),
        ]
    ) { _, args, _, _ in
        try await Task.sleep(for: .milliseconds(30))
        return AgentToolResult(content: [.text(TextContent(text: args["value"]?.value as? String ?? ""))])
    }
}

private func durationBeforeHook(_ context: BeforeToolCallContext, _ signal: CancellationToken?) async -> BeforeToolCallResult? {
    try? await Task.sleep(for: .milliseconds(200))
    return context.toolCall.id == "blocked" ? BeforeToolCallResult(block: true, reason: "no") : nil
}

@Test(.timeLimit(.minutes(1)))
func agentLoopDurationExcludesHooksV110() async throws {
    let calls = LockedState(0)
    let config = AgentLoopConfig(
        model: durationModel(),
        beforeToolCall: durationBeforeHook,
        afterToolCall: { _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return nil
        },
        convertToLlm: { $0.compactMap(\.asMessage) }
    )
    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        let index = calls.withLock { value in
            defer { value += 1 }
            return value
        }
        let message = index == 0
            ? durationAssistant([.toolCall(durationCall("ran")), .toolCall(durationCall("blocked"))], reason: .toolUse)
            : durationAssistant([.text(TextContent(text: "done"))])
        stream.push(.done(reason: message.stopReason, message: message))
        return stream
    }
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("go")))],
        context: AgentContext(messages: [], tools: [durationTool()]),
        config: config, streamFn: streamFn
    )
    var ends: [String: (isError: Bool, duration: Int?)] = [:]
    for await event in stream {
        if case .toolExecutionEnd(let id, _, _, let isError, let durationMs) = event {
            ends[id] = (isError, durationMs)
        }
    }
    let results = await stream.result().compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message else { return nil }
        return result
    }
    let ran = try #require(results.first { $0.toolCallId == "ran" })
    let blocked = try #require(results.first { $0.toolCallId == "blocked" })
    let duration = try #require(ran.durationMs)
    #expect(duration >= 25)
    #expect(duration < 200)
    #expect(ends["ran"]?.duration == duration)
    #expect(ends["ran"]?.isError == false)
    #expect(blocked.isError)
    #expect(blocked.durationMs == nil)
    #expect(ends["blocked"] != nil)
    #expect(ends["blocked"]?.duration == nil)
    #expect(ends["blocked"]?.isError == true)
}

@Test(.timeLimit(.minutes(1)))
func runToolCallDurationExcludesHooksV110() async throws {
    let options = RunToolCallOptions(
        tools: [durationTool()], assistantMessage: durationAssistant(), context: AgentContext(messages: []),
        beforeToolCall: durationBeforeHook,
        afterToolCall: { _, _ in
            try await Task.sleep(for: .milliseconds(200))
            return nil
        }
    )
    let ran = await runToolCall(durationCall("ran"), options: options)
    let blocked = await runToolCall(durationCall("blocked"), options: options)
    let duration = try #require(ran.durationMs)
    #expect(duration >= 25)
    #expect(duration < 200)
    #expect(!ran.isError)
    #expect(blocked.isError)
    #expect(blocked.durationMs == nil)
}

private enum DurationExecutionError: Error {
    case failed
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func runToolCallDurationExcludesPendingUpdatesV110(throwsError: Bool) async throws {
    let updated = LockedState(false)
    let tool = AgentTool(
        label: "Update", name: "update", description: "Send an update",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, onUpdate in
        onUpdate?(AgentToolResult(content: []))
        try await Task.sleep(for: .milliseconds(30))
        if throwsError { throw DurationExecutionError.failed }
        return AgentToolResult(content: [])
    }
    let outcome = await runToolCall(
        durationCall("update", name: "update"),
        options: RunToolCallOptions(
            tools: [tool], assistantMessage: durationAssistant(), context: AgentContext(messages: []),
            onUpdate: { _ in
                try? await Task.sleep(for: .milliseconds(200))
                updated.withLock { $0 = true }
            }
        )
    )
    let duration = try #require(outcome.durationMs)
    #expect(duration >= 25)
    #expect(duration < 200)
    #expect(outcome.isError == throwsError)
    #expect(updated.withLock { $0 })
}

@Test
func runToolCallImmediateOutcomesHaveNoDurationV110() async {
    let tool = durationTool()
    let assistant = durationAssistant()
    let context = AgentContext(messages: [])
    let options = RunToolCallOptions(tools: [tool], assistantMessage: assistant, context: context)
    let missing = await runToolCall(durationCall("missing", name: "missing"), options: options)
    let invalid = await runToolCall(ToolCall(id: "invalid", name: "echo", arguments: [:]), options: options)
    let signal = CancellationToken()
    signal.cancel()
    let aborted = await runToolCall(
        durationCall("aborted"),
        options: RunToolCallOptions(tools: [tool], assistantMessage: assistant, context: context, signal: signal)
    )
    for outcome in [missing, invalid, aborted] {
        #expect(outcome.isError)
        #expect(outcome.durationMs == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func truncatedToolResultHasNoDurationV110() async throws {
    let calls = LockedState(0)
    let config = AgentLoopConfig(model: durationModel(), convertToLlm: { $0.compactMap(\.asMessage) })
    let streamFn: StreamFn = { _, _, _ in
        let stream = AssistantMessageEventStream()
        let index = calls.withLock { value in
            defer { value += 1 }
            return value
        }
        let message = index == 0
            ? durationAssistant([.toolCall(durationCall("truncated"))], reason: .length)
            : durationAssistant([.text(TextContent(text: "done"))])
        stream.push(.done(reason: message.stopReason, message: message))
        return stream
    }
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("go")))],
        context: AgentContext(messages: [], tools: [durationTool()]), config: config, streamFn: streamFn
    )
    var ends = 0
    for await event in stream {
        if case .toolExecutionEnd(_, _, _, let isError, let durationMs) = event {
            ends += 1
            #expect(isError)
            #expect(durationMs == nil)
        }
    }
    let results = await stream.result().compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message else { return nil }
        return result
    }
    #expect(ends == 1)
    let result = try #require(results.first)
    #expect(result.isError)
    #expect(result.durationMs == nil)
}
