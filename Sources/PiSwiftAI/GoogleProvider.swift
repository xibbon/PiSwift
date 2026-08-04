import Foundation

private let googleToolCallCounter = LockedState(0)

public func streamGoogle(
    model: Model,
    context: Context,
    options: GoogleOptions
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
                throw StreamError.missingApiKey(model.provider)
            }
            if options.signal?.isCancelled == true {
                throw GoogleProviderError.aborted
            }

            let requestBody = try buildGoogleRequestBody(model: model, context: context, options: options)
            emitPayload(options.onPayload, data: requestBody)
            let url = try googleStreamUrl(model: model, apiKey: apiKey)
            var request = URLRequest(url: url)
            request.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000.0
            request.httpMethod = "POST"
            request.httpBody = requestBody

            var headers = model.headers ?? [:]
            if let extra = options.headers {
                headers.merge(extra) { _, new in new }
            }
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "text/event-stream"
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let session = proxySession(for: request.url)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleProviderError.invalidResponse
            }
            options.onResponse?(ResponseSnapshot(statusCode: http.statusCode, headers: responseHeaders(http)))
            if !(200..<300).contains(http.statusCode) {
                let body = try await collectSseStreamData(from: bytes)
                let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw GoogleProviderError.apiError(message)
            }

            stream.push(.start(partial: output))

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var knownToolCallIds = Set<String>()

            func finishCurrentBlock() {
                guard let index = currentBlockIndex else { return }
                switch output.content[index] {
                case .text(let text):
                    stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                case .thinking(let thinking):
                    stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                default:
                    break
                }
                currentBlockIndex = nil
                currentBlockKind = nil
            }

            for try await payload in streamSsePayloads(bytes: bytes, signal: options.signal) {
                guard let data = payload.data(using: .utf8) else { continue }
                guard let chunk = try? JSONDecoder().decode(GoogleStreamChunk.self, from: data) else { continue }

                if output.responseId == nil, let rid = chunk.responseId, !rid.isEmpty {
                    output.responseId = rid
                }

                if let candidate = chunk.candidates?.first, let parts = candidate.content?.parts {
                    for part in parts {
                        if let text = part.text {
                            let isThinking = isThinkingPart(thought: part.thought)
                            if currentBlockIndex == nil || (isThinking && currentBlockKind != "thinking") || (!isThinking && currentBlockKind != "text") {
                                finishCurrentBlock()
                                if isThinking {
                                    output.content.append(.thinking(ThinkingContent(thinking: "")))
                                    currentBlockIndex = output.content.count - 1
                                    currentBlockKind = "thinking"
                                    stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                                } else {
                                    output.content.append(.text(TextContent(text: "")))
                                    currentBlockIndex = output.content.count - 1
                                    currentBlockKind = "text"
                                    stream.push(.textStart(contentIndex: currentBlockIndex!, partial: output))
                                }
                            }

                            if isThinking, let index = currentBlockIndex, case .thinking(var thinking) = output.content[index] {
                                thinking.thinking += text
                                thinking.thinkingSignature = retainThoughtSignature(existing: thinking.thinkingSignature, incoming: part.thoughtSignature)
                                output.content[index] = .thinking(thinking)
                                stream.push(.thinkingDelta(contentIndex: index, delta: text, partial: output))
                            } else if let index = currentBlockIndex, case .text(var content) = output.content[index] {
                                content.text += text
                                content.textSignature = retainThoughtSignature(existing: content.textSignature, incoming: part.thoughtSignature)
                                output.content[index] = .text(content)
                                stream.push(.textDelta(contentIndex: index, delta: text, partial: output))
                            }
                        }

                        if let functionCall = part.functionCall {
                            finishCurrentBlock()

                            let providedId = functionCall.id
                            let needsNew = providedId == nil || (providedId != nil && knownToolCallIds.contains(providedId!))
                            let toolCallId: String
                            if needsNew {
                                let count = googleToolCallCounter.withLock { value -> Int in
                                    value += 1
                                    return value
                                }
                                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                                toolCallId = "\(functionCall.name ?? "tool")_\(timestamp)_\(count)"
                            } else {
                                toolCallId = providedId!
                            }
                            knownToolCallIds.insert(toolCallId)

                            let args = functionCall.args ?? [:]
                            let call = ToolCall(
                                id: toolCallId,
                                name: functionCall.name ?? "",
                                arguments: args,
                                thoughtSignature: part.thoughtSignature
                            )
                            output.content.append(.toolCall(call))
                            let toolIndex = output.content.count - 1
                            stream.push(.toolCallStart(contentIndex: toolIndex, partial: output))
                            let jsonArgs = String(
                                data: (try? JSONSerialization.data(withJSONObject: args.mapValues { $0.jsonValue }, options: [])) ?? Data(),
                                encoding: .utf8
                            ) ?? "{}"
                            stream.push(.toolCallDelta(contentIndex: toolIndex, delta: jsonArgs, partial: output))
                            stream.push(.toolCallEnd(contentIndex: toolIndex, toolCall: call, partial: output))
                        }
                    }

                    if let finishReason = candidate.finishReason {
                        output.stopReason = mapGoogleStopReason(finishReason)
                        if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                            output.stopReason = .toolUse
                        }
                    }
                }

                if let usage = chunk.usageMetadata {
                    let cacheRead = usage.cachedContentTokenCount ?? 0
                    let promptTokens = usage.promptTokenCount ?? 0
                    output.usage = Usage(
                        input: max(0, promptTokens - cacheRead),
                        output: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
                        cacheRead: cacheRead,
                        cacheWrite: 0,
                        reasoning: usage.thoughtsTokenCount,
                        totalTokens: usage.totalTokenCount ?? 0
                    )
                    calculateCost(model: model, usage: &output.usage)
                }
            }

            finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw GoogleProviderError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw GoogleProviderError.unknown
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = retryAwareErrorDescription(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private func buildGoogleRequestBody(
    model: Model,
    context: Context,
    options: GoogleOptions
) throws -> Data {
    let contents = convertGoogleMessages(model: model, context: context)

    var generationConfig: [String: Any] = [:]
    if let temperature = options.temperature {
        generationConfig["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
        generationConfig["maxOutputTokens"] = maxTokens
    }
    if let thinking = options.thinking, model.reasoning {
        let config: [String: Any]
        if thinking.enabled {
            var enabledConfig: [String: Any] = ["includeThoughts": true]
            if let level = thinking.level {
                enabledConfig["thinkingLevel"] = level.rawValue
            } else if let budget = thinking.budgetTokens {
                enabledConfig["thinkingBudget"] = budget
            }
            config = enabledConfig
        } else {
            config = googleDisabledThinkingConfig(model: model)
        }
        // thinkingConfig belongs to generationConfig; at the top level it is an unknown field.
        generationConfig["thinkingConfig"] = config
    }

    var payload: [String: Any] = [
        "contents": contents,
    ]

    if !generationConfig.isEmpty {
        payload["generationConfig"] = generationConfig
    }
    if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
        // system_instruction is a Content, not a bare string.
        payload["systemInstruction"] = [
            "parts": [
                ["text": sanitizeSurrogates(systemPrompt)],
            ],
        ]
    }
    if let tools = context.tools, !tools.isEmpty {
        payload["tools"] = convertGoogleTools(tools)
    }
    if let tools = context.tools, !tools.isEmpty, let choice = options.toolChoice {
        payload["toolConfig"] = [
            "functionCallingConfig": [
                "mode": mapGoogleToolChoice(choice),
            ],
        ]
    }

    return try JSONSerialization.data(withJSONObject: payload, options: [])
}

private func googleStreamUrl(model: Model, apiKey: String) throws -> URL {
    let trimmed = model.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : trimmed
    var normalized = base
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    let suffix: String
    if normalized.hasSuffix("/models") {
        suffix = "/\(model.id):streamGenerateContent"
    } else {
        suffix = "/models/\(model.id):streamGenerateContent"
    }
    var components = URLComponents(string: "\(normalized)\(suffix)")
    components?.queryItems = [
        URLQueryItem(name: "alt", value: "sse"),
        URLQueryItem(name: "key", value: apiKey),
    ]
    guard let url = components?.url else {
        throw GoogleProviderError.invalidResponse
    }
    return url
}

private enum GoogleProviderError: LocalizedError {
    case invalidResponse
    case apiError(String)
    case aborted
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Google API returned an invalid response."
        case .apiError(let message):
            return message
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "Google request failed"
        }
    }
}
