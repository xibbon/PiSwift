import Foundation

public func streamOpenAICodexResponses(
    model: Model,
    context: Context,
    options: OpenAICodexResponsesOptions
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
            let apiKey = options.apiKey ?? ""
            if apiKey.isEmpty {
                throw StreamError.missingApiKey(model.provider)
            }

            var mergedHeaders = model.headers ?? [:]
            if let headers = options.headers {
                for (key, value) in headers {
                    mergedHeaders[key] = value
                }
            }
            let baseHeaders = try buildOpenAICodexHeaders(baseHeaders: mergedHeaders, accessToken: apiKey)
            let headers = buildCodexHeaders(
                baseHeaders: baseHeaders,
                accessToken: apiKey,
                sessionId: options.sessionId
            )

            var body: [String: Any] = [
                "model": model.id,
                "input": convertCodexMessages(model: model, context: context),
                "stream": true,
            ]

            if let sessionId = options.sessionId, !sessionId.isEmpty {
                body["prompt_cache_key"] = sessionId
            }

            if let maxTokens = options.maxTokens {
                body["max_output_tokens"] = maxTokens
            }
            if let temperature = options.temperature {
                body["temperature"] = temperature
            }
            if let tools = context.tools {
                body["tools"] = convertCodexTools(tools)
                body["tool_choice"] = "auto"
                body["parallel_tool_calls"] = true
            }

            if let instructions = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !instructions.isEmpty {
                body["instructions"] = instructions
            }

            // v0.70.3: default Codex Responses verbosity to .low when caller didn't specify.
            // Matches upstream default and produces shorter / faster responses.
            let requestOptions = OpenAICodexRequestOptions(
                reasoningEffort: options.reasoningEffort,
                reasoningSummary: options.reasoningSummary,
                textVerbosity: options.textVerbosity ?? .low,
                include: options.include
            )
            transformCodexRequestBody(&body, options: requestOptions, prompt: nil)
            emitPayload(options.onPayload, jsonObject: body)

            var currentBlockIndex: Int? = nil
            var currentBlockKind: String? = nil
            var currentToolCallPartial = ""
            var hasStartedStream = false

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

            func updateTextDelta(_ delta: String) {
                guard let index = currentBlockIndex, currentBlockKind == "text",
                      case .text(var text) = output.content[index] else { return }
                text.text += delta
                output.content[index] = .text(text)
                stream.push(.textDelta(contentIndex: index, delta: delta, partial: output))
            }

            func updateThinkingDelta(_ delta: String) {
                guard let index = currentBlockIndex, currentBlockKind == "thinking",
                      case .thinking(var thinking) = output.content[index] else { return }
                thinking.thinking += delta
                output.content[index] = .thinking(thinking)
                stream.push(.thinkingDelta(contentIndex: index, delta: delta, partial: output))
            }

            func updateToolCallDelta(_ delta: String) {
                guard let index = currentBlockIndex, currentBlockKind == "toolCall",
                      case .toolCall(var tool) = output.content[index] else { return }
                currentToolCallPartial += delta
                tool.arguments = parseStreamingJSON(currentToolCallPartial)
                output.content[index] = .toolCall(tool)
                stream.push(.toolCallDelta(contentIndex: index, delta: delta, partial: output))
            }

            func startStreamIfNeeded() {
                guard !hasStartedStream else { return }
                hasStartedStream = true
                stream.push(.start(partial: output))
            }

            func processRawEvent(_ rawEvent: [String: Any]) throws {
                if options.signal?.isCancelled == true {
                    throw OpenAICodexStreamError.aborted
                }

                let eventType = rawEvent["type"] as? String ?? ""
                if eventType.isEmpty { return }

                switch eventType {
                case "response.output_item.added":
                    guard let item = rawEvent["item"] as? [String: Any],
                          let type = item["type"] as? String else { return }
                    if type == "reasoning" {
                        startBlock(kind: "thinking", block: .thinking(ThinkingContent(thinking: "")))
                    } else if type == "message" {
                        startBlock(kind: "text", block: .text(TextContent(text: "")))
                    } else if type == "function_call" {
                        let callId = item["call_id"] as? String ?? ""
                        let itemId = item["id"] as? String ?? ""
                        let name = item["name"] as? String ?? ""
                        let combinedId = "\(callId)|\(itemId)"
                        currentToolCallPartial = item["arguments"] as? String ?? ""
                        let toolCall = ToolCall(id: combinedId, name: name, arguments: [:])
                        startBlock(kind: "toolCall", block: .toolCall(toolCall))
                    }

                case "response.reasoning_summary_text.delta":
                    let delta = rawEvent["delta"] as? String ?? ""
                    if !delta.isEmpty {
                        updateThinkingDelta(delta)
                    }

                case "response.reasoning_summary_part.done":
                    updateThinkingDelta("\n\n")

                case "response.output_text.delta", "response.refusal.delta":
                    let delta = rawEvent["delta"] as? String ?? ""
                    if !delta.isEmpty {
                        updateTextDelta(delta)
                    }

                case "response.function_call_arguments.delta":
                    let delta = rawEvent["delta"] as? String ?? ""
                    if !delta.isEmpty {
                        updateToolCallDelta(delta)
                    }

                case "response.output_item.done":
                    guard let item = rawEvent["item"] as? [String: Any],
                          let type = item["type"] as? String else { return }
                    if type == "reasoning", let index = currentBlockIndex, currentBlockKind == "thinking",
                       case .thinking(var thinking) = output.content[index] {
                        let summaryText = extractCodexReasoningSummary(item)
                        thinking.thinking = summaryText
                        if let signature = codexJsonString(from: item) {
                            thinking.thinkingSignature = signature
                        }
                        output.content[index] = .thinking(thinking)
                        stream.push(.thinkingEnd(contentIndex: index, content: thinking.thinking, partial: output))
                        currentBlockKind = nil
                        currentBlockIndex = nil
                    } else if type == "message", let index = currentBlockIndex, currentBlockKind == "text",
                              case .text(var text) = output.content[index] {
                        text.text = extractCodexMessageText(item)
                        text.textSignature = item["id"] as? String
                        output.content[index] = .text(text)
                        stream.push(.textEnd(contentIndex: index, content: text.text, partial: output))
                        currentBlockKind = nil
                        currentBlockIndex = nil
                    } else if type == "function_call" {
                        let callId = item["call_id"] as? String ?? ""
                        let itemId = item["id"] as? String ?? ""
                        let combinedId = "\(callId)|\(itemId)"
                        let preferredArgs = currentToolCallPartial.trimmingCharacters(in: .whitespacesAndNewlines)
                        var arguments = preferredArgs.isEmpty ? [:] : parseStreamingJSON(preferredArgs)
                        if arguments.isEmpty {
                            arguments = parseCodexArguments(item["arguments"])
                        }
                        var resolvedName = item["name"] as? String ?? ""
                        if let index = currentBlockIndex, case .toolCall(let existing) = output.content[index] {
                            if resolvedName.isEmpty {
                                resolvedName = existing.name
                            }
                            if arguments.isEmpty, !existing.arguments.isEmpty {
                                arguments = existing.arguments
                            }
                        }
                        let toolCall = ToolCall(id: combinedId, name: resolvedName, arguments: arguments)
                        if let index = currentBlockIndex {
                            output.content[index] = .toolCall(toolCall)
                            stream.push(.toolCallEnd(contentIndex: index, toolCall: toolCall, partial: output))
                        }
                        currentBlockKind = nil
                        currentBlockIndex = nil
                        currentToolCallPartial = ""
                    }

                case "response.completed", "response.done":
                    if let responseInfo = rawEvent["response"] as? [String: Any] {
                        if let usage = responseInfo["usage"] as? [String: Any] {
                            let cachedTokens = intValue(usage["input_tokens_details"], key: "cached_tokens") ?? 0
                            let inputTokens = intValue(usage, key: "input_tokens") ?? 0
                            let outputTokens = intValue(usage, key: "output_tokens") ?? 0
                            let totalTokens = intValue(usage, key: "total_tokens") ?? 0
                            output.usage = Usage(
                                input: max(0, inputTokens - cachedTokens),
                                output: outputTokens,
                                cacheRead: cachedTokens,
                                cacheWrite: 0,
                                totalTokens: totalTokens
                            )
                            calculateCost(model: model, usage: &output.usage)
                        }
                        let status = responseInfo["status"] as? String
                        output.stopReason = mapCodexStopReason(status)
                        if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }),
                           output.stopReason == .stop {
                            output.stopReason = .toolUse
                        }
                    }

                case "error":
                    let code = rawEvent["code"] as? String ?? ""
                    let message = rawEvent["message"] as? String ?? ""
                    throw OpenAICodexStreamError.apiError(formatCodexErrorEvent(rawEvent, code: code, message: message))

                case "response.failed":
                    let message = formatCodexFailure(rawEvent) ?? "Codex response failed"
                    throw OpenAICodexStreamError.apiError(message)

                default:
                    break
                }
            }

            let transport = options.transport ?? .sse
            if transport != .sse {
                var websocketStarted = false
                do {
                    try await processCodexWebSocketStream(
                        url: codexWebSocketUrl(baseUrl: model.baseUrl),
                        body: body,
                        headers: headers,
                        sessionId: options.sessionId,
                        signal: options.signal,
                        onStart: {
                            websocketStarted = true
                            startStreamIfNeeded()
                        },
                        onEvent: { event in
                            try processRawEvent(event)
                        }
                    )

                    if options.signal?.isCancelled == true {
                        throw OpenAICodexStreamError.aborted
                    }
                    if output.stopReason == .aborted || output.stopReason == .error {
                        throw OpenAICodexStreamError.unknown
                    }

                    stream.push(.done(reason: output.stopReason, message: output))
                    stream.end()
                    return
                } catch {
                    if transport == .websocket || websocketStarted {
                        throw error
                    }
                }
            }

            let requestData = try JSONSerialization.data(withJSONObject: body, options: [])
            var request = URLRequest(url: codexResponsesUrl(baseUrl: model.baseUrl))
            request.httpMethod = "POST"
            request.httpBody = requestData
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let session = proxySession(for: request.url)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAICodexStreamError.invalidResponse
            }

            if !(200..<300).contains(http.statusCode) {
                let bodyData = try await collectCodexData(from: bytes)
                let info = parseCodexError(statusCode: http.statusCode, headers: http.allHeaderFields, body: bodyData)
                throw OpenAICodexStreamError.apiError(info.friendlyMessage ?? info.message)
            }

            startStreamIfNeeded()
            for try await rawEvent in parseCodexSseStream(bytes: bytes) {
                try processRawEvent(rawEvent)
            }

            if options.signal?.isCancelled == true {
                throw OpenAICodexStreamError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw OpenAICodexStreamError.unknown
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = error.localizedDescription
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private enum OpenAICodexStreamError: Error, LocalizedError {
    case aborted
    case unknown
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "Codex response failed"
        case .invalidResponse:
            return "Codex response failed: invalid response"
        case .apiError(let message):
            return message
        }
    }
}

private struct CodexErrorInfo {
    let message: String
    let status: Int
    let friendlyMessage: String?
}

private func codexResponsesUrl(baseUrl: String) -> URL {
    var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        trimmed = "https://chatgpt.com/backend-api"
    }
    if trimmed.hasSuffix("/responses") {
        return URL(string: trimmed)!
    }
    if trimmed.contains("/codex") {
        trimmed = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: trimmed + "/responses")!
    }
    let suffix = trimmed.hasSuffix("/") ? "codex/responses" : "/codex/responses"
    return URL(string: trimmed + suffix)!
}

private func codexWebSocketUrl(baseUrl: String) -> URL {
    let httpUrl = codexResponsesUrl(baseUrl: baseUrl)
    guard var components = URLComponents(url: httpUrl, resolvingAgainstBaseURL: false) else {
        return httpUrl
    }
    if components.scheme == "https" {
        components.scheme = "wss"
    } else if components.scheme == "http" {
        components.scheme = "ws"
    }
    return components.url ?? httpUrl
}

private let codexWebSocketBetaHeader = "responses_websockets=2026-02-06"
private let codexSessionWebSocketCacheTtl: TimeInterval = 5 * 60

private struct CodexWebSocketLease {
    let task: URLSessionWebSocketTask
    let sessionId: String?
    let cached: Bool
}

private final class CodexWebSocketCache: @unchecked Sendable {
    private struct Entry {
        var task: URLSessionWebSocketTask
        var busy: Bool
        var idleTimer: DispatchSourceTimer?
    }

    static let shared = CodexWebSocketCache()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    func acquire(url: URL, headers: [String: String], sessionId: String?) -> CodexWebSocketLease {
        guard let sessionId, !sessionId.isEmpty else {
            let task = connect(url: url, headers: headers)
            return CodexWebSocketLease(task: task, sessionId: nil, cached: false)
        }

        lock.lock()
        if var existing = entries[sessionId] {
            existing.idleTimer?.cancel()
            existing.idleTimer = nil
            if !existing.busy, isReusable(existing.task) {
                existing.busy = true
                entries[sessionId] = existing
                lock.unlock()
                return CodexWebSocketLease(task: existing.task, sessionId: sessionId, cached: true)
            }
            if !isReusable(existing.task) {
                closeSilently(existing.task, reason: "reconnect")
                entries.removeValue(forKey: sessionId)
            } else {
                entries[sessionId] = existing
                if existing.busy {
                    lock.unlock()
                    let task = connect(url: url, headers: headers)
                    return CodexWebSocketLease(task: task, sessionId: nil, cached: false)
                }
            }
        }
        lock.unlock()

        let task = connect(url: url, headers: headers)
        lock.lock()
        entries[sessionId] = Entry(task: task, busy: true, idleTimer: nil)
        lock.unlock()
        return CodexWebSocketLease(task: task, sessionId: sessionId, cached: true)
    }

    func release(_ lease: CodexWebSocketLease, keep: Bool) {
        guard lease.cached, let sessionId = lease.sessionId else {
            closeSilently(lease.task)
            return
        }

        lock.lock()
        guard var entry = entries[sessionId], entry.task === lease.task else {
            lock.unlock()
            closeSilently(lease.task)
            return
        }

        if !keep || !isReusable(entry.task) {
            entries.removeValue(forKey: sessionId)
            lock.unlock()
            closeSilently(entry.task)
            return
        }

        entry.busy = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + codexSessionWebSocketCacheTtl)
        timer.setEventHandler { [weak self] in
            self?.expire(sessionId: sessionId, expectedTask: lease.task)
        }
        timer.resume()
        entry.idleTimer = timer
        entries[sessionId] = entry
        lock.unlock()
    }

    private func expire(sessionId: String, expectedTask: URLSessionWebSocketTask) {
        lock.lock()
        guard let entry = entries[sessionId], entry.task === expectedTask else {
            lock.unlock()
            return
        }
        if entry.busy {
            lock.unlock()
            return
        }
        entries.removeValue(forKey: sessionId)
        lock.unlock()
        closeSilently(entry.task, reason: "idle_timeout")
    }

    private func connect(url: URL, headers: [String: String]) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let session = proxySession(for: url)
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func isReusable(_ task: URLSessionWebSocketTask) -> Bool {
        task.state == .running && task.closeCode == .invalid
    }

    private func closeSilently(_ task: URLSessionWebSocketTask, reason: String = "done") {
        task.cancel(with: .normalClosure, reason: reason.data(using: .utf8))
    }
}

private func buildCodexHeaders(
    baseHeaders: [String: String],
    accessToken: String,
    sessionId: String?
) -> [String: String] {
    var headers = baseHeaders
    headers = headers.filter { $0.key.lowercased() != "x-api-key" }
    headers["Authorization"] = "Bearer \(accessToken)"
    headers["accept"] = "text/event-stream"
    headers["content-type"] = "application/json"

    if let sessionId, !sessionId.isEmpty {
        headers["conversation_id"] = sessionId
        headers["session_id"] = sessionId
    } else {
        headers.removeValue(forKey: "conversation_id")
        headers.removeValue(forKey: "session_id")
    }
    return headers
}

private func parseCodexError(
    statusCode: Int,
    headers: [AnyHashable: Any],
    body: Data
) -> CodexErrorInfo {
    let raw = String(data: body, encoding: .utf8) ?? ""
    var message = raw.isEmpty ? "Request failed" : raw
    var friendly: String? = nil

    if let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
       let error = json["error"] as? [String: Any] {
        let code = (error["code"] as? String) ?? (error["type"] as? String) ?? ""
        let errMessage = error["message"] as? String
        if let errMessage, !errMessage.isEmpty {
            message = errMessage
        }

        let resetsAt = intValue(error, key: "resets_at")
            ?? intValue(headers, key: "x-codex-primary-reset-at")
            ?? intValue(headers, key: "x-codex-secondary-reset-at")
        let minutes = resetsAt.map { max(0, (Int64($0) * 1000 - Int64(Date().timeIntervalSince1970 * 1000)) / 60000) }

        if code.range(of: "usage_limit_reached|usage_not_included|rate_limit_exceeded", options: .regularExpression) != nil
            || statusCode == 429 {
            let plan = (error["plan_type"] as? String).map { " (\($0.lowercased()) plan)" } ?? ""
            let when = minutes.map { " Try again in ~\($0) min." } ?? ""
            friendly = "You have hit your ChatGPT usage limit\(plan).\(when)".trimmingCharacters(in: .whitespaces)
        }
    }

    return CodexErrorInfo(message: message, status: statusCode, friendlyMessage: friendly)
}

private func parseCodexSseStream(bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
    AsyncThrowingStream { continuation in
        Task {
            var buffer = Data()
            let delimiterCrlf = Data([13, 10, 13, 10])
            let delimiterLf = Data([10, 10])
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    while let range = findCodexDelimiter(in: buffer, crlf: delimiterCrlf, lf: delimiterLf) {
                        let chunk = buffer.subdata(in: 0..<range.lowerBound)
                        buffer.removeSubrange(0..<range.upperBound)
                        if let event = parseCodexSseEvent(from: chunk) {
                            continuation.yield(event)
                        }
                    }
                }
                if !buffer.isEmpty, let event = parseCodexSseEvent(from: buffer) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private func processCodexWebSocketStream(
    url: URL,
    body: [String: Any],
    headers: [String: String],
    sessionId: String?,
    signal: CancellationToken?,
    onStart: () -> Void,
    onEvent: ([String: Any]) throws -> Void
) async throws {
    var wsHeaders = headers
    wsHeaders["OpenAI-Beta"] = codexWebSocketBetaHeader

    let lease = CodexWebSocketCache.shared.acquire(url: url, headers: wsHeaders, sessionId: sessionId)
    var keepConnection = true
    defer {
        CodexWebSocketCache.shared.release(lease, keep: keepConnection)
    }
    do {
        var payload = body
        payload["type"] = "response.create"
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw OpenAICodexStreamError.apiError("Failed to encode WebSocket request payload")
        }

        if signal?.isCancelled == true {
            throw OpenAICodexStreamError.aborted
        }

        try await lease.task.send(.string(payloadText))
        onStart()

        var sawCompletion = false
        while true {
            if signal?.isCancelled == true {
                throw OpenAICodexStreamError.aborted
            }

            let message = try await lease.task.receive()
            guard let event = parseCodexWebSocketMessage(message) else { continue }
            let type = event["type"] as? String ?? ""
            if type == "response.completed" || type == "response.done" {
                sawCompletion = true
            }
            try onEvent(event)
            if sawCompletion {
                break
            }
        }

        if !sawCompletion {
            throw OpenAICodexStreamError.apiError("WebSocket stream closed before response.completed")
        }
    } catch {
        keepConnection = false
        throw error
    }
}

private func parseCodexWebSocketMessage(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
    let text: String?
    switch message {
    case .string(let value):
        text = value
    case .data(let data):
        text = String(data: data, encoding: .utf8)
    @unknown default:
        text = nil
    }

    guard let text, let data = text.data(using: .utf8) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = object as? [String: Any] else {
        return nil
    }
    return dict
}

private func findCodexDelimiter(in buffer: Data, crlf: Data, lf: Data) -> Range<Data.Index>? {
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

private func parseCodexSseEvent(from chunk: Data) -> [String: Any]? {
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

    guard let json = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: json, options: []),
          let event = object as? [String: Any] else {
        return nil
    }
    return event
}

private func collectCodexData(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
    }
    return data
}

private func convertCodexMessages(model: Model, context: Context) -> [Any] {
    var messages: [Any] = []
    let codexToolCallProviders: Set<String> = ["openai", "openai-codex", "opencode"]

    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, model, _ in
        guard codexToolCallProviders.contains(model.provider) else { return id }
        guard id.contains("|") else { return id }
        let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let callIdRaw = parts.first.map(String.init) ?? id
        let itemIdRaw = parts.count > 1 ? String(parts[1]) : ""
        let sanitizedCallId = callIdRaw.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        var sanitizedItemId = itemIdRaw.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        if !sanitizedItemId.hasPrefix("fc") {
            sanitizedItemId = "fc_\(sanitizedItemId)"
        }
        var normalizedCallId = sanitizedCallId.count > 64 ? String(sanitizedCallId.prefix(64)) : sanitizedCallId
        var normalizedItemId = sanitizedItemId.count > 64 ? String(sanitizedItemId.prefix(64)) : sanitizedItemId
        normalizedCallId = normalizedCallId.replacingOccurrences(of: "_+$", with: "", options: .regularExpression)
        normalizedItemId = normalizedItemId.replacingOccurrences(of: "_+$", with: "", options: .regularExpression)
        return "\(normalizedCallId)|\(normalizedItemId)"
    }

    let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: normalizeToolCallId)
    var msgIndex = 0

    for message in transformed {
        switch message {
        case .user(let user):
            switch user.content {
            case .text(let text):
                messages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": sanitizeSurrogates(text),
                        ]
                    ],
                ])
            case .blocks(let blocks):
                let contents = blocks.compactMap { block -> [String: Any]? in
                    switch block {
                    case .text(let textContent):
                        return [
                            "type": "input_text",
                            "text": sanitizeSurrogates(textContent.text),
                        ]
                    case .image(let imageContent):
                        return [
                            "type": "input_image",
                            "detail": "auto",
                            "image_url": "data:\(imageContent.mimeType);base64,\(imageContent.data)",
                        ]
                    default:
                        return nil
                    }
                }
                let filtered = model.input.contains(.image) ? contents : contents.filter { ($0["type"] as? String) != "input_image" }
                if !filtered.isEmpty {
                    messages.append([
                        "role": "user",
                        "content": filtered,
                    ])
                }
            }

        case .assistant(let assistant):
            var outputItems: [Any] = []
            let allowToolCalls = assistant.stopReason != .error && assistant.stopReason != .aborted
            for block in assistant.content {
                switch block {
                case .thinking(let thinking) where allowToolCalls:
                    if let signature = thinking.thinkingSignature,
                       let data = signature.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                        outputItems.append(json)
                    }
                case .text(let textBlock):
                    let messageId = codexMessageId(textBlock.textSignature, index: msgIndex)
                    outputItems.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            [
                                "type": "output_text",
                                "text": sanitizeSurrogates(textBlock.text),
                                "annotations": [],
                            ]
                        ],
                        "status": "completed",
                        "id": messageId,
                    ])
                case .toolCall(let toolCall) where allowToolCalls:
                    let parts = toolCall.id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let callId = parts.first.map(String.init) ?? toolCall.id
                    let itemId = parts.count > 1 ? String(parts[1]) : ""
                    outputItems.append([
                        "type": "function_call",
                        "id": itemId,
                        "call_id": callId,
                        "name": toolCall.name,
                        "arguments": jsonString(from: toolCall.arguments),
                    ])
                default:
                    break
                }
            }
            if !outputItems.isEmpty {
                messages.append(contentsOf: outputItems)
            }

        case .toolResult(let toolResult):
            let textResult = toolResult.content.compactMap { block -> String? in
                if case .text(let text) = block { return text.text }
                return nil
            }.joined(separator: "\n")
            let hasImages = toolResult.content.contains { if case .image = $0 { return true } else { return false } }
            let callId = toolResult.toolCallId.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? toolResult.toolCallId

            messages.append([
                "type": "function_call_output",
                "call_id": callId,
                "output": sanitizeSurrogates(textResult.isEmpty ? "(see attached image)" : textResult),
            ])

            if hasImages && model.input.contains(.image) {
                var content: [[String: Any]] = [
                    [
                        "type": "input_text",
                        "text": "Attached image(s) from tool result:",
                    ]
                ]
                for block in toolResult.content {
                    if case .image(let image) = block {
                        content.append([
                            "type": "input_image",
                            "detail": "auto",
                            "image_url": "data:\(image.mimeType);base64,\(image.data)",
                        ])
                    }
                }
                messages.append([
                    "role": "user",
                    "content": content,
                ])
            }
        }
        msgIndex += 1
    }

    return messages
}

private func codexMessageId(_ id: String?, index: Int) -> String {
    guard let id, !id.isEmpty else {
        return "msg_\(index)"
    }
    if id.count > 64 {
        return "msg_\(codexShortHash(id))"
    }
    return id
}

private func codexShortHash(_ value: String) -> String {
    var h1: UInt32 = 0xdeadbeef
    var h2: UInt32 = 0x41c6ce57
    for ch in value.utf8 {
        h1 = (h1 ^ UInt32(ch)) &* 2654435761
        h2 = (h2 ^ UInt32(ch)) &* 1597334677
    }
    h1 = (h1 ^ (h1 >> 16)) &* 2246822507 ^ (h2 ^ (h2 >> 13)) &* 3266489909
    h2 = (h2 ^ (h2 >> 16)) &* 2246822507 ^ (h1 ^ (h1 >> 13)) &* 3266489909
    return String(h2, radix: 36) + String(h1, radix: 36)
}

private func convertCodexTools(_ tools: [AITool]) -> [[String: Any]] {
    tools.map { tool in
        [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters.mapValues { $0.value },
            "strict": NSNull(),
        ]
    }
}

private func extractCodexReasoningSummary(_ item: [String: Any]) -> String {
    guard let summary = item["summary"] as? [[String: Any]] else { return "" }
    let parts = summary.compactMap { $0["text"] as? String }
    return parts.joined(separator: "\n\n")
}

private func extractCodexMessageText(_ item: [String: Any]) -> String {
    guard let content = item["content"] as? [[String: Any]] else { return "" }
    let parts = content.compactMap { part -> String? in
        if let type = part["type"] as? String, type == "output_text" {
            return part["text"] as? String
        }
        if let type = part["type"] as? String, type == "refusal" {
            return part["refusal"] as? String
        }
        return nil
    }
    return parts.joined()
}

private func parseCodexArguments(_ value: Any?) -> [String: AnyCodable] {
    if let dict = value as? [String: Any] {
        return dict.mapValues { AnyCodable($0) }
    }
    guard let string = value as? String else {
        return [:]
    }
    guard let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = object as? [String: Any] else {
        return [:]
    }
    return dict.mapValues { AnyCodable($0) }
}

private func mapCodexStopReason(_ status: String?) -> StopReason {
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

private func intValue(_ dict: Any?, key: String) -> Int? {
    guard let dict = dict as? [String: Any], let value = dict[key] else { return nil }
    if let intValue = value as? Int { return intValue }
    if let doubleValue = value as? Double { return Int(doubleValue) }
    if let stringValue = value as? String, let intValue = Int(stringValue) { return intValue }
    return nil
}

private func intValue(_ dict: [AnyHashable: Any], key: String) -> Int? {
    if let value = dict[key] as? Int { return value }
    if let value = dict[key] as? Double { return Int(value) }
    if let value = dict[key] as? String { return Int(value) }
    if let value = dict[key.lowercased()] as? Int { return value }
    if let value = dict[key.lowercased()] as? Double { return Int(value) }
    if let value = dict[key.lowercased()] as? String { return Int(value) }
    return nil
}

private func codexJsonString(from value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func formatCodexFailure(_ rawEvent: [String: Any]) -> String? {
    let response = rawEvent["response"] as? [String: Any]
    let error = (rawEvent["error"] as? [String: Any]) ?? (response?["error"] as? [String: Any])
    let message = (error?["message"] as? String) ?? (rawEvent["message"] as? String) ?? (response?["message"] as? String)
    let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? (rawEvent["code"] as? String)
    let status = (response?["status"] as? String) ?? (rawEvent["status"] as? String)

    var meta: [String] = []
    if let code, !code.isEmpty { meta.append("code=\(code)") }
    if let status, !status.isEmpty { meta.append("status=\(status)") }

    if let message, !message.isEmpty {
        let metaText = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
        return "Codex response failed: \(message)\(metaText)"
    }
    if !meta.isEmpty {
        return "Codex response failed (\(meta.joined(separator: ", ")))"
    }
    if let payload = codexJsonString(from: rawEvent) {
        return "Codex response failed: \(truncateCodex(payload, limit: 800))"
    }
    return "Codex response failed"
}

private func formatCodexErrorEvent(_ rawEvent: [String: Any], code: String, message: String) -> String {
    if let detail = formatCodexFailure(rawEvent) {
        return detail.replacingOccurrences(of: "response failed", with: "error event")
    }
    var meta: [String] = []
    if !code.isEmpty { meta.append("code=\(code)") }
    if !message.isEmpty { meta.append("message=\(message)") }
    if !meta.isEmpty {
        return "Codex error event (\(meta.joined(separator: ", ")))"
    }
    if let payload = codexJsonString(from: rawEvent) {
        return "Codex error event: \(truncateCodex(payload, limit: 800))"
    }
    return "Codex error event"
}

private func truncateCodex(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let prefix = text.prefix(limit)
    return "\(prefix)...[truncated \(text.count - limit)]"
}
