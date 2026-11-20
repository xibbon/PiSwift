import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent

private struct InterruptedTool: LocalizedError {
    var errorDescription: String? { "interrupted" }
}

private func abortModel() -> Model {
    Model(id: "mock", name: "mock", api: .openAIResponses, provider: "openai",
        baseUrl: "https://example.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8192, maxTokens: 2048)
}

private func abortAssistant(_ content: [ContentBlock], reason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(content: content, api: .openAIResponses, provider: "openai", model: "mock",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: reason)
}

private func abortedBatch(
    mode: ToolExecutionMode,
    signal: CancellationToken,
    beforeToolCall: BeforeToolCallFn? = nil,
    execute: @escaping AgentToolExecute
) async -> (events: [AgentEvent], messages: [AgentMessage]) {
    let tool = AgentTool(label: "Slow", name: "slow", description: "Slow tool",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["value": ["type": "string"]])],
        execute: execute)
    let context = testAgentContext(systemPrompt: "", messages: [], tools: [tool])
    let config = AgentLoopConfig(model: abortModel(), toolExecution: mode,
        beforeToolCall: beforeToolCall, convertToLlm: { $0.compactMap(\.asMessage) })
    let calls = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = calls.withLock { value in defer { value += 1 }; return value }
        let stream = AssistantMessageEventStream()
        Task {
            if index == 0 {
                let blocks = ["first", "second", "third"].enumerated().map { index, value in
                    ContentBlock.toolCall(ToolCall(id: "tool-\(index + 1)", name: "slow",
                        arguments: ["value": AnyCodable(value)]))
                }
                let message = abortAssistant(blocks, reason: .toolUse)
                stream.push(.done(reason: .toolUse, message: message))
                stream.end(message)
            } else {
                let message = abortAssistant([], reason: .aborted)
                stream.push(.error(reason: .aborted, error: message))
                stream.end(message)
            }
        }
        return stream
    }
    var events: [AgentEvent] = []
    let stream = agentLoop(prompts: [.user(UserMessage(content: .text("run three")))], context: context,
        config: config, signal: signal, streamFn: streamFn)
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

private func abortTexts(_ messages: [AgentMessage]) -> [(String, String, Bool, AnyCodable?)] {
    messages.compactMap { message in
        guard case .toolResult(let result) = message else { return nil }
        let text = result.content.compactMap { block -> String? in
            if case .text(let content) = block { return content.text }
            return nil
        }.joined()
        return (result.toolCallId, text, result.isError, result.details)
    }
}

// agent-loop.test.ts: "answers every tool call of a sequential batch aborted mid-batch"
@Test(.timeLimit(.minutes(1))) func answersEverySequentialToolCallAfterMidBatchAbort() async {
    let signal = CancellationToken()
    let executed = LockedState<[String]>([])
    let (events, messages) = await abortedBatch(mode: .sequential, signal: signal) { _, args, _, _ in
        let value = args["value"]?.value as? String ?? ""
        executed.withLock { $0.append(value) }
        signal.cancel()
        throw InterruptedTool()
    }
    #expect(executed.withLock { $0 } == ["first"])
    let results = abortTexts(messages)
    #expect(results.map(\.0) == ["tool-1", "tool-2", "tool-3"])
    #expect(results.map(\.1) == ["interrupted", "Operation aborted", "Operation aborted"])
    #expect(results.allSatisfy { $0.2 })
    let emptyDetails = results.allSatisfy { ($0.3?.value as? [String: Any])?.isEmpty == true }
    #expect(emptyDetails)
    let starts = events.compactMap { if case .toolExecutionStart(let id, _, _) = $0 { id } else { nil } }
    let ends = events.compactMap { if case .toolExecutionEnd(let id, _, _, _, _) = $0 { id } else { nil } }
    #expect(starts == ["tool-1", "tool-2", "tool-3"])
    #expect(ends == ["tool-1", "tool-2", "tool-3"])
}

// agent-loop.test.ts: "answers every tool call of a parallel batch aborted while calls are prepared"
@Test(.timeLimit(.minutes(1))) func answersEveryParallelToolCallAfterPreparationAbort() async {
    let signal = CancellationToken()
    let executed = LockedState<[String]>([])
    let hooks = LockedState<[String]>([])
    let (events, messages) = await abortedBatch(mode: .parallel, signal: signal,
        beforeToolCall: { context, _ in
            hooks.withLock { $0.append(context.toolCall.id) }
            if context.toolCall.id == "tool-2" { signal.cancel() }
            return nil
        }) { _, args, _, _ in
            let value = args["value"]?.value as? String ?? ""
            executed.withLock { $0.append(value) }
            return AgentToolResult(content: [.text(TextContent(text: value))])
        }
    #expect(executed.withLock { $0 }.isEmpty)
    #expect(hooks.withLock { $0 } == ["tool-1", "tool-2"])
    let results = abortTexts(messages)
    #expect(results.map(\.0) == ["tool-1", "tool-2", "tool-3"])
    #expect(results.map(\.1) == ["Operation aborted", "Operation aborted", "Operation aborted"])
    #expect(results.allSatisfy { $0.2 })
    let emptyDetails = results.allSatisfy { ($0.3?.value as? [String: Any])?.isEmpty == true }
    #expect(emptyDetails)
    let starts = events.compactMap { if case .toolExecutionStart(let id, _, _) = $0 { id } else { nil } }
    let ends = events.compactMap { if case .toolExecutionEnd(let id, _, _, _, _) = $0 { id } else { nil } }
    #expect(starts == ["tool-1", "tool-2", "tool-3"])
    #expect(Set(ends) == Set(starts))
}

@Test func abortedRunToolCallPrecedesLookupValidationAndHook() async {
    let signal = CancellationToken()
    signal.cancel()
    let hookCalled = LockedState(false)
    let call = ToolCall(id: "missing", name: "missing", arguments: [:])
    let outcome = await runToolCall(call, options: RunToolCallOptions(tools: [],
        assistantMessage: abortAssistant([]),
        context: testAgentContext(systemPrompt: "", messages: [], tools: []), signal: signal,
        beforeToolCall: { _, _ in hookCalled.withLock { $0 = true }; return nil }))
    #expect(outcome.isError)
    #expect(outcome.result.content.count == 1)
    if case .text(let text) = outcome.result.content.first { #expect(text.text == "Operation aborted") }
    let emptyDetails = (outcome.result.details?.value as? [String: Any])?.isEmpty == true
    #expect(emptyDetails)
    #expect(!hookCalled.withLock { $0 })
}
