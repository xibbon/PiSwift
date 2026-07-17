import CryptoKit
import Foundation

private enum BedrockStreamError: Error {
    case invalidUrl
    case invalidResponse
    case missingCredentials
    case aborted
    case serverError(String)
}

private struct AwsCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
}

private enum BedrockAuth: Sendable {
    case sigV4(AwsCredentials)
    case bearer(String)
}

private struct BedrockRequest: Encodable {
    let messages: [BedrockMessage]
    let system: [BedrockSystemBlock]?
    let inferenceConfig: BedrockInferenceConfig?
    let toolConfig: BedrockToolConfig?
    let additionalModelRequestFields: [String: AnyCodable]?
    /// v0.62.0: AWS Cost Explorer split cost allocation tags forwarded to Converse.
    let requestMetadata: [String: String]?
}

private struct BedrockMessage: Encodable {
    let role: String
    var content: [BedrockContentBlock]
}

private struct BedrockContentBlock: Encodable {
    let payload: AnyCodable

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

private struct BedrockSystemBlock: Encodable {
    let payload: AnyCodable

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

private struct BedrockInferenceConfig: Encodable {
    let maxTokens: Int?
    let temperature: Double?
}

private struct BedrockToolConfig: Encodable {
    let tools: [BedrockTool]
    let toolChoice: BedrockToolChoicePayload?
}

private struct BedrockTool: Encodable {
    let name: String
    let description: String
    let parameters: [String: AnyCodable]

    func encode(to encoder: Encoder) throws {
        let schema = parameters.mapValues { $0.value }
        let payload: [String: Any] = [
            "toolSpec": [
                "name": name,
                "description": description,
                "inputSchema": ["json": schema],
            ],
        ]
        var container = encoder.singleValueContainer()
        try container.encode(AnyCodable(payload))
    }
}

private struct BedrockToolChoicePayload: Encodable {
    let payload: AnyCodable

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
}

private struct BedrockContentBlockStartEvent: Decodable {
    let contentBlockIndex: Int?
    let start: BedrockContentBlockStart?
}

private struct BedrockContentBlockStart: Decodable {
    let toolUse: BedrockToolUseStart?
}

private struct BedrockToolUseStart: Decodable {
    let toolUseId: String?
    let name: String?
}

private struct BedrockContentBlockDeltaEvent: Decodable {
    let contentBlockIndex: Int?
    let delta: BedrockContentBlockDelta?
}

private struct BedrockContentBlockDelta: Decodable {
    let text: String?
    let toolUse: BedrockToolUseDelta?
    let reasoningContent: BedrockReasoningContentDelta?
}

private struct BedrockToolUseDelta: Decodable {
    let input: String?
}

private struct BedrockReasoningContentDelta: Decodable {
    let text: String?
    let signature: String?
}

private struct BedrockContentBlockStopEvent: Decodable {
    let contentBlockIndex: Int?
}

private struct BedrockMessageStartEvent: Decodable {
    let role: String?
}

private struct BedrockMessageStopEvent: Decodable {
    let stopReason: String?
}

private struct BedrockMetadataEvent: Decodable {
    let usage: BedrockUsage?
}

private struct BedrockUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let totalTokens: Int?
}

private struct BedrockMessageStartWrapper: Decodable {
    let messageStart: BedrockMessageStartEvent
}

private struct BedrockContentBlockStartWrapper: Decodable {
    let contentBlockStart: BedrockContentBlockStartEvent
}

private struct BedrockContentBlockDeltaWrapper: Decodable {
    let contentBlockDelta: BedrockContentBlockDeltaEvent
}

private struct BedrockContentBlockStopWrapper: Decodable {
    let contentBlockStop: BedrockContentBlockStopEvent
}

private struct BedrockMessageStopWrapper: Decodable {
    let messageStop: BedrockMessageStopEvent
}

private struct BedrockMetadataWrapper: Decodable {
    let metadata: BedrockMetadataEvent
}

private struct AwsEventStreamMessage {
    let headers: [String: String]
    let payload: Data
}

private struct AwsEventStreamParser {
    private var buffer = Data()

    mutating func append(_ byte: UInt8) -> [AwsEventStreamMessage] {
        buffer.append(byte)
        return drain()
    }

    private mutating func drain() -> [AwsEventStreamMessage] {
        var messages: [AwsEventStreamMessage] = []

        while buffer.count >= 12 {
            let totalLength = Int(readUInt32(buffer, at: 0))
            let headersLength = Int(readUInt32(buffer, at: 4))

            if totalLength <= 0 || totalLength > buffer.count {
                break
            }

            if totalLength < headersLength + 16 {
                buffer.removeAll()
                break
            }

            let messageData = buffer.subdata(in: 0..<totalLength)
            buffer.removeSubrange(0..<totalLength)

            let headersStart = 12
            let headersEnd = headersStart + headersLength
            let payloadStart = headersEnd
            let payloadLength = totalLength - headersLength - 16
            let payloadEnd = payloadStart + max(0, payloadLength)

            let headersData = messageData.subdata(in: headersStart..<headersEnd)
            let payload = payloadEnd <= messageData.count
                ? messageData.subdata(in: payloadStart..<payloadEnd)
                : Data()
            let headers = parseHeaders(headersData)
            messages.append(AwsEventStreamMessage(headers: headers, payload: payload))
        }

        return messages
    }
}

private struct BedrockStreamState {
    var indexMap: [Int: Int] = [:]
    var toolCallPartials: [Int: String] = [:]
}

public func streamBedrock(
    model: Model,
    context: Context,
    options: BedrockOptions
) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()

    Task {
        var output = AssistantMessage(
            content: [],
            api: .bedrockConverseStream,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop
        )

        do {
            let region = resolveBedrockRegion(model: model, options: options)
            let auth = try resolveBedrockAuth(options: options)
            let (request, body) = try buildBedrockRequest(model: model, context: context, options: options, region: region)
            var signedRequest = try signBedrockRequest(request: request, body: body, region: region, auth: auth)
            signedRequest.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000.0

            let retryLimit = max(0, options.maxRetries ?? 0)
            var attempt = 0
            while true {
                do {
                    let session = proxySession(for: signedRequest.url)
                    let (bytes, response) = try await session.bytes(for: signedRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw BedrockStreamError.invalidResponse
                    }
                    options.onResponse?(ResponseSnapshot(statusCode: httpResponse.statusCode, headers: responseHeaders(httpResponse)))
                    guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
                        let data = try await collectSseStreamData(from: bytes)
                        let text = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                        throw BedrockStreamError.serverError(formatBedrockHTTPError(statusCode: httpResponse.statusCode, body: text))
                    }

                    var parser = AwsEventStreamParser()
                    var state = BedrockStreamState()
                    let decoder = JSONDecoder()

                    for try await byte in bytes {
                        if options.signal?.isCancelled == true {
                            throw BedrockStreamError.aborted
                        }
                        for message in parser.append(byte) {
                            try handleBedrockEvent(
                                message,
                                decoder: decoder,
                                model: model,
                                output: &output,
                                state: &state,
                                stream: stream
                            )
                        }
                    }
                    break
                } catch {
                    if options.signal?.isCancelled == true {
                        throw BedrockStreamError.aborted
                    }
                    if attempt < retryLimit, isRetryableTransportError(error) {
                        attempt += 1
                        output.content = []
                        output.usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
                        output.stopReason = .stop
                        output.errorMessage = nil
                        continue
                    }
                    throw error
                }
            }

            if options.signal?.isCancelled == true {
                throw BedrockStreamError.aborted
            }

            if output.stopReason == .error || output.stopReason == .aborted {
                throw BedrockStreamError.serverError("Unknown Bedrock stream error")
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = errorMessage(for: error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private func handleBedrockEvent(
    _ message: AwsEventStreamMessage,
    decoder: JSONDecoder,
    model: Model,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) throws {
    let messageType = message.headers[":message-type"]
    if messageType == "exception" {
        let errorText = String(data: message.payload, encoding: .utf8) ?? "Bedrock exception"
        throw BedrockStreamError.serverError(errorText)
    }

    guard let eventType = message.headers[":event-type"] else { return }

    switch eventType {
    case "messageStart":
        let event = decodeEvent(
            direct: BedrockMessageStartEvent.self,
            wrapper: BedrockMessageStartWrapper.self,
            payload: message.payload,
            decoder: decoder
        )
        if let role = event?.role, role.lowercased() != "assistant" {
            throw BedrockStreamError.serverError("Unexpected role in Bedrock stream: \(role)")
        }
        stream.push(.start(partial: output))
    case "contentBlockStart":
        if let event = decodeEvent(
            direct: BedrockContentBlockStartEvent.self,
            wrapper: BedrockContentBlockStartWrapper.self,
            payload: message.payload,
            decoder: decoder
        ) {
            handleContentBlockStart(event, output: &output, state: &state, stream: stream)
        }
    case "contentBlockDelta":
        if let event = decodeEvent(
            direct: BedrockContentBlockDeltaEvent.self,
            wrapper: BedrockContentBlockDeltaWrapper.self,
            payload: message.payload,
            decoder: decoder
        ) {
            handleContentBlockDelta(event, output: &output, state: &state, stream: stream)
        }
    case "contentBlockStop":
        if let event = decodeEvent(
            direct: BedrockContentBlockStopEvent.self,
            wrapper: BedrockContentBlockStopWrapper.self,
            payload: message.payload,
            decoder: decoder
        ) {
            handleContentBlockStop(event, output: &output, state: &state, stream: stream)
        }
    case "messageStop":
        let event = decodeEvent(
            direct: BedrockMessageStopEvent.self,
            wrapper: BedrockMessageStopWrapper.self,
            payload: message.payload,
            decoder: decoder
        )
        output.stopReason = mapBedrockStopReason(event?.stopReason)
    case "metadata":
        if let event = decodeEvent(
            direct: BedrockMetadataEvent.self,
            wrapper: BedrockMetadataWrapper.self,
            payload: message.payload,
            decoder: decoder
        ) {
            handleMetadata(event, model: model, output: &output)
        }
    default:
        break
    }
}

private func handleContentBlockStart(
    _ event: BedrockContentBlockStartEvent,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) {
    guard let blockIndex = event.contentBlockIndex,
          let toolUse = event.start?.toolUse else {
        return
    }

    let toolCall = ToolCall(
        id: toolUse.toolUseId ?? "",
        name: toolUse.name ?? "",
        arguments: [:]
    )
    output.content.append(.toolCall(toolCall))
    let contentIndex = output.content.count - 1
    state.indexMap[blockIndex] = contentIndex
    state.toolCallPartials[blockIndex] = ""
    stream.push(.toolCallStart(contentIndex: contentIndex, partial: output))
}

private func handleContentBlockDelta(
    _ event: BedrockContentBlockDeltaEvent,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) {
    guard let blockIndex = event.contentBlockIndex, let delta = event.delta else { return }

    if let text = delta.text {
        let contentIndex = ensureTextBlock(for: blockIndex, output: &output, state: &state, stream: stream)
        if case .text(var textContent) = output.content[contentIndex] {
            textContent.text += text
            output.content[contentIndex] = .text(textContent)
            stream.push(.textDelta(contentIndex: contentIndex, delta: text, partial: output))
        }
        return
    }

    if let toolUse = delta.toolUse {
        guard let contentIndex = state.indexMap[blockIndex] else { return }
        if case .toolCall(var toolCall) = output.content[contentIndex] {
            let partial = (state.toolCallPartials[blockIndex] ?? "") + (toolUse.input ?? "")
            state.toolCallPartials[blockIndex] = partial
            toolCall.arguments = parseStreamingJSON(partial)
            output.content[contentIndex] = .toolCall(toolCall)
            stream.push(.toolCallDelta(contentIndex: contentIndex, delta: toolUse.input ?? "", partial: output))
        }
        return
    }

    if let reasoning = delta.reasoningContent {
        let contentIndex = ensureThinkingBlock(for: blockIndex, output: &output, state: &state, stream: stream)
        if case .thinking(var thinkingContent) = output.content[contentIndex] {
            if let text = reasoning.text, !text.isEmpty {
                thinkingContent.thinking += text
                output.content[contentIndex] = .thinking(thinkingContent)
                stream.push(.thinkingDelta(contentIndex: contentIndex, delta: text, partial: output))
            }
            if let signature = reasoning.signature, !signature.isEmpty {
                let current = thinkingContent.thinkingSignature ?? ""
                thinkingContent.thinkingSignature = current + signature
                output.content[contentIndex] = .thinking(thinkingContent)
            }
        }
    }
}

private func handleContentBlockStop(
    _ event: BedrockContentBlockStopEvent,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) {
    guard let blockIndex = event.contentBlockIndex,
          let contentIndex = state.indexMap[blockIndex] else {
        return
    }

    switch output.content[contentIndex] {
    case .text(let textContent):
        stream.push(.textEnd(contentIndex: contentIndex, content: textContent.text, partial: output))
    case .thinking(let thinkingContent):
        stream.push(.thinkingEnd(contentIndex: contentIndex, content: thinkingContent.thinking, partial: output))
    case .toolCall(var toolCall):
        let partial = state.toolCallPartials[blockIndex] ?? ""
        toolCall.arguments = parseStreamingJSON(partial)
        output.content[contentIndex] = .toolCall(toolCall)
        state.toolCallPartials.removeValue(forKey: blockIndex)
        stream.push(.toolCallEnd(contentIndex: contentIndex, toolCall: toolCall, partial: output))
    default:
        break
    }
}

private func handleMetadata(_ event: BedrockMetadataEvent, model: Model, output: inout AssistantMessage) {
    guard let usage = event.usage else { return }
    output.usage.input = usage.inputTokens ?? 0
    output.usage.output = usage.outputTokens ?? 0
    output.usage.cacheRead = usage.cacheReadInputTokens ?? 0
    output.usage.cacheWrite = usage.cacheWriteInputTokens ?? 0
    output.usage.totalTokens = usage.totalTokens ?? (output.usage.input + output.usage.output)
    calculateCost(model: model, usage: &output.usage)
}

private func ensureTextBlock(
    for blockIndex: Int,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) -> Int {
    if let existing = state.indexMap[blockIndex] {
        return existing
    }
    let textBlock = TextContent(text: "")
    output.content.append(.text(textBlock))
    let contentIndex = output.content.count - 1
    state.indexMap[blockIndex] = contentIndex
    stream.push(.textStart(contentIndex: contentIndex, partial: output))
    return contentIndex
}

private func ensureThinkingBlock(
    for blockIndex: Int,
    output: inout AssistantMessage,
    state: inout BedrockStreamState,
    stream: AssistantMessageEventStream
) -> Int {
    if let existing = state.indexMap[blockIndex] {
        return existing
    }
    let thinkingBlock = ThinkingContent(thinking: "")
    output.content.append(.thinking(thinkingBlock))
    let contentIndex = output.content.count - 1
    state.indexMap[blockIndex] = contentIndex
    stream.push(.thinkingStart(contentIndex: contentIndex, partial: output))
    return contentIndex
}

private func decodeEvent<T: Decodable, W: Decodable>(
    direct: T.Type,
    wrapper: W.Type,
    payload: Data,
    decoder: JSONDecoder
) -> T? {
    if payload.isEmpty {
        return nil
    }
    if let event = try? decoder.decode(T.self, from: payload) {
        return event
    }
    if let wrapperValue = try? decoder.decode(W.self, from: payload) {
        if let value = wrapperValue as? BedrockMessageStartWrapper {
            return value.messageStart as? T
        }
        if let value = wrapperValue as? BedrockContentBlockStartWrapper {
            return value.contentBlockStart as? T
        }
        if let value = wrapperValue as? BedrockContentBlockDeltaWrapper {
            return value.contentBlockDelta as? T
        }
        if let value = wrapperValue as? BedrockContentBlockStopWrapper {
            return value.contentBlockStop as? T
        }
        if let value = wrapperValue as? BedrockMessageStopWrapper {
            return value.messageStop as? T
        }
        if let value = wrapperValue as? BedrockMetadataWrapper {
            return value.metadata as? T
        }
    }
    return nil
}

private func mapBedrockStopReason(_ reason: String?) -> StopReason {
    switch reason {
    case "end_turn", "stop_sequence":
        return .stop
    case "max_tokens", "model_context_window_exceeded":
        return .length
    case "tool_use":
        return .toolUse
    default:
        return .error
    }
}

private func buildBedrockRequest(
    model: Model,
    context: Context,
    options: BedrockOptions,
    region: String
) throws -> (URLRequest, Data) {
    let baseUrlString = resolveBedrockBaseUrl(model: model, options: options, region: region)

    guard let baseUrl = URL(string: baseUrlString) else {
        throw BedrockStreamError.invalidUrl
    }

    let path = "/model/\(model.id)/converse-stream"
    let encodedPath = awsPercentEncodePath(path)
    guard var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) else {
        throw BedrockStreamError.invalidUrl
    }
    components.percentEncodedPath = encodedPath
    guard let url = components.url else {
        throw BedrockStreamError.invalidUrl
    }

    let cacheRetention = resolveBedrockCacheRetention(options.cacheRetention)
    let messages = convertMessages(context: context, model: model, cacheRetention: cacheRetention)
    let system = buildSystemPrompt(context.systemPrompt, model: model, cacheRetention: cacheRetention)
    let inferenceMaxTokens = options.maxTokens ?? (isAnthropicClaudeModel(model) ? model.maxTokens : nil)
    let inferenceConfig = BedrockInferenceConfig(maxTokens: inferenceMaxTokens, temperature: options.temperature)
    let toolConfig = convertToolConfig(context.tools, toolChoice: options.toolChoice)
    let additional = buildAdditionalModelRequestFields(model: model, options: options)
    let requestBody = BedrockRequest(
        messages: messages,
        system: system,
        inferenceConfig: inferenceConfig,
        toolConfig: toolConfig,
        additionalModelRequestFields: additional,
        requestMetadata: options.requestMetadata
    )

    let encoder = JSONEncoder()
    let body = try encoder.encode(requestBody)
    emitPayload(options.onPayload, payload: requestBody)

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
    request.setValue(url.host ?? "", forHTTPHeaderField: "Host")
    var customHeaders = model.headers ?? [:]
    if let optionHeaders = options.headers {
        customHeaders.merge(optionHeaders) { _, new in new }
    }
    for (key, value) in customHeaders where !isReservedBedrockHeader(key) {
        request.setValue(value, forHTTPHeaderField: key)
    }
    return (request, body)
}

private func buildSystemPrompt(_ systemPrompt: String?, model: Model, cacheRetention: CacheRetention) -> [BedrockSystemBlock]? {
    guard let systemPrompt, !systemPrompt.isEmpty else { return nil }
    var blocks = [BedrockSystemBlock(payload: AnyCodable(["text": sanitizeSurrogates(systemPrompt)]))]
    if cacheRetention != .none, supportsPromptCaching(model: model) {
        blocks.append(BedrockSystemBlock(payload: AnyCodable(["cachePoint": cachePointPayload(cacheRetention: cacheRetention)])))
    }
    return blocks
}

/// v0.70.3: when the Bedrock `model.id` is an inference-profile ARN (no "claude" in the ARN),
/// fall back to `model.name` for capability detection so prompt-caching and adaptive-thinking
/// checks still match the underlying Claude model.
private func bedrockCapabilityIdentifier(_ model: Model) -> String {
    let id = model.id.lowercased()
    if id.hasPrefix("arn:") || id.contains("inference-profile") {
        return model.name.lowercased()
    }
    return id
}

private func supportsPromptCaching(model: Model) -> Bool {
    // Force cache for all models via env var (useful for application inference profiles
    // that don't have "claude" in the ARN)
    if ProcessInfo.processInfo.environment["AWS_BEDROCK_FORCE_CACHE"] == "1" {
        return true
    }
    if model.cost.cacheRead > 0 || model.cost.cacheWrite > 0 {
        return true
    }
    let id = bedrockCapabilityIdentifier(model)
    if id.contains("claude") && (id.contains("-4-") || id.contains("-4.")) {
        return true
    }
    if id.contains("claude-3-7-sonnet") {
        return true
    }
    if id.contains("claude-3-5-haiku") {
        return true
    }
    return false
}

private func supportsThinkingSignature(model: Model) -> Bool {
    let id = bedrockCapabilityIdentifier(model)
    return id.contains("anthropic.claude") || id.contains("anthropic/claude") || id.contains("claude")
}

private func bedrockModelMatchCandidates(_ model: Model) -> [String] {
    [model.id, model.name].flatMap { value -> [String] in
        let lower = value.lowercased()
        let normalized = lower.replacingOccurrences(of: #"[\s_.:]+"#, with: "-", options: .regularExpression)
        return [lower, normalized]
    }
}

private func supportsAdaptiveThinking(model: Model) -> Bool {
    bedrockModelMatchCandidates(model).contains { candidate in
        candidate.contains("opus-4-6") ||
        candidate.contains("opus-4.6") ||
        candidate.contains("opus-4-7") ||
        candidate.contains("opus-4.7") ||
        candidate.contains("opus-4-8") ||
        candidate.contains("opus-4.8") ||
        candidate.contains("sonnet-4-6") ||
        candidate.contains("sonnet-4.6") ||
        candidate.contains("fable-5")
    }
}

private func supportsNativeXhighEffort(model: Model) -> Bool {
    bedrockModelMatchCandidates(model).contains { candidate in
        candidate.contains("opus-4-7") ||
        candidate.contains("opus-4.7") ||
        candidate.contains("opus-4-8") ||
        candidate.contains("opus-4.8") ||
        candidate.contains("fable-5")
    }
}

private func mapThinkingLevelToEffort(model: Model, level: ThinkingLevel) -> String {
    if level == .xhigh, supportsNativeXhighEffort(model: model) {
        return "xhigh"
    }
    if let mapped = model.thinkingLevelMap?[ModelThinkingLevel(level)], let mapped {
        return mapped
    }
    switch level {
    case .minimal, .low:
        return "low"
    case .medium:
        return "medium"
    case .high:
        return "high"
    case .xhigh, .max:
        return "high"
    }
}

private func resolveBedrockCacheRetention(_ cacheRetention: CacheRetention?) -> CacheRetention {
    if let cacheRetention {
        return cacheRetention
    }
    let flag = getenv("PI_CACHE_RETENTION").map { String(cString: $0) }?.lowercased()
    if flag == "long" {
        return .long
    }
    return .short
}

private func cachePointPayload(cacheRetention: CacheRetention) -> [String: Any] {
    var payload: [String: Any] = ["type": "default"]
    if cacheRetention == .long {
        payload["ttl"] = "one_hour"
    }
    return payload
}

private func convertMessages(context: Context, model: Model, cacheRetention: CacheRetention) -> [BedrockMessage] {
    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, _, _ in
        let sanitized = id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return sanitized.count > 64 ? String(sanitized.prefix(64)) : sanitized
    }
    let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: normalizeToolCallId)
    var result: [BedrockMessage] = []
    var index = 0

    while index < transformed.count {
        let message = transformed[index]
        switch message {
        case .user(let user):
            let contentBlocks = convertUserContent(user.content)
            result.append(BedrockMessage(role: "user", content: contentBlocks))
        case .assistant(let assistant):
            let blocks = convertAssistantContent(assistant.content, model: model)
            if !blocks.isEmpty {
                result.append(BedrockMessage(role: "assistant", content: blocks))
            }
        case .toolResult:
            var toolResults: [BedrockContentBlock] = []
            if case .toolResult(let tool) = message {
                toolResults.append(makeToolResultBlock(tool))
            }

            var nextIndex = index + 1
            while nextIndex < transformed.count {
                if case .toolResult(let nextTool) = transformed[nextIndex] {
                    toolResults.append(makeToolResultBlock(nextTool))
                    nextIndex += 1
                } else {
                    break
                }
            }

            result.append(BedrockMessage(role: "user", content: toolResults))
            index = nextIndex - 1
        }

        index += 1
    }

    if cacheRetention != .none, supportsPromptCaching(model: model),
       let lastIndex = result.indices.last,
       result[lastIndex].role == "user" {
        var last = result[lastIndex]
        last.content.append(BedrockContentBlock(payload: AnyCodable(["cachePoint": cachePointPayload(cacheRetention: cacheRetention)])))
        result[lastIndex] = last
    }

    return result
}

private func convertUserContent(_ content: UserContent) -> [BedrockContentBlock] {
    switch content {
    case .text(let text):
        return [BedrockContentBlock(payload: AnyCodable(["text": sanitizeSurrogates(text)]))]
    case .blocks(let blocks):
        return blocks.compactMap { block in
            switch block {
            case .text(let text):
                return BedrockContentBlock(payload: AnyCodable(["text": sanitizeSurrogates(text.text)]))
            case .image(let image):
                return BedrockContentBlock(payload: AnyCodable(["image": createImageBlock(image)]))
            default:
                return nil
            }
        }
    }
}

private func convertAssistantContent(_ blocks: [ContentBlock], model: Model) -> [BedrockContentBlock] {
    var converted: [BedrockContentBlock] = []
    for block in blocks {
        switch block {
        case .text(let text):
            let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            converted.append(BedrockContentBlock(payload: AnyCodable(["text": sanitizeSurrogates(text.text)])))
        case .toolCall(let toolCall):
            let input = toolCall.arguments.mapValues { $0.value }
            let payload: [String: Any] = [
                "toolUse": [
                    "toolUseId": toolCall.id,
                    "name": toolCall.name,
                    "input": input,
                ],
            ]
            converted.append(BedrockContentBlock(payload: AnyCodable(payload)))
        case .thinking(let thinking):
            let trimmed = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // If thinking signature is missing/empty, fall back to plain text block
            // to prevent API rejection on replayed messages.
            if supportsThinkingSignature(model: model),
               let signature = thinking.thinkingSignature,
               !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let reasoningText: [String: Any] = ["text": sanitizeSurrogates(thinking.thinking), "signature": signature]
                let payload: [String: Any] = [
                    "reasoningContent": [
                        "reasoningText": reasoningText,
                    ],
                ]
                converted.append(BedrockContentBlock(payload: AnyCodable(payload)))
            } else {
                // Fallback: emit as plain text when no valid signature
                let textPayload: [String: Any] = ["text": sanitizeSurrogates(thinking.thinking)]
                converted.append(BedrockContentBlock(payload: AnyCodable(textPayload)))
            }
        default:
            break
        }
    }
    return converted
}

private func makeToolResultBlock(_ tool: ToolResultMessage) -> BedrockContentBlock {
    let content: [[String: Any]] = tool.content.compactMap { block in
        switch block {
        case .image(let image):
            return ["image": createImageBlock(image)]
        case .text(let text):
            return ["text": sanitizeSurrogates(text.text)]
        default:
            return nil
        }
    }
    let payload: [String: Any] = [
        "toolResult": [
            "toolUseId": tool.toolCallId,
            "content": content,
            "status": tool.isError ? "error" : "success",
        ],
    ]
    return BedrockContentBlock(payload: AnyCodable(payload))
}

private func createImageBlock(_ image: ImageContent) -> [String: Any] {
    let format: String
    switch image.mimeType {
    case "image/jpeg", "image/jpg":
        format = "jpeg"
    case "image/png":
        format = "png"
    case "image/gif":
        format = "gif"
    case "image/webp":
        format = "webp"
    default:
        format = "png"
    }
    return [
        "format": format,
        "source": ["bytes": image.data],
    ]
}

private func convertToolConfig(
    _ tools: [AITool]?,
    toolChoice: BedrockToolChoice?
) -> BedrockToolConfig? {
    guard let tools, !tools.isEmpty else { return nil }

    let bedrockTools = tools.map {
        BedrockTool(name: $0.name, description: $0.description, parameters: $0.parameters)
    }

    let choicePayload: BedrockToolChoicePayload?
    switch toolChoice {
    case .some(.auto):
        choicePayload = BedrockToolChoicePayload(payload: AnyCodable(["auto": [String: Any]()]))
    case .some(.any):
        choicePayload = BedrockToolChoicePayload(payload: AnyCodable(["any": [String: Any]()]))
    case .some(.tool(let name)):
        choicePayload = BedrockToolChoicePayload(payload: AnyCodable(["tool": ["name": name]]))
    case .some(.none), nil:
        choicePayload = nil
    }

    if case .some(.none) = toolChoice {
        return nil
    }

    return BedrockToolConfig(tools: bedrockTools, toolChoice: choicePayload)
}

func buildAdditionalModelRequestFields(model: Model, options: BedrockOptions) -> [String: AnyCodable]? {
    guard let reasoning = options.reasoning, model.reasoning else { return nil }
    // v0.70.3: use capability identifier so inference-profile ARNs still detect Claude.
    let capabilityId = bedrockCapabilityIdentifier(model)
    guard isAnthropicClaudeModel(model) || capabilityId.contains("claude") else { return nil }

    var result: [String: Any] = [:]
    let display = isGovCloudBedrockTarget(model: model, options: options) ? nil : (options.thinkingDisplay ?? .summarized).rawValue

    if supportsAdaptiveThinking(model: model) {
        var thinking: [String: Any] = ["type": "adaptive"]
        if let display {
            thinking["display"] = display
        }
        result["thinking"] = thinking
        result["output_config"] = ["effort": mapThinkingLevelToEffort(model: model, level: reasoning)]
    } else {
        let defaultBudgets: [ThinkingLevel: Int] = [
            .minimal: 1024,
            .low: 2048,
            .medium: 8192,
            .high: 16384,
            .xhigh: 16384,
            .max: 16384,
        ]

        let level = (reasoning == .xhigh || reasoning == .max) ? .high : reasoning
        let budget = options.thinkingBudgets?[level] ?? defaultBudgets[level] ?? 1024
        var thinking: [String: Any] = [
            "type": "enabled",
            "budget_tokens": budget,
        ]
        if let display {
            thinking["display"] = display
        }
        result["thinking"] = thinking

        if options.interleavedThinking ?? true {
            result["anthropic_beta"] = ["interleaved-thinking-2025-05-14"]
        }
    }

    return result.mapValues { AnyCodable($0) }
}

private func isAnthropicClaudeModel(_ model: Model) -> Bool {
    let id = model.id.lowercased()
    let name = model.name.lowercased()
    return id.contains("anthropic.claude") ||
        id.contains("anthropic/claude") ||
        id.contains("claude") ||
        name.contains("anthropic.claude") ||
        name.contains("anthropic/claude") ||
        name.contains("claude")
}

private func configuredBedrockRegion(options: BedrockOptions) -> String? {
    let env = ProcessInfo.processInfo.environment
    if let region = options.region {
        return region
    }
    if let region = env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] {
        return region
    }
    return nil
}

private func hasConfiguredBedrockProfile(options: BedrockOptions) -> Bool {
    let env = ProcessInfo.processInfo.environment
    if let profile = options.profile, !profile.isEmpty {
        return true
    }
    if let profile = env["AWS_PROFILE"] ?? env["AWS_DEFAULT_PROFILE"], !profile.isEmpty {
        return true
    }
    return false
}

private func standardBedrockEndpointRegion(baseUrl: String) -> String? {
    guard let host = URL(string: baseUrl)?.host?.lowercased() else { return nil }
    let pattern = #"^bedrock-runtime(?:-fips)?\.([a-z0-9-]+)\.amazonaws\.com(?:\.cn)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)),
          let range = Range(match.range(at: 1), in: host) else {
        return nil
    }
    return String(host[range])
}

private func shouldUseExplicitBedrockEndpoint(baseUrl: String, configuredRegion: String?, hasConfiguredProfile: Bool) -> Bool {
    guard standardBedrockEndpointRegion(baseUrl: baseUrl) != nil else {
        return true
    }
    return configuredRegion == nil && !hasConfiguredProfile
}

private func bedrockArnRegion(modelId: String) -> String? {
    let pattern = #"^arn:aws(?:-[a-z0-9-]+)?:bedrock:([a-z0-9-]+):"#
    let id = modelId.lowercased()
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
          let range = Range(match.range(at: 1), in: id) else {
        return nil
    }
    return String(id[range])
}

private func resolveBedrockRegion(model: Model, options: BedrockOptions) -> String {
    if let arnRegion = bedrockArnRegion(modelId: model.id) {
        return arnRegion
    }
    if let configured = configuredBedrockRegion(options: options) {
        return configured
    }
    let hasProfile = hasConfiguredBedrockProfile(options: options)
    if let endpointRegion = standardBedrockEndpointRegion(baseUrl: model.baseUrl),
       shouldUseExplicitBedrockEndpoint(baseUrl: model.baseUrl, configuredRegion: nil, hasConfiguredProfile: hasProfile) {
        return endpointRegion
    }
    let env = ProcessInfo.processInfo.environment
    if let profile = options.profile ?? env["AWS_PROFILE"] ?? env["AWS_DEFAULT_PROFILE"],
       let region = loadAwsProfileRegion(profile: profile) {
        return region
    }
    return "us-east-1"
}

private func resolveBedrockBaseUrl(model: Model, options: BedrockOptions, region: String) -> String {
    let trimmed = model.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "https://bedrock-runtime.\(region).amazonaws.com"
    }
    if bedrockArnRegion(modelId: model.id) != nil, standardBedrockEndpointRegion(baseUrl: trimmed) != nil {
        return "https://bedrock-runtime.\(region).amazonaws.com"
    }
    let configuredRegion = configuredBedrockRegion(options: options)
    let hasProfile = hasConfiguredBedrockProfile(options: options)
    if shouldUseExplicitBedrockEndpoint(baseUrl: trimmed, configuredRegion: configuredRegion, hasConfiguredProfile: hasProfile) {
        return trimmed
    }
    return "https://bedrock-runtime.\(region).amazonaws.com"
}

private func isGovCloudBedrockTarget(model: Model, options: BedrockOptions) -> Bool {
    if let region = configuredBedrockRegion(options: options)?.lowercased(), region.hasPrefix("us-gov-") {
        return true
    }
    if let endpointRegion = standardBedrockEndpointRegion(baseUrl: model.baseUrl), endpointRegion.hasPrefix("us-gov-") {
        return true
    }
    let id = model.id.lowercased()
    return id.hasPrefix("us-gov.") || id.hasPrefix("arn:aws-us-gov:")
}

private func isReservedBedrockHeader(_ key: String) -> Bool {
    let lower = key.lowercased()
    return lower == "authorization" || lower == "host" || lower.hasPrefix("x-amz-")
}

private func resolveBedrockAuth(options: BedrockOptions) throws -> BedrockAuth {
    let env = ProcessInfo.processInfo.environment
    if env["AWS_BEDROCK_SKIP_AUTH"] != "1",
       let bearer = options.bearerToken ?? env["AWS_BEARER_TOKEN_BEDROCK"],
       !bearer.isEmpty {
        return .bearer(bearer)
    }
    if env["AWS_BEDROCK_SKIP_AUTH"] == "1" {
        return .sigV4(AwsCredentials(accessKeyId: "dummy-access-key", secretAccessKey: "dummy-secret-key", sessionToken: nil))
    }

    if let access = env["AWS_ACCESS_KEY_ID"],
       let secret = env["AWS_SECRET_ACCESS_KEY"],
       !access.isEmpty,
       !secret.isEmpty {
        let token = env["AWS_SESSION_TOKEN"]
        return .sigV4(AwsCredentials(accessKeyId: access, secretAccessKey: secret, sessionToken: token))
    }

    let selectedProfile = options.profile ?? env["AWS_PROFILE"] ?? env["AWS_DEFAULT_PROFILE"] ?? "default"
    if let credentials = loadAwsProfileCredentials(profile: selectedProfile) {
        return .sigV4(credentials)
    }

    throw BedrockStreamError.missingCredentials
}

private func formatBedrockHTTPError(statusCode: Int, body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = trimmed.isEmpty ? "HTTP \(statusCode)" : trimmed
    if statusCode == 429 {
        return "Throttling error: \(message)"
    }
    if statusCode == 503 {
        return "Service unavailable: \(message)"
    }
    return message
}

private func loadAwsProfileCredentials(profile: String) -> AwsCredentials? {
    let env = ProcessInfo.processInfo.environment
    let credentialsPath = env["AWS_SHARED_CREDENTIALS_FILE"] ?? "~/.aws/credentials"
    guard let sections = parseIniFile(path: credentialsPath),
          let values = sections[profile] else {
        return nil
    }
    guard let accessKey = values["aws_access_key_id"],
          let secretKey = values["aws_secret_access_key"] else {
        return nil
    }
    let token = values["aws_session_token"]
    return AwsCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: token)
}

func loadAwsProfileRegion(profile: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    let configPath = env["AWS_CONFIG_FILE"] ?? "~/.aws/config"
    guard let sections = parseIniFile(path: configPath) else {
        return nil
    }

    let profileKey: String
    if profile == "default" {
        profileKey = "default"
    } else {
        profileKey = "profile \(profile)"
    }

    return sections[profileKey]?["region"]
}

func parseIniFile(path: String) -> [String: [String: String]]? {
    let resolvedPath = (path as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: resolvedPath),
          let content = String(data: data, encoding: .utf8) else {
        return nil
    }

    var sections: [String: [String: String]] = [:]
    var currentSection: String?

    for rawLine in content.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
            continue
        }

        if line.hasPrefix("[") && line.hasSuffix("]") {
            let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            currentSection = name
            if sections[name] == nil {
                sections[name] = [:]
            }
            continue
        }

        guard let section = currentSection,
              let separatorIndex = line.firstIndex(of: "=") else {
            continue
        }

        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            sections[section, default: [:]][String(key)] = String(value)
        }
    }

    return sections
}

private func signBedrockRequest(
    request: URLRequest,
    body: Data,
    region: String,
    auth: BedrockAuth
) throws -> URLRequest {
    var signedRequest = request
    let payloadHash = sha256Hex(body)
    signedRequest.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

    if case .bearer(let token) = auth {
        signedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return signedRequest
    }

    guard case .sigV4(let credentials) = auth else {
        return signedRequest
    }

    let timestamp = awsTimestamp(Date())
    signedRequest.setValue(timestamp.amzDate, forHTTPHeaderField: "x-amz-date")
    if let sessionToken = credentials.sessionToken {
        signedRequest.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
    }

    let host = signedRequest.value(forHTTPHeaderField: "Host") ?? signedRequest.url?.host ?? ""
    signedRequest.setValue(host, forHTTPHeaderField: "Host")

    let signedHeaders = canonicalSignedHeaders(for: signedRequest)
    let canonicalRequest = buildCanonicalRequest(
        request: signedRequest,
        payloadHash: payloadHash,
        signedHeaders: signedHeaders.headerNames
    )

    let scope = "\(timestamp.dateStamp)/\(region)/bedrock/aws4_request"
    let stringToSign = [
        "AWS4-HMAC-SHA256",
        timestamp.amzDate,
        scope,
        sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")

    let signingKey = deriveSigningKey(
        secretKey: credentials.secretAccessKey,
        dateStamp: timestamp.dateStamp,
        region: region,
        service: "bedrock"
    )
    let signature = hmacHex(key: signingKey, message: stringToSign)

    let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders.headerNames), Signature=\(signature)"
    signedRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
    return signedRequest
}

private func canonicalSignedHeaders(for request: URLRequest) -> (headerNames: String, headerLines: String) {
    var headers: [(String, String)] = []
    for (key, value) in request.allHTTPHeaderFields ?? [:] {
        let lowerKey = key.lowercased()
        let normalizedValue = normalizeHeaderValue(value)
        headers.append((lowerKey, normalizedValue))
    }
    headers.sort { $0.0 < $1.0 }
    let headerLines = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"
    let headerNames = headers.map { $0.0 }.joined(separator: ";")
    return (headerNames, headerLines)
}

private func buildCanonicalRequest(
    request: URLRequest,
    payloadHash: String,
    signedHeaders: String
) -> String {
    let method = request.httpMethod ?? "POST"
    let canonicalUri = awsPercentEncodePath(request.url?.path ?? "/")
    let canonicalQuery = canonicalQueryString(request.url)
    let signedHeaderInfo = canonicalSignedHeaders(for: request)
    return [
        method,
        canonicalUri,
        canonicalQuery,
        signedHeaderInfo.headerLines,
        signedHeaders,
        payloadHash,
    ].joined(separator: "\n")
}

private func canonicalQueryString(_ url: URL?) -> String {
    guard let url,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let items = components.queryItems, !items.isEmpty else {
        return ""
    }
    components.queryItems = items.sorted { $0.name < $1.name }
    return components.percentEncodedQuery ?? ""
}

private func normalizeHeaderValue(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func awsTimestamp(_ date: Date) -> (amzDate: String, dateStamp: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let amzDate = formatter.string(from: date)
    let dateStamp = String(amzDate.prefix(8))
    return (amzDate, dateStamp)
}

private func sha256Hex(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) -> Data {
    let key = Data(("AWS4" + secretKey).utf8)
    let dateKey = hmac(key: key, message: dateStamp)
    let regionKey = hmac(key: dateKey, message: region)
    let serviceKey = hmac(key: regionKey, message: service)
    return hmac(key: serviceKey, message: "aws4_request")
}

private func hmacHex(key: Data, message: String) -> String {
    let signature = hmac(key: key, message: message)
    return signature.map { String(format: "%02x", $0) }.joined()
}

private func hmac(key: Data, message: String) -> Data {
    let symmetricKey = SymmetricKey(data: key)
    let data = Data(message.utf8)
    let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
    return Data(signature)
}

private func awsPercentEncodePath(_ path: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    let encoded = parts.map { segment in
        let value = String(segment)
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    var result = encoded.joined(separator: "/")
    if path.hasPrefix("/") && !result.hasPrefix("/") {
        result = "/" + result
    }
    return result
}

private func parseHeaders(_ data: Data) -> [String: String] {
    var headers: [String: String] = [:]
    var index = 0

    while index < data.count {
        guard index < data.count else { break }
        let nameLength = Int(data[index])
        index += 1
        guard index + nameLength <= data.count else { break }
        let nameData = data.subdata(in: index..<index + nameLength)
        let name = String(data: nameData, encoding: .utf8) ?? ""
        index += nameLength
        guard index < data.count else { break }
        let type = data[index]
        index += 1

        switch type {
        case 0, 1:
            break
        case 2:
            index += 1
        case 3:
            index += 2
        case 4:
            index += 4
        case 5:
            index += 8
        case 6:
            guard index + 2 <= data.count else { break }
            let length = Int(readUInt16(data, at: index))
            index += 2 + length
        case 7:
            guard index + 2 <= data.count else { break }
            let length = Int(readUInt16(data, at: index))
            index += 2
            guard index + length <= data.count else { break }
            let valueData = data.subdata(in: index..<index + length)
            index += length
            let value = String(data: valueData, encoding: .utf8) ?? ""
            headers[name] = value
        case 8:
            index += 8
        case 9:
            index += 16
        default:
            index = data.count
        }
    }

    return headers
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    let slice = data.subdata(in: offset..<offset + 4)
    return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    let slice = data.subdata(in: offset..<offset + 2)
    return slice.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
}

private func errorMessage(for error: Error) -> String {
    switch error {
    case BedrockStreamError.missingCredentials:
        return "Missing AWS credentials for Amazon Bedrock"
    case BedrockStreamError.aborted:
        return "Request was aborted"
    case BedrockStreamError.invalidResponse:
        return "Invalid response from Amazon Bedrock"
    case BedrockStreamError.invalidUrl:
        return "Invalid Amazon Bedrock URL"
    case BedrockStreamError.serverError(let message):
        return message
    default:
        return retryAwareErrorDescription(error)
    }
}
