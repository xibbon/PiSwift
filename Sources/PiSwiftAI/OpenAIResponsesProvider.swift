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

struct OpenAIResponsesCacheMiddleware: OpenAIMiddleware {
    let sessionId: String?
    let cacheRetention: CacheRetention
    let promptCacheRetention: String?
    /// v0.70.0 / v0.67.6: when false, omit the underscore-containing `session_id` HTTP header
    /// (some strict OpenAI-compatible proxies reject it). Other affinity headers still flow.
    /// Default `true` matches official Codex CLI behavior.
    let sendSessionIdHeader: Bool

    func intercept(request: URLRequest) -> URLRequest {
        var updated = request

        // v0.67.2 / v0.67.6: send aligned `session_id` and `x-client-request-id` headers
        // unconditionally when sessionId is provided. This improves prompt cache affinity
        // for non-`api.openai.com` base URLs (litellm, theclawbay, etc.).
        if let sessionId, !sessionId.isEmpty {
            if sendSessionIdHeader {
                updated.setValue(sessionId, forHTTPHeaderField: "session_id")
            }
            updated.setValue(sessionId, forHTTPHeaderField: "x-client-request-id")
        }

        guard let body = readRequestBody(request) else { return updated }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return updated }

        if cacheRetention != .none, let sessionId, !sessionId.isEmpty {
            payload["prompt_cache_key"] = sessionId
        } else {
            payload.removeValue(forKey: "prompt_cache_key")
        }
        if let promptCacheRetention {
            payload["prompt_cache_retention"] = promptCacheRetention
        } else {
            payload.removeValue(forKey: "prompt_cache_retention")
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
            reasoningEffort: options.reasoningEffort,
            reasoningSummary: mapCodexReasoningSummary(options.reasoningSummary),
            sessionId: options.sessionId,
            transport: options.transport,
            headers: options.headers,
            onPayload: options.onPayload,
            serviceTier: options.serviceTier,
            onResponse: options.onResponse,
            timeoutMs: options.timeoutMs,
            maxRetries: options.maxRetries,
            websocketConnectTimeoutMs: options.websocketConnectTimeoutMs
        )
        return streamOpenAICodexResponses(model: model, context: context, options: codexOptions)
    }

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
        var client: OpenAI? = nil
        var query: CreateModelResponseQuery? = nil

        do {
            let cacheRetention = resolveCacheRetention(options.cacheRetention)
            let promptCacheRetention = getPromptCacheRetention(baseUrl: model.baseUrl, cacheRetention: cacheRetention, compat: model.compat)
            let middleware = OpenAIResponsesCacheMiddleware(
                sessionId: options.sessionId,
                cacheRetention: cacheRetention,
                promptCacheRetention: promptCacheRetention,
                sendSessionIdHeader: model.compat?.sendSessionIdHeader ?? true
            )
            let inlineImagesMiddleware = OpenAIResponsesInlineImagesMiddleware()
            let builtClient = try makeOpenAIClient(
                model: model,
                apiKey: options.apiKey,
                headers: options.headers,
                timeoutMs: options.timeoutMs,
                middlewares: [middleware, inlineImagesMiddleware]
            )
            let builtQuery = try buildResponsesQuery(model: model, context: context, options: options)
            emitPayload(options.onPayload, payload: builtQuery)
            client = builtClient
            query = builtQuery
            let openAIStream: AsyncThrowingStream<ResponseStreamEvent, Error> = builtClient.responses.createResponseStreaming(query: builtQuery)
            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var currentToolCallArgs = ""

            func startBlock(kind: String, block: ContentBlock) {
                output.content.append(block)
                currentBlockIndex = output.content.count - 1
                currentBlockKind = kind
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
                currentBlockKind = nil
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
                            finishCurrentBlock()
                            startBlock(kind: "thinking", block: .thinking(ThinkingContent(thinking: "")))
                        case .outputMessage:
                            finishCurrentBlock()
                            startBlock(kind: "text", block: .text(TextContent(text: "")))
                        case .functionToolCall(let toolCall):
                            finishCurrentBlock()
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let call = ToolCall(id: combinedId, name: toolCall.name, arguments: [:])
                            currentToolCallArgs = toolCall.arguments
                            startBlock(kind: "toolCall", block: .toolCall(call))
                        default:
                            break
                        }
                    case .done(let doneEvent):
                        switch doneEvent.item {
                        case .reasoning(let reasoningItem):
                            if currentBlockKind == "thinking", let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
                                if let data = try? JSONEncoder().encode(reasoningItem),
                                   let signature = String(data: data, encoding: .utf8) {
                                    thinking.thinkingSignature = signature
                                    output.content[index] = .thinking(thinking)
                                }
                                stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                                currentBlockIndex = nil
                                currentBlockKind = nil
                            }
                        case .outputMessage(let message):
                            if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
                                text.textSignature = encodeTextSignatureV1(id: message.id)
                                output.content[index] = .text(text)
                                stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                                currentBlockIndex = nil
                                currentBlockKind = nil
                            }
                        case .functionToolCall(let toolCall):
                            let idPart = toolCall.id ?? ""
                            let combinedId = "\(toolCall.callId)|\(idPart)"
                            let preferredArgs = currentToolCallArgs.trimmingCharacters(in: .whitespacesAndNewlines)
                            var arguments = preferredArgs.isEmpty ? [:] : parseStreamingJSON(preferredArgs)
                            if arguments.isEmpty {
                                arguments = parseJSONStringArguments(toolCall.arguments)
                            }
                            var resolvedName = toolCall.name
                            if let index = currentBlockIndex, case .toolCall(let existing) = output.content[index] {
                                if resolvedName.isEmpty {
                                    resolvedName = existing.name
                                }
                                if arguments.isEmpty, !existing.arguments.isEmpty {
                                    arguments = existing.arguments
                                }
                            }
                            let call = ToolCall(id: combinedId, name: resolvedName, arguments: arguments)
                            if let index = currentBlockIndex {
                                output.content[index] = .toolCall(call)
                                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: output))
                            }
                            currentBlockIndex = nil
                            currentBlockKind = nil
                            currentToolCallArgs = ""
                        default:
                            break
                        }
                    }
                case .reasoningSummaryText(let summaryEvent):
                    switch summaryEvent {
                    case .delta(let deltaEvent):
                        if currentBlockKind == "thinking", let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
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
                        if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
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
                        if currentBlockKind == "text", let index = currentBlockIndex, case .text(var text) = output.content[index] {
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
                        if currentBlockKind == "toolCall", let index = currentBlockIndex, case .toolCall(var tool) = output.content[index] {
                            currentToolCallArgs += deltaEvent.delta
                            tool.arguments = parseStreamingJSON(currentToolCallArgs)
                            output.content[index] = .toolCall(tool)
                            stream.push(.toolCallDelta(contentIndex: index, delta: deltaEvent.delta, partial: output))
                        }
                    case .done(let doneEvent):
                        if currentBlockKind == "toolCall", let index = currentBlockIndex, case .toolCall(var tool) = output.content[index] {
                            let previousArgs = currentToolCallArgs
                            currentToolCallArgs = doneEvent.arguments
                            tool.arguments = parseStreamingJSON(currentToolCallArgs)
                            output.content[index] = .toolCall(tool)
                            if let delta = finalToolCallArgumentsDelta(previous: previousArgs, final: currentToolCallArgs) {
                                stream.push(.toolCallDelta(contentIndex: index, delta: delta, partial: output))
                            }
                        }
                    }
                case .created(let created):
                    // Capture responseId early from response.created event
                    if output.responseId == nil {
                        output.responseId = created.response.id
                    }
                case .completed(let completed):
                    // Capture responseId from response.completed event (fallback)
                    if output.responseId == nil {
                        output.responseId = completed.response.id
                    }
                    if let usage = completed.response.usage {
                        let cached = usage.inputTokensDetails.cachedTokens
                        output.usage = Usage(
                            input: usage.inputTokens - cached,
                            output: usage.outputTokens,
                            cacheRead: cached,
                            cacheWrite: 0,
                            totalTokens: usage.totalTokens
                        )
                        calculateCost(model: model, usage: &output.usage)
                        applyServiceTierPricing(&output.usage, serviceTier: options.serviceTier, model: model)
                    }
                    output.stopReason = mapResponsesStopReason(completed.response.status)
                    if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) && output.stopReason == .stop {
                        output.stopReason = .toolUse
                    }
                case .failed(let failed):
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

            if output.stopReason == .aborted || output.stopReason == .error {
                throw OpenAIResponsesStreamError.unknown
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

private func buildResponsesQuery(
    model: Model,
    context: Context,
    options: OpenAIResponsesOptions
) throws -> CreateModelResponseQuery {
    var inputItems = convertResponsesMessages(model: model, context: context, allowedToolCallProviders: openAIToolCallProviders)

    var reasoning: Components.Schemas.Reasoning? = nil
    var include: [Components.Schemas.Includable]? = nil
    if model.reasoning {
        if options.reasoningEffort != nil || options.reasoningSummary != nil {
            reasoning = Components.Schemas.Reasoning(
                effort: mapResponsesReasoningEffort(options.reasoningEffort),
                summary: mapReasoningSummary(options.reasoningSummary)
            )
            include = [.reasoning_encryptedContent]
        } else if model.id.hasPrefix("gpt-5") {
            let note = EasyInputMessage(role: .developer, content: .textInput(sanitizeSurrogates("# Juice: 0 !important")))
            inputItems.append(.inputMessage(note))
        }
    }

    let tools = context.tools.map(convertResponsesTools)

    let query = CreateModelResponseQuery(
        input: .inputItemList(inputItems),
        model: model.id,
        include: include,
        instructions: nil,
        maxOutputTokens: options.maxTokens,
        reasoning: reasoning,
        serviceTier: mapResponsesServiceTier(options.serviceTier),
        store: false,
        stream: true,
        temperature: options.temperature,
        toolChoice: nil,
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
    case .high, .xhigh:
        return .high
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
            let allowToolCalls = assistant.stopReason != .error && assistant.stopReason != .aborted
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
                    output: sanitizeSurrogates(textResult.isEmpty ? "(no output)" : textResult)
                )
                messages.append(.item(.functionCallOutputItemParam(toolOutput)))
            }
        }
        messageIndex += 1
    }

    return messages
}

func convertResponsesTools(_ tools: [AITool]) -> [Tool] {
    tools.compactMap { tool in
        let schema = openAIJSONSchema(from: tool.parameters) ?? .object([:])
        let function = FunctionTool(name: tool.name, description: tool.description, parameters: schema, strict: false)
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

func mapResponsesStopReason(_ status: String) -> StopReason {
    switch status {
    case "completed":
        return .stop
    case "incomplete":
        return .length
    case "failed", "cancelled":
        return .error
    case "in_progress", "queued":
        return .stop
    default:
        return .stop
    }
}

private enum OpenAIResponsesStreamError: Error {
    case aborted
    case unknown
    case apiError(String)
}
