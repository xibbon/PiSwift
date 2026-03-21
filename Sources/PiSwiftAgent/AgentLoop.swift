import Foundation
import PiSwiftAI

public enum AgentToolError: LocalizedError, Sendable {
    case toolNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool \(name) not found"
        }
    }
}

// MARK: - Public EventStream API (unchanged signatures)

public func agentLoop(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) -> EventStream<AgentEvent, [AgentMessage]> {
    let stream = createAgentStream()

    Task {
        let messages = await runAgentLoop(
            prompts: prompts,
            context: context,
            config: config,
            emit: { event in stream.push(event) },
            signal: signal,
            streamFn: streamFn
        )
        stream.end(messages)
    }

    return stream
}

public func agentLoopContinue(
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) throws -> EventStream<AgentEvent, [AgentMessage]> {
    guard !context.messages.isEmpty else {
        throw AgentLoopError.emptyContext
    }

    if let last = context.messages.last, last.role == "assistant" {
        throw AgentLoopError.lastMessageAssistant
    }

    let stream = createAgentStream()

    Task {
        let messages = await runAgentLoopContinue(
            context: context,
            config: config,
            emit: { event in stream.push(event) },
            signal: signal,
            streamFn: streamFn
        )
        stream.end(messages)
    }

    return stream
}

// MARK: - Public runnable functions (emit callback pattern)

public func runAgentLoop(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) async -> [AgentMessage] {
    let newMessages = prompts
    let currentContext = AgentContext(
        systemPrompt: context.systemPrompt,
        messages: context.messages + prompts,
        tools: context.tools
    )

    await emit(.agentStart)
    await emit(.turnStart)
    for prompt in prompts {
        await emit(.messageStart(message: prompt))
        await emit(.messageEnd(message: prompt))
    }

    return await runLoop(
        currentContext: currentContext,
        newMessages: newMessages,
        config: config,
        signal: signal,
        emit: emit,
        streamFn: streamFn
    )
}

public func runAgentLoopContinue(
    context: AgentContext,
    config: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    signal: CancellationToken? = nil,
    streamFn: StreamFn? = nil
) async -> [AgentMessage] {
    let currentContext = context

    await emit(.agentStart)
    await emit(.turnStart)

    return await runLoop(
        currentContext: currentContext,
        newMessages: [],
        config: config,
        signal: signal,
        emit: emit,
        streamFn: streamFn
    )
}

// MARK: - Errors

public enum AgentLoopError: Error, LocalizedError {
    case emptyContext
    case lastMessageAssistant

    public var errorDescription: String? {
        switch self {
        case .emptyContext:
            return "Cannot continue: no messages in context"
        case .lastMessageAssistant:
            return "Cannot continue from message role: assistant"
        }
    }
}

// MARK: - Private helpers

private func createAgentStream() -> EventStream<AgentEvent, [AgentMessage]> {
    EventStream<AgentEvent, [AgentMessage]>(
        isComplete: { event in
            if case .agentEnd = event { return true }
            return false
        },
        extractResult: { event in
            if case .agentEnd(let messages) = event { return messages }
            return []
        }
    )
}

// MARK: - Main loop

private func runLoop(
    currentContext: AgentContext,
    newMessages: [AgentMessage],
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink,
    streamFn: StreamFn?
) async -> [AgentMessage] {
    var context = currentContext
    var messages = newMessages
    var firstTurn = true
    var pendingMessages = (await config.getSteeringMessages?()) ?? []

    while true {
        var hasMoreToolCalls = true

        while hasMoreToolCalls || !pendingMessages.isEmpty {
            if !firstTurn {
                await emit(.turnStart)
            } else {
                firstTurn = false
            }

            if !pendingMessages.isEmpty {
                for message in pendingMessages {
                    await emit(.messageStart(message: message))
                    await emit(.messageEnd(message: message))
                    context.messages.append(message)
                    messages.append(message)
                }
                pendingMessages.removeAll()
            }

            do {
                let (assistantMessage, updatedContext) = try await streamAssistantResponse(
                    context: context,
                    config: config,
                    signal: signal,
                    emit: emit,
                    streamFn: streamFn
                )
                context = updatedContext
                let agentMessage = AgentMessage.assistant(assistantMessage)
                messages.append(agentMessage)

                if assistantMessage.stopReason == .error || assistantMessage.stopReason == .aborted {
                    await emit(.turnEnd(message: agentMessage, toolResults: []))
                    await emit(.agentEnd(messages: messages))
                    return messages
                }

                let toolCalls = assistantMessage.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let toolCall) = block { return toolCall }
                    return nil
                }
                hasMoreToolCalls = !toolCalls.isEmpty

                var toolResults: [ToolResultMessage] = []
                if hasMoreToolCalls {
                    toolResults = await executeToolCalls(
                        context: context,
                        assistantMessage: assistantMessage,
                        config: config,
                        signal: signal,
                        emit: emit
                    )

                    for result in toolResults {
                        let agentResult = AgentMessage.toolResult(result)
                        context.messages.append(agentResult)
                        messages.append(agentResult)
                    }
                }

                await emit(.turnEnd(message: agentMessage, toolResults: toolResults))
            } catch {
                let errorMessage = AgentMessage.assistant(buildErrorAssistantMessage(
                    model: config.model,
                    reason: signal?.isCancelled == true ? .aborted : .error,
                    message: error.localizedDescription
                ))
                messages.append(errorMessage)
                await emit(.turnEnd(message: errorMessage, toolResults: []))
                await emit(.agentEnd(messages: messages))
                return messages
            }

            // Steering is now checked AFTER all tool calls complete (not mid-execution)
            pendingMessages = (await config.getSteeringMessages?()) ?? []
        }

        let followUpMessages = (await config.getFollowUpMessages?()) ?? []
        if !followUpMessages.isEmpty {
            pendingMessages = followUpMessages
            continue
        }

        break
    }

    await emit(.agentEnd(messages: messages))
    return messages
}

// MARK: - Stream assistant response

private func streamAssistantResponse(
    context: AgentContext,
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink,
    streamFn: StreamFn?
) async throws -> (AssistantMessage, AgentContext) {
    var updatedContext = context
    var messages = context.messages

    if let transform = config.transformContext {
        messages = try await transform(messages, signal)
    }

    let llmMessages = try await config.convertToLlm(messages)

    let llmContext = Context(
        systemPrompt: context.systemPrompt,
        messages: llmMessages,
        tools: context.tools?.map { $0.aiTool }
    )

    let streamFunction: StreamFn = streamFn ?? { model, context, options in
        try streamSimple(model: model, context: context, options: options)
    }

    let resolvedApiKey = (await config.getApiKey?(config.model.provider)) ?? config.apiKey

    let response = try await streamFunction(
        config.model,
        llmContext,
        SimpleStreamOptions(
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            signal: signal,
            apiKey: resolvedApiKey,
            transport: config.transport,
            reasoning: config.reasoning,
            sessionId: config.sessionId,
            thinkingBudgets: config.thinkingBudgets,
            onPayload: config.onPayload,
            maxRetryDelayMs: config.maxRetryDelayMs
        )
    )

    var partialMessage: AssistantMessage? = nil
    var addedPartial = false

    for await event in response {
        switch event {
        case .start(let partial):
            partialMessage = partial
            let agentMessage = AgentMessage.assistant(partial)
            updatedContext.messages.append(agentMessage)
            addedPartial = true
            await emit(.messageStart(message: agentMessage))

        case .textStart(_, let partial),
             .textDelta(_, _, let partial),
             .textEnd(_, _, let partial),
             .thinkingStart(_, let partial),
             .thinkingDelta(_, _, let partial),
             .thinkingEnd(_, _, let partial),
             .toolCallStart(_, let partial),
             .toolCallDelta(_, _, let partial),
             .toolCallEnd(_, _, let partial):
            if let _ = partialMessage {
                partialMessage = partial
                let agentMessage = AgentMessage.assistant(partial)
                if addedPartial {
                    updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
                } else {
                    updatedContext.messages.append(agentMessage)
                    addedPartial = true
                }
                await emit(.messageUpdate(message: agentMessage, assistantMessageEvent: event))
            }

        case .done, .error:
            let finalMessage = await response.result()
            let agentMessage = AgentMessage.assistant(finalMessage)
            if addedPartial {
                updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
            } else {
                updatedContext.messages.append(agentMessage)
                await emit(.messageStart(message: agentMessage))
            }
            await emit(.messageEnd(message: agentMessage))
            return (finalMessage, updatedContext)
        }
    }

    let finalMessage = await response.result()
    let agentMessage = AgentMessage.assistant(finalMessage)
    if addedPartial {
        updatedContext.messages[updatedContext.messages.count - 1] = agentMessage
    } else {
        updatedContext.messages.append(agentMessage)
        await emit(.messageStart(message: agentMessage))
    }
    await emit(.messageEnd(message: agentMessage))
    return (finalMessage, updatedContext)
}

// MARK: - Tool execution dispatcher

private func executeToolCalls(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> [ToolResultMessage] {
    let toolCalls = assistantMessage.content.compactMap { block -> ToolCall? in
        if case .toolCall(let toolCall) = block { return toolCall }
        return nil
    }

    if config.toolExecution == .sequential {
        return await executeToolCallsSequential(
            context: context,
            assistantMessage: assistantMessage,
            toolCalls: toolCalls,
            config: config,
            signal: signal,
            emit: emit
        )
    }
    return await executeToolCallsParallel(
        context: context,
        assistantMessage: assistantMessage,
        toolCalls: toolCalls,
        config: config,
        signal: signal,
        emit: emit
    )
}

// MARK: - Sequential tool execution

private func executeToolCallsSequential(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    toolCalls: [ToolCall],
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> [ToolResultMessage] {
    var results: [ToolResultMessage] = []

    for toolCall in toolCalls {
        await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        let preparation = await prepareToolCall(
            context: context,
            assistantMessage: assistantMessage,
            toolCall: toolCall,
            config: config,
            signal: signal
        )

        switch preparation {
        case .immediate(let result, let isError):
            results.append(await emitToolCallOutcome(toolCall: toolCall, result: result, isError: isError, emit: emit))
        case .prepared(let prepared):
            let executed = await executePreparedToolCall(prepared: prepared, signal: signal, emit: emit)
            results.append(await finalizeExecutedToolCall(
                context: context,
                assistantMessage: assistantMessage,
                prepared: prepared,
                executed: executed,
                config: config,
                signal: signal,
                emit: emit
            ))
        }
    }

    return results
}

// MARK: - Parallel tool execution

private func executeToolCallsParallel(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    toolCalls: [ToolCall],
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> [ToolResultMessage] {
    var results: [ToolResultMessage] = []
    var runnableCalls: [PreparedToolCallInfo] = []

    // Phase 1: prepare all tool calls sequentially
    for toolCall in toolCalls {
        await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))

        let preparation = await prepareToolCall(
            context: context,
            assistantMessage: assistantMessage,
            toolCall: toolCall,
            config: config,
            signal: signal
        )

        switch preparation {
        case .immediate(let result, let isError):
            results.append(await emitToolCallOutcome(toolCall: toolCall, result: result, isError: isError, emit: emit))
        case .prepared(let prepared):
            runnableCalls.append(prepared)
        }
    }

    // Phase 2: execute allowed tools concurrently
    let runningCalls: [(prepared: PreparedToolCallInfo, execution: Task<ExecutedToolCallOutcome, Never>)] = runnableCalls.map { prepared in
        let task = Task {
            await executePreparedToolCall(prepared: prepared, signal: signal, emit: emit)
        }
        return (prepared: prepared, execution: task)
    }

    // Phase 3: finalize in source order
    for running in runningCalls {
        let executed = await running.execution.value
        results.append(await finalizeExecutedToolCall(
            context: context,
            assistantMessage: assistantMessage,
            prepared: running.prepared,
            executed: executed,
            config: config,
            signal: signal,
            emit: emit
        ))
    }

    return results
}

// MARK: - Tool call preparation, execution, finalization

private struct PreparedToolCallInfo: Sendable {
    var toolCall: ToolCall
    var tool: AgentTool
    var args: [String: AnyCodable]
}

private enum ToolCallPreparation: Sendable {
    case prepared(PreparedToolCallInfo)
    case immediate(result: AgentToolResult, isError: Bool)
}

private struct ExecutedToolCallOutcome: Sendable {
    var result: AgentToolResult
    var isError: Bool
}

private func prepareToolCall(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    toolCall: ToolCall,
    config: AgentLoopConfig,
    signal: CancellationToken?
) async -> ToolCallPreparation {
    let tool = context.tools?.first { $0.name == toolCall.name }
    guard let tool else {
        return .immediate(
            result: createErrorToolResult("Tool \(toolCall.name) not found"),
            isError: true
        )
    }

    do {
        let validatedArgs = try validateToolArguments(tool: tool.aiTool, toolCall: toolCall)

        if let beforeToolCall = config.beforeToolCall {
            let beforeResult = await beforeToolCall(
                BeforeToolCallContext(
                    assistantMessage: assistantMessage,
                    toolCall: toolCall,
                    args: validatedArgs,
                    context: context
                ),
                signal
            )
            if beforeResult?.block == true {
                return .immediate(
                    result: createErrorToolResult(beforeResult?.reason ?? "Tool execution was blocked"),
                    isError: true
                )
            }
        }

        return .prepared(PreparedToolCallInfo(toolCall: toolCall, tool: tool, args: validatedArgs))
    } catch {
        return .immediate(
            result: createErrorToolResult(error.localizedDescription),
            isError: true
        )
    }
}

private func executePreparedToolCall(
    prepared: PreparedToolCallInfo,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> ExecutedToolCallOutcome {
    do {
        let result = try await prepared.tool.execute(prepared.toolCall.id, prepared.args, signal) { partialResult in
            Task {
                await emit(.toolExecutionUpdate(
                    toolCallId: prepared.toolCall.id,
                    toolName: prepared.toolCall.name,
                    args: prepared.toolCall.arguments,
                    partialResult: partialResult
                ))
            }
        }
        return ExecutedToolCallOutcome(result: result, isError: false)
    } catch {
        return ExecutedToolCallOutcome(
            result: createErrorToolResult(error.localizedDescription),
            isError: true
        )
    }
}

private func finalizeExecutedToolCall(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    prepared: PreparedToolCallInfo,
    executed: ExecutedToolCallOutcome,
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> ToolResultMessage {
    var result = executed.result
    var isError = executed.isError

    if let afterToolCall = config.afterToolCall {
        let afterResult = await afterToolCall(
            AfterToolCallContext(
                assistantMessage: assistantMessage,
                toolCall: prepared.toolCall,
                args: prepared.args,
                result: result,
                isError: isError,
                context: context
            ),
            signal
        )
        if let afterResult {
            result = AgentToolResult(
                content: afterResult.content ?? result.content,
                details: afterResult.details ?? result.details
            )
            isError = afterResult.isError ?? isError
        }
    }

    return await emitToolCallOutcome(toolCall: prepared.toolCall, result: result, isError: isError, emit: emit)
}

private func createErrorToolResult(_ message: String) -> AgentToolResult {
    AgentToolResult(
        content: [.text(TextContent(text: message))],
        details: AnyCodable([String: Any]())
    )
}

private func emitToolCallOutcome(
    toolCall: ToolCall,
    result: AgentToolResult,
    isError: Bool,
    emit: @escaping AgentEventSink
) async -> ToolResultMessage {
    await emit(.toolExecutionEnd(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        result: result,
        isError: isError
    ))

    let toolResultMessage = ToolResultMessage(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        content: result.content,
        details: result.details,
        isError: isError
    )

    await emit(.messageStart(message: .toolResult(toolResultMessage)))
    await emit(.messageEnd(message: .toolResult(toolResultMessage)))
    return toolResultMessage
}

// MARK: - Helpers

private func buildErrorAssistantMessage(model: Model, reason: StopReason, message: String) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: ""))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: reason,
        errorMessage: message
    )
}
