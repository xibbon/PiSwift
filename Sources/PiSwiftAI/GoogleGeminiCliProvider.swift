import Foundation

private let geminiCliToolCallCounter = LockedState(0)

private let defaultGeminiCliEndpoint = "https://cloudcode-pa.googleapis.com"
private let antigravityDailyEndpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com"
private let antigravityAutopushEndpoint = "https://autopush-cloudcode-pa.sandbox.googleapis.com"
private let antigravityEndpointFallbacks = [antigravityDailyEndpoint, antigravityAutopushEndpoint, defaultGeminiCliEndpoint]

private let geminiCliHeaders: [String: String] = [
    "User-Agent": "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client": "gl-node/22.17.0",
    "Client-Metadata": #"{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#,
]

// Antigravity: minimal headers only (stripped extra headers per upstream v0.61.1)
private let antigravityHeaders: [String: String] = [:]

private let defaultAntigravityVersion = "1.21.9"

private func antigravityUserAgent() -> String {
    let env = ProcessInfo.processInfo.environment
    let version = env["PI_AI_ANTIGRAVITY_VERSION"] ?? defaultAntigravityVersion
    return "antigravity/\(version) darwin/arm64"
}

private let antigravitySystemInstruction =
    "You are Antigravity, a powerful agentic AI coding assistant designed by the Google Deepmind team working on Advanced Agentic Coding." +
    "You are pair programming with a USER to solve their coding task. The task may require creating a new codebase, modifying or debugging an existing codebase, or simply answering a question." +
    "**Absolute paths only**" +
    "**Proactiveness**"

private let maxRetries = 3
private let baseDelayMs = 1000
private let maxEmptyStreamRetries = 2
private let emptyStreamBaseDelayMs = 500
private let claudeThinkingBetaHeader = "interleaved-thinking-2025-05-14"
private let googleGeminiCliSessionOverride = LockedState<URLSession?>(nil)

func setGoogleGeminiCliSessionOverrideForTesting(_ session: URLSession?) {
    googleGeminiCliSessionOverride.withLock { $0 = session }
}

private func googleGeminiCliSession(for url: URL?) -> URLSession {
    if let override = googleGeminiCliSessionOverride.withLock({ $0 }) {
        return override
    }
    return proxySession(for: url)
}

public func streamGoogleGeminiCli(
    model: Model,
    context: Context,
    options: GoogleGeminiCliOptions
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
            guard let apiKeyRaw = options.apiKey, !apiKeyRaw.isEmpty else {
                throw GoogleGeminiCliError.missingCredentials
            }

            let credentials = try parseGeminiCliCredentials(apiKeyRaw)
            let accessToken = credentials.token
            let projectId = credentials.projectId

            if accessToken.isEmpty || projectId.isEmpty {
                throw GoogleGeminiCliError.invalidCredentials
            }

            let isAntigravity = model.provider == "google-antigravity"
            let baseUrl = model.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoints = baseUrl.isEmpty ? (isAntigravity ? antigravityEndpointFallbacks : [defaultGeminiCliEndpoint]) : [baseUrl]

            let requestBody = try buildGeminiCliRequest(model: model, context: context, projectId: projectId, options: options, isAntigravity: isAntigravity)
            emitPayload(options.onPayload, jsonObject: requestBody)
            let requestData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

            var baseHeaders = isAntigravity ? antigravityHeaders : geminiCliHeaders
            if isAntigravity {
                baseHeaders["User-Agent"] = antigravityUserAgent()
            }
            if isClaudeThinkingModel(model.id) {
                baseHeaders["anthropic-beta"] = claudeThinkingBetaHeader
            }
            if let modelHeaders = model.headers {
                baseHeaders.merge(modelHeaders) { _, new in new }
            }
            if let extra = options.headers {
                baseHeaders.merge(extra) { _, new in new }
            }

            var responseBytes: URLSession.AsyncBytes?
            var responseMeta: HTTPURLResponse?
            var requestUrl: String?
            var lastError: Error?

            let retryLimit = max(0, options.maxRetries ?? maxRetries)
            for attempt in 0...retryLimit {
                if options.signal?.isCancelled == true {
                    throw GoogleGeminiCliError.aborted
                }

                do {
                    let endpoint = endpoints[min(attempt, endpoints.count - 1)]
                    requestUrl = "\(endpoint)/v1internal:streamGenerateContent?alt=sse"
                    guard let url = URL(string: requestUrl ?? "") else {
                        throw GoogleGeminiCliError.invalidResponse
                    }

                    var request = URLRequest(url: url)
                    request.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000.0
                    request.httpMethod = "POST"
                    request.httpBody = requestData

                    var headers = baseHeaders
                    headers["Authorization"] = "Bearer \(accessToken)"
                    headers["Content-Type"] = "application/json"
                    headers["Accept"] = "text/event-stream"

                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let session = googleGeminiCliSession(for: request.url)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw GoogleGeminiCliError.invalidResponse
                    }
                    options.onResponse?(ResponseSnapshot(statusCode: http.statusCode, headers: responseHeaders(http)))

                    if http.statusCode >= 200 && http.statusCode < 300 {
                        responseBytes = bytes
                        responseMeta = http
                        break
                    }

                    let body = try await collectSseStreamData(from: bytes)
                    let errorText = String(data: body, encoding: .utf8) ?? ""

                    // 403/404: immediately try next endpoint (no delay)
                    if (http.statusCode == 403 || http.statusCode == 404) && attempt < retryLimit {
                        continue
                    }

                    if attempt < retryLimit && isRetryableError(status: http.statusCode, errorText: errorText) {
                        let serverDelay = extractRetryDelay(errorText: errorText, response: http)
                        let delay = serverDelay ?? (baseDelayMs * (1 << attempt))
                        let maxDelayMs = options.maxRetryDelayMs ?? 60000
                        if maxDelayMs > 0, let serverDelay, serverDelay > maxDelayMs {
                            let delaySeconds = Int(ceil(Double(serverDelay) / 1000.0))
                            let maxSeconds = Int(ceil(Double(maxDelayMs) / 1000.0))
                            throw GoogleGeminiCliError.apiError(
                                "Server requested \(delaySeconds)s retry delay (max: \(maxSeconds)s). \(extractErrorMessage(errorText))"
                            )
                        }
                        try await sleepMillis(delay, signal: options.signal)
                        continue
                    }
                    throw GoogleGeminiCliError.apiError("Cloud Code Assist API error (\(http.statusCode)): \(extractErrorMessage(errorText))")
                } catch {
                    if let cliError = error as? GoogleGeminiCliError, cliError == .aborted {
                        throw cliError
                    }
                    lastError = error
                    if attempt < retryLimit {
                        let delay = baseDelayMs * (1 << attempt)
                        try await sleepMillis(delay, signal: options.signal)
                        continue
                    }
                    throw error
                }
            }

            guard let bytes = responseBytes, responseMeta != nil else {
                throw lastError ?? GoogleGeminiCliError.invalidResponse
            }

            var started = false
            func ensureStarted() {
                if !started {
                    stream.push(.start(partial: output))
                    started = true
                }
            }

            func resetOutput() {
                output.content = []
                output.usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
                output.stopReason = .stop
                output.errorMessage = nil
                output.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                started = false
            }

            func streamResponse(_ bytes: URLSession.AsyncBytes) async throws -> Bool {
                var hasContent = false
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
                    guard let chunk = try? JSONDecoder().decode(GeminiCliStreamChunk.self, from: data),
                          let response = chunk.response else { continue }

                    // Capture responseId from Cloud Code Assist (mirrors Gemini's responseId)
                    if output.responseId == nil, let rid = response.responseId, !rid.isEmpty {
                        output.responseId = rid
                    }

                    if let candidate = response.candidates?.first, let parts = candidate.content?.parts {
                        for part in parts {
                            if let text = part.text {
                                hasContent = true
                                let isThinking = isThinkingPart(thought: part.thought)
                                if currentBlockIndex == nil || (isThinking && currentBlockKind != "thinking") || (!isThinking && currentBlockKind != "text") {
                                    finishCurrentBlock()
                                    if isThinking {
                                        output.content.append(.thinking(ThinkingContent(thinking: "")))
                                        currentBlockIndex = output.content.count - 1
                                        currentBlockKind = "thinking"
                                        ensureStarted()
                                        stream.push(.thinkingStart(contentIndex: currentBlockIndex!, partial: output))
                                    } else {
                                        output.content.append(.text(TextContent(text: "")))
                                        currentBlockIndex = output.content.count - 1
                                        currentBlockKind = "text"
                                        ensureStarted()
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
                                hasContent = true
                                finishCurrentBlock()

                                let providedId = functionCall.id
                                let needsNew = providedId == nil || (providedId != nil && knownToolCallIds.contains(providedId!))
                                let toolCallId: String
                                if needsNew {
                                    let count = geminiCliToolCallCounter.withLock { value -> Int in
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
                                ensureStarted()
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

                    if let usage = response.usageMetadata {
                        let promptTokens = usage.promptTokenCount ?? 0
                        let cacheRead = usage.cachedContentTokenCount ?? 0
                        output.usage = Usage(
                            input: promptTokens - cacheRead,
                            output: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
                            cacheRead: cacheRead,
                            cacheWrite: 0,
                            totalTokens: usage.totalTokenCount ?? 0
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                }

                finishCurrentBlock()
                return hasContent
            }

            var receivedContent = false
            var currentBytes = bytes

            for emptyAttempt in 0...maxEmptyStreamRetries {
                if options.signal?.isCancelled == true {
                    throw GoogleGeminiCliError.aborted
                }

                if emptyAttempt > 0 {
                    let backoffMs = emptyStreamBaseDelayMs * (1 << (emptyAttempt - 1))
                    try await sleepMillis(backoffMs, signal: options.signal)
                    guard let requestUrl, let url = URL(string: requestUrl) else {
                        throw GoogleGeminiCliError.invalidResponse
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = requestData

                    var headers = baseHeaders
                    headers["Authorization"] = "Bearer \(accessToken)"
                    headers["Content-Type"] = "application/json"
                    headers["Accept"] = "text/event-stream"
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    let session = googleGeminiCliSession(for: request.url)
                    let (retryBytes, retryResponse) = try await session.bytes(for: request)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode >= 200 && retryHttp.statusCode < 300 else {
                        let body = try await collectSseStreamData(from: retryBytes)
                        let message = String(data: body, encoding: .utf8) ?? "HTTP \(retryResponse)"
                        throw GoogleGeminiCliError.apiError("Cloud Code Assist API error: \(message)")
                    }
                    currentBytes = retryBytes
                }

                let streamed = try await streamResponse(currentBytes)
                if streamed {
                    receivedContent = true
                    break
                }

                if emptyAttempt < maxEmptyStreamRetries {
                    resetOutput()
                }
            }

            if !receivedContent {
                throw GoogleGeminiCliError.emptyResponse
            }

            if options.signal?.isCancelled == true {
                throw GoogleGeminiCliError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw GoogleGeminiCliError.unknown
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

public func streamSimpleGoogleGeminiCli(
    model: Model,
    context: Context,
    options: SimpleStreamOptions?
) -> AssistantMessageEventStream {
    let baseMaxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let base = GoogleGeminiCliOptions(
        temperature: options?.temperature,
        maxTokens: baseMaxTokens,
        signal: options?.signal,
        apiKey: options?.apiKey,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        headers: options?.headers,
        toolChoice: nil,
        thinking: nil,
        sessionId: options?.sessionId,
        projectId: nil,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries
    )

    guard let reasoning = options?.reasoning else {
        let updated = GoogleGeminiCliOptions(
            temperature: base.temperature,
            maxTokens: base.maxTokens,
            signal: base.signal,
            apiKey: base.apiKey,
            maxRetryDelayMs: base.maxRetryDelayMs,
            headers: base.headers,
            toolChoice: base.toolChoice,
            thinking: GoogleOptions.ThinkingConfig(enabled: false),
            sessionId: base.sessionId,
            projectId: base.projectId,
            onPayload: base.onPayload,
            onResponse: base.onResponse,
            timeoutMs: base.timeoutMs,
            maxRetries: base.maxRetries
        )
        return streamGoogleGeminiCli(model: model, context: context, options: updated)
    }

    let effort = clampGeminiThinkingLevel(reasoning)
    if model.id.contains("3-pro") || model.id.contains("3-flash") || model.id.contains("3.1-pro") || model.id.contains("3.1-flash") {
        let updated = GoogleGeminiCliOptions(
            temperature: base.temperature,
            maxTokens: base.maxTokens,
            signal: base.signal,
            apiKey: base.apiKey,
            maxRetryDelayMs: base.maxRetryDelayMs,
            headers: base.headers,
            toolChoice: base.toolChoice,
            thinking: GoogleOptions.ThinkingConfig(
                enabled: true,
                budgetTokens: nil,
                level: getGeminiCliThinkingLevel(effort: effort, modelId: model.id)
            ),
            sessionId: base.sessionId,
            projectId: base.projectId,
            onPayload: base.onPayload,
            onResponse: base.onResponse,
            timeoutMs: base.timeoutMs,
            maxRetries: base.maxRetries
        )
        return streamGoogleGeminiCli(model: model, context: context, options: updated)
    }

    let defaultBudgets: ThinkingBudgets = [
        .minimal: 1024,
        .low: 2048,
        .medium: 8192,
        .high: 16384,
    ]
    let budgets = defaultBudgets.merging(options?.thinkingBudgets ?? [:]) { _, new in new }
    let minOutputTokens = 1024
    var thinkingBudget = budgets[effort] ?? 1024
    let maxTokens = min(baseMaxTokens + thinkingBudget, model.maxTokens)
    if maxTokens <= thinkingBudget {
        thinkingBudget = max(0, maxTokens - minOutputTokens)
    }

    let updated = GoogleGeminiCliOptions(
        temperature: base.temperature,
        maxTokens: maxTokens,
        signal: base.signal,
        apiKey: base.apiKey,
        maxRetryDelayMs: base.maxRetryDelayMs,
        headers: base.headers,
        toolChoice: base.toolChoice,
        thinking: GoogleOptions.ThinkingConfig(enabled: true, budgetTokens: thinkingBudget, level: nil),
        sessionId: base.sessionId,
        projectId: base.projectId,
        onPayload: base.onPayload,
        onResponse: base.onResponse,
        timeoutMs: base.timeoutMs,
        maxRetries: base.maxRetries
    )
    return streamGoogleGeminiCli(model: model, context: context, options: updated)
}

private func buildGeminiCliRequest(
    model: Model,
    context: Context,
    projectId: String,
    options: GoogleGeminiCliOptions,
    isAntigravity: Bool
) throws -> [String: Any] {
    let contents = convertGoogleMessages(model: model, context: context)

    var generationConfig: [String: Any] = [:]
    if let temperature = options.temperature {
        generationConfig["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
        generationConfig["maxOutputTokens"] = maxTokens
    }

    if let thinking = options.thinking, model.reasoning {
        let thinkingConfig: [String: Any]
        if thinking.enabled {
            var enabledConfig: [String: Any] = ["includeThoughts": true]
            if let level = thinking.level {
                enabledConfig["thinkingLevel"] = level.rawValue
            } else if let budget = thinking.budgetTokens {
                enabledConfig["thinkingBudget"] = budget
            }
            thinkingConfig = enabledConfig
        } else {
            thinkingConfig = googleDisabledThinkingConfig(model: model)
        }
        generationConfig["thinkingConfig"] = thinkingConfig
    }

    var request: [String: Any] = [
        "contents": contents,
    ]

    if let sessionId = options.sessionId {
        request["sessionId"] = sessionId
    }

    if let systemPrompt = context.systemPrompt, !systemPrompt.isEmpty {
        request["systemInstruction"] = [
            "parts": [
                ["text": sanitizeSurrogates(systemPrompt)],
            ],
        ]
    }

    if !generationConfig.isEmpty {
        request["generationConfig"] = generationConfig
    }

    if let tools = context.tools, !tools.isEmpty {
        let useParameters = model.id.hasPrefix("claude-")
        request["tools"] = convertGoogleTools(tools, useParameters: useParameters)
        if let choice = options.toolChoice {
            request["toolConfig"] = [
                "functionCallingConfig": [
                    "mode": mapGoogleToolChoice(choice),
                ],
            ]
        }
    }

    if isAntigravity {
        let existingParts = ((request["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        request["systemInstruction"] = [
            "role": "user",
            "parts": [
                ["text": antigravitySystemInstruction],
                ["text": "Please ignore following [ignore]\(antigravitySystemInstruction)[/ignore]"],
            ] + existingParts,
        ]
    }

    let prefix = isAntigravity ? "agent" : "pi"
    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    let randomSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9)

    var payload: [String: Any] = [
        "project": projectId,
        "model": model.id,
        "request": request,
        "userAgent": isAntigravity ? "antigravity" : "pi-coding-agent",
        "requestId": "\(prefix)-\(timestamp)-\(randomSuffix)",
    ]

    if isAntigravity {
        payload["requestType"] = "agent"
    }

    return payload
}

private func parseGeminiCliCredentials(_ raw: String) throws -> (token: String, projectId: String) {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: Any] else {
        throw GoogleGeminiCliError.invalidCredentials
    }
    let token = dict["token"] as? String ?? ""
    let projectId = dict["projectId"] as? String ?? ""
    if token.isEmpty || projectId.isEmpty {
        throw GoogleGeminiCliError.invalidCredentials
    }
    return (token, projectId)
}

func extractRetryDelay(errorText: String, response: HTTPURLResponse?) -> Int? {
    func normalizeDelay(_ ms: Double) -> Int? {
        ms > 0 ? Int(ceil(ms + 1000)) : nil
    }

    if let response {
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after") {
            if let seconds = Double(retryAfter) {
                if let delay = normalizeDelay(seconds * 1000) { return delay }
            }
            if let date = DateFormatter.rfc1123.date(from: retryAfter) {
                let ms = date.timeIntervalSinceNow * 1000
                if let delay = normalizeDelay(ms) { return delay }
            }
        }

        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let seconds = Double(reset) {
            let ms = seconds * 1000 - Date().timeIntervalSince1970 * 1000
            if let delay = normalizeDelay(ms) { return delay }
        }

        if let resetAfter = response.value(forHTTPHeaderField: "x-ratelimit-reset-after"),
           let seconds = Double(resetAfter) {
            if let delay = normalizeDelay(seconds * 1000) { return delay }
        }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "reset after ([0-9hms.]+)"),
       let ms = parseDuration(groups[0]) {
        if let delay = normalizeDelay(ms) { return delay }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "Please retry in ([0-9.]+)(ms|s)"),
       groups.count >= 2,
       let number = Double(groups[0]) {
        let unit = groups[1].lowercased()
        let ms = unit == "ms" ? number : number * 1000
        if let delay = normalizeDelay(ms) { return delay }
    }

    if let groups = firstRegexGroups(in: errorText, pattern: "\"retryDelay\":\\s*\"([0-9.]+)(ms|s)\""),
       groups.count >= 2,
       let number = Double(groups[0]) {
        let unit = groups[1].lowercased()
        let ms = unit == "ms" ? number : number * 1000
        if let delay = normalizeDelay(ms) { return delay }
    }

    return nil
}

private func parseDuration(_ value: String) -> Double? {
    let pattern = "([0-9.]+)(ms|s|m|h)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = regex.matches(in: value, options: [], range: range)
    guard !matches.isEmpty else { return nil }
    var totalMs: Double = 0
    for match in matches {
        guard match.numberOfRanges == 3,
              let valueRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let number = Double(value[valueRange]) else { continue }
        let unit = value[unitRange]
        switch unit {
        case "ms":
            totalMs += number
        case "s":
            totalMs += number * 1000
        case "m":
            totalMs += number * 60 * 1000
        case "h":
            totalMs += number * 60 * 60 * 1000
        default:
            break
        }
    }
    return totalMs > 0 ? totalMs : nil
}

private func firstRegexGroups(in text: String, pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
    var groups: [String] = []
    for idx in 1..<match.numberOfRanges {
        guard let groupRange = Range(match.range(at: idx), in: text) else { continue }
        groups.append(String(text[groupRange]))
    }
    return groups.isEmpty ? nil : groups
}

private func isClaudeThinkingModel(_ modelId: String) -> Bool {
    let normalized = modelId.lowercased()
    if normalized.contains("claude") && normalized.contains("thinking") {
        return true
    }
    // Claude models on Antigravity (e.g. claude-sonnet-4-6) need the thinking beta header
    if normalized.hasPrefix("claude-") {
        return true
    }
    return false
}

private func isRetryableError(status: Int, errorText: String) -> Bool {
    if status == 429 || status == 500 || status == 502 || status == 503 || status == 504 || status == 524 {
        return true
    }
    let pattern = "resource.?exhausted|rate.?limit|overloaded|service.?unavailable|other.?side.?closed|socket connection was closed|you can retry your request|try your request again|please retry your request"
    return errorText.range(of: pattern, options: .regularExpression) != nil
}

private func extractErrorMessage(_ errorText: String) -> String {
    if let data = errorText.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
       let error = json["error"] as? [String: Any],
       let message = error["message"] as? String,
       !message.isEmpty {
        return message
    }
    return errorText
}

private func sleepMillis(_ ms: Int, signal: CancellationToken?) async throws {
    if signal?.isCancelled == true {
        throw GoogleGeminiCliError.aborted
    }
    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    if signal?.isCancelled == true {
        throw GoogleGeminiCliError.aborted
    }
}

private func getGeminiCliThinkingLevel(effort: ThinkingLevel, modelId: String) -> GoogleThinkingLevel {
    let clamped = (effort == .xhigh || effort == .max) ? .high : effort
    if modelId.contains("3-pro") || modelId.contains("3.1-pro") {
        switch clamped {
        case .minimal, .low:
            return .low
        case .medium, .high, .xhigh, .max:
            return .high
        }
    }
    switch clamped {
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

private func clampGeminiThinkingLevel(_ effort: ThinkingLevel) -> ThinkingLevel {
    (effort == .xhigh || effort == .max) ? .high : effort
}

private enum GoogleGeminiCliError: LocalizedError, Equatable {
    case missingCredentials
    case invalidCredentials
    case emptyResponse
    case invalidResponse
    case apiError(String)
    case aborted
    case unknown

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Google Cloud Code Assist requires OAuth authentication. Use /login to authenticate."
        case .invalidCredentials:
            return "Invalid Google Cloud Code Assist credentials. Use /login to re-authenticate."
        case .emptyResponse:
            return "Cloud Code Assist API returned an empty response."
        case .invalidResponse:
            return "Cloud Code Assist API returned an invalid response."
        case .apiError(let message):
            return message
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "Cloud Code Assist API request failed"
        }
    }
}

private extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
