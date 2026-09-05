import Foundation

/// Stream from Mistral. Uses Mistral's OpenAI-compatible chat completions endpoint with
/// Mistral-specific extensions: prompt-mode reasoning for Magistral, `reasoning_effort` for
/// `mistral-small-2603` / `mistral-small-latest`, thinking-content blocks (text-array form),
/// 9-character tool-call IDs, and `x-affinity` session headers for KV-cache reuse.
public func streamMistral(
    model: Model,
    context: Context,
    options: MistralOptions
) -> AssistantMessageEventStream {
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
            guard let apiKey = options.apiKey, !apiKey.isEmpty else {
                throw MistralStreamError.missingApiKey(model.provider)
            }

            let normalizer = MistralToolCallIdNormalizer()
            let payload = try buildMistralPayload(
                model: model,
                context: context,
                options: options,
                normalizer: normalizer
            )

            emitPayload(options.onPayload, jsonObject: payload)
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])

            var request = URLRequest(url: mistralChatCompletionsUrl(baseUrl: model.baseUrl))
            request.timeoutInterval = Double(options.timeoutMs ?? 60_000) / 1000.0
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(getPiUserAgent(), forHTTPHeaderField: "User-Agent")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            request.setValue("application/json", forHTTPHeaderField: "content-type")

            var mergedHeaders = mergeProviderHeaders(model.headers, options.headers) ?? [:]
            // Mistral infrastructure uses `x-affinity` for KV-cache reuse (prefix caching).
            if let sessionId = options.sessionId, !sessionId.isEmpty, options.cacheRetention != CacheRetention.none,
               !providerHeadersContain(mergedHeaders, name: "x-affinity") {
                mergedHeaders.updateValue(sessionId, forKey: "x-affinity")
            }
            applyProviderHeaders(mergedHeaders, to: &request)
            request.httpBody = bodyData

            let response = try await fetchMistralStream(request: request, options: options)
            defer { response.cancel() }

            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var toolCallArgsByIndex: [Int: String] = [:]
            var toolCallContentIndexByKey: [String: Int] = [:]

            func finishCurrentBlock() {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let textContent):
                    stream.push(.textEnd(contentIndex: index, content: textContent.text, partial: output))
                case .thinking(let thinkingContent):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinkingContent.thinking, partial: output))
                default:
                    break
                }
                currentBlockIndex = nil
                currentBlockKind = nil
            }

            for try await rawEvent in parseMistralSseStream(body: response.body) {
                let event = rawEvent.mapValues(\.value)
                if options.signal?.isCancelled == true {
                    throw MistralStreamError.aborted
                }
                if let id = event["id"] as? String, output.responseId == nil, !id.isEmpty {
                    output.responseId = id
                }

                if let usage = event["usage"] as? [String: Any] {
                    let promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
                    let completionTokens = (usage["completion_tokens"] as? Int) ?? 0
                    let cachedTokens = mistralCachedPromptTokens(usage, promptTokens: promptTokens)
                    let reportedTotal = usage["total_tokens"] as? Int ?? 0
                    let totalTokens = reportedTotal == 0 ? promptTokens + completionTokens : reportedTotal
                    output.usage = Usage(
                        input: max(0, promptTokens - cachedTokens),
                        output: completionTokens,
                        cacheRead: cachedTokens,
                        cacheWrite: 0,
                        totalTokens: totalTokens
                    )
                    _ = calculateCost(model: model, usage: &output.usage)
                }

                guard let choices = event["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }

                if let finishReason = choice["finish_reason"] as? String {
                    output.rawStopReason = finishReason
                    let result = mapMistralStopReason(finishReason)
                    output.stopReason = result.stopReason
                    if let errorMessage = result.errorMessage {
                        output.errorMessage = errorMessage
                    }
                }

                guard let delta = choice["delta"] as? [String: Any] else { continue }

                if let content = delta["content"] {
                    let items: [Any]
                    if let str = content as? String {
                        items = [str]
                    } else if let arr = content as? [Any] {
                        items = arr
                    } else {
                        items = []
                    }
                    for item in items {
                        if let textDelta = item as? String, !textDelta.isEmpty {
                            if currentBlockKind != "text" {
                                finishCurrentBlock()
                                let textContent = TextContent(text: "")
                                output.content.append(.text(textContent))
                                currentBlockIndex = output.content.count - 1
                                currentBlockKind = "text"
                                stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                            }
                            let sanitized = sanitizeSurrogates(textDelta)
                            if case .text(var existing) = output.content[currentBlockIndex!] {
                                existing.text += sanitized
                                output.content[currentBlockIndex!] = .text(existing)
                            }
                            stream.push(.textDelta(contentIndex: currentBlockIndex!, delta: sanitized, partial: output))
                            continue
                        }
                        guard let dict = item as? [String: Any], let type = dict["type"] as? String else { continue }
                        if type == "text", let text = dict["text"] as? String, !text.isEmpty {
                            if currentBlockKind != "text" {
                                finishCurrentBlock()
                                let textContent = TextContent(text: "")
                                output.content.append(.text(textContent))
                                currentBlockIndex = output.content.count - 1
                                currentBlockKind = "text"
                                stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                            }
                            let sanitized = sanitizeSurrogates(text)
                            if case .text(var existing) = output.content[currentBlockIndex!] {
                                existing.text += sanitized
                                output.content[currentBlockIndex!] = .text(existing)
                            }
                            stream.push(.textDelta(contentIndex: currentBlockIndex!, delta: sanitized, partial: output))
                        } else if type == "thinking", let thinkingArr = dict["thinking"] as? [[String: Any]] {
                            let combined = thinkingArr
                                .compactMap { $0["text"] as? String }
                                .joined()
                            if combined.isEmpty { continue }
                            if currentBlockKind != "thinking" {
                                finishCurrentBlock()
                                let thinkingContent = ThinkingContent(thinking: "")
                                output.content.append(.thinking(thinkingContent))
                                currentBlockIndex = output.content.count - 1
                                currentBlockKind = "thinking"
                                stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                            }
                            let sanitized = sanitizeSurrogates(combined)
                            if case .thinking(var existing) = output.content[currentBlockIndex!] {
                                existing.thinking += sanitized
                                output.content[currentBlockIndex!] = .thinking(existing)
                            }
                            stream.push(.thinkingDelta(contentIndex: currentBlockIndex!, delta: sanitized, partial: output))
                        }
                    }
                }

                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for toolCall in toolCalls {
                        if currentBlockIndex != nil {
                            finishCurrentBlock()
                        }
                        let rawId = toolCall["id"] as? String
                        let toolIndex = toolCall["index"] as? Int ?? 0
                        let callId: String
                        if let rawId, !rawId.isEmpty, rawId != "null" {
                            callId = rawId
                        } else {
                            callId = MistralToolCallIdNormalizer.derive(from: "toolcall:\(toolIndex)", attempt: 0)
                        }
                        let key = (toolCall["index"] as? Int).map { "index:\($0)" } ?? "id:\(callId)"
                        let function = toolCall["function"] as? [String: Any]
                        let name = (function?["name"] as? String) ?? ""
                        let argDelta: String
                        if let args = function?["arguments"] as? String {
                            argDelta = args
                        } else if let argObj = function?["arguments"] {
                            argDelta = (try? String(data: JSONSerialization.data(withJSONObject: argObj, options: []), encoding: .utf8)) ?? ""
                        } else {
                            argDelta = ""
                        }

                        let contentIndex: Int
                        if let existing = toolCallContentIndexByKey[key] {
                            contentIndex = existing
                        } else {
                            let toolCallBlock = ToolCall(id: callId, name: name, arguments: [:])
                            output.content.append(.toolCall(toolCallBlock))
                            contentIndex = output.content.count - 1
                            toolCallContentIndexByKey[key] = contentIndex
                            stream.push(.toolCallStart(contentIndex: contentIndex, partial: output))
                        }
                        let prior = toolCallArgsByIndex[contentIndex] ?? ""
                        let combined = prior + argDelta
                        toolCallArgsByIndex[contentIndex] = combined
                        if case .toolCall(var block) = output.content[contentIndex] {
                            if !name.isEmpty { block.name = name }
                            if let rawId, !rawId.isEmpty, rawId != "null" { block.id = rawId }
                            block.arguments = parseStreamingJSON(combined)
                            output.content[contentIndex] = .toolCall(block)
                        }
                        stream.push(.toolCallDelta(contentIndex: contentIndex, delta: argDelta, partial: output))
                    }
                }
            }

            finishCurrentBlock()
            for (index, args) in toolCallArgsByIndex {
                if case .toolCall(var block) = output.content[index] {
                    block.arguments = parseStreamingJSON(args)
                    output.content[index] = .toolCall(block)
                    stream.push(.toolCallEnd(contentIndex: index, toolCall: block, partial: output))
                }
            }

            if options.signal?.isCancelled == true {
                throw MistralStreamError.aborted
            }
            if output.stopReason == .pending {
                throw MistralStreamError.streamEndedWithoutFinishReason
            }
            if output.stopReason == .aborted {
                throw MistralStreamError.aborted
            }
            if output.stopReason == .error {
                throw MistralStreamError.providerError(output.errorMessage ?? "An unknown error occurred")
            }
            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = formatMistralError(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

public enum MistralStreamError: Error, LocalizedError {
    case missingApiKey(String)
    case invalidResponse
    case apiError(Int, String)
    case aborted
    case unknown
    case streamEndedWithoutFinishReason
    case providerError(String)
    case timeout
    case invalidStreamingEvent

    public var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for provider: \(provider)"
        case .invalidResponse:
            return "Mistral response failed: invalid response"
        case .apiError(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "Request failed with status \(status)" : truncateMistralErrorText(trimmed, maxChars: 4000)
            return "Mistral API error (\(status)): \(detail)"
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "An unknown error occurred"
        case .streamEndedWithoutFinishReason:
            return "Mistral stream ended without a finish reason"
        case .providerError(let message):
            return message
        case .timeout:
            return "Mistral request timeout"
        case .invalidStreamingEvent:
            return "Invalid Mistral streaming event"
        }
    }
}

private func formatMistralError(_ error: Error) -> String {
    if let mistralError = error as? MistralStreamError {
        return mistralError.errorDescription ?? "\(mistralError)"
    }
    if case StreamError.providerRequest(let status?, _, let body) = error {
        return MistralStreamError.apiError(status, body).errorDescription ?? body
    }
    return retryAwareErrorDescription(error)
}

private func truncateMistralErrorText(_ text: String, maxChars: Int) -> String {
    guard text.count > maxChars else { return text }
    let head = text.prefix(maxChars)
    return "\(head)... [truncated \(text.count - maxChars) chars]"
}

private func mistralChatCompletionsUrl(baseUrl: String) -> URL {
    let trimmed = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    if trimmed.hasSuffix("/v1") {
        return URL(string: "\(trimmed)/chat/completions")!
    }
    return URL(string: "\(trimmed)/v1/chat/completions")!
}

func mapMistralStopReason(_ reason: String) -> StopReasonResult {
    switch reason {
    case "stop": return StopReasonResult(stopReason: .stop)
    case "length", "model_length": return StopReasonResult(stopReason: .length)
    case "tool_calls": return StopReasonResult(stopReason: .toolUse)
    case "error": return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: error")
    default: return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: \(reason)")
    }
}

/// Transforms domain messages into Mistral chat-completions wire format. Tool-call IDs are
/// normalized to nine-character alphanumeric strings (a Mistral API constraint).
private func buildMistralPayload(
    model: Model,
    context: Context,
    options: MistralOptions,
    normalizer: MistralToolCallIdNormalizer
) throws -> [String: Any] {
    var payload: [String: Any] = [
        "model": model.id,
        "stream": true,
    ]

    let supportsImages = model.input.contains(.image)
    var messages: [[String: Any]] = []
    if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
        messages.append([
            "role": "system",
            "content": sanitizeSurrogates(systemPrompt),
        ])
    }
    for message in context.messages {
        switch message {
        case .user(let user):
            if let entry = encodeMistralUserMessage(user, supportsImages: supportsImages) {
                messages.append(entry)
            }
        case .assistant(let assistant):
            if let entry = encodeMistralAssistantMessage(assistant, normalizer: normalizer) {
                messages.append(entry)
            }
        case .toolResult(let toolResult):
            messages.append(encodeMistralToolResult(toolResult, supportsImages: supportsImages, normalizer: normalizer))
        }
    }
    payload["messages"] = messages

    if let tools = context.tools, !tools.isEmpty {
        payload["tools"] = try tools.map { tool -> [String: Any] in
            let strict = try resolveJsonSchemaStrictSampling(tool: tool, supportsStrictMode: true)
            var function: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "strict": strict ?? false,
            ]
            function["parameters"] = try getJsonSchemaToolParameters(tool, strict: strict == true).mapValues { $0.value }
            return ["type": "function", "function": function]
        }
    }

    if let temperature = options.temperature {
        payload["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
        payload["max_tokens"] = maxTokens
    }
    if let toolChoice = options.toolChoice?.value {
        payload["tool_choice"] = toolChoice
    }
    if let promptMode = options.promptMode {
        payload["prompt_mode"] = promptMode
    }
    if let effort = options.reasoningEffort {
        payload["reasoning_effort"] = effort
    }
    if let sessionId = options.sessionId, !sessionId.isEmpty, options.cacheRetention != CacheRetention.none {
        payload["prompt_cache_key"] = sessionId
    }
    return payload
}

private func encodeMistralUserMessage(_ user: UserMessage, supportsImages: Bool) -> [String: Any]? {
    switch user.content {
    case .text(let text):
        let sanitized = sanitizeSurrogates(text)
        if sanitized.isEmpty { return nil }
        return ["role": "user", "content": sanitized]
    case .blocks(let blocks):
        var parts: [[String: Any]] = []
        var hadImages = false
        for block in blocks {
            switch block {
            case .text(let textBlock):
                parts.append(["type": "text", "text": sanitizeSurrogates(textBlock.text)])
            case .image(let imageBlock):
                hadImages = true
                if supportsImages {
                    parts.append([
                        "type": "image_url",
                        "image_url": "data:\(imageBlock.mimeType);base64,\(imageBlock.data)",
                    ])
                }
            default:
                continue
            }
        }
        if !parts.isEmpty {
            return ["role": "user", "content": parts]
        }
        if hadImages {
            return ["role": "user", "content": "(image omitted: model does not support images)"]
        }
        return nil
    }
}

private func encodeMistralAssistantMessage(
    _ assistant: AssistantMessage,
    normalizer: MistralToolCallIdNormalizer
) -> [String: Any]? {
    var contentParts: [[String: Any]] = []
    var toolCalls: [[String: Any]] = []

    for block in assistant.content {
        switch block {
        case .text(let textBlock):
            let trimmed = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                contentParts.append(["type": "text", "text": sanitizeSurrogates(textBlock.text)])
            }
        case .thinking(let thinkingBlock):
            let trimmed = thinkingBlock.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                contentParts.append([
                    "type": "thinking",
                    "thinking": [["type": "text", "text": sanitizeSurrogates(thinkingBlock.thinking)]],
                ])
            }
        case .toolCall(let toolCall):
            let argsJSON = jsonEncodeMistralArgs(toolCall.arguments)
            toolCalls.append([
                "id": normalizer.normalize(toolCall.id),
                "type": "function",
                "index": 0,
                "function": [
                    "name": toolCall.name,
                    "arguments": argsJSON,
                ],
            ])
        default:
            continue
        }
    }

    if contentParts.isEmpty && toolCalls.isEmpty {
        return nil
    }
    var entry: [String: Any] = ["role": "assistant", "prefix": false]
    if !contentParts.isEmpty {
        entry["content"] = contentParts
    }
    if !toolCalls.isEmpty {
        entry["tool_calls"] = toolCalls
    }
    return entry
}

private func encodeMistralToolResult(
    _ result: ToolResultMessage,
    supportsImages: Bool,
    normalizer: MistralToolCallIdNormalizer
) -> [String: Any] {
    let textParts = result.content.compactMap { block -> String? in
        if case .text(let textBlock) = block { return sanitizeSurrogates(textBlock.text) }
        return nil
    }
    let combinedText = textParts.joined(separator: "\n")
    let hasImages = result.content.contains { block in
        if case .image = block { return true } else { return false }
    }
    let toolText = mistralBuildToolResultText(text: combinedText, hasImages: hasImages, supportsImages: supportsImages, isError: result.isError)
    var content: [[String: Any]] = [["type": "text", "text": toolText]]
    if supportsImages {
        for block in result.content {
            if case .image(let imageBlock) = block {
                content.append([
                    "type": "image_url",
                    "image_url": "data:\(imageBlock.mimeType);base64,\(imageBlock.data)",
                ])
            }
        }
    }
    return [
        "role": "tool",
        "tool_call_id": normalizer.normalize(result.toolCallId),
        "name": result.toolName,
        "content": content,
    ]
}

private func mistralBuildToolResultText(text: String, hasImages: Bool, supportsImages: Bool, isError: Bool) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let errorPrefix = isError ? "[tool error] " : ""
    if !trimmed.isEmpty {
        let imageSuffix = hasImages && !supportsImages ? "\n[tool image omitted: model does not support images]" : ""
        return "\(errorPrefix)\(trimmed)\(imageSuffix)"
    }
    if hasImages {
        if supportsImages {
            return isError ? "[tool error] (see attached image)" : "(see attached image)"
        }
        return isError
            ? "[tool error] (image omitted: model does not support images)"
            : "(image omitted: model does not support images)"
    }
    return isError ? "[tool error] (no tool output)" : "(no tool output)"
}

private func jsonEncodeMistralArgs(_ args: [String: AnyCodable]) -> String {
    let plain = args.mapValues { $0.value }
    if let data = try? JSONSerialization.data(withJSONObject: plain, options: []),
       let str = String(data: data, encoding: .utf8) {
        return str
    }
    return "{}"
}

/// Mistral requires tool-call IDs to be exactly 9 alphanumeric characters. This normalizer
/// preserves identity (same input yields same output) and resolves collisions by hashing.
///
/// SAFETY: instances are request-local and used synchronously while constructing
/// one payload, so the mutable maps are not shared across concurrent tasks.
private final class MistralToolCallIdNormalizer {
    private static let length = 9
    private var idMap: [String: String] = [:]
    private var reverseMap: [String: String] = [:]

    func normalize(_ id: String) -> String {
        if let existing = idMap[id] { return existing }
        var attempt = 0
        while true {
            let candidate = MistralToolCallIdNormalizer.derive(from: id, attempt: attempt)
            if let owner = reverseMap[candidate], owner != id {
                attempt += 1
                continue
            }
            idMap[id] = candidate
            reverseMap[candidate] = id
            return candidate
        }
    }

    static func derive(from id: String, attempt: Int) -> String {
        let normalized = id.filter { $0.isLetter || $0.isNumber }
        if attempt == 0 && normalized.count == length {
            return normalized
        }
        let seedBase = normalized.isEmpty ? id : normalized
        let seed = attempt == 0 ? seedBase : "\(seedBase):\(attempt)"
        let hashed = shortHash(seed).filter { $0.isLetter || $0.isNumber }
        return String(hashed.prefix(length))
    }
}

private enum MistralSseEvent {
    case message([String: AnyCodable])
    case done
    case ignored
}

private func parseMistralSseStream(body: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<[String: AnyCodable], Error> {
    AsyncThrowingStream { continuation in
        let reader = Task {
            var buffer = Data()
            do {
                for try await chunk in body {
                    buffer.append(chunk)
                    while let range = findMistralDelimiter(in: buffer) {
                        let frame = buffer.subdata(in: 0..<range.lowerBound)
                        buffer.removeSubrange(0..<range.upperBound)
                        switch try parseMistralSseEvent(from: frame) {
                        case .message(let event): continuation.yield(event)
                        case .done:
                            continuation.finish()
                            return
                        case .ignored: break
                        }
                    }
                }
                if !buffer.isEmpty, case .message(let event) = try parseMistralSseEvent(from: buffer) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reader.cancel() }
    }
}

private func findMistralDelimiter(in buffer: Data) -> Range<Data.Index>? {
    let delimiters: [[UInt8]] = [[13,10,13,10], [13,10,13], [13,10,10], [13,13,10], [10,13,10], [13,13], [10,13], [10,10]]
    return delimiters.compactMap { buffer.range(of: Data($0)) }.min {
        $0.lowerBound == $1.lowerBound ? $0.count > $1.count : $0.lowerBound < $1.lowerBound
    }
}

private func parseMistralSseEvent(from chunk: Data) throws -> MistralSseEvent {
    guard !chunk.isEmpty else { return .ignored }
    let raw = String(decoding: chunk, as: UTF8.self)
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    let dataLines = lines.filter { $0.hasPrefix("data:") }.map { line in
        String(line.dropFirst(5).drop(while: { $0.isWhitespace }))
    }
    let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else { return .ignored }
    if payload == "[DONE]" { return .done }
    guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
          object["choices"] is [Any] else { throw MistralStreamError.invalidStreamingEvent }
    return .message(object.mapValues(AnyCodable.init))
}

private func mistralCachedPromptTokens(_ usage: [String: Any], promptTokens: Int) -> Int {
    let candidates: [Any?] = [
        (usage["promptTokensDetails"] as? [String: Any])?["cachedTokens"],
        (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"],
        (usage["promptTokenDetails"] as? [String: Any])?["cachedTokens"],
        (usage["prompt_token_details"] as? [String: Any])?["cached_tokens"],
        usage["numCachedTokens"], usage["num_cached_tokens"],
    ]
    let raw = candidates.compactMap { $0 }.first { !($0 is NSNull) }
    guard let value = raw as? Int else { return 0 }
    return min(promptTokens, max(0, value))
}

private struct MistralHTTPStream: Sendable {
    let body: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () -> Void
}

private func fetchMistralStream(
    request: URLRequest,
    options: MistralOptions
) async throws -> MistralHTTPStream {
    let client = options.httpClient ?? DefaultProviderHTTPClient()
    let signal = CancellationToken()
    let timedOut = LockedState(false)
    let externalHandler = options.signal?.addCancellationHandler { signal.cancel() }
    let timeout = Task {
        do {
            try await Task.sleep(for: .milliseconds(max(0, options.timeoutMs ?? 60_000)))
            timedOut.withLock { $0 = true }
            signal.cancel()
        } catch {}
    }
    let response: ProviderHTTPResponse
    do {
        response = try await retryProviderRequest(
            maxRetries: options.maxRetries,
            maxRetryDelayMs: options.maxRetryDelayMs,
            signal: signal
        ) {
            let response = try await client.send(request)
            options.onResponse?(ResponseSnapshot(statusCode: response.statusCode, headers: response.headers))
            guard (200..<300).contains(response.statusCode) else {
                throw try await providerHTTPError(from: response)
            }
            return response
        }
    } catch {
        timeout.cancel()
        if let externalHandler { options.signal?.removeCancellationHandler(externalHandler) }
        if timedOut.withLock({ $0 }) { throw MistralStreamError.timeout }
        throw error
    }
    let body = AsyncThrowingStream<Data, Error> { continuation in
        let reader = Task {
            do {
                for try await data in response.body {
                    try Task.checkCancellation()
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let cancellationHandler = signal.addCancellationHandler {
            continuation.finish(throwing: timedOut.withLock({ $0 }) ? MistralStreamError.timeout : MistralStreamError.aborted)
            reader.cancel()
        }
        continuation.onTermination = { _ in
            reader.cancel()
            timeout.cancel()
            if let cancellationHandler { signal.removeCancellationHandler(cancellationHandler) }
            if let externalHandler { options.signal?.removeCancellationHandler(externalHandler) }
        }
    }
    return MistralHTTPStream(body: body, cancel: { signal.cancel() })
}

/// Maps `SimpleStreamOptions` onto `MistralOptions`, applying Mistral's reasoning conventions.
public func mapMistralSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> MistralOptions {
    let useReasoningEffort = mistralUsesReasoningEffort(model: model)
    let usePromptMode = model.reasoning && !useReasoningEffort
    let reasoning = clampThinkingLevel(model: model, requested: options?.reasoning)

    let promptMode: String? = (usePromptMode && model.reasoning && reasoning != nil) ? "reasoning" : nil
    let reasoningEffort: String? = {
        guard useReasoningEffort, model.reasoning, let reasoning else { return nil }
        return mappedThinkingLevel(model: model, level: reasoning) ?? "high"
    }()

    return MistralOptions(
        temperature: options?.temperature,
        maxTokens: options?.maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        toolChoice: options?.toolChoice.map { AnyCodable($0.rawValue) },
        promptMode: promptMode,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        cacheRetention: options?.cacheRetention
    )
}

private func mistralUsesReasoningEffort(model: Model) -> Bool {
    return model.id == "mistral-small-2603" ||
        model.id == "mistral-small-latest" ||
        model.id == "mistral-medium-2604" ||
        model.id == "mistral-medium-3.5"
}
