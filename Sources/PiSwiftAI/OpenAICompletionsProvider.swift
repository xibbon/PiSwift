import Foundation
import OpenAI

public func streamOpenAICompletions(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()

    Task {
        var output = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )

        do {
            let compat = resolveCompat(model: model)
            let query = try buildCompletionsQuery(model: model, context: context, options: options, compat: compat)
            let openAIStream: AsyncThrowingStream<ChatStreamResult, Error>
            if compat.thinkingFormat == .zai {
                openAIStream = try streamZaiCompletions(model: model, context: context, options: options, query: query)
            } else if model.provider == "github-copilot" {
                openAIStream = try streamManualOpenAICompletions(model: model, options: options, query: query)
            } else {
                emitPayload(options.onPayload, payload: query)
                let middlewares = buildCompletionsMiddlewares(model: model, compat: compat, options: options)
                let client = try makeOpenAIClient(
                    model: model,
                    apiKey: options.apiKey,
                    headers: options.headers,
                    timeoutMs: options.timeoutMs,
                    middlewares: middlewares
                )
                openAIStream = client.chatsStream(query: query)
            }
            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var currentToolCallArgs = ""
            var currentToolCallId: String? = nil
            var currentToolCallIndex: Int? = nil
            var toolCallIdByIndex: [Int: String] = [:]

            func finishCurrentBlock() {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let textContent):
                    stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: output))
                case .thinking(let thinkingContent):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: output))
                case .toolCall(var toolCall):
                    let parsed = parseStreamingJSON(currentToolCallArgs)
                    toolCall.arguments = parsed
                    output.content[index] = .toolCall(toolCall)
                    stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: output))
                default:
                    break
                }
                currentBlockIndex = nil
                currentBlockKind = nil
                currentToolCallArgs = ""
                currentToolCallId = nil
                currentToolCallIndex = nil
            }

            for try await chunk in openAIStream {
                if options.signal?.isCancelled == true {
                    throw OpenAICompletionsStreamError.aborted
                }

                // Capture response ID from chunk
                if output.responseId == nil, !chunk.id.isEmpty {
                    output.responseId = chunk.id
                }

                if let usage = chunk.usage {
                    let cachedTokens = usage.promptTokensDetails?.cachedTokens ?? 0
                    let input = usage.promptTokens - cachedTokens
                    let outputTokens = usage.completionTokens
                    output.usage = Usage(
                        input: input,
                        output: outputTokens,
                        cacheRead: cachedTokens,
                        cacheWrite: 0,
                        totalTokens: usage.totalTokens
                    )
                    calculateCost(model: model, usage: &output.usage)
                }

                guard let choice = chunk.choices.first else { continue }
                if let finishReason = choice.finishReason {
                    let result = mapStopReason(finishReason)
                    output.stopReason = result.stopReason
                    if let errorMessage = result.errorMessage {
                        output.errorMessage = errorMessage
                    }
                }

                let delta = choice.delta

                if let content = delta.content, !content.isEmpty {
                    if currentBlockKind != "text" {
                        finishCurrentBlock()
                        let textBlock = TextContent(text: "")
                        output.content.append(.text(textBlock))
                        currentBlockIndex = output.content.count - 1
                        currentBlockKind = "text"
                        stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                    }

                    if let index = currentBlockIndex, case .text(var textContent) = output.content[index] {
                        textContent.text += content
                        output.content[index] = .text(textContent)
                        stream.push(.textDelta(contentIndex: index, delta: content, partial: output))
                    }
                }

                if let reasoning = delta.reasoning, !reasoning.isEmpty {
                    if currentBlockKind != "thinking" {
                        finishCurrentBlock()
                        let thinkingBlock = ThinkingContent(thinking: "", thinkingSignature: "reasoning")
                        output.content.append(.thinking(thinkingBlock))
                        currentBlockIndex = output.content.count - 1
                        currentBlockKind = "thinking"
                        stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                    }

                    if let index = currentBlockIndex, case .thinking(var thinkingContent) = output.content[index] {
                        thinkingContent.thinking += reasoning
                        output.content[index] = .thinking(thinkingContent)
                        stream.push(.thinkingDelta(contentIndex: index, delta: reasoning, partial: output))
                    }
                }

                if let toolCalls = delta.toolCalls {
                    for toolCall in toolCalls {
                        let resolved = resolveToolCallIdentity(
                            toolCall: toolCall,
                            currentToolCallId: currentToolCallId,
                            currentToolCallIndex: currentToolCallIndex,
                            toolCallIdByIndex: &toolCallIdByIndex,
                            requiresMistral: false
                        )
                        let index = resolved.index
                        let normalizedId = resolved.id

                        if currentBlockKind != "toolCall" || currentToolCallId != normalizedId {
                            finishCurrentBlock()
                            let tool = ToolCall(id: normalizedId, name: toolCall.function?.name ?? "", arguments: [:])
                            output.content.append(.toolCall(tool))
                            currentBlockIndex = output.content.count - 1
                            currentBlockKind = "toolCall"
                            currentToolCallArgs = ""
                            currentToolCallId = normalizedId
                            currentToolCallIndex = index
                            stream.push(.toolCallStart(contentIndex: currentBlockIndex!, partial: output))
                        }

                        if let index = currentBlockIndex, case .toolCall(var tool) = output.content[index] {
                            if let name = toolCall.function?.name, !name.isEmpty {
                                tool.name = name
                            }
                            if let argsDelta = toolCall.function?.arguments {
                                currentToolCallArgs += argsDelta
                                tool.arguments = parseStreamingJSON(currentToolCallArgs)
                                output.content[index] = .toolCall(tool)
                                stream.push(.toolCallDelta(contentIndex: index, delta: argsDelta, partial: output))
                            }
                        }
                    }
                }
            }

            finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw OpenAICompletionsStreamError.aborted
            }

            if output.stopReason == .aborted {
                throw OpenAICompletionsStreamError.aborted
            }
            if output.stopReason == .error {
                throw OpenAICompletionsStreamError.apiError(output.errorMessage ?? "Provider returned an error stop reason")
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = describeOpenAIError(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private struct StopReasonResult {
    var stopReason: StopReason
    var errorMessage: String?
}

private func mapStopReason(_ reason: ChatStreamResult.Choice.FinishReason) -> StopReasonResult {
    switch reason {
    case .stop:
        return StopReasonResult(stopReason: .stop)
    case .length:
        return StopReasonResult(stopReason: .length)
    case .toolCalls, .functionCall:
        return StopReasonResult(stopReason: .toolUse)
    case .contentFilter:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider finish_reason: content_filter")
    default:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider finish_reason: \(reason)")
    }
}

private struct ResolvedOpenAICompat {
    let supportsStore: Bool
    let supportsDeveloperRole: Bool
    let supportsReasoningEffort: Bool
    let supportsUsageInStreaming: Bool
    let maxTokensField: OpenAICompatMaxTokensField
    let requiresToolResultName: Bool
    let requiresAssistantAfterToolResult: Bool
    let requiresThinkingAsText: Bool
    let requiresMistralToolIds: Bool
    let thinkingFormat: OpenAICompatThinkingFormat
    let supportsStrictMode: Bool
    let reasoningEffortMap: [ThinkingLevel: String]?
    /// v0.70.1: when true, replayed assistant messages must include a `reasoning_content` field
    /// (DeepSeek V4 requirement). Empty string is injected when no thinking content exists.
    let requiresReasoningContentOnAssistantMessages: Bool
}

private func detectCompat(model: Model) -> ResolvedOpenAICompat {
    let baseUrl = model.baseUrl.lowercased()
    let provider = model.provider.lowercased()
    let isCerebras = provider == "cerebras" || baseUrl.contains("cerebras.ai")
    let isGrok = provider == "xai" || baseUrl.contains("api.x.ai")
    let isGroq = provider == "groq" || baseUrl.contains("groq.com")
    let isChutes = baseUrl.contains("chutes.ai")
    let isZai = provider == "zai" || baseUrl.contains("z.ai")
    let isDeepSeek = provider == "deepseek" || baseUrl.contains("deepseek.com")
    let isOpencode = provider == "opencode" || baseUrl.contains("opencode.ai")
    let isOpenRouter = provider == "openrouter" || baseUrl.contains("openrouter.ai")

    let isNonStandard = isCerebras || isGrok || isChutes || isDeepSeek || isZai || isOpencode || isOpenRouter
    let useMaxTokens = isChutes

    let thinkingFormat: OpenAICompatThinkingFormat
    if isZai {
        thinkingFormat = .zai
    } else if isDeepSeek {
        thinkingFormat = .deepseek
    } else if isOpenRouter {
        thinkingFormat = .openrouter
    } else {
        thinkingFormat = .openai
    }

    let reasoningEffortMap: [ThinkingLevel: String]?
    if isDeepSeek {
        reasoningEffortMap = [
            .minimal: "high",
            .low: "high",
            .medium: "high",
            .high: "high",
            .xhigh: "max",
        ]
    } else if isGroq {
        reasoningEffortMap = [
            .minimal: "default",
            .low: "default",
            .medium: "default",
            .high: "default",
            .xhigh: "default",
        ]
    } else {
        reasoningEffortMap = nil
    }

    return ResolvedOpenAICompat(
        supportsStore: !isNonStandard,
        supportsDeveloperRole: !isNonStandard,
        supportsReasoningEffort: !isGrok && !isZai,
        supportsUsageInStreaming: true,
        maxTokensField: useMaxTokens ? .maxTokens : .maxCompletionTokens,
        requiresToolResultName: false,
        requiresAssistantAfterToolResult: false,
        requiresThinkingAsText: false,
        requiresMistralToolIds: false,
        thinkingFormat: thinkingFormat,
        supportsStrictMode: true,
        reasoningEffortMap: reasoningEffortMap,
        requiresReasoningContentOnAssistantMessages: isDeepSeek
    )
}

private func resolveCompat(model: Model) -> ResolvedOpenAICompat {
    let detected = detectCompat(model: model)
    guard let compat = model.compat else { return detected }

    return ResolvedOpenAICompat(
        supportsStore: compat.supportsStore ?? detected.supportsStore,
        supportsDeveloperRole: compat.supportsDeveloperRole ?? detected.supportsDeveloperRole,
        supportsReasoningEffort: compat.supportsReasoningEffort ?? detected.supportsReasoningEffort,
        supportsUsageInStreaming: compat.supportsUsageInStreaming ?? detected.supportsUsageInStreaming,
        maxTokensField: compat.maxTokensField ?? detected.maxTokensField,
        requiresToolResultName: compat.requiresToolResultName ?? detected.requiresToolResultName,
        requiresAssistantAfterToolResult: compat.requiresAssistantAfterToolResult ?? detected.requiresAssistantAfterToolResult,
        requiresThinkingAsText: compat.requiresThinkingAsText ?? detected.requiresThinkingAsText,
        requiresMistralToolIds: compat.requiresMistralToolIds ?? detected.requiresMistralToolIds,
        thinkingFormat: compat.thinkingFormat ?? detected.thinkingFormat,
        supportsStrictMode: compat.supportsStrictMode ?? detected.supportsStrictMode,
        reasoningEffortMap: compat.reasoningEffortMap ?? detected.reasoningEffortMap,
        requiresReasoningContentOnAssistantMessages: compat.requiresReasoningContentOnAssistantMessages ?? detected.requiresReasoningContentOnAssistantMessages
    )
}

func resolveToolCallIdentity(
    toolCall: ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall,
    currentToolCallId: String?,
    currentToolCallIndex: Int?,
    toolCallIdByIndex: inout [Int: String],
    requiresMistral: Bool = false
) -> (id: String, index: Int) {
    let index = toolCall.index ?? currentToolCallIndex ?? 0
    if let id = toolCall.id, !id.isEmpty {
        toolCallIdByIndex[index] = id
        return (id, index)
    }
    if let existing = toolCallIdByIndex[index] {
        return (existing, index)
    }
    if let current = currentToolCallId, currentToolCallIndex == index {
        return (current, index)
    }
    let fallback = "toolcall_\(index)"
    toolCallIdByIndex[index] = fallback
    return (fallback, index)
}

private func hasToolHistory(_ messages: [Message]) -> Bool {
    for msg in messages {
        switch msg {
        case .toolResult:
            return true
        case .assistant(let assistant):
            if assistant.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                return true
            }
        case .user:
            continue
        }
    }
    return false
}

private func buildCompletionsQuery(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions,
    compat: ResolvedOpenAICompat
) throws -> ChatQuery {
    let messages = convertCompletionsMessages(model: model, context: context, compat: compat)

    let toolChoice = options.toolChoice.map { choice -> ChatQuery.ChatCompletionFunctionCallOptionParam in
        switch choice {
        case .auto:
            return .auto
        case .none:
            return .none
        case .required:
            return .required
        case .function(let name):
            return .function(name)
        }
    }

    let tools: [ChatQuery.ChatCompletionToolParam]? = {
        // v0.70.3: omit `tools` field entirely when no tools are active. DashScope/Aliyun Qwen
        // reject `"tools": []` with HTTP 400 `"[] is too short - 'tools'"`. The legacy LiteLLM/
        // Anthropic-proxy workaround (sending `[]` to keep tool history coherent) is preserved
        // only when the conversation actually contains tool history.
        if let tools = context.tools {
            let converted = convertCompletionsTools(tools, compat: compat)
            if converted.isEmpty {
                return hasToolHistory(context.messages) ? [] : nil
            }
            return converted
        }
        if hasToolHistory(context.messages) {
            return []
        }
        return nil
    }()

    let reasoningEffort: ChatQuery.ReasoningEffort? = {
        guard let effort = options.reasoningEffort,
              model.reasoning,
              compat.supportsReasoningEffort,
              compat.thinkingFormat == .openai else { return nil }
        // Use provider-specific reasoning effort map if available
        if let mapped = mappedThinkingLevel(model: model, level: effort) ?? compat.reasoningEffortMap?[effort] {
            return .customValue(mapped)
        }
        return mapChatReasoningEffort(effort)
    }()

    let maxCompletionTokens = options.maxTokens
    let streamOptions: ChatQuery.StreamOptions? = compat.supportsUsageInStreaming ? .init(includeUsage: true) : nil

    let query = ChatQuery(
        messages: messages,
        model: model.id,
        reasoningEffort: reasoningEffort,
        maxCompletionTokens: maxCompletionTokens,
        store: compat.supportsStore ? false : nil,
        temperature: options.temperature,
        toolChoice: toolChoice,
        tools: tools,
        stream: true,
        streamOptions: streamOptions
    )

    return query
}

private func mapChatReasoningEffort(_ effort: ThinkingLevel) -> ChatQuery.ReasoningEffort {
    switch effort {
    case .minimal:
        return .minimal
    case .low:
        return .low
    case .medium:
        return .medium
    case .high, .xhigh:
        return .high
    }
}

private func convertCompletionsMessages(
    model: Model,
    context: Context,
    compat: ResolvedOpenAICompat
) -> [ChatQuery.ChatCompletionMessageParam] {
    var params: [ChatQuery.ChatCompletionMessageParam] = []

    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, model, _ in
        if id.contains("|") {
            let callId = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
            let sanitized = callId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            return String(sanitized.prefix(40))
        }

        if model.provider == "openai" {
            return id.count > 40 ? String(id.prefix(40)) : id
        }

        if model.provider == "github-copilot", model.id.lowercased().contains("claude") {
            let sanitized = id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            return String(sanitized.prefix(64))
        }

        return id
    }

    let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: normalizeToolCallId)

    if let systemPrompt = context.systemPrompt {
        let role: ChatQuery.ChatCompletionMessageParam.Role = (model.reasoning && compat.supportsDeveloperRole) ? .developer : .system
        let content = ChatQuery.ChatCompletionMessageParam.TextContent.textContent(sanitizeSurrogates(systemPrompt))
        switch role {
        case .developer:
            params.append(.developer(.init(content: content)))
        default:
            params.append(.system(.init(content: content)))
        }
    }

    var lastRole: String? = nil

    for msg in transformed {
        if compat.requiresAssistantAfterToolResult && lastRole == "toolResult" && msg.role == "user" {
            params.append(.assistant(.init(content: .textContent("I have processed the tool results."))))
        }

        switch msg {
        case .user(let user):
            switch user.content {
            case .text(let text):
                params.append(.user(.init(content: .string(sanitizeSurrogates(text)))))
            case .blocks(let blocks):
                let parts = blocks.compactMap { block -> ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart? in
                    switch block {
                    case .text(let textContent):
                        return .text(.init(text: sanitizeSurrogates(textContent.text)))
                    case .image(let imageContent):
                        return .image(.init(imageUrl: .init(url: "data:\(imageContent.mimeType);base64,\(imageContent.data)", detail: .auto)))
                    default:
                        return nil
                    }
                }
                let filtered = model.input.contains(.image) ? parts : parts.filter { part in
                    if case .image = part { return false }
                    return true
                }
                if !filtered.isEmpty {
                    params.append(.user(.init(content: .contentParts(filtered))))
                }
            }
        case .assistant(let assistant):
            var assistantMessage = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam()
            let textBlocks = assistant.content.compactMap { block -> String? in
                if case .text(let textContent) = block {
                    let trimmed = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : sanitizeSurrogates(textContent.text)
                }
                return nil
            }

            var contentText = textBlocks.joined()

            let thinkingBlocks = assistant.content.compactMap { block -> ThinkingContent? in
                if case .thinking(let thinking) = block {
                    let trimmed = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : thinking
                }
                return nil
            }

            if !thinkingBlocks.isEmpty && compat.requiresThinkingAsText {
                let thinkingText = thinkingBlocks.map { $0.thinking }.joined(separator: "\n\n")
                contentText = thinkingText + contentText
            }

            if !contentText.isEmpty {
                assistantMessage = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam(content: .textContent(contentText))
            }

            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let toolCall) = block { return toolCall }
                return nil
            }

            if !toolCalls.isEmpty {
                assistantMessage = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam(
                    content: compat.requiresAssistantAfterToolResult ? .textContent("") : (contentText.isEmpty ? nil : .textContent(contentText)),
                    toolCalls: toolCalls.map {
                        .init(
                            id: $0.id,
                            function: .init(arguments: jsonString(from: $0.arguments), name: $0.name)
                        )
                    }
                )
            }

            if assistantMessage.content != nil || assistantMessage.toolCalls != nil {
                params.append(.assistant(assistantMessage))
            }
        case .toolResult(let toolResult):
            let text = toolResult.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined(separator: "\n")

            let hasImages = toolResult.content.contains { block in
                if case .image = block { return true }
                return false
            }

            let toolText = sanitizeSurrogates(text.isEmpty ? "(see attached image)" : text)
            let toolMessage = ChatQuery.ChatCompletionMessageParam.ToolMessageParam(
                content: .textContent(toolText),
                toolCallId: toolResult.toolCallId
            )
            params.append(.tool(toolMessage))

            if hasImages && model.input.contains(.image) {
                var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [
                    .text(.init(text: "Attached image(s) from tool result:"))
                ]
                for block in toolResult.content {
                    if case .image(let image) = block {
                        parts.append(.image(.init(imageUrl: .init(url: "data:\(image.mimeType);base64,\(image.data)", detail: .auto))))
                    }
                }
                params.append(.user(.init(content: .contentParts(parts))))
            }
        }

        lastRole = msg.role
    }

    return params
}

private func convertCompletionsTools(_ tools: [AITool], compat: ResolvedOpenAICompat) -> [ChatQuery.ChatCompletionToolParam] {
    tools.compactMap { tool in
        let schema = openAIJSONSchema(from: tool.parameters)
        let definition = ChatQuery.ChatCompletionToolParam.FunctionDefinition(
            name: tool.name,
            description: tool.description,
            parameters: schema,
            strict: compat.supportsStrictMode ? false : nil
        )
        return .init(function: definition)
    }
}

private func streamZaiCompletions(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions,
    query: ChatQuery
) throws -> AsyncThrowingStream<ChatStreamResult, Error> {
    guard let apiKey = options.apiKey, !apiKey.isEmpty else {
        throw StreamError.missingApiKey(model.provider)
    }

    var request = URLRequest(url: chatCompletionsUrl(baseUrl: model.baseUrl))
    request.timeoutInterval = Double(options.timeoutMs ?? 60_000) / 1000.0
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    var mergedHeaders = model.headers ?? [:]
    if let headers = options.headers {
        for (key, value) in headers {
            mergedHeaders[key] = value
        }
    }
    for (key, value) in mergedHeaders {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let body = try buildZaiRequestBody(query: query, model: model, options: options)
    request.httpBody = body
    emitPayload(options.onPayload, data: body)
    return streamChatCompletions(request: request, signal: options.signal, onResponse: options.onResponse)
}

private func buildZaiRequestBody(query: ChatQuery, model: Model, options: OpenAICompletionsOptions) throws -> Data {
    let encoded = try JSONEncoder().encode(query)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw OpenAICompletionsStreamError.invalidResponse
    }

    if model.reasoning {
        let enabled = options.reasoningEffort != nil
        object["thinking"] = ["type": enabled ? "enabled" : "disabled"]
    }

    return try JSONSerialization.data(withJSONObject: object, options: [])
}

private func buildCompletionsMiddlewares(
    model: Model,
    compat: ResolvedOpenAICompat,
    options: OpenAICompletionsOptions
) -> [OpenAIMiddleware] {
    var middlewares: [OpenAIMiddleware] = []
    if compat.thinkingFormat == .qwen, model.reasoning {
        let enabled = options.reasoningEffort != nil
        middlewares.append(OpenAICompletionsThinkingMiddleware(enableThinking: enabled))
    }
    if compat.thinkingFormat == .qwenChatTemplate, model.reasoning {
        let enabled = options.reasoningEffort != nil
        middlewares.append(OpenAICompletionsChatTemplateMiddleware(enableThinking: enabled))
    }
    if compat.thinkingFormat == .openrouter, model.reasoning {
        let enabled = options.reasoningEffort != nil
        let effort = options.reasoningEffort
        middlewares.append(OpenAICompletionsOpenRouterReasoningMiddleware(enableReasoning: enabled, effort: effort))
    }
    if compat.thinkingFormat == .deepseek, model.reasoning {
        let enabled = options.reasoningEffort != nil
        let mappedEffort: String?
        if let effort = options.reasoningEffort {
            mappedEffort = mappedThinkingLevel(model: model, level: effort) ?? compat.reasoningEffortMap?[effort] ?? effort.rawValue
        } else {
            mappedEffort = nil
        }
        middlewares.append(OpenAICompletionsDeepSeekMiddleware(enableThinking: enabled, mappedEffort: mappedEffort))
    }
    if compat.requiresReasoningContentOnAssistantMessages {
        middlewares.append(OpenAICompletionsReasoningContentInjectionMiddleware())
    }
    if model.compat?.openRouterRouting != nil || model.compat?.vercelGatewayRouting != nil {
        middlewares.append(OpenAICompletionsRoutingMiddleware(
            baseUrl: model.baseUrl,
            openRouterRouting: model.compat?.openRouterRouting,
            vercelGatewayRouting: model.compat?.vercelGatewayRouting
        ))
    }
    return middlewares
}

private func streamManualOpenAICompletions(
    model: Model,
    options: OpenAICompletionsOptions,
    query: ChatQuery
) throws -> AsyncThrowingStream<ChatStreamResult, Error> {
    guard let apiKey = options.apiKey, !apiKey.isEmpty else {
        throw StreamError.missingApiKey(model.provider)
    }

    var request = URLRequest(url: chatCompletionsUrl(baseUrl: model.baseUrl))
    request.timeoutInterval = Double(options.timeoutMs ?? 60_000) / 1000.0
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    var mergedHeaders = model.headers ?? [:]
    if let headers = options.headers {
        for (key, value) in headers {
            mergedHeaders[key] = value
        }
    }
    for (key, value) in mergedHeaders {
        request.setValue(value, forHTTPHeaderField: key)
    }

    let body = try JSONEncoder().encode(query)
    request.httpBody = body
    emitPayload(options.onPayload, data: body)
    return streamChatCompletions(request: request, signal: options.signal, onResponse: options.onResponse)
}

private struct OpenAICompletionsThinkingMiddleware: OpenAIMiddleware {
    let enableThinking: Bool

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }
        payload["enable_thinking"] = enableThinking
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

/// Middleware for Qwen models that use chat-template format for thinking control.
/// v0.67.67: also sets `preserve_thinking: true` so multi-turn tool-call arguments survive
/// across turns. Without this, Qwen chat-template models lose prior thinking state and
/// degrade to empty `{}` tool-call payloads on the second turn.
private struct OpenAICompletionsChatTemplateMiddleware: OpenAIMiddleware {
    let enableThinking: Bool

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = request.httpBody else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }
        payload["chat_template_kwargs"] = [
            "enable_thinking": enableThinking,
            "preserve_thinking": true,
        ]
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

/// v0.70.1: Middleware for DeepSeek V4 models. Sets `thinking: { type: "enabled"|"disabled" }`
/// and, when reasoning is enabled, `reasoning_effort` mapped via the compat reasoning effort map.
private struct OpenAICompletionsDeepSeekMiddleware: OpenAIMiddleware {
    let enableThinking: Bool
    let mappedEffort: String?

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }
        payload["thinking"] = ["type": enableThinking ? "enabled" : "disabled"]
        if enableThinking, let mappedEffort {
            payload["reasoning_effort"] = mappedEffort
        }
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

/// v0.70.1: Injects an empty `reasoning_content` field into replayed assistant messages that
/// don't already carry one. DeepSeek V4 rejects assistant turns missing this field even when
/// no thinking content was produced.
private struct OpenAICompletionsReasoningContentInjectionMiddleware: OpenAIMiddleware {
    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }
        guard var messages = payload["messages"] as? [[String: Any]] else { return request }
        var changed = false
        for index in messages.indices {
            let message = messages[index]
            guard let role = message["role"] as? String, role == "assistant" else { continue }
            if message["reasoning_content"] == nil {
                messages[index]["reasoning_content"] = ""
                changed = true
            }
        }
        guard changed else { return request }
        payload["messages"] = messages
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

/// Middleware for OpenRouter models that injects reasoning effort via the `provider` object.
/// OpenRouter uses `{ "provider": { "reasoning_effort": "<level>" } }` in the request body.
private struct OpenAICompletionsOpenRouterReasoningMiddleware: OpenAIMiddleware {
    let enableReasoning: Bool
    let effort: ThinkingLevel?

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }

        if enableReasoning, let effort {
            var provider = payload["provider"] as? [String: Any] ?? [:]
            provider["reasoning_effort"] = effort.rawValue
            payload["provider"] = provider
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

private func encodeRoutingPercentile(_ value: OpenRouterRoutingPercentile) -> Any {
    switch value {
    case .scalar(let n):
        return n
    case .percentiles(let p50, let p75, let p90, let p99):
        var dict: [String: Any] = [:]
        if let v = p50 { dict["p50"] = v }
        if let v = p75 { dict["p75"] = v }
        if let v = p90 { dict["p90"] = v }
        if let v = p99 { dict["p99"] = v }
        return dict
    }
}

private struct OpenAICompletionsRoutingMiddleware: OpenAIMiddleware {
    let baseUrl: String
    let openRouterRouting: OpenRouterRouting?
    let vercelGatewayRouting: VercelGatewayRouting?

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }

        if baseUrl.contains("openrouter.ai"), let routing = openRouterRouting {
            // v0.67.0: full OpenRouter routing field set. Only emit fields the caller set.
            var provider: [String: Any] = [:]
            if let v = routing.allowFallbacks { provider["allow_fallbacks"] = v }
            if let v = routing.requireParameters { provider["require_parameters"] = v }
            if let v = routing.dataCollection { provider["data_collection"] = v }
            if let v = routing.zdr { provider["zdr"] = v }
            if let v = routing.enforceDistillableText { provider["enforce_distillable_text"] = v }
            if let only = routing.only { provider["only"] = only }
            if let order = routing.order { provider["order"] = order }
            if let ignore = routing.ignore { provider["ignore"] = ignore }
            if let q = routing.quantizations { provider["quantizations"] = q }
            if let sort = routing.sort {
                switch sort {
                case .named(let s):
                    provider["sort"] = s
                case .structured(let by, let partition):
                    var dict: [String: Any] = [:]
                    if let by { dict["by"] = by }
                    if let partition { dict["partition"] = partition }
                    if !dict.isEmpty { provider["sort"] = dict }
                }
            }
            if let mp = routing.maxPrice {
                var price: [String: Any] = [:]
                if let v = mp.prompt { price["prompt"] = v }
                if let v = mp.completion { price["completion"] = v }
                if let v = mp.image { price["image"] = v }
                if let v = mp.audio { price["audio"] = v }
                if let v = mp.request { price["request"] = v }
                if !price.isEmpty { provider["max_price"] = price }
            }
            if let tp = routing.preferredMinThroughput {
                provider["preferred_min_throughput"] = encodeRoutingPercentile(tp)
            }
            if let lat = routing.preferredMaxLatency {
                provider["preferred_max_latency"] = encodeRoutingPercentile(lat)
            }
            payload["provider"] = provider
        }

        if baseUrl.contains("ai-gateway.vercel.sh"), let routing = vercelGatewayRouting {
            var gateway: [String: Any] = [:]
            if let only = routing.only { gateway["only"] = only }
            if let order = routing.order { gateway["order"] = order }
            if let v = routing.allowFallbacks { gateway["allow_fallbacks"] = v }
            if !gateway.isEmpty {
                payload["providerOptions"] = ["gateway": gateway]
            }
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

private func chatCompletionsUrl(baseUrl: String) -> URL {
    var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        trimmed = "https://api.openai.com/v1"
    }
    if trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    if trimmed.hasSuffix("/chat/completions") {
        return URL(string: trimmed)!
    }
    return URL(string: trimmed + "/chat/completions")!
}

private func streamChatCompletions(
    request: URLRequest,
    signal: CancellationToken?,
    onResponse: ResponseHandler?
) -> AsyncThrowingStream<ChatStreamResult, Error> {
    AsyncThrowingStream { continuation in
        Task {
            var buffer = Data()
            let delimiterCrlf = Data([13, 10, 13, 10])
            let delimiterLf = Data([10, 10])

            do {
                let session = proxySession(for: request.url)
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw OpenAICompletionsStreamError.invalidResponse
                }
                onResponse?(ResponseSnapshot(statusCode: http.statusCode, headers: responseHeaders(http)))
                if !(200..<300).contains(http.statusCode) {
                    let body = try await collectStreamData(from: bytes)
                    let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    throw OpenAICompletionsStreamError.apiError(message)
                }

                for try await byte in bytes {
                    if signal?.isCancelled == true {
                        throw OpenAICompletionsStreamError.aborted
                    }
                    buffer.append(byte)
                    while let range = findStreamDelimiter(in: buffer, crlf: delimiterCrlf, lf: delimiterLf) {
                        let chunk = buffer.subdata(in: 0..<range.lowerBound)
                        buffer.removeSubrange(0..<range.upperBound)
                        if let event = parseOpenAISseEvent(from: chunk) {
                            continuation.yield(event)
                        }
                    }
                }

                if !buffer.isEmpty, let event = parseOpenAISseEvent(from: buffer) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func findStreamDelimiter(in buffer: Data, crlf: Data, lf: Data) -> Range<Data.Index>? {
    let crlfRange = buffer.range(of: crlf)
    let lfRange = buffer.range(of: lf)

    switch (crlfRange, lfRange) {
    case (nil, nil):
        return nil
    case (let range?, nil):
        return range
    case (nil, let range?):
        return range
    case (let range1?, let range2?):
        return range1.lowerBound <= range2.lowerBound ? range1 : range2
    }
}

private func parseOpenAISseEvent(from chunk: Data) -> ChatStreamResult? {
    guard !chunk.isEmpty, let raw = String(data: chunk, encoding: .utf8) else { return nil }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    var dataLines: [String] = []
    for line in lines {
        if line.hasPrefix("data:") {
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            dataLines.append(data)
        }
    }

    guard !dataLines.isEmpty else { return nil }
    let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty, payload != "[DONE]" else { return nil }
    guard let json = payload.data(using: .utf8) else { return nil }
    if var object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
        object["object"] = object["object"] ?? "chat.completion.chunk"
        if let normalized = try? JSONSerialization.data(withJSONObject: object, options: []) {
            return try? JSONDecoder().decode(ChatStreamResult.self, from: normalized)
        }
    }
    return try? JSONDecoder().decode(ChatStreamResult.self, from: json)
}

private func collectStreamData(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
    }
    return data
}

private enum OpenAICompletionsStreamError: Error, LocalizedError {
    case aborted
    case unknown
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "OpenAI request failed"
        case .invalidResponse:
            return "OpenAI request failed: invalid response"
        case .apiError(let message):
            return message
        }
    }
}
