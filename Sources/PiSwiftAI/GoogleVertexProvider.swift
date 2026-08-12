import Foundation

private let vertexToolCallCounter = LockedState(0)

public func streamGoogleVertex(
    model: Model,
    context: Context,
    options: GoogleVertexOptions
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
            if options.signal?.isCancelled == true {
                throw GoogleVertexError.aborted
            }
            let project = try resolveVertexProject(options: options)
            let location = try resolveVertexLocation(options: options)
            let accessToken = try resolveVertexAccessToken(options: options)

            let requestBody = try buildVertexRequestBody(model: model, context: context, options: options)
            emitPayload(options.onPayload, data: requestBody)
            let url = try vertexStreamUrl(model: model, project: project, location: location)
            var request = URLRequest(url: url)
            request.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000.0
            request.httpMethod = "POST"
            request.httpBody = requestBody

            var headers = model.headers ?? [:]
            if let extra = options.headers {
                headers.merge(extra) { _, new in new }
            }
            headers["Authorization"] = "Bearer \(accessToken)"
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "text/event-stream"
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let session = proxySession(for: request.url)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GoogleVertexError.invalidResponse
            }
            options.onResponse?(ResponseSnapshot(statusCode: http.statusCode, headers: responseHeaders(http)))
            if !(200..<300).contains(http.statusCode) {
                let body = try await collectSseStreamData(from: bytes)
                let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw GoogleVertexError.apiError(message)
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
                                let count = vertexToolCallCounter.withLock { value -> Int in
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
                        output.rawStopReason = finishReason
                        let result = mapGoogleStopReason(finishReason)
                        output.stopReason = result.stopReason
                        if let errorMessage = result.errorMessage {
                            output.errorMessage = errorMessage
                        }
                        if output.stopReason != .error,
                           output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
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
                throw GoogleVertexError.aborted
            }

            if output.stopReason == .pending {
                throw GoogleVertexError.apiError("Google Vertex stream ended without a finish reason")
            }
            if output.stopReason == .aborted {
                throw GoogleVertexError.aborted
            }
            if output.stopReason == .error {
                throw GoogleVertexError.apiError(output.errorMessage ?? "An unknown error occurred")
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

private func buildVertexRequestBody(
    model: Model,
    context: Context,
    options: GoogleVertexOptions
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

private func resolveVertexProject(options: GoogleVertexOptions) throws -> String {
    let env = ProcessInfo.processInfo.environment
    if let project = options.project ?? env["GOOGLE_CLOUD_PROJECT"] ?? env["GCLOUD_PROJECT"], !project.isEmpty {
        return project
    }
    throw GoogleVertexError.missingProject
}

private func resolveVertexLocation(options: GoogleVertexOptions) throws -> String {
    let env = ProcessInfo.processInfo.environment
    if let location = options.location ?? env["GOOGLE_CLOUD_LOCATION"], !location.isEmpty {
        return location
    }
    // Respect region from AWS profile config when AWS_PROFILE is set
    if let profile = env["AWS_PROFILE"] ?? env["AWS_DEFAULT_PROFILE"],
       let region = loadAwsProfileRegion(profile: profile), !region.isEmpty {
        return region
    }
    throw GoogleVertexError.missingLocation
}

/// Checks whether an API key is a placeholder like `<your-api-key>`.
private func isPlaceholderApiKey(_ key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
}

/// v0.67.3: `gcp-vertex-credentials` is a marker telling Vertex to use Application Default
/// Credentials, not a literal API key. Treat it like the `<authenticated>` placeholder.
private func isAdcMarker(_ key: String) -> Bool {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "gcp-vertex-credentials"
}

/// Cache for ADC token resolution to avoid concurrent gcloud subprocess races.
///
/// SAFETY: token and timestamp mutation are serialized by `lock`; callers only
/// receive copied `String` values.
#if os(macOS) || os(Linux)
private final class VertexTokenCache: @unchecked Sendable {
    static let shared = VertexTokenCache()
    private let lock = NSLock()
    private var cachedToken: String?
    private var cacheTime: Date?
    private let ttl: TimeInterval = 50 * 60 // 50 minutes (OAuth tokens expire at 60m)

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = cachedToken, let time = cacheTime else { return nil }
        if Date().timeIntervalSince(time) > ttl {
            cachedToken = nil
            cacheTime = nil
            return nil
        }
        return token
    }

    func set(_ token: String) {
        lock.lock()
        cachedToken = token
        cacheTime = Date()
        lock.unlock()
    }
}
#endif

private func resolveVertexAccessToken(options: GoogleVertexOptions) throws -> String {
    if let apiKey = options.apiKey, !apiKey.isEmpty, apiKey != "<authenticated>", !isPlaceholderApiKey(apiKey), !isAdcMarker(apiKey) {
        return apiKey
    }
    let env = ProcessInfo.processInfo.environment
    // Support GOOGLE_CLOUD_API_KEY for API key auth
    if let apiKey = env["GOOGLE_CLOUD_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !apiKey.isEmpty, !isPlaceholderApiKey(apiKey), !isAdcMarker(apiKey) {
        return apiKey
    }
    if let token = env["GOOGLE_ACCESS_TOKEN"] ?? env["GCLOUD_ACCESS_TOKEN"] ?? env["GOOGLE_OAUTH_ACCESS_TOKEN"] {
        if !token.isEmpty {
            return token
        }
    }
    #if os(macOS) || os(Linux)
    // The gcloud CLI is only available on desktop/server platforms. Mobile callers must provide
    // a token directly through options or one of the token environment keys.
    if let cached = VertexTokenCache.shared.get() {
        return cached
    }
    if let token = runCommandCapture("gcloud", ["auth", "application-default", "print-access-token"]) {
        VertexTokenCache.shared.set(token)
        return token
    }
    #endif
    throw GoogleVertexError.missingToken
}

private func vertexStreamUrl(model: Model, project: String, location: String) throws -> URL {
    let baseTemplate = model.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    var base = baseTemplate.isEmpty ? "https://\(location)-aiplatform.googleapis.com" : baseTemplate
    base = base.replacingOccurrences(of: "{location}", with: location)
    base = base.replacingOccurrences(of: "{project}", with: project)
    while base.hasSuffix("/") {
        base.removeLast()
    }
    let path = "/v1/projects/\(project)/locations/\(location)/publishers/google/models/\(model.id):streamGenerateContent"
    var components = URLComponents(string: "\(base)\(path)")
    components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
    guard let url = components?.url else {
        throw GoogleVertexError.invalidResponse
    }
    return url
}

#if os(macOS) || os(Linux)
private func runCommandCapture(_ command: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == false ? output : nil
}
#endif

private enum GoogleVertexError: LocalizedError {
    case missingProject
    case missingLocation
    case missingToken
    case invalidResponse
    case apiError(String)
    case aborted
    case unknown

    var errorDescription: String? {
        switch self {
        case .missingProject:
            return "Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT or pass project in options."
        case .missingLocation:
            return "Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION or pass location in options."
        case .missingToken:
            return "Vertex AI requires an access token. Use application default credentials or pass a token in options."
        case .invalidResponse:
            return "Vertex AI returned an invalid response."
        case .apiError(let message):
            return message
        case .aborted:
            return "Request was aborted"
        case .unknown:
            return "Vertex AI request failed"
        }
    }
}
