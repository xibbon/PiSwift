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
        do {
            let messages = try await runAgentLoopContinue(
                context: context,
                config: config,
                emit: { event in stream.push(event) },
                signal: signal,
                streamFn: streamFn
            )
            stream.end(messages)
        } catch {
            stream.end([])
        }
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
) async throws -> [AgentMessage] {
    guard !context.messages.isEmpty else {
        throw AgentLoopError.emptyContext
    }
    if let last = context.messages.last, last.role == "assistant" {
        throw AgentLoopError.lastMessageAssistant
    }

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
    var config = config
    var lastCompletedTurn: PrepareNextTurnContext?
    var pendingMessages = (await config.getSteeringMessages?()) ?? []

    while true {
        var hasMoreToolCalls = true

        while hasMoreToolCalls || !pendingMessages.isEmpty {
            do {
                if let lastCompletedTurn {
                    if let update = try await config.prepareNextTurn?(lastCompletedTurn) {
                        context = update.context ?? context
                        config.model = update.model ?? config.model
                        if let level = update.thinkingLevel {
                            config.reasoning = ReasoningEffort(rawValue: level.rawValue)
                        }
                    }
                    if pendingMessages.isEmpty {
                        pendingMessages = (await config.getSteeringMessages?()) ?? []
                    }
                    await emit(.turnStart)
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

                switch assistantMessage.stopReason {
                case .pending, .error, .aborted, .deferred:
                    await emit(.turnEnd(message: agentMessage, toolResults: []))
                    await emit(.agentEnd(messages: messages))
                    return messages
                case .stop, .length, .toolUse:
                    break
                }

                let toolCalls = assistantMessage.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let toolCall) = block { return toolCall }
                    return nil
                }
                hasMoreToolCalls = !toolCalls.isEmpty

                var toolResults: [ToolResultMessage] = []
                if hasMoreToolCalls {
                    // A length stop means the model output was cut off. Tool-call arguments
                    // from that message may be incomplete even when a salvage parser accepted
                    // them, so report errors instead of executing unsafe calls.
                    let outcome = assistantMessage.stopReason == .length
                        ? await failToolCallsFromTruncatedMessage(toolCalls, emit: emit)
                        : await executeToolCalls(
                            context: context,
                            assistantMessage: assistantMessage,
                            config: config,
                            signal: signal,
                            emit: emit
                        )
                    toolResults = outcome.results

                    for result in toolResults {
                        let agentResult = AgentMessage.toolResult(result)
                        context.messages.append(agentResult)
                        messages.append(agentResult)
                    }

                    // v0.69.0: terminating tool results skip the automatic follow-up LLM turn.
                    // When every finalized result in this batch sets terminate=true, drop out of
                    // the inner loop without re-prompting the model.
                    if outcome.terminate {
                        hasMoreToolCalls = false
                    }
                }

                await emit(.turnEnd(message: agentMessage, toolResults: toolResults))

                let completedTurn = PrepareNextTurnContext(
                    message: assistantMessage,
                    toolResults: toolResults,
                    context: context,
                    newMessages: messages
                )
                lastCompletedTurn = completedTurn
                if await config.shouldStopAfterTurn?(completedTurn) == true {
                    await emit(.agentEnd(messages: messages))
                    return messages
                }
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

    let modelAuth = await config.getModelAuth?(config.model)
    let providerApiKey = await config.getApiKey?(config.model.provider)
    let resolvedApiKey = modelAuth?.apiKey ?? providerApiKey ?? config.apiKey
    let resolvedHeaders = mergeHeaders(config.headers, modelAuth?.headers)
    let resolvedModel = applyBaseUrlOverride(config.model, modelAuth?.baseUrl)

    let response = try await streamFunction(
        resolvedModel,
        llmContext,
        SimpleStreamOptions(
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            signal: signal,
            apiKey: resolvedApiKey,
            transport: config.transport,
            reasoning: config.reasoning,
            cacheRetention: config.cacheRetention,
            sessionId: config.sessionId,
            thinkingBudgets: config.thinkingBudgets,
            headers: resolvedHeaders,
            onPayload: config.onPayload,
            maxRetryDelayMs: config.maxRetryDelayMs,
            metadata: config.metadata,
            onResponse: config.onResponse,
            timeoutMs: config.timeoutMs,
            websocketConnectTimeoutMs: config.websocketConnectTimeoutMs,
            maxRetries: config.maxRetries
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

private func mergeHeaders(_ base: ProviderHeaders?, _ override: ProviderHeaders?) -> ProviderHeaders? {
    mergeProviderHeaders(base, override)
}

private func applyBaseUrlOverride(_ model: Model, _ baseUrl: String?) -> Model {
    guard let baseUrl, !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, baseUrl != model.baseUrl else {
        return model
    }
    return Model(
        id: model.id,
        name: model.name,
        api: model.api,
        provider: model.provider,
        baseUrl: baseUrl,
        reasoning: model.reasoning,
        input: model.input,
        cost: model.cost,
        contextWindow: model.contextWindow,
        maxTokens: model.maxTokens,
        samplingParams: model.samplingParams,
        headers: model.headers,
        compat: model.compat,
        thinkingLevelMap: model.thinkingLevelMap
    )
}

// MARK: - Tool execution dispatcher

/// Outcome of executing one assistant turn's tool batch.
/// `terminate` is true when every finalized result in the batch opted into early termination
/// (via `AgentToolResult.terminate == true`). The loop uses this to skip the automatic
/// follow-up LLM turn after a terminating tool batch.
struct ToolBatchOutcome: Sendable {
    var results: [ToolResultMessage]
    var terminate: Bool
}

private func failToolCallsFromTruncatedMessage(
    _ toolCalls: [ToolCall],
    emit: @escaping AgentEventSink
) async -> ToolBatchOutcome {
    var results: [ToolResultMessage] = []
    for toolCall in toolCalls {
        await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
        let result = createErrorToolResult(
            "Tool call \"\(toolCall.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
        )
        results.append(await emitToolCallOutcome(toolCall: toolCall, result: result, isError: true, emit: emit))
    }
    return ToolBatchOutcome(results: results, terminate: false)
}

private func executeToolCalls(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> ToolBatchOutcome {
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
) async -> ToolBatchOutcome {
    var results: [ToolResultMessage] = []
    var allTerminate = !toolCalls.isEmpty

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
            if result.terminate != true { allTerminate = false }
        case .prepared(let prepared):
            let executed = await executePreparedToolCall(prepared: prepared, signal: signal, emit: emit)
            let finalized = await finalizeExecutedToolCall(
                context: context,
                assistantMessage: assistantMessage,
                prepared: prepared,
                executed: executed,
                config: config,
                signal: signal
            )
            let message = await emitToolCallOutcome(
                toolCall: finalized.toolCall,
                result: finalized.result,
                isError: finalized.isError,
                emit: emit
            )
            results.append(message)
            if !finalized.terminate { allTerminate = false }
        }
    }

    return ToolBatchOutcome(results: results, terminate: allTerminate)
}

// MARK: - Parallel tool execution

private func executeToolCallsParallel(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    toolCalls: [ToolCall],
    config: AgentLoopConfig,
    signal: CancellationToken?,
    emit: @escaping AgentEventSink
) async -> ToolBatchOutcome {
    var finalizedByIndex: [Int: FinalizedToolCall] = [:]
    var runnableCalls: [(index: Int, prepared: PreparedToolCallInfo)] = []

    // Phase 1: prepare all tool calls sequentially
    for (index, toolCall) in toolCalls.enumerated() {
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
            let finalized = await emitToolExecutionEndOnly(
                toolCall: toolCall,
                result: result,
                isError: isError,
                emit: emit
            )
            finalizedByIndex[index] = finalized
        case .prepared(let prepared):
            runnableCalls.append((index, prepared))
        }
    }

    // Phase 2: execute allowed tools concurrently and emit tool_execution_end as each
    // finalized tool completes. Tool-result message artifacts are assembled later in
    // assistant source order from finalizedByIndex.
    await withTaskGroup(of: (Int, FinalizedToolCall).self) { group in
        for runnable in runnableCalls {
            group.addTask {
                if signal?.isCancelled == true {
                    return (runnable.index, FinalizedToolCall(
                        toolCall: runnable.prepared.toolCall,
                        result: createErrorToolResult("Operation aborted"),
                        isError: true,
                        terminate: false
                    ))
                }
                let executed = await executePreparedToolCall(prepared: runnable.prepared, signal: signal, emit: emit)
                let finalized = await finalizeExecutedToolCall(
                    context: context,
                    assistantMessage: assistantMessage,
                    prepared: runnable.prepared,
                    executed: executed,
                    config: config,
                    signal: signal
                )
                return (runnable.index, finalized)
            }
        }

        for await (index, finalized) in group {
            await emitToolExecutionEndOnly(
                toolCall: finalized.toolCall,
                result: finalized.result,
                isError: finalized.isError,
                emit: emit
            )
            finalizedByIndex[index] = finalized
        }
    }

    var results: [ToolResultMessage] = []
    var allTerminate = !toolCalls.isEmpty
    for index in toolCalls.indices {
        guard let finalized = finalizedByIndex[index] else { continue }
        let message = await emitToolResultMessage(
            toolCall: finalized.toolCall,
            result: finalized.result,
            isError: finalized.isError,
            emit: emit
        )
        results.append(message)
        if !finalized.terminate { allTerminate = false }
    }

    return ToolBatchOutcome(results: results, terminate: allTerminate && results.count == toolCalls.count)
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
        // prepareArguments runs BEFORE schema validation so legacy payloads can be reshaped
        // (e.g., the built-in edit tool folds single-edit shape into edits[]).
        // Returning nil keeps the raw arguments unchanged.
        var rewrittenToolCall = toolCall
        if let prepare = tool.prepareArguments,
           let rewritten = try await prepare(toolCall.arguments) {
            rewrittenToolCall.arguments = rewritten
        }

        let validatedArgs = try validateToolArguments(tool: tool.aiTool, toolCall: rewrittenToolCall)

        if let beforeToolCall = config.beforeToolCall {
            let beforeResult = await beforeToolCall(
                BeforeToolCallContext(
                    assistantMessage: assistantMessage,
                    toolCall: rewrittenToolCall,
                    args: validatedArgs,
                    context: context
                ),
                signal
            )
            if signal?.isCancelled == true {
                return .immediate(
                    result: createErrorToolResult("Operation aborted"),
                    isError: true
                )
            }
            if beforeResult?.block == true {
                return .immediate(
                    result: createErrorToolResult(
                        beforeResult?.reason ?? "Tool execution was blocked",
                        terminate: beforeResult?.terminate == true ? true : nil
                    ),
                    isError: true
                )
            }
        }

        if signal?.isCancelled == true {
            return .immediate(
                result: createErrorToolResult("Operation aborted"),
                isError: true
            )
        }

        return .prepared(PreparedToolCallInfo(toolCall: rewrittenToolCall, tool: tool, args: validatedArgs))
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
    // Collect update event tasks so we can await them all before returning,
    // matching upstream behavior that guarantees all update emissions complete.
    let pendingUpdates = LockedState<[Task<Void, Never>]>([])
    let finalized = LockedState(false)

    do {
        let result = try await prepared.tool.execute(prepared.toolCall.id, prepared.args, signal) { partialResult in
            guard !finalized.withLock({ $0 }) else { return }
            let task = Task {
                await emit(.toolExecutionUpdate(
                    toolCallId: prepared.toolCall.id,
                    toolName: prepared.toolCall.name,
                    args: prepared.toolCall.arguments,
                    partialResult: partialResult
                ))
            }
            pendingUpdates.withLock { $0.append(task) }
        }
        finalized.withLock { $0 = true }
        // Await all pending update emissions before returning
        for task in pendingUpdates.withLock({ $0 }) {
            await task.value
        }
        return ExecutedToolCallOutcome(result: result, isError: false)
    } catch {
        finalized.withLock { $0 = true }
        // Await pending updates even on error path
        for task in pendingUpdates.withLock({ $0 }) {
            await task.value
        }
        return ExecutedToolCallOutcome(
            result: createErrorToolResult(error.localizedDescription),
            isError: true
        )
    }
}

private struct FinalizedToolCall: Sendable {
    var toolCall: ToolCall
    var result: AgentToolResult
    var isError: Bool
    var terminate: Bool
}

private func finalizeExecutedToolCall(
    context: AgentContext,
    assistantMessage: AssistantMessage,
    prepared: PreparedToolCallInfo,
    executed: ExecutedToolCallOutcome,
    config: AgentLoopConfig,
    signal: CancellationToken?
) async -> FinalizedToolCall {
    var result = executed.result
    var isError = executed.isError

    if let afterToolCall = config.afterToolCall {
        do {
            let afterResult = try await afterToolCall(
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
                    details: afterResult.details ?? result.details,
                    usage: afterResult.usage ?? result.usage,
                    addedToolNames: result.addedToolNames,
                    terminate: afterResult.terminate ?? result.terminate
                )
                isError = afterResult.isError ?? isError
            }
        } catch {
            result = createErrorToolResult(error.localizedDescription)
            isError = true
        }
    }

    return FinalizedToolCall(
        toolCall: prepared.toolCall,
        result: result,
        isError: isError,
        terminate: result.terminate == true
    )
}

private func createErrorToolResult(_ message: String, terminate: Bool? = nil) -> AgentToolResult {
    AgentToolResult(
        content: [.text(TextContent(text: message))],
        details: AnyCodable([String: Any]()),
        terminate: terminate
    )
}

private func emitToolCallOutcome(
    toolCall: ToolCall,
    result: AgentToolResult,
    isError: Bool,
    emit: @escaping AgentEventSink
) async -> ToolResultMessage {
    await emitToolExecutionEndOnly(toolCall: toolCall, result: result, isError: isError, emit: emit)
    return await emitToolResultMessage(toolCall: toolCall, result: result, isError: isError, emit: emit)
}

@discardableResult
private func emitToolExecutionEndOnly(
    toolCall: ToolCall,
    result: AgentToolResult,
    isError: Bool,
    emit: @escaping AgentEventSink
) async -> FinalizedToolCall {
    await emit(.toolExecutionEnd(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        result: result,
        isError: isError
    ))

    return FinalizedToolCall(
        toolCall: toolCall,
        result: result,
        isError: isError,
        terminate: result.terminate == true
    )
}

private func emitToolResultMessage(
    toolCall: ToolCall,
    result: AgentToolResult,
    isError: Bool,
    emit: @escaping AgentEventSink
) async -> ToolResultMessage {
    let toolResultMessage = ToolResultMessage(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        content: result.content,
        details: result.details,
        usage: result.usage,
        addedToolNames: result.addedToolNames,
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
