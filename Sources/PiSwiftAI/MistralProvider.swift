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
            stopReason: .stop
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
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            request.setValue("application/json", forHTTPHeaderField: "content-type")

            var mergedHeaders: [String: String] = model.headers ?? [:]
            if let headers = options.headers {
                for (key, value) in headers {
                    mergedHeaders[key] = value
                }
            }
            // Mistral infrastructure uses `x-affinity` for KV-cache reuse (prefix caching).
            if let sessionId = options.sessionId, mergedHeaders["x-affinity"] == nil {
                mergedHeaders["x-affinity"] = sessionId
            }
            for (key, value) in mergedHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.httpBody = bodyData

            let session = proxySession(for: request.url)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MistralStreamError.invalidResponse
            }
            if !(200..<300).contains(http.statusCode) {
                let bodyText = try await collectMistralData(from: bytes)
                let snippet = String(data: bodyText, encoding: .utf8) ?? ""
                throw MistralStreamError.apiError(http.statusCode, snippet)
            }

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

            for try await event in parseMistralSseStream(bytes: bytes) {
                if options.signal?.isCancelled == true {
                    throw MistralStreamError.aborted
                }
                if let id = event["id"] as? String, output.responseId == nil, !id.isEmpty {
                    output.responseId = id
                }

                if let usage = event["usage"] as? [String: Any] {
                    let promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
                    let completionTokens = (usage["completion_tokens"] as? Int) ?? 0
                    let totalTokens = (usage["total_tokens"] as? Int) ?? (promptTokens + completionTokens)
                    output.usage = Usage(
                        input: promptTokens,
                        output: completionTokens,
                        cacheRead: 0,
                        cacheWrite: 0,
                        totalTokens: totalTokens
                    )
                    _ = calculateCost(model: model, usage: &output.usage)
                }

                guard let choices = event["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }

                if let finishReason = choice["finish_reason"] as? String {
                    output.stopReason = mapMistralStopReason(finishReason)
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
                        let key = "\(callId):\(toolIndex)"
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
            if output.stopReason == .aborted || output.stopReason == .error {
                throw MistralStreamError.unknown
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

    public var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for provider: \(provider)"
        case .invalidResponse:
            return "Mistral response failed: invalid response"
        case .apiError(let status, let body):
            let bodyText = body.isEmpty ? "" : ": \(truncateMistralErrorText(body, maxChars: 4000))"
            return "Mistral API error (\(status))\(bodyText)"
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "An unknown error occurred"
        }
    }
}

private func formatMistralError(_ error: Error) -> String {
    if let mistralError = error as? MistralStreamError {
        return mistralError.errorDescription ?? "\(mistralError)"
    }
    return error.localizedDescription
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

private func mapMistralStopReason(_ reason: String) -> StopReason {
    switch reason {
    case "stop": return .stop
    case "length", "model_length": return .length
    case "tool_calls": return .toolUse
    case "error": return .error
    default: return .stop
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
        payload["tools"] = tools.map { tool -> [String: Any] in
            var function: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "strict": false,
            ]
            function["parameters"] = tool.parameters.mapValues { $0.value }
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
    var entry: [String: Any] = ["role": "assistant"]
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
private final class MistralToolCallIdNormalizer: @unchecked Sendable {
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

private func parseMistralSseStream(bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
    AsyncThrowingStream { continuation in
        Task {
            var buffer = Data()
            let delimiterCrlf = Data([13, 10, 13, 10])
            let delimiterLf = Data([10, 10])
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    while let range = findMistralDelimiter(in: buffer, crlf: delimiterCrlf, lf: delimiterLf) {
                        let chunk = buffer.subdata(in: 0..<range.lowerBound)
                        buffer.removeSubrange(0..<range.upperBound)
                        if let event = parseMistralSseEvent(from: chunk) {
                            continuation.yield(event)
                        }
                    }
                }
                if !buffer.isEmpty, let event = parseMistralSseEvent(from: buffer) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func findMistralDelimiter(in buffer: Data, crlf: Data, lf: Data) -> Range<Data.Index>? {
    let crlfRange = buffer.range(of: crlf)
    let lfRange = buffer.range(of: lf)
    switch (crlfRange, lfRange) {
    case (nil, nil): return nil
    case (let r?, nil): return r
    case (nil, let r?): return r
    case (let r1?, let r2?): return r1.lowerBound <= r2.lowerBound ? r1 : r2
    }
}

private func parseMistralSseEvent(from chunk: Data) -> [String: Any]? {
    guard !chunk.isEmpty, let raw = String(data: chunk, encoding: .utf8) else { return nil }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    var dataLines: [String] = []
    for line in lines {
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            dataLines.append(value)
        }
    }
    guard !dataLines.isEmpty else { return nil }
    let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty, payload != "[DONE]" else { return nil }
    guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: []),
          let event = object as? [String: Any] else { return nil }
    return event
}

private func collectMistralData(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
    }
    return data
}

/// Maps `SimpleStreamOptions` onto `MistralOptions`, applying Mistral's reasoning conventions.
public func mapMistralSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> MistralOptions {
    let useReasoningEffort = mistralUsesReasoningEffort(model: model)
    let usePromptMode = model.reasoning && !useReasoningEffort
    let reasoningPresent = options?.reasoning != nil

    let promptMode: String? = (usePromptMode && model.reasoning && reasoningPresent) ? "reasoning" : nil
    let reasoningEffort: String? = (useReasoningEffort && model.reasoning && reasoningPresent) ? "high" : nil

    return MistralOptions(
        temperature: options?.temperature,
        maxTokens: options?.maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        toolChoice: nil,
        promptMode: promptMode,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId,
        headers: options?.headers,
        onPayload: options?.onPayload
    )
}

private func mistralUsesReasoningEffort(model: Model) -> Bool {
    return model.id == "mistral-small-2603" || model.id == "mistral-small-latest"
}
