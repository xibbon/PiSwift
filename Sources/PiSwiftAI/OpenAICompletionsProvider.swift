import Foundation
import OpenAI

public func streamOpenAICompletions(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions
) -> AssistantMessageEventStream {
    let model = resolveCloudflareModel(model)
    var options = options
    options.samplingParams = mergeSamplingParams(model: model, request: options.samplingParams)
    let stream = AssistantMessageEventStream()

    Task {
        var output = AssistantMessage(
            content: [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .pending
        )

        do {
            let compat = resolveCompat(model: model)
            let grammarToolInputProperties = try createGrammarToolInputProperties(
                tools: context.tools,
                supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools
            )
            try validateGrammarToolCallReplay(
                messages: context.messages,
                grammarToolInputProperties: grammarToolInputProperties
            )
            let query = try buildCompletionsQuery(model: model, context: context, options: options, compat: compat)
            let openAIStream: AsyncThrowingStream<OpenAICompletionsStreamChunk, Error>
            if compat.thinkingFormat == .zai {
                openAIStream = try await streamZaiCompletions(model: model, context: context, options: options, query: query, compat: compat)
            } else {
                let middlewares = buildCompletionsMiddlewares(model: model, context: context, compat: compat, options: options)
                openAIStream = try await streamManualOpenAICompletions(
                    model: model,
                    options: options,
                    query: query,
                    middlewares: middlewares
                )
            }
            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var currentToolCallArgs = ""
            var currentToolCallId: String? = nil
            var currentToolCallIndex: Int? = nil
            var toolCallIdByIndex: [Int: String] = [:]
            var hasFinishReason = false
            var currentGrammarInputProperty: String? = nil
            var grammarInputBuffer = GrammarToolInputJsonBuffer()

            func finishCurrentBlock() throws {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let textContent):
                    stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: output))
                case .thinking(let thinkingContent):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: output))
                case .toolCall(var toolCall):
                    if let inputProperty = currentGrammarInputProperty {
                        if let delta = try appendGrammarToolInputJsonDelta(
                            buffer: &grammarInputBuffer,
                            inputProperty: inputProperty,
                            nextInput: currentToolCallArgs,
                            close: true
                        ) {
                            stream.push(.toolCallDelta(contentIndex: index, delta: delta, partial: output))
                        }
                        toolCall.arguments = [inputProperty: AnyCodable(currentToolCallArgs)]
                    } else {
                        toolCall.arguments = parseStreamingJSON(currentToolCallArgs)
                    }
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
                currentGrammarInputProperty = nil
                grammarInputBuffer = GrammarToolInputJsonBuffer()
            }

            for try await chunk in openAIStream {
                if options.signal?.isCancelled == true {
                    throw OpenAICompletionsStreamError.aborted
                }
                let result = chunk.result

                // Capture response ID from chunk
                if output.responseId == nil, !result.id.isEmpty {
                    output.responseId = result.id
                }

                if let rawUsage = chunk.rawUsage {
                    output.usage = parseCompletionsUsage(rawUsage)
                    calculateCost(model: model, usage: &output.usage)
                } else if let usage = result.usage {
                    output.usage = parseCompletionsUsage(usage)
                    calculateCost(model: model, usage: &output.usage)
                }

                guard let choice = result.choices.first else { continue }
                if let finishReason = chunk.rawFinishReason, !finishReason.isEmpty {
                    output.rawStopReason = finishReason
                    let result = mapStopReason(finishReason)
                    output.stopReason = result.stopReason
                    if let errorMessage = result.errorMessage {
                        output.errorMessage = errorMessage
                    }
                    hasFinishReason = true
                }

                let delta = choice.delta

                if let content = delta.content, !content.isEmpty {
                    if currentBlockKind != "text" {
                        try finishCurrentBlock()
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
                        try finishCurrentBlock()
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

                let functionToolCalls = delta.toolCalls?.filter { $0.type != "custom" }
                if let toolCalls = functionToolCalls {
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
                            try finishCurrentBlock()
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

                for customCall in chunk.customToolCalls {
                    let index = customCall.index ?? currentToolCallIndex ?? 0
                    let normalizedId = customCall.id ?? currentToolCallId ?? ""
                    if currentBlockKind != "toolCall" || currentToolCallId != normalizedId {
                        try finishCurrentBlock()
                        let inputProperty = grammarToolInputProperties[customCall.name] ?? "input"
                        let tool = ToolCall(
                            id: normalizedId,
                            name: customCall.name,
                            arguments: [inputProperty: AnyCodable("")]
                        )
                        output.content.append(.toolCall(tool))
                        currentBlockIndex = output.content.count - 1
                        currentBlockKind = "toolCall"
                        currentToolCallArgs = ""
                        currentToolCallId = normalizedId
                        currentToolCallIndex = index
                        currentGrammarInputProperty = inputProperty
                        grammarInputBuffer = GrammarToolInputJsonBuffer()
                        stream.push(.toolCallStart(contentIndex: currentBlockIndex!, partial: output))
                    }
                    guard let contentIndex = currentBlockIndex,
                          let inputProperty = currentGrammarInputProperty else { continue }
                    let nextInput = currentToolCallArgs + customCall.input
                    if let jsonDelta = try appendGrammarToolInputJsonDelta(
                        buffer: &grammarInputBuffer,
                        inputProperty: inputProperty,
                        nextInput: nextInput,
                        close: false
                    ) {
                        stream.push(.toolCallDelta(contentIndex: contentIndex, delta: jsonDelta, partial: output))
                    }
                    currentToolCallArgs = nextInput
                    if case .toolCall(var tool) = output.content[contentIndex] {
                        if tool.name.isEmpty { tool.name = customCall.name }
                        tool.arguments = [inputProperty: AnyCodable(nextInput)]
                        output.content[contentIndex] = .toolCall(tool)
                    }
                }
            }

            try finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw OpenAICompletionsStreamError.aborted
            }

            if output.stopReason == .aborted {
                throw OpenAICompletionsStreamError.aborted
            }
            if !hasFinishReason && !compat.supportsFinishReason {
                output.stopReason = output.content.contains { block in
                    if case .toolCall = block { return true }
                    return false
                } ? .toolUse : .stop
            }
            if output.stopReason == .error {
                throw OpenAICompletionsStreamError.apiError(output.errorMessage ?? "Provider returned an error stop reason")
            }
            if (compat.supportsFinishReason && !hasFinishReason) || output.stopReason == .pending {
                throw OpenAICompletionsStreamError.apiError("Stream ended without finish_reason")
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

struct StopReasonResult: Sendable, Equatable {
    var stopReason: StopReason
    var errorMessage: String?
}

func mapStopReason(_ reason: String) -> StopReasonResult {
    switch reason {
    case "stop", "end":
        return StopReasonResult(stopReason: .stop)
    case "length":
        return StopReasonResult(stopReason: .length)
    case "tool_calls", "function_call":
        return StopReasonResult(stopReason: .toolUse)
    case "content_filter":
        return StopReasonResult(stopReason: .error, errorMessage: "Provider finish_reason: content_filter")
    case "network_error":
        return StopReasonResult(stopReason: .error, errorMessage: "Provider finish_reason: network_error")
    default:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: \(reason)")
    }
}

private struct ResolvedOpenAICompat {
    let supportsStore: Bool
    let supportsDeveloperRole: Bool
    let supportsReasoningEffort: Bool
    let supportsUsageInStreaming: Bool
    let supportsFinishReason: Bool
    let maxTokensField: OpenAICompatMaxTokensField
    let requiresToolResultName: Bool
    let requiresAssistantAfterToolResult: Bool
    let requiresThinkingAsText: Bool
    let requiresMistralToolIds: Bool
    let thinkingFormat: OpenAICompatThinkingFormat
    let chatTemplateKwargs: [String: ChatTemplateKwargValue]
    let chatTemplateArgs: [String: ChatTemplateKwargValue]
    let supportsThinkingTokenBudget: Bool
    let supportsStrictMode: Bool
    let supportsOpenAIGrammarTools: Bool
    let reasoningEffortMap: [ThinkingLevel: String]?
    let cacheControlFormat: OpenAICompatCacheControlFormat?
    let sendSessionAffinityHeaders: Bool
    let sessionAffinityFormat: SessionAffinityFormat
    let supportsLongCacheRetention: Bool
    let supportsCacheControlOnTools: Bool
    let deferredToolsMode: DeferredToolsMode?
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
    let isZai = provider == "zai"
        || provider == "zai-coding-cn"
        || baseUrl.contains("api.z.ai")
        || baseUrl.contains("open.bigmodel.cn")
    let isDeepSeek = provider == "deepseek" || baseUrl.contains("deepseek.com")
    let isOpencode = provider == "opencode" || baseUrl.contains("opencode.ai")
    let isOpenRouter = provider == "openrouter" || baseUrl.contains("openrouter.ai")
    let isTogether = provider == "together" || baseUrl.contains("api.together.ai") || baseUrl.contains("api.together.xyz")
    let isCloudflareWorkersAI = provider == "cloudflare-workers-ai" || baseUrl.contains("api.cloudflare.com")
    let isCloudflareAiGateway = provider == "cloudflare-ai-gateway" || baseUrl.contains("gateway.ai.cloudflare.com")
    let isNvidia = provider == "nvidia" || baseUrl.contains("integrate.api.nvidia.com")
    let isAntLing = provider == "ant-ling" || baseUrl.contains("api.ant-ling.com")

    let isNonStandard = isCerebras || isGrok || isChutes || isDeepSeek || isZai || isOpencode || isOpenRouter
    let useMaxTokens = isChutes || isZai

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
            .max: "max",
        ]
    } else if isGroq {
        reasoningEffortMap = [
            .minimal: "default",
            .low: "default",
            .medium: "default",
            .high: "default",
            .xhigh: "default",
            .max: "default",
        ]
    } else {
        reasoningEffortMap = nil
    }

    return ResolvedOpenAICompat(
        supportsStore: !isNonStandard,
        supportsDeveloperRole: !isNonStandard,
        supportsReasoningEffort: !isGrok && !isZai,
        supportsUsageInStreaming: true,
        supportsFinishReason: true,
        maxTokensField: useMaxTokens ? .maxTokens : .maxCompletionTokens,
        requiresToolResultName: false,
        requiresAssistantAfterToolResult: false,
        requiresThinkingAsText: false,
        requiresMistralToolIds: false,
        thinkingFormat: thinkingFormat,
        chatTemplateKwargs: [:],
        chatTemplateArgs: [:],
        supportsThinkingTokenBudget: false,
        supportsStrictMode: true,
        supportsOpenAIGrammarTools: false,
        reasoningEffortMap: reasoningEffortMap,
        cacheControlFormat: isOpenRouter && model.id.range(
            of: #"^~?anthropic/"#,
            options: .regularExpression
        ) != nil ? .anthropic : nil,
        sendSessionAffinityHeaders: false,
        sessionAffinityFormat: isOpenRouter ? .openrouter : .openai,
        supportsLongCacheRetention: !(isTogether || isCloudflareWorkersAI || isCloudflareAiGateway || isNvidia || isAntLing),
        supportsCacheControlOnTools: true,
        deferredToolsMode: nil,
        requiresReasoningContentOnAssistantMessages: isDeepSeek
    )
}

func detectedOpenAICompletionsMaxTokensField(model: Model) -> OpenAICompatMaxTokensField {
    detectCompat(model: model).maxTokensField
}

private func resolveCompat(model: Model) -> ResolvedOpenAICompat {
    let detected = detectCompat(model: model)
    guard let compat = model.compat else { return detected }

    return ResolvedOpenAICompat(
        supportsStore: compat.supportsStore ?? detected.supportsStore,
        supportsDeveloperRole: compat.supportsDeveloperRole ?? detected.supportsDeveloperRole,
        supportsReasoningEffort: compat.supportsReasoningEffort ?? detected.supportsReasoningEffort,
        supportsUsageInStreaming: compat.supportsUsageInStreaming ?? detected.supportsUsageInStreaming,
        supportsFinishReason: compat.supportsFinishReason ?? detected.supportsFinishReason,
        maxTokensField: compat.maxTokensField ?? detected.maxTokensField,
        requiresToolResultName: compat.requiresToolResultName ?? detected.requiresToolResultName,
        requiresAssistantAfterToolResult: compat.requiresAssistantAfterToolResult ?? detected.requiresAssistantAfterToolResult,
        requiresThinkingAsText: compat.requiresThinkingAsText ?? detected.requiresThinkingAsText,
        requiresMistralToolIds: compat.requiresMistralToolIds ?? detected.requiresMistralToolIds,
        thinkingFormat: compat.thinkingFormat ?? detected.thinkingFormat,
        chatTemplateKwargs: compat.chatTemplateKwargs ?? detected.chatTemplateKwargs,
        chatTemplateArgs: compat.chatTemplateArgs ?? detected.chatTemplateArgs,
        supportsThinkingTokenBudget: compat.supportsThinkingTokenBudget ?? detected.supportsThinkingTokenBudget,
        supportsStrictMode: compat.supportsStrictMode ?? detected.supportsStrictMode,
        supportsOpenAIGrammarTools: compat.supportsOpenAIGrammarTools ?? detected.supportsOpenAIGrammarTools,
        reasoningEffortMap: compat.reasoningEffortMap ?? detected.reasoningEffortMap,
        cacheControlFormat: compat.cacheControlFormat ?? detected.cacheControlFormat,
        sendSessionAffinityHeaders: compat.sendSessionAffinityHeaders ?? detected.sendSessionAffinityHeaders,
        sessionAffinityFormat: compat.sessionAffinityFormat ?? detected.sessionAffinityFormat,
        supportsLongCacheRetention: compat.supportsLongCacheRetention ?? detected.supportsLongCacheRetention,
        supportsCacheControlOnTools: compat.supportsCacheControlOnTools ?? detected.supportsCacheControlOnTools,
        deferredToolsMode: compat.deferredToolsMode ?? detected.deferredToolsMode,
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
    if let existing = toolCallIdByIndex[index] {
        return (existing, index)
    }
    if let id = toolCall.id, !id.isEmpty {
        toolCallIdByIndex[index] = id
        return (id, index)
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

private func getDeferredToolNames(_ messages: [Message]) -> Set<String> {
    var names = Set<String>()
    for case .toolResult(let toolResult) in messages {
        for name in toolResult.addedToolNames ?? [] {
            names.insert(name)
        }
    }
    return names
}

private func buildCompletionsQuery(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions,
    compat: ResolvedOpenAICompat
) throws -> ChatQuery {
    let messages = convertCompletionsMessages(model: model, context: context, compat: compat)
    let deferredToolNames = compat.deferredToolsMode == .kimi
        ? getDeferredToolNames(context.messages)
        : Set<String>()
    let activeTools = context.tools?.filter { !deferredToolNames.contains($0.name) }

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

    let tools: [ChatQuery.ChatCompletionToolParam]? = try {
        // v0.70.3: omit `tools` field entirely when no tools are active. DashScope/Aliyun Qwen
        // reject `"tools": []` with HTTP 400 `"[] is too short - 'tools'"`. The legacy LiteLLM/
        // Anthropic-proxy workaround (sending `[]` to keep tool history coherent) is preserved
        // only when the conversation actually contains tool history.
        if let activeTools {
            let converted = try convertCompletionsTools(activeTools, compat: compat)
            if converted.isEmpty {
                return hasToolHistory(context.messages) ? [] : nil
            }
            return converted
        } else if hasToolHistory(context.messages) {
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
    case .max:
        return .customValue("max")
    }
}

private func convertCompletionsMessages(
    model: Model,
    context: Context,
    compat: ResolvedOpenAICompat
) -> [ChatQuery.ChatCompletionMessageParam] {
    var params: [ChatQuery.ChatCompletionMessageParam] = []

    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, model, _ in
        normalizeCompletionsToolCallId(id, model: model)
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
    var kimiPendingAddedNames: [String] = []

    func flushKimiPendingAddedTools() {
        guard compat.deferredToolsMode == .kimi, !kimiPendingAddedNames.isEmpty else { return }
        let names = kimiPendingAddedNames.filter { name in
            context.tools?.contains { $0.name == name } == true
        }
        kimiPendingAddedNames = []
        guard !names.isEmpty,
              let namesData = try? JSONSerialization.data(withJSONObject: names),
              let namesJSON = String(data: namesData, encoding: .utf8) else { return }
        let marker = "\u{0}__PI_KIMI_DEFERRED_TOOLS__:" + namesJSON
        params.append(.system(.init(content: .textContent(marker))))
    }

    for msg in transformed {
        if compat.requiresAssistantAfterToolResult && lastRole == "toolResult" && msg.role == "user" {
            params.append(.assistant(.init(content: .textContent("I have processed the tool results."))))
        }
        if lastRole == "toolResult" && msg.role != "toolResult" {
            flushKimiPendingAddedTools()
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

            let contentText = textBlocks.joined()
            var assistantContent: ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? = nil

            let thinkingBlocks = assistant.content.compactMap { block -> ThinkingContent? in
                if case .thinking(let thinking) = block {
                    let trimmed = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : thinking
                }
                return nil
            }

            if !thinkingBlocks.isEmpty && compat.requiresThinkingAsText {
                var contentParts: [ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent.ContentPart] = [
                    .text(.init(text: sanitizeSurrogates(thinkingBlocks.map { $0.thinking }.joined(separator: "\n\n"))))
                ]
                contentParts.append(contentsOf: textBlocks.map { .text(.init(text: $0)) })
                assistantContent = .contentParts(contentParts)
            } else if !contentText.isEmpty {
                assistantContent = .textContent(contentText)
            }

            if let assistantContent {
                assistantMessage = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam(content: assistantContent)
            }

            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let toolCall) = block { return toolCall }
                return nil
            }

            if !toolCalls.isEmpty {
                assistantMessage = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam(
                    content: compat.requiresAssistantAfterToolResult ? .textContent("") : assistantContent,
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
            if compat.deferredToolsMode == .kimi {
                for name in toolResult.addedToolNames ?? [] where !kimiPendingAddedNames.contains(name) {
                    kimiPendingAddedNames.append(name)
                }
            }

            let text = toolResult.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined(separator: "\n")

            let hasImages = toolResult.content.contains { block in
                if case .image = block { return true }
                return false
            }

            // An empty text-only result is not an image attachment. Telling the model
            // otherwise causes it to invent an image that was never supplied.
            let emptyToolResult = hasImages ? "(see attached image)" : "(no tool output)"
            let toolText = sanitizeSurrogates(text.isEmpty ? emptyToolResult : text)
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

    flushKimiPendingAddedTools()

    return params
}

func normalizeCompletionsToolCallId(_ id: String, model: Model) -> String {
    if let separator = id.firstIndex(of: "|") {
        let callId = id[..<separator].map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        let itemStart = id.index(after: separator)
        let itemId = id[itemStart...].map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        let combined = String(callId) + (itemId.isEmpty ? "" : "_" + String(itemId))
        if combined.count <= 40 { return combined }
        let hash = String(shortHash(id).prefix(8))
        let prefixLength = max(1, 40 - hash.count - 1)
        return "\(String(callId.prefix(prefixLength)))_\(hash)"
    }
    if model.provider == "openai" { return id.count > 40 ? String(id.prefix(40)) : id }
    if model.provider == "github-copilot", model.id.lowercased().contains("claude") {
        return String(id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(64))
    }
    return id
}

private func convertCompletionsTools(_ tools: [AITool], compat: ResolvedOpenAICompat) throws -> [ChatQuery.ChatCompletionToolParam] {
    try tools.compactMap { tool in
        let schema = openAIJSONSchema(from: tool.parameters)
        let constrainedStrict = try resolveJsonSchemaStrictSampling(
            tool: tool,
            supportsStrictMode: compat.supportsStrictMode
        )
        let definition = ChatQuery.ChatCompletionToolParam.FunctionDefinition(
            name: tool.name,
            description: tool.description,
            parameters: schema,
            strict: compat.supportsStrictMode ? (constrainedStrict ?? false) : nil
        )
        return .init(function: definition)
    }
}

private func streamZaiCompletions(
    model: Model,
    context: Context,
    options: OpenAICompletionsOptions,
    query: ChatQuery,
    compat: ResolvedOpenAICompat
) async throws -> AsyncThrowingStream<OpenAICompletionsStreamChunk, Error> {
    guard let apiKey = options.apiKey, !apiKey.isEmpty else {
        throw StreamError.missingApiKey(model.provider)
    }

    var request = URLRequest(url: chatCompletionsUrl(baseUrl: model.baseUrl))
    request.timeoutInterval = Double(options.timeoutMs ?? 60_000) / 1000.0
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    request = applyOpenAICompletionsSessionAffinityHeaders(
        request: request,
        sessionId: options.sessionId,
        sendSessionAffinityHeaders: compat.sendSessionAffinityHeaders,
        sessionAffinityFormat: compat.sessionAffinityFormat
    )
    applyProviderHeaders(
        mergeProviderHeaders(model.headers, options.headers),
        to: &request
    )

    var body = try buildZaiRequestBody(query: query, model: model, options: options)
    body = applyOpenAICompletionsMaxTokensField(data: body, field: compat.maxTokensField)
    if let updated = applyOpenAICompletionsPromptCache(
        data: body,
        baseUrl: model.baseUrl,
        sessionId: options.sessionId,
        cacheRetention: resolveCacheRetention(options.cacheRetention),
        supportsLongCacheRetention: compat.supportsLongCacheRetention
    ) {
        body = updated
    }
    if let cacheControl = openAICompatCacheControl(compat: compat, cacheRetention: resolveCacheRetention(options.cacheRetention)),
       let updated = applyOpenAICompatCacheControl(
        data: body,
        cacheControl: cacheControl,
        supportsCacheControlOnTools: compat.supportsCacheControlOnTools
       ) {
        body = updated
    }
    if compat.supportsThinkingTokenBudget,
       let effort = options.reasoningEffort,
       model.reasoning,
       var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
        applyThinkingTokenBudget(
            payload: &payload,
            modelMaxTokens: model.maxTokens,
            effort: effort,
            thinkingBudgets: options.thinkingBudgets
        )
        body = try JSONSerialization.data(withJSONObject: payload)
    }
    // Keep this last so custom keys override all named request fields.
    body = applyOpenAISamplingParams(data: body, samplingParams: options.samplingParams)
    request.httpBody = body
    emitPayload(options.onPayload, data: body)
    return try await streamChatCompletions(request: request, options: options)
}

private func buildZaiRequestBody(query: ChatQuery, model: Model, options: OpenAICompletionsOptions) throws -> Data {
    let encoded = try JSONEncoder().encode(query)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw OpenAICompletionsStreamError.invalidResponse
    }

    if model.reasoning {
        let enabled = options.reasoningEffort != nil
        // Keep replayed reasoning_content so Z.AI can include it in its cache.
        object["thinking"] = enabled
            ? ["type": "enabled", "clear_thinking": false]
            : ["type": "disabled"]
    }

    return try JSONSerialization.data(withJSONObject: object, options: [])
}

private struct OpenAICompletionsStreamChunk {
    let result: ChatStreamResult
    let rawUsage: OpenAICompletionsRawUsage?
    let rawFinishReason: String?
    let customToolCalls: [OpenAICompletionsCustomToolCall]
}

private struct OpenAICompletionsCustomToolCall {
    let index: Int?
    let id: String?
    let name: String
    let input: String
}

private struct OpenAICompletionsRawUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptCacheHitTokens: Int?
    let promptTokensDetails: PromptTokensDetails?
    let completionTokensDetails: CompletionTokensDetails?

    struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?
        let cacheWriteTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
            case cacheWriteTokens = "cache_write_tokens"
        }
    }

    struct CompletionTokensDetails: Decodable {
        let reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }
}

private func parseCompletionsUsage(_ rawUsage: OpenAICompletionsRawUsage) -> Usage {
    let promptTokens = rawUsage.promptTokens ?? 0
    let cacheReadTokens = rawUsage.promptTokensDetails?.cachedTokens ?? rawUsage.promptCacheHitTokens ?? 0
    let cacheWriteTokens = rawUsage.promptTokensDetails?.cacheWriteTokens ?? 0
    let input = max(0, promptTokens - cacheReadTokens - cacheWriteTokens)
    let outputTokens = rawUsage.completionTokens ?? 0
    return Usage(
        input: input,
        output: outputTokens,
        cacheRead: cacheReadTokens,
        cacheWrite: cacheWriteTokens,
        reasoning: rawUsage.completionTokensDetails?.reasoningTokens,
        totalTokens: input + outputTokens + cacheReadTokens + cacheWriteTokens
    )
}

private func parseCompletionsUsage(_ usage: ChatResult.CompletionUsage) -> Usage {
    let rawUsage = OpenAICompletionsRawUsage(
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        totalTokens: usage.totalTokens,
        promptCacheHitTokens: nil,
        promptTokensDetails: usage.promptTokensDetails.map {
            OpenAICompletionsRawUsage.PromptTokensDetails(
                cachedTokens: $0.cachedTokens,
                cacheWriteTokens: nil
            )
        },
        completionTokensDetails: nil
    )
    return parseCompletionsUsage(rawUsage)
}

private func buildCompletionsMiddlewares(
    model: Model,
    context: Context,
    compat: ResolvedOpenAICompat,
    options: OpenAICompletionsOptions
) -> [OpenAIMiddleware] {
    var middlewares: [OpenAIMiddleware] = [
        OpenAICompletionsMaxTokensMiddleware(field: compat.maxTokensField),
    ]
    if compat.sendSessionAffinityHeaders || shouldSendOpenAICompletionsPromptCache(baseUrl: model.baseUrl, cacheRetention: resolveCacheRetention(options.cacheRetention), compat: compat) {
        middlewares.append(OpenAICompletionsSessionMiddleware(
            baseUrl: model.baseUrl,
            sessionId: options.sessionId,
            cacheRetention: resolveCacheRetention(options.cacheRetention),
            sendSessionAffinityHeaders: compat.sendSessionAffinityHeaders,
            sessionAffinityFormat: compat.sessionAffinityFormat,
            supportsLongCacheRetention: compat.supportsLongCacheRetention
        ))
    }
    if let cacheControl = openAICompatCacheControl(compat: compat, cacheRetention: resolveCacheRetention(options.cacheRetention)) {
        middlewares.append(OpenAICompletionsCacheControlMiddleware(
            cacheControl: cacheControl,
            supportsCacheControlOnTools: compat.supportsCacheControlOnTools
        ))
    }
    if compat.thinkingFormat == .qwen, model.reasoning {
        let enabled = options.reasoningEffort != nil
        middlewares.append(OpenAICompletionsThinkingMiddleware(enableThinking: enabled))
    }
    if compat.thinkingFormat == .qwenChatTemplate, model.reasoning {
        let enabled = options.reasoningEffort != nil
        middlewares.append(OpenAICompletionsChatTemplateMiddleware(enableThinking: enabled))
    }
    if compat.thinkingFormat == .chatTemplate, model.reasoning {
        middlewares.append(OpenAICompletionsConfiguredChatTemplateMiddleware(
            model: model,
            effort: options.reasoningEffort,
            kwargs: compat.chatTemplateKwargs
        ))
    }
    if compat.thinkingFormat == .baseten, model.reasoning {
        middlewares.append(OpenAICompletionsBasetenThinkingMiddleware(
            model: model,
            effort: options.reasoningEffort,
            args: compat.chatTemplateArgs,
            supportsReasoningEffort: compat.supportsReasoningEffort
        ))
    }
    if compat.thinkingFormat == .openrouter, model.reasoning {
        middlewares.append(OpenAICompletionsOpenRouterReasoningMiddleware(model: model, effort: options.reasoningEffort))
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
    if compat.deferredToolsMode == .kimi {
        let deferredToolNames = getDeferredToolNames(context.messages)
        let orderedDeferredTools: [(name: String, json: [String: Any])] = (context.tools ?? []).compactMap { tool in
            guard deferredToolNames.contains(tool.name),
                  let converted = try? convertCompletionsTools([tool], compat: compat),
                  let data = try? JSONEncoder().encode(converted),
                  let toolsJSON = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let toolJSON = toolsJSON.first else { return nil }
            return (name: tool.name, json: toolJSON)
        }
        middlewares.append(OpenAICompletionsKimiDeferredToolsMiddleware(
            orderedDeferredTools: orderedDeferredTools
        ))
    }
    if compat.supportsOpenAIGrammarTools,
       let grammarTools = try? makeOpenAIGrammarToolPayloads(
           tools: context.tools ?? [],
           supportsOpenAIGrammarTools: true
       ), !grammarTools.isEmpty,
       let properties = try? createGrammarToolInputProperties(
           tools: context.tools,
           supportsOpenAIGrammarTools: true
       ) {
        middlewares.append(OpenAICompletionsGrammarToolsMiddleware(
            grammarTools: grammarTools,
            grammarToolInputProperties: properties
        ))
    }
    if compat.supportsThinkingTokenBudget,
       let effort = options.reasoningEffort,
       model.reasoning {
        middlewares.append(OpenAICompletionsThinkingTokenBudgetMiddleware(
            modelMaxTokens: model.maxTokens,
            effort: effort,
            thinkingBudgets: options.thinkingBudgets
        ))
    }
    if let samplingParams = options.samplingParams, !samplingParams.isEmpty {
        // Keep this last so custom keys override all named request fields.
        middlewares.append(OpenAISamplingParamsMiddleware(samplingParams: samplingParams))
    }
    return middlewares
}

private struct OpenAICompletionsMaxTokensMiddleware: OpenAIMiddleware {
    let field: OpenAICompatMaxTokensField

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = request.httpBody else { return request }
        var updated = request
        updated.httpBody = applyOpenAICompletionsMaxTokensField(data: body, field: field)
        return updated
    }
}

func applyOpenAICompletionsMaxTokensField(data: Data, field: OpenAICompatMaxTokensField) -> Data {
    guard field == .maxTokens,
          var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let limit = payload.removeValue(forKey: OpenAICompatMaxTokensField.maxCompletionTokens.rawValue) else {
        return data
    }
    payload[OpenAICompatMaxTokensField.maxTokens.rawValue] = limit
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? data
}

private struct OpenAICompletionsGrammarToolsMiddleware: OpenAIMiddleware {
    let grammarTools: [String: OpenAICompletionsGrammarTool]
    let grammarToolInputProperties: [String: String]

    func intercept(request: URLRequest) -> URLRequest {
        let body = requestBodyData(request)
        guard !body.isEmpty,
              var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return request
        }

        if var tools = payload["tools"] as? [[String: Any]] {
            for index in tools.indices {
                guard let function = tools[index]["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let grammarTool = grammarTools[name] else { continue }
                tools[index] = grammarTool.payload
            }
            payload["tools"] = tools
        }

        if var messages = payload["messages"] as? [[String: Any]] {
            for messageIndex in messages.indices {
                guard var toolCalls = messages[messageIndex]["tool_calls"] as? [[String: Any]] else { continue }
                for toolIndex in toolCalls.indices {
                    guard let function = toolCalls[toolIndex]["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let inputProperty = grammarToolInputProperties[name],
                          let arguments = function["arguments"] as? String,
                          let data = arguments.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let input = object[inputProperty] as? String else { continue }
                    toolCalls[toolIndex].removeValue(forKey: "function")
                    toolCalls[toolIndex]["type"] = "custom"
                    toolCalls[toolIndex]["custom"] = ["name": name, "input": sanitizeSurrogates(input)]
                }
                messages[messageIndex]["tool_calls"] = toolCalls
            }
            payload["messages"] = messages
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

private struct OpenAICompletionsGrammarTool: Sendable {
    let name: String
    let description: String
    let format: GrammarConstrainedSampling.Format
    let definition: String

    var payload: [String: Any] {
        [
            "type": "custom",
            "custom": [
                "name": name,
                "description": description,
                "format": [
                    "type": "grammar",
                    "grammar": [
                        "syntax": format.rawValue,
                        "definition": definition,
                    ],
                ],
            ],
        ]
    }
}

private func makeOpenAIGrammarToolPayloads(
    tools: [AITool],
    supportsOpenAIGrammarTools: Bool
) throws -> [String: OpenAICompletionsGrammarTool] {
    var result: [String: OpenAICompletionsGrammarTool] = [:]
    for tool in tools {
        guard let grammar = try resolveGrammarConstrainedSampling(
            tool: tool,
            supportsOpenAIGrammarTools: supportsOpenAIGrammarTools
        ) else { continue }
        result[tool.name] = OpenAICompletionsGrammarTool(
            name: tool.name,
            description: tool.description,
            format: grammar.format,
            definition: grammar.definition
        )
    }
    return result
}

private func validateGrammarToolCallReplay(
    messages: [Message],
    grammarToolInputProperties: [String: String]
) throws {
    guard !grammarToolInputProperties.isEmpty else { return }
    for message in messages {
        guard case .assistant(let assistant) = message else { continue }
        for case .toolCall(let toolCall) in assistant.content {
            guard let inputProperty = grammarToolInputProperties[toolCall.name] else { continue }
            _ = try getGrammarToolInput(
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                inputProperty: inputProperty
            )
        }
    }
}

private func shouldSendOpenAICompletionsPromptCache(
    baseUrl: String,
    cacheRetention: CacheRetention,
    compat: ResolvedOpenAICompat
) -> Bool {
    (baseUrl.contains("api.openai.com") && cacheRetention != .none) ||
        (cacheRetention == .long && compat.supportsLongCacheRetention)
}

func applyOpenAICompletionsSessionAffinityHeaders(
    request: URLRequest,
    sessionId: String?,
    sendSessionAffinityHeaders: Bool,
    sessionAffinityFormat: SessionAffinityFormat
) -> URLRequest {
    guard sendSessionAffinityHeaders, let sessionId, !sessionId.isEmpty else { return request }
    var updated = request
    if sessionAffinityFormat == .openrouter {
        updated.setValue(sessionId, forHTTPHeaderField: "x-session-id")
    } else {
        if sessionAffinityFormat == .openai {
            updated.setValue(sessionId, forHTTPHeaderField: "session_id")
        }
        updated.setValue(sessionId, forHTTPHeaderField: "x-client-request-id")
        updated.setValue(sessionId, forHTTPHeaderField: "x-session-affinity")
    }
    return updated
}

func applyOpenAICompletionsPromptCache(
    data: Data,
    baseUrl: String,
    sessionId: String?,
    cacheRetention: CacheRetention,
    supportsLongCacheRetention: Bool
) -> Data? {
    guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let shouldSendPromptCacheKey = (baseUrl.contains("api.openai.com") && cacheRetention != .none) ||
        (cacheRetention == .long && supportsLongCacheRetention)
    if shouldSendPromptCacheKey, let key = clampOpenAIPromptCacheKey(sessionId) {
        payload["prompt_cache_key"] = key
    } else {
        payload.removeValue(forKey: "prompt_cache_key")
    }

    if cacheRetention == .long, supportsLongCacheRetention {
        payload["prompt_cache_retention"] = "24h"
    } else {
        payload.removeValue(forKey: "prompt_cache_retention")
    }

    return try? JSONSerialization.data(withJSONObject: payload, options: [])
}

private struct OpenAICompletionsKimiDeferredToolsMiddleware: OpenAIMiddleware {
    private let markerPrefix = "\u{0}__PI_KIMI_DEFERRED_TOOLS__:"
    private let orderedDeferredTools: [(name: String, json: AnyCodable)]

    init(orderedDeferredTools: [(name: String, json: [String: Any])]) {
        self.orderedDeferredTools = orderedDeferredTools.map { tool in
            (name: tool.name, json: AnyCodable(tool.json))
        }
    }

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request),
              var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let messages = payload["messages"] as? [[String: Any]] else { return request }

        let rewrittenMessages: [[String: Any]] = messages.compactMap { message in
            guard message["role"] as? String == "system",
                  let content = message["content"] as? String,
                  content.hasPrefix(markerPrefix) else { return message }

            let namesJSON = String(content.dropFirst(markerPrefix.count))
            let names = namesJSON.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String]
            } ?? []
            let nameSet = Set(names)
            let tools = orderedDeferredTools.compactMap { tool -> [String: Any]? in
                guard nameSet.contains(tool.name) else { return nil }
                return tool.json.value as? [String: Any]
            }
            guard !tools.isEmpty else { return nil }
            return ["role": "system", "tools": tools]
        }

        payload["messages"] = rewrittenMessages
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return request
        }
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

private func openAICompatCacheControl(compat: ResolvedOpenAICompat, cacheRetention: CacheRetention) -> [String: Any]? {
    guard compat.cacheControlFormat == .anthropic, cacheRetention != .none else { return nil }
    var cacheControl: [String: Any] = ["type": "ephemeral"]
    if cacheRetention == .long, compat.supportsLongCacheRetention {
        cacheControl["ttl"] = "1h"
    }
    return cacheControl
}

func applyOpenAICompatCacheControl(
    data: Data,
    cacheControl: [String: Any],
    supportsCacheControlOnTools: Bool
) -> Data? {
    guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    guard var messages = payload["messages"] as? [[String: Any]] else { return nil }

    addCacheControlToInstructionMessage(messages: &messages, cacheControl: cacheControl)
    addCacheControlToLastConversationMessage(messages: &messages, cacheControl: cacheControl)
    payload["messages"] = messages

    if supportsCacheControlOnTools, var tools = payload["tools"] as? [[String: Any]], !tools.isEmpty {
        tools[tools.count - 1]["cache_control"] = cacheControl
        payload["tools"] = tools
    }

    return try? JSONSerialization.data(withJSONObject: payload, options: [])
}

private struct OpenAICompletionsSessionMiddleware: OpenAIMiddleware {
    let baseUrl: String
    let sessionId: String?
    let cacheRetention: CacheRetention
    let sendSessionAffinityHeaders: Bool
    let sessionAffinityFormat: SessionAffinityFormat
    let supportsLongCacheRetention: Bool

    func intercept(request: URLRequest) -> URLRequest {
        var updated = applyOpenAICompletionsSessionAffinityHeaders(
            request: request,
            sessionId: sessionId,
            sendSessionAffinityHeaders: sendSessionAffinityHeaders,
            sessionAffinityFormat: sessionAffinityFormat
        )
        guard let body = readRequestBody(updated) else { return updated }
        guard let updatedBody = applyOpenAICompletionsPromptCache(
            data: body,
            baseUrl: baseUrl,
            sessionId: sessionId,
            cacheRetention: cacheRetention,
            supportsLongCacheRetention: supportsLongCacheRetention
        ) else { return updated }
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

private func addCacheControlToInstructionMessage(messages: inout [[String: Any]], cacheControl: [String: Any]) {
    for index in messages.indices {
        guard let role = messages[index]["role"] as? String, role == "system" || role == "developer" else {
            continue
        }
        if addCacheControlToTextContent(message: &messages[index], cacheControl: cacheControl) {
            return
        }
    }
}

private func addCacheControlToLastConversationMessage(messages: inout [[String: Any]], cacheControl: [String: Any]) {
    for index in messages.indices.reversed() {
        guard let role = messages[index]["role"] as? String,
              role == "user" || role == "assistant" || role == "tool" else {
            continue
        }
        if addCacheControlToTextContent(message: &messages[index], cacheControl: cacheControl) {
            return
        }
    }
}

@discardableResult
private func addCacheControlToTextContent(message: inout [String: Any], cacheControl: [String: Any]) -> Bool {
    if let content = message["content"] as? String {
        guard !content.isEmpty else { return false }
        message["content"] = [
            [
                "type": "text",
                "text": content,
                "cache_control": cacheControl,
            ]
        ]
        return true
    }

    guard var content = message["content"] as? [[String: Any]] else { return false }
    for index in content.indices.reversed() {
        guard content[index]["type"] as? String == "text" else { continue }
        content[index]["cache_control"] = cacheControl
        message["content"] = content
        return true
    }
    return false
}

/// SAFETY: middleware captures immutable configuration and does not mutate
/// shared state while intercepting requests.
private struct OpenAICompletionsCacheControlMiddleware: OpenAIMiddleware, @unchecked Sendable {
    let cacheControl: [String: Any]
    let supportsCacheControlOnTools: Bool

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard let updatedBody = applyOpenAICompatCacheControl(
            data: body,
            cacheControl: cacheControl,
            supportsCacheControlOnTools: supportsCacheControlOnTools
        ) else { return request }
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

private func streamManualOpenAICompletions(
    model: Model,
    options: OpenAICompletionsOptions,
    query: ChatQuery,
    middlewares: [OpenAIMiddleware]
) async throws -> AsyncThrowingStream<OpenAICompletionsStreamChunk, Error> {
    guard let apiKey = options.apiKey, !apiKey.isEmpty else {
        throw StreamError.missingApiKey(model.provider)
    }

    var request = URLRequest(url: chatCompletionsUrl(baseUrl: model.baseUrl))
    request.timeoutInterval = Double(options.timeoutMs ?? 60_000) / 1000.0
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.setValue("application/json", forHTTPHeaderField: "content-type")

    request.httpBody = try JSONEncoder().encode(query)
    request = middlewares.reduce(request) { current, middleware in
        middleware.intercept(request: current)
    }
    applyProviderHeaders(
        mergeProviderHeaders(model.headers, options.headers),
        to: &request
    )
    emitPayload(options.onPayload, data: requestBodyData(request))
    return try await streamChatCompletions(request: request, options: options)
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

private struct OpenAICompletionsConfiguredChatTemplateMiddleware: OpenAIMiddleware {
    let model: Model
    let effort: ThinkingLevel?
    let kwargs: [String: ChatTemplateKwargValue]

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = request.httpBody,
              let updatedBody = applyOpenAIChatTemplateKwargs(data: body, model: model, effort: effort, kwargs: kwargs) else {
            return request
        }

        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

func applyOpenAIChatTemplateKwargs(
    data: Data,
    model: Model,
    effort: ThinkingLevel?,
    kwargs: [String: ChatTemplateKwargValue]
) -> Data? {
    guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }

    let resolved = resolveOpenAIChatTemplateValues(model: model, effort: effort, values: kwargs)
    guard !resolved.isEmpty else { return nil }
    payload["chat_template_kwargs"] = resolved
    return try? JSONSerialization.data(withJSONObject: payload)
}

private func resolveOpenAIChatTemplateValues(
    model: Model,
    effort: ThinkingLevel?,
    values: [String: ChatTemplateKwargValue]
) -> [String: Any] {
    var resolved: [String: Any] = [:]
    for (key, value) in values {
        if let value = resolveChatTemplateKwarg(value, model: model, effort: effort) {
            resolved[key] = value
        }
    }
    return resolved
}

private struct OpenAICompletionsBasetenThinkingMiddleware: OpenAIMiddleware {
    let model: Model
    let effort: ThinkingLevel?
    let args: [String: ChatTemplateKwargValue]
    let supportsReasoningEffort: Bool

    func intercept(request: URLRequest) -> URLRequest {
        let body = requestBodyData(request)
        guard !body.isEmpty,
              var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return request
        }

        let resolvedArgs = resolveOpenAIChatTemplateValues(model: model, effort: effort, values: args)
        if !resolvedArgs.isEmpty {
            payload["chat_template_args"] = resolvedArgs
        }

        if supportsReasoningEffort, let resolvedEffort = basetenReasoningEffort(model: model, requested: effort) {
            payload["reasoning_effort"] = resolvedEffort
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

private func basetenReasoningEffort(model: Model, requested: ThinkingLevel?) -> String? {
    guard let requested else {
        guard let map = model.thinkingLevelMap else { return nil }
        return map[.off] ?? nil
    }
    guard let map = model.thinkingLevelMap else { return requested.rawValue }
    switch map[ModelThinkingLevel(requested)] {
    case nil:
        return requested.rawValue
    case .some(nil):
        return nil
    case .some(.some(let mapped)):
        return mapped
    }
}

private struct OpenAICompletionsThinkingTokenBudgetMiddleware: OpenAIMiddleware {
    let modelMaxTokens: Int
    let effort: ThinkingLevel
    let thinkingBudgets: ThinkingBudgets?

    func intercept(request: URLRequest) -> URLRequest {
        let body = requestBodyData(request)
        guard !body.isEmpty,
              var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return request
        }

        applyThinkingTokenBudget(
            payload: &payload,
            modelMaxTokens: modelMaxTokens,
            effort: effort,
            thinkingBudgets: thinkingBudgets
        )
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

private func applyThinkingTokenBudget(
    payload: inout [String: Any],
    modelMaxTokens: Int,
    effort: ThinkingLevel,
    thinkingBudgets: ThinkingBudgets?
) {
    let level = clampThinkingLevel(effort) ?? effort
    let defaults: ThinkingBudgets = [
        .minimal: 1_024,
        .low: 2_048,
        .medium: 8_192,
        .high: 16_384,
    ]
    let budgets = defaults.merging(thinkingBudgets ?? [:]) { _, requestValue in requestValue }
    guard let requestedBudget = budgets[level] else { return }
    let ceiling = payload["max_tokens"] as? Int
        ?? payload["max_completion_tokens"] as? Int
        ?? modelMaxTokens
    let budget = min(requestedBudget, max(0, ceiling - minimumAnswerTokens))
    if budget > 0 {
        payload["thinking_token_budget"] = budget
    }
}

private func resolveChatTemplateKwarg(
    _ value: ChatTemplateKwargValue,
    model: Model,
    effort: ThinkingLevel?
) -> Any? {
    switch value {
    case .string(let value):
        return value
    case .number(let value):
        return value
    case .bool(let value):
        return value
    case .null:
        return NSNull()
    case .variable(.thinkingEnabled, _):
        return effort != nil
    case .variable(.thinkingEffort, let omitWhenOff):
        guard let effort else {
            guard !omitWhenOff else { return nil }
            return mappedOffThinkingLevel(model: model)
        }
        return mappedThinkingLevel(model: model, level: effort) ?? effort.rawValue
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

/// Middleware for OpenRouter models that injects reasoning effort via the nested `reasoning` object.
/// v0.61.0 / v0.62.0: OpenRouter normalizes reasoning as `{ "reasoning": { "effort": "<level>" } }`;
/// when no effort is requested, explicitly disable reasoning with `"none"`.
private struct OpenAICompletionsOpenRouterReasoningMiddleware: OpenAIMiddleware {
    let model: Model
    let effort: ThinkingLevel?

    func intercept(request: URLRequest) -> URLRequest {
        guard let body = readRequestBody(request) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }

        var reasoning = payload["reasoning"] as? [String: Any] ?? [:]
        if let effort {
            reasoning["effort"] = mappedThinkingLevel(model: model, level: effort) ?? effort.rawValue
        } else {
            reasoning["effort"] = mappedOffThinkingLevel(model: model) ?? "none"
        }
        payload["reasoning"] = reasoning

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
    options: OpenAICompletionsOptions
) async throws -> AsyncThrowingStream<OpenAICompletionsStreamChunk, Error> {
    let client = options.httpClient ?? DefaultProviderHTTPClient()
    let response = try await retryProviderRequest(
        maxRetries: options.maxRetries,
        maxRetryDelayMs: options.maxRetryDelayMs,
        signal: options.signal
    ) {
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw try await providerHTTPError(from: response)
        }
        return response
    }
    options.onResponse?(ResponseSnapshot(statusCode: response.statusCode, headers: response.headers))

    return AsyncThrowingStream { continuation in
        Task {
            var buffer = Data()
            let delimiterCrlf = Data([13, 10, 13, 10])
            let delimiterLf = Data([10, 10])

            do {
                for try await chunkData in response.body {
                    if options.signal?.isCancelled == true {
                        throw OpenAICompletionsStreamError.aborted
                    }
                    buffer.append(chunkData)
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

private func parseOpenAISseEvent(from chunk: Data) -> OpenAICompletionsStreamChunk? {
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
        preferFunctionToolCallsOverEmptyCustomPayloads(in: &object)
        let rawUsage = decodeOpenAICompletionsRawUsage(from: object["usage"]) ?? decodeFirstChoiceUsage(from: object["choices"])
        let rawFinishReason = decodeFirstChoiceFinishReason(from: object["choices"])
        normalizeUnknownFinishReason(in: &object, rawFinishReason: rawFinishReason)
        object["object"] = object["object"] ?? "chat.completion.chunk"
        if let normalized = try? JSONSerialization.data(withJSONObject: object, options: []) {
            guard let result = try? JSONDecoder().decode(ChatStreamResult.self, from: normalized) else { return nil }
            return OpenAICompletionsStreamChunk(
                result: result,
                rawUsage: rawUsage,
                rawFinishReason: rawFinishReason,
                customToolCalls: decodeCustomToolCalls(from: object["choices"])
            )
        }
    }
    guard let result = try? JSONDecoder().decode(ChatStreamResult.self, from: json) else { return nil }
    return OpenAICompletionsStreamChunk(
        result: result,
        rawUsage: nil,
        rawFinishReason: result.choices.first?.finishReason?.rawValue,
        customToolCalls: []
    )
}

private func preferFunctionToolCallsOverEmptyCustomPayloads(in object: inout [String: Any]) {
    guard var choices = object["choices"] as? [[String: Any]] else { return }
    for choiceIndex in choices.indices {
        guard var delta = choices[choiceIndex]["delta"] as? [String: Any],
              var toolCalls = delta["tool_calls"] as? [[String: Any]] else { continue }
        var changed = false
        for toolIndex in toolCalls.indices {
            guard toolCalls[toolIndex]["function"] is [String: Any],
                  toolCalls[toolIndex]["custom"] is [String: Any] else { continue }
            toolCalls[toolIndex].removeValue(forKey: "custom")
            toolCalls[toolIndex]["type"] = "function"
            changed = true
        }
        if changed {
            delta["tool_calls"] = toolCalls
            choices[choiceIndex]["delta"] = delta
        }
    }
    object["choices"] = choices
}

private func decodeCustomToolCalls(from choices: Any?) -> [OpenAICompletionsCustomToolCall] {
    guard let first = (choices as? [[String: Any]])?.first,
          let delta = first["delta"] as? [String: Any],
          let toolCalls = delta["tool_calls"] as? [[String: Any]] else { return [] }
    return toolCalls.compactMap { toolCall in
        guard (toolCall["type"] as? String) == "custom",
              let custom = toolCall["custom"] as? [String: Any] else { return nil }
        return OpenAICompletionsCustomToolCall(
            index: toolCall["index"] as? Int,
            id: toolCall["id"] as? String,
            name: custom["name"] as? String ?? "",
            input: custom["input"] as? String ?? ""
        )
    }
}

private func decodeFirstChoiceFinishReason(from choices: Any?) -> String? {
    guard let choices = choices as? [[String: Any]], let first = choices.first else { return nil }
    return first["finish_reason"] as? String
}

private func normalizeUnknownFinishReason(in object: inout [String: Any], rawFinishReason: String?) {
    guard let rawFinishReason,
          ChatStreamResult.Choice.FinishReason(rawValue: rawFinishReason) == nil,
          var choices = object["choices"] as? [[String: Any]],
          !choices.isEmpty else { return }
    choices[0]["finish_reason"] = NSNull()
    object["choices"] = choices
}

private func decodeFirstChoiceUsage(from choices: Any?) -> OpenAICompletionsRawUsage? {
    guard let choices = choices as? [[String: Any]], let first = choices.first else { return nil }
    return decodeOpenAICompletionsRawUsage(from: first["usage"])
}

private func decodeOpenAICompletionsRawUsage(from value: Any?) -> OpenAICompletionsRawUsage? {
    guard let value, !(value is NSNull) else { return nil }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
    return try? JSONDecoder().decode(OpenAICompletionsRawUsage.self, from: data)
}

private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
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
    return data
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
