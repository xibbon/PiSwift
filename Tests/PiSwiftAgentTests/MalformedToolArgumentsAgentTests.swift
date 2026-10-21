import Testing
import PiSwiftAI
import PiSwiftAgent

private let malformedAgentArguments = #"{"value":"unfinished"#

private func malformedAgentCall() -> ToolCall {
    var call = ToolCall(id: "malformed-1", name: "echo", arguments: [:])
    call.finalizeArguments(from: malformedAgentArguments)
    return call
}

private func malformedAgentAssistant(_ call: ToolCall, model: Model) -> AssistantMessage {
    AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
}

private func malformedAgentTool(_ calls: LockedState<[String]>) -> AgentTool {
    AgentTool(label: "Echo", name: "echo", description: "Echo tool", parameters: [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["value": ["type": "string"]]),
    ], execute: { _, _, _, _ in
        calls.withLock { $0.append("execute") }
        return AgentToolResult(content: [])
    }, prepareArguments: { _ in
        calls.withLock { $0.append("prepare") }
        return ["value": AnyCodable("replacement")]
    })
}

private func malformedAgentResultText(_ content: [ContentBlock]) -> String? {
    guard case .text(let text) = content.first else { return nil }
    return text.text
}

@Test(arguments: [false, true])
func malformedArgumentsFailDirectToolCall(argumentsPrepared: Bool) async throws {
    let call = malformedAgentCall()
    let diagnostic = try #require(call.argumentsError)
    let calls = LockedState<[String]>([])
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let outcome = await runToolCall(call, options: RunToolCallOptions(
        tools: [malformedAgentTool(calls)],
        assistantMessage: malformedAgentAssistant(call, model: model),
        context: AgentContext(messages: []),
        beforeToolCall: { _, _ in calls.withLock { $0.append("before") }; return nil },
        afterToolCall: { _, _ in calls.withLock { $0.append("after") }; return nil },
        argumentsPrepared: argumentsPrepared
    ))

    #expect(outcome.isError)
    #expect(outcome.toolCall.argumentsError == diagnostic)
    #expect(outcome.toolCall.arguments.isEmpty)
    #expect(malformedAgentResultText(outcome.result.content) == "Invalid arguments for tool \"echo\": \(diagnostic)")
    #expect(diagnostic.hasSuffix("\n\nReceived arguments:\n\(malformedAgentArguments)"))
    #expect(calls.withLock { $0 } == (argumentsPrepared ? [] : ["prepare"]))
}

@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel])
func malformedArgumentsFailAgentLoop(mode: ToolExecutionMode) async throws {
    let call = malformedAgentCall()
    let diagnostic = try #require(call.argumentsError)
    let calls = LockedState<[String]>([])
    let config = AgentLoopConfig(
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"), toolExecution: mode,
        beforeToolCall: { _, _ in calls.withLock { $0.append("before") }; return nil },
        afterToolCall: { _, _ in calls.withLock { $0.append("after") }; return nil },
        convertToLlm: { $0.compactMap(\.asMessage) }, finishTurn: { _, _ in .end }
    )
    let stream = agentLoop(prompts: [.user(UserMessage(content: .text("run")))],
        context: AgentContext(messages: [], tools: [malformedAgentTool(calls)]), config: config,
        streamFn: { model, _, _ in
            let message = malformedAgentAssistant(call, model: model)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
            return stream
        })

    var outcomes = 0
    for await event in stream {
        if case .toolExecutionEnd(let id, let name, let result, let isError, _) = event {
            outcomes += 1
            #expect(id == call.id && name == call.name)
            #expect(isError)
            #expect(malformedAgentResultText(result.content) == "Invalid arguments for tool \"echo\": \(diagnostic)")
        }
    }
    #expect(outcomes == 1)
    #expect(calls.withLock { $0 } == ["prepare"])

    let messages = await stream.result()
    let results = messages.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message else { return nil }
        return result
    }
    let result = try #require(results.first)
    #expect(results.count == 1)
    #expect(result.isError)
    #expect(malformedAgentResultText(result.content) == "Invalid arguments for tool \"echo\": \(diagnostic)")
    #expect(diagnostic.hasSuffix("\n\nReceived arguments:\n\(malformedAgentArguments)"))
    let storedCalls = messages.compactMap { message -> ToolCall? in
        guard case .assistant(let assistant) = message, case .toolCall(let storedCall) = assistant.content.first else { return nil }
        return storedCall
    }
    #expect(storedCalls.first?.argumentsError == diagnostic)
}
