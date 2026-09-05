import CryptoKit
import Foundation
import OpenAI

private let openAIToolCallProviders: Set<String> = ["openai", "openai-codex", "opencode"]

func resolveCacheRetention(_ cacheRetention: CacheRetention?) -> CacheRetention {
    if let cacheRetention {
        return cacheRetention
    }
    let flag = getenv("PI_CACHE_RETENTION").map { String(cString: $0) }?.lowercased()
    if flag == "long" {
        return .long
    }
    return .short
}

/// v0.70.0: opt-out via `compat.supportsLongCacheRetention == false` for proxies that
/// reject the `prompt_cache_retention` field. Long retention is on by default for direct
/// `api.openai.com` requests when `cacheRetention == .long`.
func getPromptCacheRetention(baseUrl: String, cacheRetention: CacheRetention, compat: OpenAICompat? = nil) -> String? {
    guard cacheRetention == .long else { return nil }
    if compat?.supportsLongCacheRetention == false { return nil }
    guard baseUrl.contains("api.openai.com") else { return nil }
    return "24h"
}

func makeOpenAIResponsesUsage(_ usage: Components.Schemas.ResponseUsage) -> Usage {
    let cached = usage.inputTokensDetails.cachedTokens
    return Usage(
        input: usage.inputTokens - cached,
        output: usage.outputTokens,
        cacheRead: cached,
        cacheWrite: 0,
        reasoning: usage.outputTokensDetails.reasoningTokens,
        totalTokens: usage.totalTokens
    )
}

struct OpenAIResponsesCacheMiddleware: OpenAIMiddleware {
    let sessionId: String?
    let cacheRetention: CacheRetention
    let promptCacheRetention: String?
    let sessionAffinityFormat: SessionAffinityFormat
    var supportsExplicitPromptCacheMode = false

    func intercept(request: URLRequest) -> URLRequest {
        var updated = request

        if let sessionId, !sessionId.isEmpty {
            if sessionAffinityFormat == .openrouter {
                updated.setValue(sessionId, forHTTPHeaderField: "x-session-id")
            } else {
                if sessionAffinityFormat == .openai {
                    updated.setValue(sessionId, forHTTPHeaderField: "session_id")
                }
                updated.setValue(sessionId, forHTTPHeaderField: "x-client-request-id")
            }
        }

        guard let body = readRequestBody(request) else { return updated }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return updated }

        if cacheRetention != .none, let sessionId, !sessionId.isEmpty {
            payload["prompt_cache_key"] = clampOpenAIPromptCacheKey(sessionId)
        } else {
            payload.removeValue(forKey: "prompt_cache_key")
        }
        if let promptCacheRetention {
            payload["prompt_cache_retention"] = promptCacheRetention
        } else {
            payload.removeValue(forKey: "prompt_cache_retention")
        }
        if cacheRetention == .none, supportsExplicitPromptCacheMode {
            payload["prompt_cache_options"] = ["mode": "explicit"]
        } else {
            payload.removeValue(forKey: "prompt_cache_options")
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return updated }
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

struct OpenAIResponsesReasoningEffortMiddleware: OpenAIMiddleware {
    let effort: String?

    func intercept(request: URLRequest) -> URLRequest {
        guard let effort,
              let body = request.httpBody,
              let updatedBody = applyOpenAIResponsesReasoningEffort(data: body, effort: effort) else {
            return request
        }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

func applyOpenAIResponsesReasoningEffort(data: Data, effort: String) -> Data? {
    guard var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var reasoning = payload["reasoning"] as? [String: Any] else {
        return nil
    }
    reasoning["effort"] = effort
    payload["reasoning"] = reasoning
    return try? JSONSerialization.data(withJSONObject: payload)
}

/// Middleware that rewrites function_call_output items containing inline image markers
/// into the proper array format (ResponseFunctionCallOutputItemList).
private let inlineImageMarker = "__INLINE_IMAGES__"

struct OpenAIResponsesInlineImagesMiddleware: OpenAIMiddleware {
    func intercept(request: URLRequest) -> URLRequest {
        guard let body = request.httpBody ?? readStream(request.httpBodyStream) else { return request }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return request }
        guard var input = payload["input"] as? [[String: Any]] else { return request }

        var modified = false
        for i in input.indices {
            guard let type = input[i]["type"] as? String, type == "function_call_output" else { continue }
            guard let output = input[i]["output"] as? String, output.hasPrefix(inlineImageMarker) else { continue }

            let json = String(output.dropFirst(inlineImageMarker.count))
            guard let data = json.data(using: .utf8),
                  let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }

            input[i]["output"] = parts
            modified = true
        }

        guard modified else { return request }
        payload["input"] = input
        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }

    private func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data.isEmpty ? nil : data
    }
}

public func streamOpenAIResponses(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
) -> AssistantMessageEventStream {
    if model.provider.lowercased() == "openai-codex" {
        let codexOptions = OpenAICodexResponsesOptions(
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            signal: options.signal,
            apiKey: options.apiKey,
            httpClient: options.httpClient,
            reasoningEffort: options.reasoningEffort,
            reasoningSummary: mapCodexReasoningSummary(options.reasoningSummary),
            cacheRetention: options.cacheRetention,
            sessionId: options.sessionId,
            transport: options.transport,
            headers: options.headers,
            onPayload: options.onPayload,
            serviceTier: options.serviceTier,
            onResponse: options.onResponse,
            timeoutMs: options.timeoutMs,
            maxRetries: options.maxRetries,
            maxRetryDelayMs: options.maxRetryDelayMs,
            websocketConnectTimeoutMs: options.websocketConnectTimeoutMs,
            toolChoice: options.toolChoice
        )
        return streamOpenAICodexResponses(model: model, context: context, options: codexOptions)
    }

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
        var client: OpenAI? = nil
        var query: CreateModelResponseQuery? = nil

        do {
            let cacheRetention = resolveCacheRetention(options.cacheRetention)
            let promptCacheRetention = getPromptCacheRetention(baseUrl: model.baseUrl, cacheRetention: cacheRetention, compat: model.compat)
            let isOpenRouter = model.provider == "openrouter" || model.baseUrl.contains("openrouter.ai")
            let middleware = OpenAIResponsesCacheMiddleware(
                sessionId: options.sessionId,
                cacheRetention: cacheRetention,
                promptCacheRetention: promptCacheRetention,
                sessionAffinityFormat: model.compat?.sessionAffinityFormat ?? (isOpenRouter ? .openrouter : .openai),
                supportsExplicitPromptCacheMode: model.compat?.supportsExplicitPromptCacheMode ?? false
            )
            let inlineImagesMiddleware = OpenAIResponsesInlineImagesMiddleware()
            let reasoningEffortMiddleware = OpenAIResponsesReasoningEffortMiddleware(
                effort: rawResponsesReasoningEffort(model: model, requested: options.reasoningEffort)
            )
            let supportsStrictMode = model.compat?.supportsStrictMode ?? true
            let supportsGrammar = model.compat?.supportsOpenAIGrammarTools ?? false
            let constrainedSamplingMiddleware = try makeOpenAIResponsesConstrainedSamplingMiddleware(
                tools: context.tools,
                supportsStrictMode: supportsStrictMode,
                supportsOpenAIGrammarTools: supportsGrammar
            )
            try validateResponsesGrammarReplay(
                messages: context.messages,
                grammarToolInputProperties: constrainedSamplingMiddleware.grammarToolInputProperties
            )
            var middlewares: [OpenAIMiddleware] = [
                middleware,
                inlineImagesMiddleware,
                reasoningEffortMiddleware,
                constrainedSamplingMiddleware,
                try makeResponsesReplayMiddleware(model: model, context: context),
            ]
            if let samplingParams = options.samplingParams, !samplingParams.isEmpty {
                // Keep this last so custom keys override all named request fields.
                middlewares.append(OpenAISamplingParamsMiddleware(samplingParams: samplingParams))
            }
            let builtClient = try makeOpenAIClient(
                model: model,
                apiKey: options.apiKey,
                headers: options.headers,
                timeoutMs: options.timeoutMs,
                middlewares: middlewares
            )
            let builtQuery = try buildResponsesQuery(model: model, context: context, options: options)
            let encodedQuery = try JSONEncoder().encode(builtQuery)
            var capturedRequest = URLRequest(url: openAIResponsesURL(baseUrl: model.baseUrl, provider: model.provider))
            capturedRequest.httpBody = encodedQuery
            capturedRequest = middlewares.reduce(capturedRequest) { $1.intercept(request: $0) }
            emitPayload(options.onPayload, data: capturedRequest.httpBody ?? encodedQuery)
            client = builtClient
            query = builtQuery
            if model.api == .openAIResponses
                || !constrainedSamplingMiddleware.grammarToolInputProperties.isEmpty
                || options.httpClient != nil
                || (options.maxRetries ?? 0) > 0 {
                var request = capturedRequest
                request.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000
                request.httpMethod = "POST"
                request.setValue("Bearer \(options.apiKey ?? "")", forHTTPHeaderField: "Authorization")
                request.setValue(getPiUserAgent(), forHTTPHeaderField: "User-Agent")
                request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                for (key, value) in model.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
                for (key, value) in options.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
                try await processRawOpenAIResponsesStream(
                    request: request,
                    model: model,
                    httpClient: options.httpClient,
                    signal: options.signal,
                    maxRetries: options.maxRetries,
                    maxRetryDelayMs: options.maxRetryDelayMs,
                    onResponse: options.onResponse,
                    serviceTier: options.serviceTier,
                    grammarToolInputProperties: constrainedSamplingMiddleware.grammarToolInputProperties,
                    stream: stream,
                    output: &output
                )
                try finishRawResponsesOutput(
                    output: output,
                    signal: options.signal,
                    providerName: "OpenAI Responses"
                )
                stream.push(.done(reason: output.stopReason, message: output))
                stream.end()
                return
            }
            let openAIStream: AsyncThrowingStream<ResponseStreamEvent, Error> = builtClient.responses.createResponseStreaming(query: builtQuery)
            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentToolCallArgs = ""
            // Responses events are multiplexed: a reasoning item can finish after
            // a later text/tool item has started. Track each item by output_index.
            var blockIndexByOutputIndex: [Int: Int] = [:]
            var toolCallArgsByOutputIndex: [Int: String] = [:]

            func startBlock(outputIndex: Int, kind: String, block: ContentBlock) {
                output.content.append(block)
                currentBlockIndex = output.content.count - 1
                blockIndexByOutputIndex[outputIndex] = currentBlockIndex
                switch block {
                case .text:
                    stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                case .thinking:
                    stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                case .toolCall:
                    stream.push(.toolCallStart(contentIndex: currentBlockIndex!, partial: output))
                default:
                    break
                }
            }

            func finishCurrentBlock() {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let textContent):
                    stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: output))
                case .thinking(let thinkingContent):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: output))
                case .toolCall(var toolCall):
                    toolCall.arguments = parseStreamingJSON(currentToolCallArgs)
                    output.content[index] = .toolCall(toolCall)
                    stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: output))
                default:
                    break
                }
                currentBlockIndex = nil
                currentToolCallArgs = ""
            }

            for try await event in openAIStream {
                if options.signal?.isCancelled == true {
                    throw OpenAIResponsesStreamError.aborted
                }

                switch event {
                case .outputItem(let itemEvent):
                    switch itemEvent {
                    case .added(let added):
                        switch added.item {
                        case .reasoning:
                            startBlock(outputIndex: added.outputIndex, kind: "thinking", block: .thinking(ThinkingContent(thinking: "")))
                        case .outputMessage:
                            startBlock(outputIndex: added.outputIndex, kind: "text", block: .text(TextContent(text: "")))
                        case .functionToolCall(let toolCall):
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let call = ToolCall(id: combinedId, name: toolCall.name, arguments: [:])
                            currentToolCallArgs = toolCall.arguments
                            toolCallArgsByOutputIndex[added.outputIndex] = toolCall.arguments
                            startBlock(outputIndex: added.outputIndex, kind: "toolCall", block: .toolCall(call))
                        default:
                            break
                        }
                    case .done(let doneEvent):
                        switch doneEvent.item {
                        case .reasoning(let reasoningItem):
                            if let index = blockIndexByOutputIndex[doneEvent.outputIndex], case .thinking(var thinking) = output.content[index] {
                                if let data = try? JSONEncoder().encode(reasoningItem),
                                   let signature = String(data: data, encoding: .utf8) {
                                    thinking.thinkingSignature = signature
                                    output.content[index] = .thinking(thinking)
                                }
                                stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                                blockIndexByOutputIndex.removeValue(forKey: doneEvent.outputIndex)
                            }
                        case .outputMessage(let message):
                            if let index = blockIndexByOutputIndex[doneEvent.outputIndex], case .text(var text) = output.content[index] {
                                text.textSignature = encodeTextSignatureV1(id: message.id)
                                output.content[index] = .text(text)
                                stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                                blockIndexByOutputIndex.removeValue(forKey: doneEvent.outputIndex)
                            }
                        case .functionToolCall(let toolCall):
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let partialArgs = toolCallArgsByOutputIndex[doneEvent.outputIndex] ?? ""
                            let preferredArgs = partialArgs.trimmingCharacters(in: .whitespacesAndNewlines)
                            var arguments = preferredArgs.isEmpty ? [:] : parseStreamingJSON(preferredArgs)
                            if arguments.isEmpty {
                                arguments = parseJSONStringArguments(toolCall.arguments)
                            }
                            var resolvedName = toolCall.name
                            if let index = blockIndexByOutputIndex[doneEvent.outputIndex], case .toolCall(let existing) = output.content[index] {
                                if resolvedName.isEmpty {
                                    resolvedName = existing.name
                                }
                                if arguments.isEmpty, !existing.arguments.isEmpty {
                                    arguments = existing.arguments
                                }
                            }
                            let call = ToolCall(id: combinedId, name: resolvedName, arguments: arguments)
                            if let index = blockIndexByOutputIndex[doneEvent.outputIndex] {
                                output.content[index] = .toolCall(call)
                                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: output))
                            }
                            blockIndexByOutputIndex.removeValue(forKey: doneEvent.outputIndex)
                            toolCallArgsByOutputIndex.removeValue(forKey: doneEvent.outputIndex)
                        default:
                            break
                        }
                    }
                case .reasoningSummaryText(let summaryEvent):
                    switch summaryEvent {
                    case .delta(let deltaEvent):
                        if let index = blockIndexByOutputIndex[deltaEvent.outputIndex], case .thinking(var thinking) = output.content[index] {
                            thinking.thinking += deltaEvent.delta
                            output.content[index] = .thinking(thinking)
                            stream.push(.thinkingDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .outputText(let outputTextEvent):
                    switch outputTextEvent {
                    case .delta(let deltaEvent):
                        if let index = blockIndexByOutputIndex[deltaEvent.outputIndex], case .text(var text) = output.content[index] {
                            text.text += deltaEvent.delta
                            output.content[index] = .text(text)
                            stream.push(.textDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .refusal(let refusalEvent):
                    switch refusalEvent {
                    case .delta(let deltaEvent):
                        if let index = blockIndexByOutputIndex[deltaEvent.outputIndex], case .text(var text) = output.content[index] {
                            text.text += deltaEvent.delta
                            output.content[index] = .text(text)
                            stream.push(.textDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done:
                        break
                    }
                case .functionCallArguments(let argumentsEvent):
                    switch argumentsEvent {
                    case .delta(let deltaEvent):
                        if let index = blockIndexByOutputIndex[deltaEvent.outputIndex], case .toolCall(var tool) = output.content[index] {
                            let args = (toolCallArgsByOutputIndex[deltaEvent.outputIndex] ?? "") + deltaEvent.delta
                            toolCallArgsByOutputIndex[deltaEvent.outputIndex] = args
                            tool.arguments = parseStreamingJSON(args)
                            output.content[index] = .toolCall(tool)
                            stream.push(.toolCallDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done(let doneEvent):
                        if let index = blockIndexByOutputIndex[doneEvent.outputIndex], case .toolCall(var tool) = output.content[index] {
                            let previousArgs = toolCallArgsByOutputIndex[doneEvent.outputIndex] ?? ""
                            toolCallArgsByOutputIndex[doneEvent.outputIndex] = doneEvent.arguments
                            tool.arguments = parseStreamingJSON(doneEvent.arguments)
                            output.content[index] = .toolCall(tool)
                            if let delta = finalToolCallArgumentsDelta(previous: previousArgs, final: doneEvent.arguments) {
                                stream.push(.toolCallDelta(contentIndex: index, delta: delta, partial: output))
                            }
                        }
                    }
                case .created(let created):
                    // Capture responseId early from response.created event
                    if output.responseId == nil {
                        output.responseId = created.response.id
                    }
                case .completed(let completed), .incomplete(let completed):
                    // Capture responseId from response.completed event (fallback)
                    if output.responseId == nil {
                        output.responseId = completed.response.id
                    }
                    if let usage = completed.response.usage {
                        output.usage = makeOpenAIResponsesUsage(usage)
                        calculateCost(model: model, usage: &output.usage)
                        applyServiceTierPricing(&output.usage, serviceTier: options.serviceTier, model: model)
                    }
                    let status = completed.response.status
                    let incompleteDetails = completed.response.incompleteDetails ?? nil
                    let incompleteReason = incompleteDetails?.reason?.rawValue
                    output.rawStopReason = incompleteReason.map { "\(status).\($0)" } ?? status
                    let result = mapResponsesStopReason(status, incompleteReason: incompleteReason)
                    output.stopReason = result.stopReason
                    if let errorMessage = result.errorMessage {
                        output.errorMessage = errorMessage
                    }
                    if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) && output.stopReason == .stop {
                        output.stopReason = .toolUse
                    }
                case .failed(let failed):
                    output.rawStopReason = failed.response.status
                    let errorDetail: String
                    if let responseError = failed.response.error {
                        errorDetail = "[\(responseError.code.rawValue)] \(responseError.message)"
                    } else {
                        errorDetail = "Response failed with status: \(failed.response.status)"
                    }
                    throw OpenAIResponsesStreamError.apiError(errorDetail)
                case .error(let errorEvent):
                    throw OpenAIResponsesStreamError.apiError(errorEvent.message)
                default:
                    break
                }
            }

            finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw OpenAIResponsesStreamError.aborted
            }

            if output.stopReason == .pending {
                throw OpenAIResponsesStreamError.apiError("OpenAI Responses stream ended without a stop reason")
            }
            if output.stopReason == .aborted {
                throw OpenAIResponsesStreamError.aborted
            }
            if output.stopReason == .error {
                throw OpenAIResponsesStreamError.apiError(output.errorMessage ?? "Provider returned an error stop reason")
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            if shouldLogOpenAIErrorBody(), let client, let query, error is OpenAIError {
                await debugOpenAIResponsesError(client: client, query: query)
            }
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = describeOpenAIError(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

func buildResponsesQuery(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
) throws -> CreateModelResponseQuery {
    let inputItems = convertResponsesMessages(model: model, context: context, allowedToolCallProviders: openAIToolCallProviders)

    var reasoning: Components.Schemas.Reasoning? = nil
    var include: [Components.Schemas.Includable]? = nil
    if model.reasoning {
        if options.reasoningEffort != nil || options.reasoningSummary != nil {
            reasoning = Components.Schemas.Reasoning(
                effort: mapResponsesReasoningEffort(model: model, requested: options.reasoningEffort) ?? .medium,
                summary: mapReasoningSummary(options.reasoningSummary) ?? .auto
            )
            include = [.reasoning_encryptedContent]
        } else if model.provider.lowercased() != "github-copilot", model.provider.lowercased() != "xai",
                  let offEffort = mapDisabledResponsesReasoningEffort(model: model) {
            reasoning = Components.Schemas.Reasoning(
                effort: offEffort,
                summary: nil
            )
        }
    }

    if model.provider.lowercased() == "xai", model.reasoning { include = [.reasoning_encryptedContent] }

    let tools = try responsesToolsPayload(
        context.tools,
        supportsStrictMode: model.compat?.supportsStrictMode ?? true
    )

    let query = CreateModelResponseQuery(
        input: .inputItemList(inputItems),
        model: model.id,
        include: include,
        instructions: nil,
        // OpenAI Responses rejects max_output_tokens below 16.
        maxOutputTokens: model.compat?.supportsMaxOutputTokens == false ? nil : options.maxTokens.map { max($0, 16) },
        reasoning: reasoning,
        serviceTier: mapResponsesServiceTier(options.serviceTier),
        store: false,
        stream: true,
        temperature: options.temperature,
        toolChoice: mapResponsesToolChoice(options.toolChoice),
        tools: tools
    )
    logOpenAIResponsesQuery(query)
    return query
}

func mapResponsesReasoningEffort(_ effort: ThinkingLevel?) -> Components.Schemas.ReasoningEffort? {
    guard let effort else { return nil }
    switch effort {
    case .minimal:
        return .minimal
    case .low:
        return .low
    case .medium:
        return .medium
    case .high, .xhigh, .max:
        return .high
    }
}

func mapResponsesReasoningEffort(model: Model, requested effort: ThinkingLevel?) -> Components.Schemas.ReasoningEffort? {
    guard let effort else { return nil }
    if let mapped = mappedThinkingLevel(model: model, level: effort),
       let mappedEffort = mapResponsesReasoningEffortValue(mapped) {
        return mappedEffort
    }
    return mapResponsesReasoningEffort(effort)
}

func rawResponsesReasoningEffort(model: Model, requested effort: ThinkingLevel?) -> String? {
    guard let effort else { return nil }
    let rawEffort = mappedThinkingLevel(model: model, level: effort) ?? effort.rawValue
    return rawEffort == "xhigh" || rawEffort == "max" ? rawEffort : nil
}

func mapDisabledResponsesReasoningEffort(model: Model) -> Components.Schemas.ReasoningEffort? {
    guard let off = mappedOffThinkingLevel(model: model) else { return nil }
    return mapResponsesReasoningEffortValue(off)
}

private func mapResponsesReasoningEffortValue(_ value: String) -> Components.Schemas.ReasoningEffort? {
    switch value.lowercased() {
    case "none":
        return Components.Schemas.ReasoningEffort.none
    case "minimal":
        return .minimal
    case "low":
        return .low
    case "medium":
        return .medium
    case "high", "xhigh", "max":
        return .high
    default:
        return nil
    }
}

func mapReasoningSummary(_ summary: OpenAIReasoningSummary?) -> Components.Schemas.Reasoning.SummaryPayload? {
    switch summary {
    case .auto:
        return .auto
    case .concise:
        return .concise
    case .detailed:
        return .detailed
    case .none:
        return nil
    }
}

private func mapCodexReasoningSummary(_ summary: OpenAIReasoningSummary?) -> OpenAICodexReasoningSummary? {
    switch summary {
    case .auto:
        return .auto
    case .concise:
        return .concise
    case .detailed:
        return .detailed
    case .none:
        return nil
    }
}

private func mapResponsesServiceTier(_ tier: OpenAIServiceTier?) -> ServiceTier? {
    switch tier {
    case .auto:
        return .auto
    case .defaultTier:
        return .defaultTier
    case .flex:
        return .flexTier
    case .priority, .onDemand:
        return .onDemand
    case .none:
        return nil
    }
}

/// v0.70.0: GPT-5.5 Codex applies a 2.5x priority service-tier multiplier (vs 2x for older
/// Codex models). Pass the model so we can pick the right rate.
private func serviceTierMultiplier(_ tier: OpenAIServiceTier?, model: Model? = nil) -> Double {
    switch tier {
    case .flex:
        return 0.5
    case .priority, .onDemand:
        if let modelId = model?.id, modelId.contains("gpt-5.5") {
            return 2.5
        }
        return 2
    default:
        return 1
    }
}

func applyServiceTierPricing(_ usage: inout Usage, serviceTier: OpenAIServiceTier?, model: Model? = nil) {
    let multiplier = serviceTierMultiplier(serviceTier, model: model)
    guard multiplier != 1 else { return }
    usage.cost.input *= multiplier
    usage.cost.output *= multiplier
    usage.cost.cacheRead *= multiplier
    usage.cost.cacheWrite *= multiplier
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite
}

func finalToolCallArgumentsDelta(previous: String, final: String) -> String? {
    guard final.hasPrefix(previous) else { return nil }
    let suffix = String(final.dropFirst(previous.count))
    return suffix.isEmpty ? nil : suffix
}

func responsesToolsPayload(_ tools: [AITool]?, supportsStrictMode: Bool) throws -> [Tool]? {
    guard let tools, !tools.isEmpty else { return nil }
    return try convertResponsesTools(tools, supportsStrictMode: supportsStrictMode)
}

func responsesToolsPayload(_ tools: [AITool]?) -> [Tool]? {
    try? responsesToolsPayload(tools, supportsStrictMode: true)
}

func normalizeIdPart(_ raw: String) -> String {
    let sanitized = raw.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
    let truncated = sanitized.count > 64 ? String(sanitized.prefix(64)) : sanitized
    return truncated.replacingOccurrences(of: "_+$", with: "", options: .regularExpression)
}

func convertResponsesMessages(model: Model, context: Context, allowedToolCallProviders: Set<String>) -> [InputItem] {
    var messages: [InputItem] = []

    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, model, source in
        guard allowedToolCallProviders.contains(model.provider) else { return normalizeIdPart(id) }
        if id.contains("|") {
            let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let callIdRaw = parts.first.map(String.init) ?? id
            let itemIdRaw = parts.count > 1 ? String(parts[1]) : ""

            let normalizedCallId = normalizeIdPart(callIdRaw)
            let isForeignToolCall = source.provider != model.provider || source.api != model.api
            var normalizedItemId = isForeignToolCall
                ? openAIResponsesForeignFunctionCallItemId(itemIdRaw)
                : normalizeIdPart(itemIdRaw)
            if !normalizedItemId.hasPrefix("fc_") {
                normalizedItemId = normalizeIdPart("fc_\(normalizedItemId)")
            }
            return "\(normalizedCallId)|\(normalizedItemId)"
        }
        return normalizeIdPart(id)
    }

    let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: normalizeToolCallId)

    if let systemPrompt = context.systemPrompt {
        let role: EasyInputMessage.RolePayload = model.reasoning ? .developer : .system
        let message = EasyInputMessage(role: role, content: .textInput(sanitizeSurrogates(systemPrompt)))
        messages.append(.inputMessage(message))
    }

    var messageIndex = 0
    for msg in transformed {
        switch msg {
        case .user(let user):
            switch user.content {
            case .text(let text):
                messages.append(.inputMessage(EasyInputMessage(role: .user, content: .textInput(sanitizeSurrogates(text)))))
            case .blocks(let blocks):
                let contents = blocks.compactMap { block -> InputContent? in
                    switch block {
                    case .text(let textContent):
                        return .inputText(Components.Schemas.InputTextContent(_type: .inputText, text: sanitizeSurrogates(textContent.text)))
                    case .image(let imageContent):
                        return .inputImage(InputImage(_type: .inputImage, imageUrl: "data:\(imageContent.mimeType);base64,\(imageContent.data)", detail: .auto))
                    default:
                        return nil
                    }
                }
                let filtered = model.input.contains(.image) ? contents : contents.filter {
                    if case .inputImage = $0 { return false }
                    return true
                }
                if !filtered.isEmpty {
                    messages.append(.inputMessage(EasyInputMessage(role: .user, content: .inputItemContentList(filtered))))
                }
            }
        case .assistant(let assistant):
            var items: [InputItem] = []
            let allowToolCalls: Bool
            switch assistant.stopReason {
            case .stop, .length, .toolUse:
                allowToolCalls = true
            case .pending, .error, .aborted, .deferred:
                allowToolCalls = false
            }
            let isDifferentModel = assistant.model != model.id &&
                assistant.provider == model.provider &&
                assistant.api == model.api
            for block in assistant.content {
                switch block {
                case .text(let textBlock):
                    let parsed = parseTextSignature(textBlock.textSignature)
                    let resolvedId = parsed?.id
                    let id = normalizeResponseItemId(resolvedId, fallbackIndex: messageIndex)
                    let content = Components.Schemas.OutputTextContent(_type: .outputText, text: sanitizeSurrogates(textBlock.text), annotations: [])
                    let outputMessage = Components.Schemas.OutputMessage(
                        id: id,
                        _type: .message,
                        role: .assistant,
                        content: [.OutputTextContent(content)],
                        status: .completed
                    )
                    items.append(.item(.outputMessage(outputMessage)))
                case .toolCall(let toolCall):
                    guard allowToolCalls else { break }
                    let parts = toolCall.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let callId = parts.first.map(String.init) ?? toolCall.id
                    let rawItemId = parts.count > 1 ? String(parts[1]) : nil
                    var itemId = normalizeOptionalResponseItemId(rawItemId)
                    if isDifferentModel, itemId?.hasPrefix("fc") == true {
                        itemId = nil
                    }
                    let toolItem = Components.Schemas.FunctionToolCall(
                        id: itemId,
                        _type: .functionCall,
                        callId: callId,
                        name: toolCall.name,
                        arguments: jsonString(from: toolCall.arguments),
                        status: .completed
                    )
                    items.append(.item(.functionToolCall(toolItem)))
                case .thinking(let thinking):
                    guard allowToolCalls else { break }
                    guard let signature = thinking.thinkingSignature,
                          let data = signature.data(using: .utf8) else {
                        break
                    }
                    if let reasoningItem = try? JSONDecoder().decode(Components.Schemas.ReasoningItem.self, from: data) {
                        items.append(.item(.reasoningItem(reasoningItem)))
                    } else {
                        logOpenAIDebug("openai responses failed to decode reasoning item signature")
                    }
                case .image:
                    break
                }
            }
            if !items.isEmpty {
                messages.append(contentsOf: items)
            }
        case .toolResult(let toolResult):
            let textResult = toolResult.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined(separator: "\n")
            let hasImages = toolResult.content.contains { block in
                if case .image = block { return true }
                return false
            }

            let callId = toolResult.toolCallId.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? toolResult.toolCallId

            if hasImages && model.input.contains(.image) {
                // Inline images in function_call_output via middleware rewrite.
                // We encode a JSON placeholder that the middleware will expand into
                // the proper ResponseFunctionCallOutputItemList array format.
                var inlineParts: [[String: Any]] = []
                if !textResult.isEmpty {
                    inlineParts.append(["type": "input_text", "text": sanitizeSurrogates(textResult)])
                }
                for block in toolResult.content {
                    if case .image(let image) = block {
                        inlineParts.append(["type": "input_image", "detail": "auto", "image_url": "data:\(image.mimeType);base64,\(image.data)"])
                    }
                }
                // Encode as JSON string — the middleware will parse and inline it
                let marker = "__INLINE_IMAGES__"
                if let partsData = try? JSONSerialization.data(withJSONObject: inlineParts),
                   let partsJson = String(data: partsData, encoding: .utf8) {
                    let toolOutput = Components.Schemas.FunctionCallOutputItemParam(
                        callId: callId,
                        _type: .functionCallOutput,
                        output: "\(marker)\(partsJson)"
                    )
                    messages.append(.item(.functionCallOutputItemParam(toolOutput)))
                } else {
                    // Fallback: send as text + separate user message
                    let toolOutput = Components.Schemas.FunctionCallOutputItemParam(
                        callId: callId,
                        _type: .functionCallOutput,
                        output: sanitizeSurrogates(textResult.isEmpty ? "(see attached image)" : textResult)
                    )
                    messages.append(.item(.functionCallOutputItemParam(toolOutput)))
                }
            } else {
                let toolOutput = Components.Schemas.FunctionCallOutputItemParam(
                    callId: callId,
                    _type: .functionCallOutput,
                    output: sanitizeSurrogates(textResult.isEmpty ? "(no tool output)" : textResult)
                )
                messages.append(.item(.functionCallOutputItemParam(toolOutput)))
            }
        }
        messageIndex += 1
    }

    return messages
}

func convertResponsesTools(_ tools: [AITool], supportsStrictMode: Bool) throws -> [Tool] {
    try tools.compactMap { tool in
        let constrainedStrict = try resolveJsonSchemaStrictSampling(
            tool: tool,
            supportsStrictMode: supportsStrictMode
        )
        let strict = constrainedStrict ?? false
        let parameters = try getJsonSchemaToolParameters(tool, strict: strict)
        let schema = openAIJSONSchema(from: parameters) ?? .object([:])
        let function = FunctionTool(name: tool.name, description: tool.description, parameters: schema, strict: strict)
        return .functionTool(function)
    }
}

func normalizeResponseItemId(_ id: String?, fallbackIndex: Int) -> String {
    var resolved = (id?.isEmpty == false) ? id! : "msg_\(fallbackIndex)"
    if resolved.count > 64 {
        resolved = "msg_\(shortHash(resolved))"
    }
    return resolved
}

func normalizeOptionalResponseItemId(_ id: String?) -> String? {
    guard let id, !id.isEmpty else { return nil }
    if id.count > 64 {
        return "msg_\(shortHash(id))"
    }
    return id
}

func openAIResponsesForeignFunctionCallItemId(_ itemId: String) -> String {
    let normalized = "fc_\(openAIResponsesShortHash(itemId))"
    return normalized.count > 64 ? String(normalized.prefix(64)) : normalized
}

func openAIResponsesShortHash(_ value: String) -> String {
    var h1: UInt32 = 0xdeadbeef
    var h2: UInt32 = 0x41c6ce57
    for unit in value.utf16 {
        h1 = (h1 ^ UInt32(unit)) &* 2_654_435_761
        h2 = (h2 ^ UInt32(unit)) &* 1_597_334_677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2_246_822_507) ^ ((h2 ^ (h2 >> 13)) &* 3_266_489_909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2_246_822_507) ^ ((h1 ^ (h1 >> 13)) &* 3_266_489_909)
    return String(h2, radix: 36) + String(h1, radix: 36)
}

func shortHash(_ value: String) -> String {
    guard let data = value.data(using: .utf8) else {
        return String(value.prefix(16))
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
}

private func shouldLogOpenAIPayload() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = env["PI_DEBUG_OPENAI_PAYLOAD"]?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes" || flag == "full"
}

private func shouldLogOpenAIErrorBody() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = env["PI_DEBUG_OPENAI_BODY"]?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

private func logOpenAIResponsesQuery(_ query: CreateModelResponseQuery) {
    guard shouldLogOpenAIDebug() else { return }
    let inputCount: Int
    switch query.input {
    case .textInput:
        inputCount = 1
    case .inputItemList(let items):
        inputCount = items.count
    }
    let toolCount = query.tools?.count ?? 0
    logOpenAIDebug("openai responses query model=\(query.model) inputItems=\(inputCount) tools=\(toolCount) reasoning=\(query.reasoning != nil) stream=\(query.stream == true)")

    guard shouldLogOpenAIPayload() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(query),
       var payload = String(data: data, encoding: .utf8) {
        if payload.count > 20000 {
            payload = String(payload.prefix(20000)) + "\n... (truncated)"
        }
        logOpenAIDebug("openai responses payload=\n\(payload)")
    }
}

private func debugOpenAIResponsesError(client: OpenAI, query: CreateModelResponseQuery) async {
    let nonStreaming = CreateModelResponseQuery(
        input: query.input,
        model: query.model,
        include: query.include,
        background: query.background,
        instructions: query.instructions,
        maxOutputTokens: query.maxOutputTokens,
        metadata: query.metadata,
        parallelToolCalls: query.parallelToolCalls,
        previousResponseId: query.previousResponseId,
        prompt: query.prompt,
        reasoning: query.reasoning,
        serviceTier: query.serviceTier,
        store: query.store,
        stream: false,
        temperature: query.temperature,
        text: query.text,
        toolChoice: query.toolChoice,
        tools: query.tools,
        topP: query.topP,
        truncation: query.truncation,
        user: query.user
    )

    do {
        _ = try await client.responses.createResponse(query: nonStreaming)
    } catch {
        if let apiError = error as? APIErrorResponse {
            logOpenAIDebug("openai errorBody message=\(apiError.error.message) type=\(apiError.error.type) param=\(apiError.error.param ?? "nil") code=\(apiError.error.code ?? "nil")")
        } else {
            logOpenAIDebug("openai nonstreaming error=\(error.localizedDescription)")
        }
    }
}

func parseJSONStringArguments(_ json: String) -> [String: AnyCodable] {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object.mapValues { AnyCodable($0) }
}

func encodeTextSignatureV1(id: String, phase: String? = nil) -> String {
    var payload: [String: Any] = ["v": 1, "id": id]
    if let phase { payload["phase"] = phase }
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let str = String(data: data, encoding: .utf8) { return str }
    return id
}

func parseTextSignature(_ signature: String?) -> (id: String, phase: String?)? {
    guard let sig = signature, !sig.isEmpty else { return nil }
    if sig.hasPrefix("{"), let data = sig.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let v = parsed["v"] as? Int, v == 1,
       let id = parsed["id"] as? String {
        return (id, parsed["phase"] as? String)
    }
    return (sig, nil)
}

func mapResponsesStopReason(_ status: String, incompleteReason: String? = nil) -> StopReasonResult {
    switch status {
    case "completed":
        return StopReasonResult(stopReason: .stop)
    case "incomplete":
        if incompleteReason == "max_output_tokens" {
            return StopReasonResult(stopReason: .length)
        }
        let message = incompleteReason.map { "Response incomplete: \($0)" }
            ?? "Response incomplete without a provider reason"
        return StopReasonResult(stopReason: .error, errorMessage: message)
    case "failed", "cancelled":
        return StopReasonResult(stopReason: .error)
    case "in_progress", "queued":
        return StopReasonResult(stopReason: .stop)
    default:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: \(status)")
    }
}

private enum OpenAIResponsesStreamError: LocalizedError {
    case aborted
    case unknown
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "OpenAI Responses request failed"
        case .apiError(let message):
            return message
        }
    }
}

func responsesToolChoicePayload(_ choice: OpenAIToolChoice) -> Any {
    switch choice {
    case .auto: return "auto"
    case .none: return "none"
    case .required: return "required"
    case .function(let name): return ["type": "function", "name": name]
    }
}

func mapResponsesToolChoice(_ choice: OpenAIToolChoice?) -> Components.Schemas.ResponseProperties.ToolChoicePayload? {
    guard let choice else { return nil }
    switch choice {
    case .auto: return .ToolChoiceOptions(.auto)
    case .none: return .ToolChoiceOptions(.none)
    case .required: return .ToolChoiceOptions(.required)
    case .function(let name): return .ToolChoiceFunction(.init(_type: .function, name: name))
    }
}

func responsesDeferredToolsEnabled(_ model: Model) -> Bool {
    model.compat?.supportsAdditionalTools == true || model.compat?.supportsToolSearch == true
}

/// The SDK does not represent namespaces or deferred-tool input items.
/// Keep these wire fields in a JSON rewrite after the SDK encodes the request.
struct ResponsesReplayMiddleware: OpenAIMiddleware {
    let namespaces: [String: String]
    let additions: [String: Data]
    let immediateToolNames: Set<String>

    func rewriteInput(_ input: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for var item in input {
            let type = item["type"] as? String
            let callId = item["call_id"] as? String ?? ""
            if type == "function_call" || type == "custom_tool_call" {
                if let namespace = namespaces[callId] { item["namespace"] = namespace }
                else { item.removeValue(forKey: "namespace") }
            }
            result.append(item)
            if (type == "function_call_output" || type == "custom_tool_call_output"),
               let data = additions[callId],
               let added = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                result.append(contentsOf: added)
            }
        }
        return result
    }

    func intercept(request: URLRequest) -> URLRequest {
        guard let data = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return request }
        if let input = payload["input"] as? [[String: Any]] { payload["input"] = rewriteInput(input) }
        if let tools = payload["tools"] as? [[String: Any]] {
            let immediate = tools.filter { immediateToolNames.contains($0["name"] as? String ?? "") }
            if immediate.isEmpty { payload.removeValue(forKey: "tools") }
            else { payload["tools"] = immediate }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return request }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = body
        return updated
    }
}

func makeResponsesReplayMiddleware(
    model: Model,
    context: Context,
    supportsDeferredTools: Bool = true
) throws -> ResponsesReplayMiddleware {
    let enabled = supportsDeferredTools && responsesDeferredToolsEnabled(model)
    let placement = splitDeferredTools(context, enabled: enabled)
    let deferred = Dictionary(uniqueKeysWithValues: placement.deferred.map { ($0.name, $0) })
    var namespaces: [String: String] = [:]
    var additions: [String: Data] = [:]
    var loadedNames: Set<String> = []
    for message in context.messages {
        switch message {
        case .assistant(let assistant):
            let sameModel = assistant.provider == model.provider && assistant.api == model.api && assistant.model == model.id
            for case .toolCall(let call) in assistant.content {
                guard let namespace = call.namespace, sameModel || deferred[call.name] != nil else { continue }
                let callId = call.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? call.id
                namespaces[callId] = namespace
                namespaces[normalizeIdPart(callId)] = namespace
                namespaces[normalizeIdPart(call.id)] = namespace
            }
        case .toolResult(let result):
            let tools = (result.addedToolNames ?? []).compactMap { name -> AITool? in
                guard let tool = deferred[name], loadedNames.insert(name).inserted else { return nil }
                return tool
            }
            guard !tools.isEmpty else { continue }
            var converted = try convertCodexTools(
                tools,
                supportsStrictMode: model.compat?.supportsStrictMode ?? true,
                supportsOpenAIGrammarTools: model.compat?.supportsOpenAIGrammarTools ?? false,
                defaultStrict: model.api == .openAICodexResponses ? nil : false
            )
            let items: [[String: Any]]
            if model.compat?.supportsAdditionalTools == true {
                items = [["type": "additional_tools", "role": "developer", "tools": converted]]
            } else {
                let names = tools.map(\.name)
                let searchId = "pi_tool_load_\(openAIResponsesShortHash("\(result.toolCallId):\(names.joined(separator: ","))"))"
                for index in converted.indices { converted[index]["defer_loading"] = true }
                items = [
                    ["type": "tool_search_call", "call_id": searchId, "execution": "client", "status": "completed",
                     "arguments": ["query": names.joined(separator: " "), "limit": names.count]],
                    ["type": "tool_search_output", "call_id": searchId, "execution": "client", "status": "completed", "tools": converted],
                ]
            }
            let callId = result.toolCallId.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? result.toolCallId
            let data = try JSONSerialization.data(withJSONObject: items)
            additions[callId] = data
            additions[normalizeIdPart(callId)] = data
            additions[normalizeIdPart(result.toolCallId)] = data
        case .user:
            break
        }
    }
    return ResponsesReplayMiddleware(
        namespaces: namespaces,
        additions: additions,
        immediateToolNames: Set(placement.immediate.map(\.name))
    )
}
