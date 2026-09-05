import Foundation
@preconcurrency import SwiftAnthropic

private let claudeCodeVersion = "2.1.251"

private let claudeCodeTools: [String] = [
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Grep",
    "Glob",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
    "KillShell",
    "NotebookEdit",
    "Skill",
    "Task",
    "TaskOutput",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
]

private let claudeCodeToolLookup: [String: String] = Dictionary(
    uniqueKeysWithValues: claudeCodeTools.map { ($0.lowercased(), $0) }
)

private func toClaudeCodeName(_ name: String) -> String {
    claudeCodeToolLookup[name.lowercased()] ?? name
}

private func fromClaudeCodeName(_ name: String, tools: [AITool]?) -> String {
    if let tools, !tools.isEmpty {
        let lowerName = name.lowercased()
        if let match = tools.first(where: { $0.name.lowercased() == lowerName }) {
            return match.name
        }
    }
    return name
}

private func isAnthropicOAuthToken(_ apiKey: String) -> Bool {
    apiKey.contains("sk-ant-oat")
}

func usesAnthropicBearerTransport(_ apiKey: String) -> Bool {
    if isAnthropicOAuthToken(apiKey) {
        return true
    }
    return ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"] == apiKey
}

func anthropicAuthenticationHeaders(apiKey: String, usesBearerTransport: Bool) -> [String: String] {
    if usesBearerTransport {
        return ["Authorization": "Bearer \(apiKey)"]
    }
    return ["x-api-key": apiKey]
}

private func shouldLogAnthropicDebug() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_DEBUG_ANTHROPIC"] ?? env["PI_DEBUG_LIVE_TESTS"] ?? env["PI_DEBUG_API_KEYS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

private func logAnthropicDebug(_ message: String) {
    guard shouldLogAnthropicDebug() else { return }
    let line = "PI_DEBUG: \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func debugNonStreamingError(_ service: AnthropicService, _ parameters: MessageParameter) async {
    guard shouldLogAnthropicDebug() else { return }
    do {
        _ = try await service.createMessage(parameters)
        logAnthropicDebug("anthropic debug non-streaming request succeeded")
    } catch {
        if let apiError = error as? APIError {
            logAnthropicDebug("anthropic debug non-streaming apiError=\(apiError.displayDescription)")
        } else {
            logAnthropicDebug("anthropic debug non-streaming error=\(error.localizedDescription)")
        }
    }
}

private struct ResolvedAnthropicCompat {
    let supportsEagerToolInputStreaming: Bool
    let supportsLongCacheRetention: Bool
    let sendSessionAffinityHeaders: Bool
    let supportsCacheControlOnTools: Bool
    let supportsTemperature: Bool
    let supportsToolReferences: Bool
    let supportsStrictTools: Bool
}

func defaultSupportsToolReferences(model: Model) -> Bool {
    guard model.provider == "anthropic", !model.id.contains("haiku") else { return false }

    let pattern = #"^claude-(?:opus|sonnet|fable)-(\d+)(?:-(\d+))?(?:-|$)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
              in: model.id,
              range: NSRange(model.id.startIndex..<model.id.endIndex, in: model.id)
          ),
          let majorRange = Range(match.range(at: 1), in: model.id),
          let major = Int(model.id[majorRange]) else {
        return false
    }

    let minor: Int
    if match.range(at: 2).location != NSNotFound,
       let minorRange = Range(match.range(at: 2), in: model.id),
       model.id[minorRange].count < 8 {
        minor = Int(model.id[minorRange]) ?? 0
    } else {
        minor = 0
    }

    return major > 4 || (major == 4 && minor >= 5)
}

private func resolveAnthropicCompat(model: Model) -> ResolvedAnthropicCompat {
    let provider = model.provider.lowercased()
    let baseUrl = model.baseUrl.lowercased()
    let isFireworks = provider == "fireworks"
    let isCloudflareAiGatewayAnthropic = provider == "cloudflare-ai-gateway" && baseUrl.contains("anthropic")
    let compat = model.compat
    return ResolvedAnthropicCompat(
        supportsEagerToolInputStreaming: compat?.supportsEagerToolInputStreaming ?? !isFireworks,
        supportsLongCacheRetention: compat?.supportsLongCacheRetention ?? !isFireworks,
        sendSessionAffinityHeaders: compat?.sendSessionAffinityHeaders ?? (isFireworks || isCloudflareAiGatewayAnthropic),
        supportsCacheControlOnTools: compat?.supportsCacheControlOnTools ?? !isFireworks,
        supportsTemperature: compat?.supportsTemperature ?? true,
        supportsToolReferences: compat?.supportsToolReferences ?? defaultSupportsToolReferences(model: model),
        supportsStrictTools: compat?.supportsStrictTools ?? false
    )
}

func makeAnthropicUsage(
    input: Int,
    output: Int,
    cacheRead: Int,
    cacheWrite: Int,
    reasoning: Int?
) -> Usage {
    Usage(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        totalTokens: input + output + cacheRead + cacheWrite
    )
}

public func streamAnthropic(
    model: Model,
    context: Context,
    options: AnthropicOptions
) -> AssistantMessageEventStream {
    let model = resolveCloudflareModel(model)
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
        output.providerThinkingLevel = model.compat?.supportsMidConvoEffort == true ? (options.effort?.rawValue ?? "high") : nil
        var usageModel = model
        var inputTransformations: [[String: AnyCodable]]?
        var debugService: AnthropicService?
        var debugParameters: MessageParameter?

        do {
            let apiKey = options.apiKey ?? ""
            if apiKey.isEmpty {
                throw StreamError.missingApiKey(model.provider)
            }
            let isOAuthToken = isAnthropicOAuthToken(apiKey)
            let compat = resolveAnthropicCompat(model: model)
            let toolPlacement = isOAuthToken
                ? splitDeferredTools(
                    context,
                    enabled: compat.supportsToolReferences,
                    normalizeName: toClaudeCodeName
                )
                : splitDeferredTools(context, enabled: compat.supportsToolReferences)
            var immediateTools = toolPlacement.immediate
            var deferredTools = toolPlacement.deferred
            if immediateTools.isEmpty && !deferredTools.isEmpty {
                immediateTools = deferredTools
                deferredTools = []
            }
            let deferredToolNames = Set(deferredTools.map {
                isOAuthToken ? toClaudeCodeName($0.name) : $0.name
            })
            let orderedTools = immediateTools + deferredTools
            let strictToolSchemas = try resolveAnthropicStrictToolSchemas(
                tools: orderedTools,
                isOAuthToken: isOAuthToken,
                supportsStrictTools: compat.supportsStrictTools
            )
            var toolResultAddedNames: [String: [String]] = [:]
            for message in context.messages {
                if case .toolResult(let toolResult) = message,
                   let addedToolNames = toolResult.addedToolNames,
                   !addedToolNames.isEmpty {
                    toolResultAddedNames[sanitizeToolCallId(toolResult.toolCallId)] = addedToolNames
                }
            }

            let betaHeaders = anthropicBetaFeatures(model: model, context: context, options: options)
            if let betaHeaders {
                logAnthropicDebug("anthropic betaHeaders=\(betaHeaders.joined(separator: ","))")
            } else {
                logAnthropicDebug("anthropic betaHeaders=none")
            }
            var mergedHeaders = model.headers
            // Copilot: add dynamic headers for vision and initiator
            if model.provider == "github-copilot" {
                let copilotHeaders = buildCopilotDynamicHeaders(messages: context.messages)
                mergedHeaders = mergeProviderHeaders(mergedHeaders, copilotHeaders)
            }
            mergedHeaders = mergeProviderHeaders(mergedHeaders, options.headers)
            // Apply the resolved beta list after user overrides, including explicit deletion.
            mergedHeaders = mergeProviderHeaders(mergedHeaders, ["anthropic-beta": betaHeaders?.joined(separator: ",")])
            let parameters = buildAnthropicParameters(
                model: model,
                context: context,
                options: options,
                isOAuthToken: isOAuthToken,
                compat: compat,
                orderedTools: orderedTools
            )
            let encodedBody = try anthropicJSONBody(parameters)
            let constrainedBody = injectAnthropicRequestBody(
                body: encodedBody,
                ttl: anthropicCacheTtl(baseUrl: model.baseUrl, supportsLongCacheRetention: compat.supportsLongCacheRetention),
                metadataUserId: extractAnthropicMetadataUserId(options.metadata),
                supportsEagerToolInputStreaming: compat.supportsEagerToolInputStreaming,
                supportsCacheControlOnTools: compat.supportsCacheControlOnTools,
                thinkingDisabled: model.reasoning && options.thinkingEnabled == false && mappedOffThinkingLevel(model: model) != nil,
                deferredToolNames: deferredToolNames,
                toolResultAddedNames: toolResultAddedNames,
                isOAuthToken: isOAuthToken,
                strictToolSchemas: strictToolSchemas
            ) ?? encodedBody
            let rawRequestBody = try prepareAnthropicRawPayload(constrainedBody, model: model, context: context, options: options)
            emitPayload(options.onPayload, data: rawRequestBody)
            let httpClient = buildAnthropicHttpClient(
                providerHTTPClient: options.httpClient,
                isOAuthToken: isOAuthToken,
                extraHeaders: mergedHeaders ?? [:],
                baseUrl: model.baseUrl,
                metadataUserId: extractAnthropicMetadataUserId(options.metadata),
                supportsLongCacheRetention: compat.supportsLongCacheRetention,
                supportsEagerToolInputStreaming: compat.supportsEagerToolInputStreaming,
                supportsCacheControlOnTools: compat.supportsCacheControlOnTools,
                thinkingDisabled: model.reasoning && options.thinkingEnabled == false && mappedOffThinkingLevel(model: model) != nil,
                deferredToolNames: deferredToolNames,
                toolResultAddedNames: toolResultAddedNames,
                strictToolSchemas: strictToolSchemas,
                rawRequestBody: rawRequestBody
            )
            let service = AnthropicServiceFactory.service(
                apiKey: apiKey,
                basePath: model.baseUrl,
                betaHeaders: betaHeaders,
                httpClient: httpClient,
                debugEnabled: false
            )

            debugService = service
            debugParameters = parameters
            let toolCount = context.tools?.count ?? 0
            logAnthropicDebug("anthropic request model=\(model.id) maxTokens=\(parameters.maxTokens) messages=\(parameters.messages.count) system=\(parameters.system != nil) tools=\(toolCount) thinking=\(parameters.thinking != nil)")
            let usesBearerTransport = usesAnthropicBearerTransport(apiKey)
                || providerHeaderValue(mergedHeaders, name: "Authorization")?
                    .lowercased().hasPrefix("bearer ") == true
            let anthropicStream = try await retryProviderRequest(
                maxRetries: options.maxRetries,
                maxRetryDelayMs: options.maxRetryDelayMs,
                signal: options.signal
            ) {
                try await streamAnthropicMessagesTolerant(
                    apiKey: apiKey,
                    usesBearerTransport: usesBearerTransport,
                    baseUrl: model.baseUrl,
                    betaHeaders: betaHeaders,
                    httpClient: httpClient,
                    parameters: parameters,
                    onResponse: options.onResponse
                )
            }

            stream.push(.start(partial: output))

            var indexMap: [Int: Int] = [:]
            var toolCallPartials: [Int: String] = [:]

            for try await decodedEvent in anthropicStream {
                if options.signal?.isCancelled == true {
                    throw AnthropicStreamError.aborted
                }

                let event = decodedEvent.response
                switch event.streamEvent {
                case .messageStart:
                    if let transformations = decodedEvent.inputTransformations { inputTransformations = transformations }
                    if let servingModel = decodedEvent.servingModel {
                        output.model = servingModel
                        usageModel = anthropicUsageModel(model, servingModel: servingModel)
                    }
                    if let messageId = event.message?.id {
                        output.responseId = messageId
                    }
                    if let usage = event.message?.usage {
                        let input = usage.inputTokens ?? 0
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? 0
                        let cacheWrite = usage.cacheCreationInputTokens ?? 0
                        output.usage = makeAnthropicUsage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            reasoning: usage.thinkingTokens
                        )
                        calculateCost(model: usageModel, usage: &output.usage)
                    }
                case .contentBlockStart:
                    guard let block = event.contentBlock, let index = event.index else { break }
                    switch block.type {
                    case "fallback":
                        if !output.content.isEmpty {
                            throw AnthropicStreamError.apiError("Anthropic performed an unsupported mid-output model fallback")
                        }
                        continue

                    case "text":
                        let textBlock = TextContent(text: block.text ?? "")
                        output.content.append(.text(textBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.textStart(contentIndex: output.content.count - 1, partial: output))
                    case "thinking":
                        let thinkingBlock = ThinkingContent(
                            thinking: block.thinking ?? "",
                            thinkingSignature: decodedEvent.initialThinkingSignature
                        )
                        output.content.append(.thinking(thinkingBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.thinkingStart(contentIndex: output.content.count - 1, partial: output))
                    case "redacted_thinking":
                        let thinkingBlock = ThinkingContent(
                            thinking: "[Reasoning redacted]",
                            thinkingSignature: block.data,
                            redacted: true
                        )
                        output.content.append(.thinking(thinkingBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.thinkingStart(contentIndex: output.content.count - 1, partial: output))
                        stream.push(.thinkingEnd(contentIndex: output.content.count - 1, content: thinkingBlock.thinking, partial: output))
                    case "tool_use":
                        let toolName = isOAuthToken ? fromClaudeCodeName(block.name ?? "", tools: context.tools) : (block.name ?? "")
                        let tool = ToolCall(id: block.id ?? "", name: toolName, arguments: [:])
                        output.content.append(.toolCall(tool))
                        indexMap[index] = output.content.count - 1
                        toolCallPartials[index] = ""
                        stream.push(.toolCallStart(contentIndex: output.content.count - 1, partial: output))
                    default:
                        break
                    }
                case .contentBlockDelta:
                    guard let index = event.index, let contentIndex = indexMap[index] else { break }
                    if let deltaType = event.delta?.type {
                        switch deltaType {
                        case "text_delta":
                            if case .text(var textBlock) = output.content[contentIndex] {
                                let deltaText = event.delta?.text ?? ""
                                textBlock.text += deltaText
                                output.content[contentIndex] = .text(textBlock)
                                stream.push(.textDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "thinking_delta":
                            if case .thinking(var thinkingBlock) = output.content[contentIndex] {
                                let deltaText = event.delta?.thinking ?? ""
                                thinkingBlock.thinking += deltaText
                                output.content[contentIndex] = .thinking(thinkingBlock)
                                stream.push(.thinkingDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "input_json_delta":
                            if case .toolCall(var toolCall) = output.content[contentIndex] {
                                let deltaText = event.delta?.partialJson ?? ""
                                let partial = (toolCallPartials[index] ?? "") + deltaText
                                toolCallPartials[index] = partial
                                toolCall.arguments = parseStreamingJSON(partial)
                                output.content[contentIndex] = .toolCall(toolCall)
                                stream.push(.toolCallDelta(contentIndex: contentIndex, delta: deltaText, partial: output))
                            }
                        case "signature_delta":
                            if case .thinking(var thinkingBlock) = output.content[contentIndex] {
                                let signature = event.delta?.signature ?? ""
                                thinkingBlock.thinkingSignature = (thinkingBlock.thinkingSignature ?? "") + signature
                                output.content[contentIndex] = .thinking(thinkingBlock)
                            }
                        default:
                            break
                        }
                    }
                case .contentBlockStop:
                    guard let index = event.index, let contentIndex = indexMap[index] else { break }
                    switch output.content[contentIndex] {
                    case .text(let textBlock):
                        stream.push(.textEnd(contentIndex: contentIndex, content: textBlock.text, partial: output))
                    case .thinking(let thinkingBlock):
                        stream.push(.thinkingEnd(contentIndex: contentIndex, content: thinkingBlock.thinking, partial: output))
                    case .toolCall(var toolCall):
                        let partial = toolCallPartials[index] ?? ""
                        toolCall.arguments = parseStreamingJSON(partial)
                        output.content[contentIndex] = .toolCall(toolCall)
                        stream.push(.toolCallEnd(contentIndex: contentIndex, toolCall: toolCall, partial: output))
                    default:
                        break
                    }
                case .messageDelta:
                    if let transformations = decodedEvent.inputTransformations { inputTransformations = transformations }
                    if let stopReason = event.delta?.stopReason {
                        output.rawStopReason = stopReason
                        let result = mapAnthropicStopReason(
                            stopReason,
                            refusalExplanation: decodedEvent.refusalExplanation
                        )
                        output.stopReason = result.stopReason
                        if let errorMessage = result.errorMessage {
                            output.errorMessage = errorMessage
                        }
                    }
                    if let usage = event.usage {
                        let input = usage.inputTokens ?? output.usage.input
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? output.usage.cacheRead
                        let cacheWrite = usage.cacheCreationInputTokens ?? output.usage.cacheWrite
                        output.usage = makeAnthropicUsage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            reasoning: usage.thinkingTokens ?? output.usage.reasoning
                        )
                        calculateCost(model: usageModel, usage: &output.usage)
                    }
                case .messageStop:
                    break
                case .none:
                    break
                }
            }

            if options.signal?.isCancelled == true {
                throw AnthropicStreamError.aborted
            }

            if output.stopReason == .pending {
                throw AnthropicStreamError.apiError("Anthropic stream ended without a stop reason")
            }
            if output.stopReason == .aborted {
                throw AnthropicStreamError.aborted
            }
            if output.stopReason == .error {
                throw AnthropicStreamError.apiError(output.errorMessage ?? "An unknown error occurred")
            }

            if let inputTransformations, !inputTransformations.isEmpty {
                var diagnostics = output.diagnostics ?? []
                diagnostics.append(AssistantMessageDiagnostic(
                    type: "anthropic_input_transformations",
                    details: ["transformations": AnyCodable(inputTransformations.map { $0.mapValues(\.value) })]
                ))
                output.diagnostics = diagnostics
            }
            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            logAnthropicDebug("anthropic error model=\(model.id) baseUrl=\(model.baseUrl) type=\(String(describing: type(of: error)))")
            if let apiError = error as? APIError {
                logAnthropicDebug("anthropic apiError=\(apiError.displayDescription)")
                if let debugService, let debugParameters {
                    await debugNonStreamingError(debugService, debugParameters)
                }
            } else {
                logAnthropicDebug("anthropic errorDescription=\(error.localizedDescription)")
            }
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = retryAwareErrorDescription(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private func buildAnthropicParameters(
    model: Model,
    context: Context,
    options: AnthropicOptions,
    isOAuthToken: Bool,
    compat: ResolvedAnthropicCompat,
    orderedTools: [AITool]
) -> MessageParameter {
    let messages = convertAnthropicMessages(model: model, messages: context.messages, isOAuthToken: isOAuthToken)
    let maxTokens = options.maxTokens ?? model.maxTokens

    var system: MessageParameter.System? = nil
    if let prompt = context.systemPrompt {
        system = .text(sanitizeSurrogates(prompt))
    }

    let tools = orderedTools.isEmpty ? nil : convertAnthropicTools(orderedTools, isOAuthToken: isOAuthToken)

    let thinkingEnabled = options.thinkingEnabled == true && model.reasoning
    let thinking: MessageParameter.Thinking? = {
        guard thinkingEnabled else { return nil }
        return MessageParameter.Thinking(budgetTokens: options.thinkingBudgetTokens ?? 1024)
    }()

    // Do NOT send temperature when thinking is enabled (incompatible with both
    // adaptive and budget-based thinking).
    let temperature = thinkingEnabled || !compat.supportsTemperature ? nil : options.temperature

    let toolChoice = options.toolChoice.map { convertAnthropicToolChoice($0, isOAuthToken: isOAuthToken) }

    let anthroModel = mapAnthropicModel(model.id)

    return MessageParameter(
        model: anthroModel,
        messages: messages,
        maxTokens: maxTokens,
        system: system,
        stream: true,
        temperature: temperature,
        tools: tools,
        toolChoice: toolChoice,
        thinking: thinking
    )
}

private let anthropicMessageSseEvents: Set<String> = [
    "message_start",
    "message_delta",
    "message_stop",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
]

struct AnthropicServerSentEvent {
    var event: String?
    var data: String
    var raw: [String]
}

private struct AnthropicSSEDecoder {
    var event: String?
    var data: [String] = []
    var raw: [String] = []

    mutating func decode(line: String) -> AnthropicServerSentEvent? {
        let normalized = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if normalized.isEmpty {
            return flush()
        }

        if normalized.hasPrefix(":") {
            raw.append(normalized)
            return nil
        }

        let parts = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let fieldName = parts.first.map(String.init) ?? normalized
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") {
            value.removeFirst()
        }

        if fieldName == "event" {
            // Line-based byte streams (AsyncLineSequence) swallow the blank
            // lines that delimit SSE events, so a new event field arriving
            // with data buffered means the previous event is complete.
            let pending = data.isEmpty ? nil : flush()
            raw.append(normalized)
            event = value
            return pending
        }
        raw.append(normalized)
        if fieldName == "data" {
            data.append(value)
        }
        return nil
    }

    mutating func flush() -> AnthropicServerSentEvent? {
        guard event != nil || !data.isEmpty else { return nil }
        let result = AnthropicServerSentEvent(event: event, data: data.joined(separator: "\n"), raw: raw)
        event = nil
        data = []
        raw = []
        return result
    }
}

func decodeAnthropicSSELines(_ lines: [String]) throws -> [MessageStreamResponse] {
    try decodeAnthropicSSEEvents(lines).map(\.response)
}

/// Same decode as `decodeAnthropicSSELines`, but preserves the fields that `MessageStreamResponse`
/// cannot carry (thinking signature, refusal explanation).
func decodeAnthropicSSEEvents(_ lines: [String]) throws -> [AnthropicDecodedMessageEvent] {
    var decoder = AnthropicSSEDecoder()
    var events: [AnthropicDecodedMessageEvent] = []
    var sawMessageStart = false
    var sawMessageStop = false

    func append(_ event: AnthropicDecodedMessageEvent) {
        if event.response.type == "message_start" {
            sawMessageStart = true
        } else if event.response.type == "message_stop" {
            sawMessageStop = true
        }
        events.append(event)
    }

    for line in lines {
        if let sse = decoder.decode(line: line),
           let event = try decodeAnthropicMessageEvent(sse) {
            append(event)
        }
    }
    if let sse = decoder.flush(),
       let event = try decodeAnthropicMessageEvent(sse) {
        append(event)
    }

    if sawMessageStart && !sawMessageStop {
        throw AnthropicTolerantStreamError.messageStopMissing
    }
    return events
}

struct AnthropicDecodedMessageEvent {
    let response: MessageStreamResponse
    let initialThinkingSignature: String?
    /// `delta.stop_details.explanation` from a `message_delta` event. `MessageStreamResponse.Delta`
    /// (vendored in SwiftAnthropic) has no `stop_details` field, so it is read out of the raw JSON.
    let refusalExplanation: String?
    let servingModel: String?
    let inputTransformations: [[String: AnyCodable]]?
}

private func decodeAnthropicMessageEvent(_ sse: AnthropicServerSentEvent) throws -> AnthropicDecodedMessageEvent? {
    if sse.event == "error" {
        throw AnthropicTolerantStreamError.sseError(sse.data)
    }
    guard let eventName = sse.event, anthropicMessageSseEvents.contains(eventName) else {
        return nil
    }
    do {
        return try decodeAnthropicJSONEvent(sse.data)
    } catch {
        throw AnthropicTolerantStreamError.invalidEvent(eventName: eventName, data: sse.data, raw: sse.raw, underlying: error)
    }
}

private func decodeAnthropicJSONEvent(_ json: String) throws -> AnthropicDecodedMessageEvent {
    guard let data = repairedAnthropicJSON(json).data(using: .utf8) else {
        throw AnthropicTolerantStreamError.invalidUTF8
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(MessageStreamResponse.self, from: data)
    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let contentBlock = root?["content_block"] as? [String: Any]
    let delta = root?["delta"] as? [String: Any]
    let stopDetails = delta?["stop_details"] as? [String: Any]
    let message = root?["message"] as? [String: Any]
    let transformationSource = response.type == "message_start" ? message : root
    let transformations = (transformationSource?["input_transformations"] as? [[String: Any]])?.map { item in
        var result: [String: AnyCodable] = [:]
        for key in ["type", "path", "reason"] {
            if let value = item[key], !(value is NSNull) { result[key] = AnyCodable(value) }
        }
        return result
    }
    return AnthropicDecodedMessageEvent(
        response: response,
        initialThinkingSignature: contentBlock?["signature"] as? String,
        refusalExplanation: stopDetails?["explanation"] as? String,
        servingModel: message?["model"] as? String,
        inputTransformations: transformations
    )
}

private func repairedAnthropicJSON(_ json: String) -> String {
    let validEscapes: Set<Character> = ["\"", "\\", "/", "b", "f", "n", "r", "t", "u"]
    var repaired = ""
    var inString = false
    var index = json.startIndex

    while index < json.endIndex {
        let char = json[index]
        if !inString {
            repaired.append(char)
            if char == "\"" {
                inString = true
            }
            index = json.index(after: index)
            continue
        }

        if char == "\"" {
            repaired.append(char)
            inString = false
            index = json.index(after: index)
            continue
        }

        if char == "\\" {
            let nextIndex = json.index(after: index)
            guard nextIndex < json.endIndex else {
                repaired.append("\\\\")
                index = nextIndex
                continue
            }
            let next = json[nextIndex]
            if next == "u" {
                let hexStart = json.index(after: nextIndex)
                let hexEnd = json.index(hexStart, offsetBy: 4, limitedBy: json.endIndex) ?? json.endIndex
                let digits = String(json[hexStart..<hexEnd])
                if digits.count == 4, digits.allSatisfy(\.isHexDigit) {
                    repaired.append("\\u\(digits)")
                    index = hexEnd
                    continue
                }
            }
            if validEscapes.contains(next) {
                repaired.append("\\")
                repaired.append(next)
                index = json.index(after: nextIndex)
                continue
            }
            repaired.append("\\\\")
            index = nextIndex
            continue
        }

        if char.isASCII, let scalar = char.unicodeScalars.first, scalar.value <= 0x1f {
            switch char {
            case "\u{08}":
                repaired.append("\\b")
            case "\u{0C}":
                repaired.append("\\f")
            case "\n":
                repaired.append("\\n")
            case "\r":
                repaired.append("\\r")
            case "\t":
                repaired.append("\\t")
            default:
                repaired.append(String(format: "\\u%04x", scalar.value))
            }
        } else {
            repaired.append(char)
        }
        index = json.index(after: index)
    }

    return repaired
}

private func streamAnthropicMessagesTolerant(
    apiKey: String,
    usesBearerTransport: Bool,
    baseUrl: String,
    betaHeaders: [String]?,
    httpClient: HTTPClient,
    parameters: MessageParameter,
    onResponse: ResponseHandler?
) async throws -> AsyncThrowingStream<AnthropicDecodedMessageEvent, Error> {
    var localParameters = parameters
    localParameters.stream = true
    let body = try anthropicJSONBody(localParameters)
    let url = try anthropicMessagesURL(baseUrl: baseUrl)
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
    ]
    // OAuth access tokens must be sent as a bearer token (matching upstream
    // pi's authToken usage); x-api-key is rejected with a 401 for them.
    for (name, value) in anthropicAuthenticationHeaders(
        apiKey: apiKey,
        usesBearerTransport: usesBearerTransport
    ) {
        headers[name] = value
    }
    if let betaHeaders, !betaHeaders.isEmpty {
        headers["anthropic-beta"] = betaHeaders.joined(separator: ",")
    }
    let request = HTTPRequest(url: url, method: .post, headers: headers, body: body)
    let (byteStream, response) = try await httpClient.bytes(for: request)
    let snapshot = anthropicResponseSnapshot(response)
    onResponse?(snapshot)
    guard snapshot.statusCode == 200 else {
        let body = try await collectAnthropicHTTPBody(byteStream)
        let message = String(data: body, encoding: .utf8) ?? "HTTP \(snapshot.statusCode)"
        throw StreamError.providerRequest(
            statusCode: snapshot.statusCode,
            headers: snapshot.headers,
            message: message
        )
    }
    return decodeAnthropicSSEStream(byteStream)
}

private func anthropicJSONBody(_ parameters: MessageParameter) throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try encoder.encode(parameters)
}

private func anthropicMessagesURL(baseUrl: String) throws -> URL {
    var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        trimmed = "https://api.anthropic.com"
    }
    if trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard let url = URL(string: trimmed + "/v1/messages") else {
        throw AnthropicTolerantStreamError.invalidBaseUrl(baseUrl)
    }
    return url
}

private func anthropicResponseSnapshot(_ response: HTTPResponse) -> ResponseSnapshot {
    var statusCode = 0
    var headers: [String: String] = [:]
    for child in Mirror(reflecting: response).children {
        switch child.label {
        case "statusCode":
            statusCode = child.value as? Int ?? statusCode
        case "headers":
            headers = child.value as? [String: String] ?? headers
        default:
            continue
        }
    }
    return ResponseSnapshot(statusCode: statusCode, headers: headers)
}

private func decodeAnthropicSSEStream(_ stream: HTTPByteStream) -> AsyncThrowingStream<AnthropicDecodedMessageEvent, Error> {
    let lines = anthropicLines(from: stream)
    return AsyncThrowingStream<AnthropicDecodedMessageEvent, Error> { continuation in
        let task = Task {
            var decoder = AnthropicSSEDecoder()
            var sawMessageStart = false
            var sawMessageStop = false

            func handle(_ sse: AnthropicServerSentEvent) throws {
                guard let event = try decodeAnthropicMessageEvent(sse) else { return }
                if event.response.type == "message_start" {
                    sawMessageStart = true
                } else if event.response.type == "message_stop" {
                    sawMessageStop = true
                }
                continuation.yield(event)
            }

            do {
                for try await line in lines {
                    if let sse = decoder.decode(line: line) {
                        try handle(sse)
                    }
                }
                if let sse = decoder.flush() {
                    try handle(sse)
                }
                if sawMessageStart && !sawMessageStop {
                    throw AnthropicTolerantStreamError.messageStopMissing
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
    }
}

private func anthropicLines(from stream: HTTPByteStream) -> AsyncThrowingStream<String, Error> {
    switch stream {
    case .lines(let lines):
        return lines
    case .bytes(let bytes):
        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var buffer = ""
                    for try await byte in bytes {
                        buffer.append(Character(UnicodeScalar(byte)))
                        while let range = buffer.range(of: #"\r\n|\n|\r"#, options: .regularExpression) {
                            continuation.yield(String(buffer[..<range.lowerBound]))
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private func mapAnthropicModel(_ id: String) -> SwiftAnthropic.Model {
    switch id {
    case "claude-3-5-haiku-latest":
        return .claude35Haiku
    default:
        return .other(id)
    }
}

/// Check if a model supports adaptive thinking.
/// These models have interleaved thinking built-in and don't need the beta header.
/// v0.67.5 added Opus 4.7 to this list.
private func supportsAdaptiveThinking(_ modelId: String) -> Bool {
    modelId.contains("opus-4-6") || modelId.contains("opus-4.6") ||
    modelId.contains("sonnet-4-6") || modelId.contains("sonnet-4.6") ||
    modelId.contains("opus-4-7") || modelId.contains("opus-4.7") ||
    modelId.contains("opus-4-8") || modelId.contains("opus-4.8") ||
    modelId.contains("sonnet-5") || modelId.contains("fable-5")
}

/// Maps an adaptive thinking effort level to a token budget.
private func adaptiveThinkingBudget(effort: ThinkingLevel, maxTokens: Int) -> Int {
    switch effort {
    case .minimal:
        return max(1024, maxTokens / 8)
    case .low:
        return max(1024, maxTokens / 4)
    case .medium:
        return max(2048, maxTokens / 2)
    case .high:
        return max(4096, maxTokens)
    case .xhigh:
        return max(8192, maxTokens * 2)
    case .max:
        return max(8192, maxTokens * 2)
    }
}

func buildAnthropicBetaHeaders(
    apiKey: String,
    interleavedThinking: Bool,
    provider: String,
    modelId: String = "",
    hasTools: Bool = true,
    supportsEagerToolInputStreaming: Bool = false
) -> [String]? {
    let env = ProcessInfo.processInfo.environment
    let disableFlag = (env["PI_DISABLE_ANTHROPIC_BETA"] ?? "").lowercased()
    if disableFlag == "1" || disableFlag == "true" || disableFlag == "yes" {
        return nil
    }
    if let override = env["PI_ANTHROPIC_BETA_HEADERS"] {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" {
            return nil
        }
        let items = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    // Adaptive thinking models (Opus 4.6, Sonnet 4.6) have interleaved thinking built-in.
    // The beta header is deprecated/redundant for these models.
    let needsInterleavedBeta = interleavedThinking && !supportsAdaptiveThinking(modelId)

    var headers: [String] = []
    if provider == "github-copilot" {
        if needsInterleavedBeta {
            headers.append("interleaved-thinking-2025-05-14")
        }
    } else {
        if hasTools && !supportsEagerToolInputStreaming {
            headers.append("fine-grained-tool-streaming-2025-05-14")
        }
        if needsInterleavedBeta {
            headers.append("interleaved-thinking-2025-05-14")
        }
    }
    if isAnthropicOAuthToken(apiKey) {
        headers.insert("oauth-2025-04-20", at: 0)
        headers.insert("claude-code-20250219", at: 0)
    }
    return headers.isEmpty ? nil : headers
}

private func convertAnthropicMessages(model: Model, messages: [Message], isOAuthToken: Bool) -> [MessageParameter.Message] {
    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, _, _ in
        let sanitized = id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return String(sanitized.prefix(64))
    }
    let transformed = transformMessages(messages, model: model, normalizeToolCallId: normalizeToolCallId)
    var params: [MessageParameter.Message] = []

    var index = 0
    while index < transformed.count {
        let msg = transformed[index]
        switch msg {
        case .user(let user):
            let content = convertUserContent(model: model, content: user.content)
            if let content {
                params.append(MessageParameter.Message(role: .user, content: content))
            }
        case .assistant(let assistant):
            let contentObjects = convertAssistantContent(assistant, isOAuthToken: isOAuthToken)
            if !contentObjects.isEmpty {
                params.append(MessageParameter.Message(role: .assistant, content: .list(contentObjects)))
            }
        case .toolResult(let toolResult):
            var toolResults: [MessageParameter.Message.Content.ContentObject] = []
            var imageBlocks: [ImageContent] = []
            toolResults.append(convertToolResultContent(toolResult: toolResult))
            imageBlocks.append(contentsOf: toolResult.content.compactMap { block in
                if case .image(let image) = block { return image }
                return nil
            })

            var lookahead = index + 1
            while lookahead < transformed.count {
                if case .toolResult(let next) = transformed[lookahead] {
                    toolResults.append(convertToolResultContent(toolResult: next))
                    imageBlocks.append(contentsOf: next.content.compactMap { block in
                        if case .image(let image) = block { return image }
                        return nil
                    })
                    lookahead += 1
                } else {
                    break
                }
            }
            index = lookahead - 1
            params.append(MessageParameter.Message(role: .user, content: .list(toolResults)))

            if !imageBlocks.isEmpty && model.input.contains(.image) {
                var imageContent: [MessageParameter.Message.Content.ContentObject] = [
                    .text("Attached image(s) from tool result:")
                ]
                for image in imageBlocks {
                    if let media = anthropicMediaType(from: image.mimeType) {
                        let source = MessageParameter.Message.Content.ImageSource(type: .base64, mediaType: media, data: image.data)
                        imageContent.append(.image(source))
                    }
                }
                params.append(MessageParameter.Message(role: .user, content: .list(imageContent)))
            }
        }
        index += 1
    }

    return params
}

private func convertUserContent(model: Model, content: UserContent) -> MessageParameter.Message.Content? {
    switch content {
    case .text(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return .text(sanitizeSurrogates(text))
    case .blocks(let blocks):
        var objects: [MessageParameter.Message.Content.ContentObject] = []
        for block in blocks {
            switch block {
            case .text(let textBlock):
                let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                objects.append(.text(sanitizeSurrogates(textBlock.text)))
            case .image(let imageBlock):
                if model.input.contains(.image), let media = anthropicMediaType(from: imageBlock.mimeType) {
                    let source = MessageParameter.Message.Content.ImageSource(type: .base64, mediaType: media, data: imageBlock.data)
                    objects.append(.image(source))
                }
            default:
                continue
            }
        }
        if objects.isEmpty { return nil }
        return .list(objects)
    }
}

private func convertAssistantContent(_ assistant: AssistantMessage, isOAuthToken: Bool) -> [MessageParameter.Message.Content.ContentObject] {
    var objects: [MessageParameter.Message.Content.ContentObject] = []
    for block in assistant.content {
        switch block {
        case .text(let textBlock):
            let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            objects.append(.text(sanitizeSurrogates(textBlock.text)))
        case .thinking(let thinkingBlock):
            // Redacted thinking: pass the opaque payload back as redacted_thinking
            if thinkingBlock.redacted == true {
                if let signature = thinkingBlock.thinkingSignature {
                    objects.append(.redactedThinking(signature))
                }
                continue
            }
            let trimmed = thinkingBlock.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let signature = thinkingBlock.thinkingSignature, !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                objects.append(.thinking(sanitizeSurrogates(thinkingBlock.thinking), signature))
            } else {
                objects.append(.text(sanitizeSurrogates(thinkingBlock.thinking)))
            }
        case .toolCall(let toolCall):
            let toolInput = convertToolArguments(toolCall.arguments)
            let toolName = isOAuthToken ? toClaudeCodeName(toolCall.name) : toolCall.name
            objects.append(.toolUse(sanitizeToolCallId(toolCall.id), toolName, toolInput))
        default:
            continue
        }
    }
    return objects
}

private func convertToolResultContent(toolResult: ToolResultMessage) -> MessageParameter.Message.Content.ContentObject {
    let textResult = toolResult.content.compactMap { block -> String? in
        if case .text(let textBlock) = block { return textBlock.text }
        return nil
    }.joined(separator: "\n")
    let content = sanitizeSurrogates(textResult.isEmpty ? "(see attached image)" : textResult)
    let toolResultObject = MessageParameter.Message.Content.ContentObject.toolResult(
        sanitizeToolCallId(toolResult.toolCallId),
        content,
        isError: toolResult.isError
    )
    return toolResultObject
}

private func convertAnthropicTools(_ tools: [AITool], isOAuthToken: Bool) -> [MessageParameter.Tool] {
    tools.compactMap { tool in
        let schema = anthropicJSONSchema(from: tool.parameters)
        let toolName = isOAuthToken ? toClaudeCodeName(tool.name) : tool.name
        return .function(name: toolName, description: tool.description, inputSchema: schema)
    }
}

private func anthropicJSONSchema(from parameters: [String: AnyCodable]) -> JSONSchema? {
    let jsonObject = parameters.mapValues { $0.jsonValue }
    guard JSONSerialization.isValidJSONObject(jsonObject),
          let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: []) else {
        return nil
    }
    return try? JSONDecoder().decode(JSONSchema.self, from: data)
}

private func convertAnthropicToolChoice(_ choice: AnthropicToolChoice, isOAuthToken: Bool) -> MessageParameter.ToolChoice {
    switch choice {
    case .auto:
        return .init(type: .auto)
    case .any:
        return .init(type: .any)
    case .none:
        return .init(type: .auto, disableParallelToolUse: true)
    case .tool(let name):
        let toolName = isOAuthToken ? toClaudeCodeName(name) : name
        return .init(type: .tool, name: toolName)
    }
}

func anthropicCacheTtl(baseUrl: String, supportsLongCacheRetention: Bool = true) -> String? {
    let flag = getenv("PI_CACHE_RETENTION").map { String(cString: $0) }?.lowercased()
    guard flag == "long" else { return nil }
    guard supportsLongCacheRetention else { return nil }
    guard baseUrl.contains("api.anthropic.com") else { return nil }
    return "1h"
}

private func buildAnthropicHttpClient(
    providerHTTPClient: (any ProviderHTTPClient)?,
    isOAuthToken: Bool,
    extraHeaders: ProviderHeaders,
    baseUrl: String,
    metadataUserId: String?,
    supportsLongCacheRetention: Bool,
    supportsEagerToolInputStreaming: Bool,
    supportsCacheControlOnTools: Bool,
    thinkingDisabled: Bool,
    deferredToolNames: Set<String> = [],
    toolResultAddedNames: [String: [String]] = [:],
    strictToolSchemas: [String: [String: AnyCodable]] = [:],
    rawRequestBody: Data? = nil
) -> HTTPClient {
    var merged = extraHeaders
    if !isOAuthToken && !providerHeadersContain(merged, name: "user-agent") {
        merged.updateValue(getPiUserAgent(), forKey: "User-Agent")
    }
    if isOAuthToken {
        if !providerHeadersContain(merged, name: "user-agent") {
            merged.updateValue("claude-cli/\(claudeCodeVersion)", forKey: "user-agent")
        }
        if !providerHeadersContain(merged, name: "x-app") {
            merged.updateValue("cli", forKey: "x-app")
        }
    }
    let cacheTtl = anthropicCacheTtl(baseUrl: baseUrl, supportsLongCacheRetention: supportsLongCacheRetention)
    let base: any HTTPClient = if let providerHTTPClient {
        ProviderAnthropicHTTPClient(base: providerHTTPClient)
    } else {
        HTTPClientFactory.createDefault()
    }
    return AnthropicHeaderInjectingHTTPClient(
        base: base,
        extraHeaders: merged,
        cacheTtl: cacheTtl,
        metadataUserId: metadataUserId,
        supportsEagerToolInputStreaming: supportsEagerToolInputStreaming,
        supportsCacheControlOnTools: supportsCacheControlOnTools,
        thinkingDisabled: thinkingDisabled,
        deferredToolNames: deferredToolNames,
        toolResultAddedNames: toolResultAddedNames,
        strictToolSchemas: strictToolSchemas,
        isOAuthToken: isOAuthToken,
        rawRequestBody: rawRequestBody
    )
}

private struct ProviderAnthropicHTTPClient: HTTPClient {
    let base: any ProviderHTTPClient

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        let response = try await base.send(try urlRequest(from: request))
        return (
            try await collectProviderHTTPBody(response.body),
            HTTPResponse(statusCode: response.statusCode, headers: response.headers)
        )
    }

    func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
        let response = try await base.send(try urlRequest(from: request))
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in response.body {
                        for byte in chunk {
                            continuation.yield(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (
            .bytes(stream),
            HTTPResponse(statusCode: response.statusCode, headers: response.headers)
        )
    }

    private func urlRequest(from request: HTTPRequest) throws -> URLRequest {
        let mirror = Mirror(reflecting: request)
        var url: URL?
        var method: HTTPMethod?
        var headers: [String: String] = [:]
        var body: Data?
        for child in mirror.children {
            switch child.label {
            case "url": url = child.value as? URL
            case "method": method = child.value as? HTTPMethod
            case "headers": headers = child.value as? [String: String] ?? [:]
            case "body": body = child.value as? Data
            default: break
            }
        }
        guard let url, let method else { throw StreamError.invalidHTTPResponse }
        var result = URLRequest(url: url)
        result.httpMethod = method.rawValue
        result.httpBody = body
        for (name, value) in headers {
            result.setValue(value, forHTTPHeaderField: name)
        }
        return result
    }
}

private func collectAnthropicHTTPBody(_ stream: HTTPByteStream) async throws -> Data {
    var data = Data()
    switch stream {
    case .bytes(let bytes):
        for try await byte in bytes { data.append(byte) }
    case .lines(let lines):
        for try await line in lines {
            data.append(Data(line.utf8))
            data.append(0x0A)
        }
    }
    return data
}

// MARK: - Copilot dynamic headers

/// Checks if any messages contain image content (for Copilot-Vision-Request header).
private func hasCopilotVisionInput(_ messages: [Message]) -> Bool {
    messages.contains { msg in
        switch msg {
        case .user(let user):
            if case .blocks(let blocks) = user.content {
                return blocks.contains { if case .image = $0 { return true } else { return false } }
            }
            return false
        case .toolResult(let toolResult):
            return toolResult.content.contains { if case .image = $0 { return true } else { return false } }
        case .assistant:
            return false
        }
    }
}

/// Infers X-Initiator value for Copilot requests.
private func inferCopilotInitiator(_ messages: [Message]) -> String {
    guard let last = messages.last else { return "user" }
    if case .user = last { return "user" }
    return "agent"
}

/// Builds dynamic headers for GitHub Copilot requests.
private func buildCopilotDynamicHeaders(messages: [Message]) -> [String: String] {
    var headers: [String: String] = [
        "X-Initiator": inferCopilotInitiator(messages),
        "Openai-Intent": "conversation-edits",
    ]
    if hasCopilotVisionInput(messages) {
        headers["Copilot-Vision-Request"] = "true"
    }
    return headers
}

private struct AnthropicHeaderInjectingHTTPClient: HTTPClient {
    let base: HTTPClient
    let extraHeaders: ProviderHeaders
    let cacheTtl: String?
    let metadataUserId: String?
    let supportsEagerToolInputStreaming: Bool
    let supportsCacheControlOnTools: Bool
    let thinkingDisabled: Bool
    let deferredToolNames: Set<String>
    let toolResultAddedNames: [String: [String]]
    let strictToolSchemas: [String: [String: AnyCodable]]
    let isOAuthToken: Bool
    let rawRequestBody: Data?

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        let updated = injectingHeaders(request)
        return try await base.data(for: updated)
    }

    func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
        let updated = injectingHeaders(request)
        return try await base.bytes(for: updated)
    }

    private func injectingHeaders(_ request: HTTPRequest) -> HTTPRequest {
        // SwiftAnthropic doesn't expose HTTPRequest properties publicly; mirror to add headers when possible.
        let mirror = Mirror(reflecting: request)
        var url: URL?
        var method: HTTPMethod?
        var headers: [String: String]?
        var body: Data?

        for child in mirror.children {
            switch child.label {
            case "url":
                url = child.value as? URL
            case "method":
                method = child.value as? HTTPMethod
            case "headers":
                headers = child.value as? [String: String]
            case "body":
                if let data = child.value as? Data {
                    body = data
                } else if let data = child.value as? Data? {
                    body = data
                }
            default:
                continue
            }
        }

        guard let url, let method, let headers else { return request }
        let mergedHeaders = providerHeadersToRecord(
            mergeProviderHeaders(headers, extraHeaders)
        ) ?? [:]
        let updatedBody = injectAnthropicRequestBody(
            body: body,
            ttl: cacheTtl,
            metadataUserId: metadataUserId,
            supportsEagerToolInputStreaming: supportsEagerToolInputStreaming,
            supportsCacheControlOnTools: supportsCacheControlOnTools,
            thinkingDisabled: thinkingDisabled,
            deferredToolNames: deferredToolNames,
            toolResultAddedNames: toolResultAddedNames,
            isOAuthToken: isOAuthToken,
            strictToolSchemas: strictToolSchemas
        )
        return HTTPRequest(url: url, method: method, headers: mergedHeaders, body: rawRequestBody ?? updatedBody ?? body)
    }
}

private func extractAnthropicMetadataUserId(_ metadata: [String: AnyCodable]?) -> String? {
    guard let raw = metadata?["user_id"]?.value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func injectAnthropicRequestBody(
    body: Data?,
    ttl: String?,
    metadataUserId: String?,
    supportsEagerToolInputStreaming: Bool = false,
    supportsCacheControlOnTools: Bool = true,
    thinkingDisabled: Bool = false,
    deferredToolNames: Set<String> = [],
    toolResultAddedNames: [String: [String]] = [:],
    isOAuthToken: Bool = false,
    strictToolSchemas: [String: [String: AnyCodable]] = [:]
) -> Data? {
    guard let body,
          var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return nil
    }

    if let system = payload["system"] {
        if let text = system as? String {
            payload["system"] = [cacheTextObject(text: text, ttl: ttl)]
        } else if var list = system as? [[String: Any]] {
            for index in list.indices {
                list[index] = ensureCacheControl(in: list[index], ttl: ttl)
            }
            payload["system"] = list
        }
    }

    // Anthropic's OAuth endpoint only serves Claude Code-shaped requests: the
    // first system block must be its identity line (matching upstream pi).
    if isOAuthToken {
        let spoof: [String: Any] = ["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."]
        if var list = payload["system"] as? [[String: Any]] {
            list.insert(spoof, at: 0)
            payload["system"] = list
        } else {
            payload["system"] = [spoof]
        }
    }

    if !deferredToolNames.isEmpty,
       var messages = payload["messages"] as? [[String: Any]] {
        var loadedToolNames = Set<String>()

        for messageIndex in messages.indices {
            guard (messages[messageIndex]["role"] as? String) == "user",
                  var blocks = messages[messageIndex]["content"] as? [[String: Any]] else {
                continue
            }

            var siblings: [[String: Any]] = []
            for blockIndex in blocks.indices {
                guard (blocks[blockIndex]["type"] as? String) == "tool_result",
                      let toolUseId = blocks[blockIndex]["tool_use_id"] as? String else {
                    continue
                }

                var references: [[String: Any]] = []
                for name in toolResultAddedNames[toolUseId] ?? [] {
                    let normalizedName = isOAuthToken ? toClaudeCodeName(name) : name
                    guard deferredToolNames.contains(normalizedName),
                          !loadedToolNames.contains(normalizedName) else {
                        continue
                    }
                    loadedToolNames.insert(normalizedName)
                    references.append([
                        "type": "tool_reference",
                        "tool_name": isOAuthToken ? toClaudeCodeName(name) : name,
                    ])
                }

                guard !references.isEmpty else { continue }
                let originalContent = blocks[blockIndex]["content"]
                blocks[blockIndex]["content"] = references

                if let text = originalContent as? String, !text.isEmpty {
                    siblings.append(["type": "text", "text": text])
                } else if let originalBlocks = originalContent as? [[String: Any]] {
                    siblings.append(contentsOf: originalBlocks)
                }
            }

            if !siblings.isEmpty {
                blocks.append(contentsOf: siblings)
            }
            messages[messageIndex]["content"] = blocks
        }
        payload["messages"] = messages
    }

    if var messages = payload["messages"] as? [[String: Any]],
       let lastIndex = messages.indices.last {
        var last = messages[lastIndex]
        if (last["role"] as? String) == "user" {
            if let content = last["content"] as? String {
                last["content"] = [cacheTextObject(text: content, ttl: ttl)]
            } else if var list = last["content"] as? [[String: Any]] {
                if let contentIndex = list.indices.last {
                    let block = list[contentIndex]
                    if shouldAddCacheControl(block) {
                        list[contentIndex] = ensureCacheControl(in: block, ttl: ttl)
                    }
                }
                last["content"] = list
            }
            messages[lastIndex] = last
            payload["messages"] = messages
        }
    }

    // v0.67.4: add a cache_control breakpoint on the last tool definition so tool schemas
    // can be cached independently from transcript updates while preserving existing cache
    // retention behavior.
    if var tools = payload["tools"] as? [[String: Any]], !tools.isEmpty {
        for index in tools.indices {
            if supportsEagerToolInputStreaming {
                tools[index]["eager_input_streaming"] = true
            }
            if let name = tools[index]["name"] as? String,
               deferredToolNames.contains(name) {
                tools[index]["defer_loading"] = true
            }
            if let name = tools[index]["name"] as? String,
               let schema = strictToolSchemas[name] {
                tools[index]["strict"] = true
                tools[index]["input_schema"] = schema.mapValues(\.value)
            }
        }

        if supportsCacheControlOnTools, let lastToolIndex = tools.indices.last {
            let lastTool = tools[lastToolIndex]
            if lastTool["cache_control"] == nil {
                tools[lastToolIndex] = ensureCacheControl(in: lastTool, ttl: ttl)
            }
        }
        payload["tools"] = tools
    }

    if let metadataUserId {
        payload["metadata"] = ["user_id": metadataUserId]
    }
    if thinkingDisabled {
        payload["thinking"] = ["type": "disabled"]
    }

    return try? JSONSerialization.data(withJSONObject: payload)
}

private func resolveAnthropicStrictToolSchemas(
    tools: [AITool],
    isOAuthToken: Bool,
    supportsStrictTools: Bool
) throws -> [String: [String: AnyCodable]] {
    var result: [String: [String: AnyCodable]] = [:]
    for tool in tools {
        if try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: supportsStrictTools) == true {
            result[isOAuthToken ? toClaudeCodeName(tool.name) : tool.name] = try getJsonSchemaToolParameters(tool, strict: true)
        }
    }
    return result
}

func injectCacheControl(body: Data?, ttl: String?) -> Data? {
    injectAnthropicRequestBody(body: body, ttl: ttl, metadataUserId: nil)
}

private func cacheTextObject(text: String, ttl: String?) -> [String: Any] {
    var object: [String: Any] = [
        "type": "text",
        "text": text,
    ]
    object["cache_control"] = cacheControlPayload(ttl: ttl)
    return object
}

private func cacheControlPayload(ttl: String?) -> [String: Any] {
    var control: [String: Any] = ["type": "ephemeral"]
    if let ttl {
        control["ttl"] = ttl
    }
    return control
}

private func ensureCacheControl(in block: [String: Any], ttl: String?) -> [String: Any] {
    guard block["cache_control"] == nil else { return block }
    var updated = block
    updated["cache_control"] = cacheControlPayload(ttl: ttl)
    return updated
}

private func shouldAddCacheControl(_ block: [String: Any]) -> Bool {
    guard let type = block["type"] as? String else { return false }
    return type == "text" || type == "image" || type == "tool_result"
}

func mapAnthropicStopReason(_ reason: String, refusalExplanation: String? = nil) -> StopReasonResult {
    switch reason {
    case "end_turn":
        return StopReasonResult(stopReason: .stop)
    case "max_tokens":
        return StopReasonResult(stopReason: .length)
    case "tool_use":
        return StopReasonResult(stopReason: .toolUse)
    case "refusal":
        // Upstream uses `stopDetails?.explanation || "..."`, so an empty explanation also falls back.
        let explanation = refusalExplanation.flatMap { $0.isEmpty ? nil : $0 }
        return StopReasonResult(
            stopReason: .error,
            errorMessage: explanation ?? "The model refused to complete the request"
        )
    case "pause_turn":
        return StopReasonResult(stopReason: .stop)
    case "stop_sequence":
        return StopReasonResult(stopReason: .stop)
    case "sensitive":
        return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: sensitive")
    default:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: \(reason)")
    }
}

private func sanitizeToolCallId(_ id: String) -> String {
    let allowed = id.map { char -> Character in
        if char.isLetter || char.isNumber || char == "_" || char == "-" {
            return char
        }
        return "_"
    }
    return String(allowed)
}

private func convertToolArguments(_ arguments: [String: AnyCodable]) -> MessageResponse.Content.Input {
    arguments.mapValues { convertDynamicContent($0.value) }
}

private func convertDynamicContent(_ value: Any) -> MessageResponse.Content.DynamicContent {
    switch value {
    case is NSNull:
        return .null
    case let intVal as Int:
        return .integer(intVal)
    case let doubleVal as Double:
        return .double(doubleVal)
    case let stringVal as String:
        return .string(stringVal)
    case let boolVal as Bool:
        return .bool(boolVal)
    case let arrayVal as [Any]:
        return .array(arrayVal.map { convertDynamicContent($0) })
    case let dictVal as [String: Any]:
        return .dictionary(dictVal.mapValues { convertDynamicContent($0) })
    default:
        return .string(String(describing: value))
    }
}

private func anthropicMediaType(from mimeType: String) -> MessageParameter.Message.Content.ImageSource.MediaType? {
    switch mimeType {
    case "image/jpeg", "image/jpg":
        return .jpeg
    case "image/png":
        return .png
    case "image/gif":
        return .gif
    case "image/webp":
        return .webp
    default:
        return nil
    }
}

private enum AnthropicStreamError: LocalizedError {
    case aborted
    case unknown
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "An unknown error occurred"
        case .apiError(let message):
            return message
        }
    }
}

private enum AnthropicTolerantStreamError: Error, LocalizedError {
    case invalidBaseUrl(String)
    case invalidUTF8
    case sseError(String)
    case invalidEvent(eventName: String, data: String, raw: [String], underlying: Error)
    case messageStopMissing
    case unsuccessfulStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseUrl(let baseUrl):
            return "Invalid Anthropic base URL: \(baseUrl)"
        case .invalidUTF8:
            return "Anthropic SSE event was not valid UTF-8"
        case .sseError(let data):
            return data
        case .invalidEvent(let eventName, let data, let raw, let underlying):
            return "Could not parse Anthropic SSE event \(eventName): \(underlying.localizedDescription); data=\(data); raw=\(raw.joined(separator: "\\n"))"
        case .messageStopMissing:
            return "Anthropic stream ended before message_stop"
        case .unsuccessfulStatus(let status):
            return "Anthropic stream returned status code \(status)"
        }
    }
}

func anthropicBetaFeatures(model: Model, context: Context, options: AnthropicOptions) -> [String]? {
    var configured: String?? = nil
    for headers in [model.headers, options.headers] {
        for (name, value) in headers ?? [:] where name.lowercased() == "anthropic-beta" {
            configured = .some(value)
        }
    }
    if let configured {
        guard let configured else { return nil }
        var seen = Set<String>()
        let values = configured.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return values.isEmpty ? nil : values
    }
    var features: [String] = []
    if isAnthropicOAuthToken(options.apiKey ?? "") {
        features += ["claude-code-20250219", "oauth-2025-04-20"]
    }
    if context.tools?.isEmpty == false && !resolveAnthropicCompat(model: model).supportsEagerToolInputStreaming {
        features.append("fine-grained-tool-streaming-2025-05-14")
    }
    if model.reasoning && options.thinkingEnabled == true && (options.interleavedThinking ?? true)
        && model.compat?.forceAdaptiveThinking != true {
        features.append("interleaved-thinking-2025-05-14")
    }
    if model.compat?.allowedFallbackModels?.isEmpty == false {
        features.append("server-side-fallback-2026-07-01")
    }
    if model.compat?.supportsMidConvoEffort == true {
        features += ["mid-conversation-output-config-2026-07-01", "thinking-binding-controls-2026-08-01"]
    }
    return features.isEmpty ? nil : features
}

func prepareAnthropicRawPayload(_ data: Data, model: Model, context: Context, options: AnthropicOptions) throws -> Data {
    var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    payload["stream"] = true
    let managed = model.compat?.supportsMidConvoEffort == true
    let display = options.thinkingDisplay?.rawValue ?? "summarized"
    if managed {
        payload["thinking"] = ["type": "adaptive", "display": display,
            "block_binding": ["prefix_mismatch_behavior": "drop_block"]]
        payload["output_config"] = ["effort": "high"]
        payload.removeValue(forKey: "temperature")
        let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: { id, _, _ in
            String(id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression).prefix(64))
        })
        let levels: [String?] = transformed.compactMap { message -> [String?]? in
            guard case .assistant(let assistant) = message,
                  !convertAssistantContent(assistant, isOAuthToken: isAnthropicOAuthToken(options.apiKey ?? "")).isEmpty else { return nil }
            let level = assistant.providerThinkingLevel
            let valid = assistant.api == .anthropicMessages && assistant.provider == model.provider
                && ["low", "medium", "high", "xhigh", "max"].contains(level ?? "")
            return [valid ? level : nil]
        }.flatMap { $0 }
        var messages: [[String: Any]] = []
        var assistantIndex = 0
        for message in payload["messages"] as? [[String: Any]] ?? [] {
            if message["role"] as? String == "assistant" {
                if assistantIndex < levels.count, let level = levels[assistantIndex] {
                    messages.append(anthropicEffortMarker(level))
                }
                assistantIndex += 1
            }
            messages.append(message)
        }
        messages.append(anthropicEffortMarker(options.effort?.rawValue ?? "high"))
        payload["messages"] = messages
    } else if model.reasoning && options.thinkingEnabled == true {
        if model.compat?.forceAdaptiveThinking == true {
            payload["thinking"] = ["type": "adaptive", "display": display]
            if let effort = options.effort { payload["output_config"] = ["effort": effort.rawValue] }
        } else {
            let budget = options.thinkingBudgetTokens ?? 1024
            payload["thinking"] = ["type": "enabled", "display": display, "budget_tokens": budget == 0 ? 1024 : budget]
        }
    }
    if let fallbacks = model.compat?.allowedFallbackModels, !fallbacks.isEmpty {
        payload["fallbacks"] = fallbacks.map { ["model": $0.model] }
    }
    return try JSONSerialization.data(withJSONObject: payload)
}

private func anthropicEffortMarker(_ level: String) -> [String: Any] {
    ["role": "system", "content": [Any](), "output_config": ["effort": level]]
}

func anthropicUsageModel(_ model: Model, servingModel: String) -> Model {
    guard servingModel != model.id,
          let fallback = model.compat?.allowedFallbackModels?.first(where: {
              $0.provider == model.provider && $0.model == servingModel
          }) else { return model }
    return Model(id: servingModel, name: model.name, api: model.api, provider: model.provider,
        baseUrl: model.baseUrl, reasoning: model.reasoning, input: model.input, cost: fallback.cost,
        contextWindow: model.contextWindow, maxTokens: model.maxTokens,
        samplingParams: model.samplingParams, headers: model.headers, compat: model.compat,
        thinkingLevelMap: model.thinkingLevelMap)
}
