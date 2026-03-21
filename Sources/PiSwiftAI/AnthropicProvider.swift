import Foundation
import SwiftAnthropic

private let claudeCodeVersion = "2.1.75"

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

public func streamAnthropic(
    model: Model,
    context: Context,
    options: AnthropicOptions
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
        var debugService: AnthropicService?
        var debugParameters: MessageParameter?

        do {
            let apiKey = options.apiKey ?? ""
            if apiKey.isEmpty {
                throw StreamError.missingApiKey(model.provider)
            }
            let isOAuthToken = isAnthropicOAuthToken(apiKey)

            let betaHeaders = buildAnthropicBetaHeaders(
                apiKey: apiKey,
                interleavedThinking: options.interleavedThinking ?? true,
                provider: model.provider,
                modelId: model.id
            )
            if let betaHeaders {
                logAnthropicDebug("anthropic betaHeaders=\(betaHeaders.joined(separator: ","))")
            } else {
                logAnthropicDebug("anthropic betaHeaders=none")
            }
            let mergedHeaders = mergeHeaders(model.headers, options.headers)
            let httpClient = buildAnthropicHttpClient(
                isOAuthToken: isOAuthToken,
                extraHeaders: mergedHeaders,
                baseUrl: model.baseUrl,
                metadataUserId: extractAnthropicMetadataUserId(options.metadata)
            )
            let service = AnthropicServiceFactory.service(
                apiKey: apiKey,
                basePath: model.baseUrl,
                betaHeaders: betaHeaders,
                httpClient: httpClient,
                debugEnabled: false
            )

            let parameters = buildAnthropicParameters(model: model, context: context, options: options, isOAuthToken: isOAuthToken)
            emitPayload(options.onPayload, payload: parameters)
            debugService = service
            debugParameters = parameters
            let toolCount = context.tools?.count ?? 0
            logAnthropicDebug("anthropic request model=\(model.id) maxTokens=\(parameters.maxTokens) messages=\(parameters.messages.count) system=\(parameters.system != nil) tools=\(toolCount) thinking=\(parameters.thinking != nil)")
            let anthropicStream = try await service.streamMessage(parameters)

            stream.push(.start(partial: output))

            var indexMap: [Int: Int] = [:]
            var toolCallPartials: [Int: String] = [:]

            for try await event in anthropicStream {
                if options.signal?.isCancelled == true {
                    throw AnthropicStreamError.aborted
                }

                switch event.streamEvent {
                case .messageStart:
                    if let messageId = event.message?.id {
                        output.responseId = messageId
                    }
                    if let usage = event.message?.usage {
                        let input = usage.inputTokens ?? 0
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? 0
                        let cacheWrite = usage.cacheCreationInputTokens ?? 0
                        output.usage = Usage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            totalTokens: input + outputTokens + cacheRead + cacheWrite
                        )
                        calculateCost(model: model, usage: &output.usage)
                    }
                case .contentBlockStart:
                    guard let block = event.contentBlock, let index = event.index else { break }
                    switch block.type {
                    case "text":
                        let textBlock = TextContent(text: "")
                        output.content.append(.text(textBlock))
                        indexMap[index] = output.content.count - 1
                        stream.push(.textStart(contentIndex: output.content.count - 1, partial: output))
                    case "thinking":
                        let thinkingBlock = ThinkingContent(thinking: "")
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
                    if let stopReason = event.delta?.stopReason {
                        output.stopReason = mapAnthropicStopReason(stopReason)
                    }
                    if let usage = event.usage {
                        let input = usage.inputTokens ?? output.usage.input
                        let outputTokens = usage.outputTokens
                        let cacheRead = usage.cacheReadInputTokens ?? output.usage.cacheRead
                        let cacheWrite = usage.cacheCreationInputTokens ?? output.usage.cacheWrite
                        output.usage = Usage(
                            input: input,
                            output: outputTokens,
                            cacheRead: cacheRead,
                            cacheWrite: cacheWrite,
                            totalTokens: input + outputTokens + cacheRead + cacheWrite
                        )
                        calculateCost(model: model, usage: &output.usage)
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

            if output.stopReason == .aborted || output.stopReason == .error {
                throw AnthropicStreamError.unknown
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
            output.errorMessage = error.localizedDescription
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

private func buildAnthropicParameters(model: Model, context: Context, options: AnthropicOptions, isOAuthToken: Bool) -> MessageParameter {
    let messages = convertAnthropicMessages(model: model, messages: context.messages, isOAuthToken: isOAuthToken)
    let maxTokens = options.maxTokens ?? max(model.maxTokens / 3, 1024)

    var system: MessageParameter.System? = nil
    if let prompt = context.systemPrompt {
        system = .text(sanitizeSurrogates(prompt))
    }

    let tools = context.tools.map { convertAnthropicTools($0, isOAuthToken: isOAuthToken) }

    let thinkingEnabled = options.thinkingEnabled == true && model.reasoning
    let thinking = thinkingEnabled
        ? MessageParameter.Thinking(budgetTokens: options.thinkingBudgetTokens ?? 1024)
        : nil

    // Do NOT send temperature when thinking is enabled (incompatible with both
    // adaptive and budget-based thinking).
    let temperature = thinkingEnabled ? nil : options.temperature

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

private func mapAnthropicModel(_ id: String) -> SwiftAnthropic.Model {
    switch id {
    case "claude-3-5-haiku-latest":
        return .claude35Haiku
    default:
        return .other(id)
    }
}

/// Check if a model supports adaptive thinking (Opus 4.6 and Sonnet 4.6).
/// These models have interleaved thinking built-in and don't need the beta header.
private func supportsAdaptiveThinking(_ modelId: String) -> Bool {
    modelId.contains("opus-4-6") || modelId.contains("opus-4.6") ||
    modelId.contains("sonnet-4-6") || modelId.contains("sonnet-4.6")
}

func buildAnthropicBetaHeaders(apiKey: String, interleavedThinking: Bool, provider: String, modelId: String = "") -> [String]? {
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
        headers.append("fine-grained-tool-streaming-2025-05-14")
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

func anthropicCacheTtl(baseUrl: String) -> String? {
    let flag = getenv("PI_CACHE_RETENTION").map { String(cString: $0) }?.lowercased()
    guard flag == "long" else { return nil }
    guard baseUrl.contains("api.anthropic.com") else { return nil }
    return "1h"
}

private func buildAnthropicHttpClient(
    isOAuthToken: Bool,
    extraHeaders: [String: String],
    baseUrl: String,
    metadataUserId: String?
) -> HTTPClient {
    var merged = extraHeaders
    if isOAuthToken {
        if merged["user-agent"] == nil {
            merged["user-agent"] = "claude-cli/\(claudeCodeVersion) (external, cli)"
        }
        if merged["x-app"] == nil {
            merged["x-app"] = "cli"
        }
    }
    let cacheTtl = anthropicCacheTtl(baseUrl: baseUrl)
    return AnthropicHeaderInjectingHTTPClient(
        base: HTTPClientFactory.createDefault(),
        extraHeaders: merged,
        cacheTtl: cacheTtl,
        metadataUserId: metadataUserId
    )
}

private func mergeHeaders(_ base: [String: String]?, _ extra: [String: String]?) -> [String: String] {
    var merged = base ?? [:]
    if let extra {
        for (key, value) in extra {
            merged[key] = value
        }
    }
    return merged
}

private struct AnthropicHeaderInjectingHTTPClient: HTTPClient {
    let base: HTTPClient
    let extraHeaders: [String: String]
    let cacheTtl: String?
    let metadataUserId: String?

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

        guard let url, let method, var headers else { return request }
        for (key, value) in extraHeaders where headers[key] == nil {
            headers[key] = value
        }
        let updatedBody = injectAnthropicRequestBody(body: body, ttl: cacheTtl, metadataUserId: metadataUserId)
        return HTTPRequest(url: url, method: method, headers: headers, body: updatedBody ?? body)
    }
}

private func extractAnthropicMetadataUserId(_ metadata: [String: AnyCodable]?) -> String? {
    guard let raw = metadata?["user_id"]?.value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func injectAnthropicRequestBody(body: Data?, ttl: String?, metadataUserId: String?) -> Data? {
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

    if let metadataUserId {
        payload["metadata"] = ["user_id": metadataUserId]
    }

    return try? JSONSerialization.data(withJSONObject: payload)
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

private func mapAnthropicStopReason(_ reason: String) -> StopReason {
    switch reason {
    case "end_turn":
        return .stop
    case "max_tokens":
        return .length
    case "tool_use":
        return .toolUse
    case "refusal":
        return .error
    case "pause_turn":
        return .stop
    case "stop_sequence":
        return .stop
    case "sensitive":
        return .error
    default:
        return .stop
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

private enum AnthropicStreamError: Error {
    case aborted
    case unknown
}
