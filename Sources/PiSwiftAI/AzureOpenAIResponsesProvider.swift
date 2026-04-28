import Foundation
import OpenAI

private let defaultAzureApiVersion = "v1"
private let azureToolCallProviders: Set<String> = ["openai", "openai-codex", "opencode", "azure-openai-responses"]

private func parseDeploymentNameMap(_ value: String?) -> [String: String] {
    guard let value, !value.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for entry in value.split(separator: ",") {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let modelId = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let deployment = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelId.isEmpty, !deployment.isEmpty else { continue }
        result[modelId] = deployment
    }
    return result
}

private func resolveDeploymentName(model: Model, options: AzureOpenAIResponsesOptions?) -> String {
    if let override = options?.azureDeploymentName, !override.isEmpty {
        return override
    }
    let envMap = parseDeploymentNameMap(ProcessInfo.processInfo.environment["AZURE_OPENAI_DEPLOYMENT_NAME_MAP"])
    if let mapped = envMap[model.id] {
        return mapped
    }
    return model.id
}

internal func normalizeAzureBaseUrl(_ baseUrl: String) throws -> String {
    var trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard var components = URLComponents(string: trimmed), let host = components.host else {
        throw AzureOpenAIResponsesError.invalidBaseUrl(baseUrl)
    }

    // v0.70.3: also recognize Azure Cognitive Services endpoints. Both `.openai.azure.com`
    // and `.cognitiveservices.azure.com` are Azure-hosted OpenAI deployments and need the
    // SDK base path normalized to `/openai/v1` so deployment routes (`/deployments/<model>/...`)
    // and `?api-version=v1` query strings hang off the right prefix.
    let isAzureHost = host.hasSuffix(".openai.azure.com") || host.hasSuffix(".cognitiveservices.azure.com")
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }

    if isAzureHost && (path.isEmpty || path == "/" || path == "/openai") {
        components.path = "/openai/v1"
        components.query = nil
    }

    var result = components.string ?? trimmed
    while result.hasSuffix("/") { result.removeLast() }
    return result
}

public enum AzureOpenAIResponsesError: Error, LocalizedError, Sendable {
    case invalidBaseUrl(String)
    public var errorDescription: String? {
        switch self {
        case .invalidBaseUrl(let url): return "Invalid Azure OpenAI base URL: \(url)"
        }
    }
}

private func buildDefaultAzureBaseUrl(resourceName: String) -> String {
    "https://\(resourceName).openai.azure.com/openai/v1"
}

private func resolveAzureConfig(model: Model, options: AzureOpenAIResponsesOptions?) throws -> (baseUrl: String, apiVersion: String) {
    let env = ProcessInfo.processInfo.environment
    let apiVersion = options?.azureApiVersion ?? env["AZURE_OPENAI_API_VERSION"] ?? defaultAzureApiVersion

    let baseUrlOption = options?.azureBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let envBaseUrl = env["AZURE_OPENAI_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resourceName = options?.azureResourceName ?? env["AZURE_OPENAI_RESOURCE_NAME"]

    var resolvedBaseUrl = baseUrlOption?.isEmpty == false ? baseUrlOption : envBaseUrl?.isEmpty == false ? envBaseUrl : nil
    if resolvedBaseUrl == nil, let resourceName, !resourceName.isEmpty {
        resolvedBaseUrl = buildDefaultAzureBaseUrl(resourceName: resourceName)
    }
    if resolvedBaseUrl == nil, !model.baseUrl.isEmpty {
        resolvedBaseUrl = model.baseUrl
    }

    guard let baseUrl = resolvedBaseUrl, !baseUrl.isEmpty else {
        throw AzureOpenAIResponsesConfigError.missingBaseUrl
    }

    return (try normalizeAzureBaseUrl(baseUrl), apiVersion)
}

private struct AzureOpenAIResponsesMiddleware: OpenAIMiddleware {
    let apiKey: String
    let apiVersion: String

    func intercept(request: URLRequest) -> URLRequest {
        var updated = request

        if let url = updated.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "api-version" }) {
                items.append(URLQueryItem(name: "api-version", value: apiVersion))
            }
            components.queryItems = items
            updated.url = components.url
        }

        var headers = updated.allHTTPHeaderFields ?? [:]
        for key in headers.keys where key.lowercased() == "authorization" {
            headers.removeValue(forKey: key)
        }
        headers["api-key"] = apiKey
        updated.allHTTPHeaderFields = headers
        return updated
    }
}

public func streamAzureOpenAIResponses(
    model: Model,
    context: Context,
    options: AzureOpenAIResponsesOptions
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
        var client: OpenAI? = nil
        var query: CreateModelResponseQuery? = nil

        do {
            guard let apiKey = options.apiKey, !apiKey.isEmpty else {
                throw StreamError.missingApiKey(model.provider)
            }

            let deploymentName = resolveDeploymentName(model: model, options: options)
            let azureConfig = try resolveAzureConfig(model: model, options: options)

            let cacheMiddleware = OpenAIResponsesCacheMiddleware(
                sessionId: options.sessionId,
                cacheRetention: .none,
                promptCacheRetention: nil,
                sendSessionIdHeader: model.compat?.sendSessionIdHeader ?? true
            )
            let azureMiddleware = AzureOpenAIResponsesMiddleware(
                apiKey: apiKey,
                apiVersion: azureConfig.apiVersion
            )

            var azureModel = model
            azureModel = Model(
                id: model.id,
                name: model.name,
                api: model.api,
                provider: model.provider,
                baseUrl: azureConfig.baseUrl,
                reasoning: model.reasoning,
                input: model.input,
                cost: model.cost,
                contextWindow: model.contextWindow,
                maxTokens: model.maxTokens,
                headers: model.headers,
                compat: model.compat
            )

            let builtClient = try makeOpenAIClient(
                model: azureModel,
                apiKey: apiKey,
                headers: options.headers,
                middlewares: [cacheMiddleware, azureMiddleware]
            )
            let builtQuery = try buildAzureResponsesQuery(model: model, context: context, options: options, deploymentName: deploymentName)
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
                    throw AzureOpenAIResponsesStreamError.aborted
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
                                text.textSignature = message.id
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
                            currentToolCallArgs = doneEvent.arguments
                            tool.arguments = parseStreamingJSON(currentToolCallArgs)
                            output.content[index] = .toolCall(tool)
                        }
                    }
                case .completed(let completed):
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
                    }
                    output.stopReason = mapResponsesStopReason(completed.response.status)
                    if output.content.contains(where: { if case .toolCall = $0 { return true } else { return false } }) && output.stopReason == .stop {
                        output.stopReason = .toolUse
                    }
                case .failed:
                    throw AzureOpenAIResponsesStreamError.unknown
                case .error(let errorEvent):
                    throw AzureOpenAIResponsesStreamError.apiError(errorEvent.message)
                default:
                    break
                }
            }

            finishCurrentBlock()

            if options.signal?.isCancelled == true {
                throw AzureOpenAIResponsesStreamError.aborted
            }

            if output.stopReason == .aborted || output.stopReason == .error {
                throw AzureOpenAIResponsesStreamError.unknown
            }

            stream.push(.done(reason: output.stopReason, message: output))
            stream.end()
        } catch {
            _ = client
            _ = query
            output.stopReason = options.signal?.isCancelled == true ? .aborted : .error
            output.errorMessage = describeOpenAIError(error)
            stream.push(.error(reason: output.stopReason, error: output))
            stream.end()
        }
    }

    return stream
}

public func streamSimpleAzureOpenAIResponses(
    model: Model,
    context: Context,
    options: SimpleStreamOptions?
) -> AssistantMessageEventStream {
    let apiKey = options?.apiKey ?? getEnvApiKey(provider: model.provider)
    guard let apiKey else {
        fatalError("No API key for provider: \(model.provider)")
    }

    let maxTokens = options?.maxTokens ?? min(model.maxTokens, 32000)
    let reasoningEffort = supportsXhigh(model: model) ? options?.reasoning : clampAzureThinkingLevel(options?.reasoning)

    let providerOptions = AzureOpenAIResponsesOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        reasoningEffort: reasoningEffort,
        reasoningSummary: nil,
        sessionId: options?.sessionId,
        headers: options?.headers
    )
    return streamAzureOpenAIResponses(model: model, context: context, options: providerOptions)
}

private func buildAzureResponsesQuery(
    model: Model,
    context: Context,
    options: AzureOpenAIResponsesOptions,
    deploymentName: String
) throws -> CreateModelResponseQuery {
    var inputItems = convertResponsesMessages(model: model, context: context, allowedToolCallProviders: azureToolCallProviders)

    var reasoning: Components.Schemas.Reasoning? = nil
    var include: [Components.Schemas.Includable]? = nil
    if model.reasoning {
        if options.reasoningEffort != nil || options.reasoningSummary != nil {
            reasoning = Components.Schemas.Reasoning(
                effort: mapResponsesReasoningEffort(options.reasoningEffort),
                summary: mapReasoningSummary(options.reasoningSummary)
            )
            include = [.reasoning_encryptedContent]
        } else if model.name.lowercased().hasPrefix("gpt-5") {
            let note = EasyInputMessage(role: .developer, content: .textInput(sanitizeSurrogates("# Juice: 0 !important")))
            inputItems.append(.inputMessage(note))
        }
    }

    let tools = context.tools.map(convertResponsesTools)

    return CreateModelResponseQuery(
        input: .inputItemList(inputItems),
        model: deploymentName,
        include: include,
        instructions: nil,
        maxOutputTokens: options.maxTokens,
        reasoning: reasoning,
        serviceTier: nil,
        store: nil,
        stream: true,
        temperature: options.temperature,
        toolChoice: nil,
        tools: tools
    )
}

private enum AzureOpenAIResponsesStreamError: Error {
    case aborted
    case unknown
    case apiError(String)
}

private func clampAzureThinkingLevel(_ effort: ThinkingLevel?) -> ThinkingLevel? {
    guard let effort else { return nil }
    if effort == .xhigh {
        return .high
    }
    return effort
}

private enum AzureOpenAIResponsesConfigError: LocalizedError {
    case missingBaseUrl

    var errorDescription: String? {
        switch self {
        case .missingBaseUrl:
            return "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl."
        }
    }
}
