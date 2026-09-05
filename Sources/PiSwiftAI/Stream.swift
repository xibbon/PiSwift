import Foundation

public func createAssistantMessageEventStream() -> AssistantMessageEventStream {
    AssistantMessageEventStream()
}

public func resetApiProviders() {
    clearApiProviders()
    registerBuiltInProviders()
}

private func shouldLogApiKeyDebug() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let flag = (env["PI_DEBUG_API_KEYS"] ?? env["PI_DEBUG_LIVE_TESTS"])?.lowercased()
    return flag == "1" || flag == "true" || flag == "yes"
}

private func apiKeyInfo(_ key: String?) -> String {
    guard let key else { return "missing" }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasWhitespace = trimmed.count != key.count
    return "present length=\(key.count) trimmedLength=\(trimmed.count) whitespace=\(hasWhitespace)"
}

private func logApiKeyDebug(_ message: String) {
    guard shouldLogApiKeyDebug() else { return }
    let line = "PI_DEBUG: \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

public func getEnvApiKey(provider: KnownProvider) -> String? {
    getEnvApiKey(provider: provider.rawValue)
}

public func findEnvKeys(provider: KnownProvider) -> [String]? {
    findEnvKeys(provider: provider.rawValue)
}

/// Return configured API-key environment variable names for a provider without exposing values.
///
/// This intentionally reports only explicit key/token variables and excludes ambient credential
/// sources such as AWS profiles, IAM credentials, and Google Vertex ADC files.
public func findEnvKeys(provider: String) -> [String]? {
    let env = ProcessInfo.processInfo.environment
    guard let envVars = apiKeyEnvVars(provider: provider) else { return nil }
    let found = envVars.filter { key in
        guard let value = env[key] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return found.isEmpty ? nil : found
}

public func getEnvApiKey(provider: String) -> String? {
    let env = ProcessInfo.processInfo.environment

    if provider == "github-copilot" {
        return env["COPILOT_GITHUB_TOKEN"] ?? env["GH_TOKEN"] ?? env["GITHUB_TOKEN"]
    }

    if provider == "amazon-bedrock" {
        if env["AWS_PROFILE"] != nil ||
            (env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil) ||
            env["AWS_BEARER_TOKEN_BEDROCK"] != nil ||
            env["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] != nil ||
            env["AWS_CONTAINER_CREDENTIALS_FULL_URI"] != nil ||
            env["AWS_WEB_IDENTITY_TOKEN_FILE"] != nil {
            return "<authenticated>"
        }
    }

    if provider == "anthropic" {
        let authToken = env["ANTHROPIC_AUTH_TOKEN"]
        let oauth = env["ANTHROPIC_OAUTH_TOKEN"]
        let apiKey = env["ANTHROPIC_API_KEY"]
        let selected = authToken ?? oauth ?? apiKey
        let source: String
        if authToken != nil {
            source = "ANTHROPIC_AUTH_TOKEN"
        } else if oauth != nil {
            source = "ANTHROPIC_OAUTH_TOKEN"
        } else if apiKey != nil {
            source = "ANTHROPIC_API_KEY"
        } else {
            source = "none"
        }
        logApiKeyDebug("provider=anthropic env apiKey=\(apiKeyInfo(apiKey)) oauth=\(apiKeyInfo(oauth)) authToken=\(apiKeyInfo(authToken)) selected=\(source)")
        return selected
    }

    if provider == "google-vertex" {
        if let apiKey = env["GOOGLE_CLOUD_API_KEY"], !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return apiKey
        }
        if hasGoogleVertexCredentials(env: env) {
            return "<authenticated>"
        }
    }

    if let envVar = apiKeyEnvVars(provider: provider)?.first {
        let apiKey = env[envVar]
        logApiKeyDebug("provider=\(provider) env apiKey=\(apiKeyInfo(apiKey))")
        return apiKey
    }

    return nil
}

private func apiKeyEnvVars(provider: String) -> [String]? {
    if provider == "github-copilot" {
        return ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]
    }

    if provider == "anthropic" {
        return ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
    }

    let envMap: [String: String] = [
        "openai": "OPENAI_API_KEY",
        "openai-codex": "OPENAI_API_KEY",
        "azure-openai-responses": "AZURE_OPENAI_API_KEY",
        "google": "GEMINI_API_KEY",
        "google-vertex": "GOOGLE_CLOUD_API_KEY",
        "groq": "GROQ_API_KEY",
        "cerebras": "CEREBRAS_API_KEY",
        "baseten": "BASETEN_API_KEY",
        "qwen-token-plan": "QWEN_TOKEN_PLAN_API_KEY",
        "qwen-token-plan-individual": "QWEN_TOKEN_PLAN_API_KEY",
        "qwen-token-plan-cn": "QWEN_TOKEN_PLAN_CN_API_KEY",
        "xai": "XAI_API_KEY",
        "openrouter": "OPENROUTER_API_KEY",
        "vercel-ai-gateway": "AI_GATEWAY_API_KEY",
        "zai": "ZAI_API_KEY",
        "mistral": "MISTRAL_API_KEY",
        "minimax": "MINIMAX_API_KEY",
        "minimax-cn": "MINIMAX_CN_API_KEY",
        "huggingface": "HF_TOKEN",
        "opencode": "OPENCODE_API_KEY",
        "opencode-go": "OPENCODE_API_KEY",
        "kimi-coding": "KIMI_API_KEY",
        "fireworks": "FIREWORKS_API_KEY",
        "deepseek": "DEEPSEEK_API_KEY",
    ]

    guard let envVar = envMap[provider] else { return nil }
    return [envVar]
}

private func hasGoogleVertexCredentials(env: [String: String]) -> Bool {
    let project = env["GOOGLE_CLOUD_PROJECT"] ?? env["GCLOUD_PROJECT"]
    let location = env["GOOGLE_CLOUD_LOCATION"]
    guard project != nil, location != nil else { return false }

    let fileManager = FileManager.default
    if let gacPath = env["GOOGLE_APPLICATION_CREDENTIALS"],
       fileManager.fileExists(atPath: gacPath) {
        return true
    }

    #if os(macOS) || os(Linux)
    let defaultPath = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/gcloud/application_default_credentials.json")
        .path
    return fileManager.fileExists(atPath: defaultPath)
    #else
    return false
    #endif
}

public func stream(model: Model, context: Context, options: StreamOptions? = nil) throws -> AssistantMessageEventStream {
    try validateHTTPClientSupport(api: model.api, transport: options?.transport, httpClient: options?.httpClient)
    if getApiProvider(model.api) == nil {
        ensureBuiltInProviders()
    }
    guard let provider = getApiProvider(model.api) else {
        throw StreamError.noApiProvider(model.api.rawValue)
    }
    return provider.stream(model, context, options)
}

public func complete(model: Model, context: Context, options: StreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try stream(model: model, context: context, options: options)
    return await stream.result()
}

public func streamSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) throws -> AssistantMessageEventStream {
    try validateHTTPClientSupport(api: model.api, transport: options?.transport, httpClient: options?.httpClient)
    if getApiProvider(model.api) == nil {
        ensureBuiltInProviders()
    }
    guard let provider = getApiProvider(model.api) else {
        throw StreamError.noApiProvider(model.api.rawValue)
    }
    var resolvedOptions = options ?? SimpleStreamOptions()
    let requestedMaxTokens = options?.maxTokens ?? model.maxTokens
    resolvedOptions.maxTokens = clampSimpleMaxTokensToContext(model: model, context: context, maxTokens: requestedMaxTokens)
    return provider.streamSimple(model, context, resolvedOptions)
}

private func validateHTTPClientSupport(
    api: Api,
    transport: Transport?,
    httpClient: (any ProviderHTTPClient)?
) throws {
    guard httpClient != nil else { return }
    switch api {
    case .googleGenerativeAI:
        throw StreamError.unsupportedHTTPClient("Google Generative AI adapter")
    case .googleVertex:
        throw StreamError.unsupportedHTTPClient("Google Vertex adapter")
    case .googleGeminiCli:
        throw StreamError.unsupportedHTTPClient("Google Gemini CLI adapter")
    case .bedrockConverseStream:
        throw StreamError.unsupportedHTTPClient("Amazon Bedrock adapter")
    case .openAICodexResponses where transport == .websocket || transport == .websocketCached:
        throw StreamError.unsupportedHTTPClient("OpenAI Codex WebSocket transport")
    case .anthropicMessages, .openAICompletions, .openAIResponses,
         .openAICodexResponses, .azureOpenAIResponses, .mistralConversations:
        return
    }
}

/// Leave room for protocol overhead and completion tokens on APIs whose context
/// window covers both the prompt and generated output.
func clampSimpleMaxTokensToContext(model: Model, context: Context, maxTokens: Int) -> Int {
    guard model.contextWindow > 0 else { return max(1, maxTokens) }
    let available = model.contextWindow - estimateContextTokens(context) - 4_096
    return min(maxTokens, max(1, available))
}

func estimateContextTokens(_ context: Context) -> Int {
    func textTokens(_ text: String) -> Int { (text.count + 3) / 4 }
    func blocksTokens(_ blocks: [ContentBlock]) -> Int {
        blocks.reduce(0) { total, block in
            switch block {
            case .text(let text): return total + textTokens(text.text)
            case .thinking(let thinking): return total + textTokens(thinking.thinking)
            case .image: return total + 1_200
            case .toolCall(let call): return total + textTokens(call.name + jsonString(from: call.arguments))
            }
        }
    }

    func messageTokens(_ message: Message) -> Int {
        switch message {
        case .user(let user):
            switch user.content {
            case .text(let text): return textTokens(text)
            case .blocks(let blocks): return blocksTokens(blocks)
            }
        case .toolResult(let result): return blocksTokens(result.content)
        case .assistant(let assistant): return blocksTokens(assistant.content)
        }
    }

    // Usage from an assistant turn already represents the entire request context;
    // only estimate messages appended after that turn. Summing the whole history
    // again would unnecessarily shrink the output budget on long conversations.
    if let lastUsageIndex = context.messages.indices.reversed().first(where: { index in
        guard case .assistant(let assistant) = context.messages[index] else { return false }
        switch assistant.stopReason {
        case .stop, .length, .toolUse:
            break
        case .pending, .error, .aborted, .deferred:
            return false
        }
        return assistant.usage.totalTokens > 0 || assistant.usage.input + assistant.usage.output + assistant.usage.cacheRead + assistant.usage.cacheWrite > 0
    }), case .assistant(let assistant) = context.messages[lastUsageIndex] {
        let usage = assistant.usage.totalTokens > 0
            ? assistant.usage.totalTokens
            : assistant.usage.input + assistant.usage.output + assistant.usage.cacheRead + assistant.usage.cacheWrite
        let trailing = lastUsageIndex + 1 < context.messages.endIndex
            ? context.messages[(lastUsageIndex + 1)...].reduce(0) { $0 + messageTokens($1) }
            : 0
        return usage + trailing
    }

    var total = textTokens(context.systemPrompt ?? "") + context.messages.reduce(0) { $0 + messageTokens($1) }
    if let tools = context.tools, !tools.isEmpty {
        total += textTokens(tools.map { "\($0.name):\($0.description)" }.joined(separator: "\n"))
    }
    return total
}

public func completeSimple(model: Model, context: Context, options: SimpleStreamOptions? = nil) async throws -> AssistantMessage {
    let stream = try streamSimple(model: model, context: context, options: options)
    return await stream.result()
}

func mapAnthropicSimpleOptions(model: Model, context: Context, options: SimpleStreamOptions?, apiKey: String) -> AnthropicOptions {
    let baseMaxTokens = options?.maxTokens ?? model.maxTokens

    if options?.reasoning == nil {
        return AnthropicOptions(
            temperature: options?.temperature,
            maxTokens: baseMaxTokens,
            signal: options?.signal,
            apiKey: apiKey,
            httpClient: options?.httpClient,
            thinkingEnabled: false,
            toolChoice: options?.toolChoice.map { $0 == .auto ? AnthropicToolChoice.auto : .none },
        metadata: options?.metadata,
            headers: options?.headers,
            onPayload: options?.onPayload,
            onResponse: options?.onResponse,
            timeoutMs: options?.timeoutMs,
            maxRetries: options?.maxRetries,
            maxRetryDelayMs: options?.maxRetryDelayMs
        )
    }

    let effort = clampThinkingLevel(model: model, requested: options?.reasoning) ?? .medium
    let adaptiveEffort = mapAnthropicAdaptiveThinkingEffort(model: model, level: effort)
    let adjusted = adjustMaxTokensForThinking(
        baseMaxTokens: baseMaxTokens,
        modelMaxTokens: model.maxTokens,
        reasoningLevel: effort,
        customBudgets: options?.thinkingBudgets
    )
    // v0.80.x (#5595): the thinking budget is added on top of the base output cap, so
    // re-clamp the inflated total against the context window and fit the thinking budget
    // inside it, mirroring upstream `anthropic-messages.ts` clampMaxTokensToContext.
    let clampedMaxTokens = clampSimpleMaxTokensToContext(model: model, context: context, maxTokens: adjusted.maxTokens)
    let clampedThinkingBudget = min(adjusted.thinkingBudget, max(0, clampedMaxTokens - minimumAnswerTokens))

    return AnthropicOptions(
        temperature: options?.temperature,
        maxTokens: clampedMaxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        thinkingEnabled: true,
        thinkingBudgetTokens: clampedThinkingBudget,
        effort: model.compat?.forceAdaptiveThinking == true ? adaptiveEffort : nil,
        toolChoice: options?.toolChoice.map { $0 == .auto ? AnthropicToolChoice.auto : .none },
        metadata: options?.metadata,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

/// Resolves catalog aliases such as Opus 4.6's `xhigh -> max` before Anthropic
/// adaptive-thinking request construction.
func mapAnthropicAdaptiveThinkingEffort(model: Model, level: ThinkingLevel) -> ThinkingLevel {
    guard let mapped = mappedThinkingLevel(model: model, level: level),
          let effort = ThinkingLevel(rawValue: mapped) else {
        return level
    }
    return effort
}

func clampThinkingLevel(_ effort: ThinkingLevel?) -> ThinkingLevel? {
    guard let effort else { return nil }
    if effort == .xhigh || effort == .max {
        return .high
    }
    return effort
}

let minimumAnswerTokens = 1_024

func mergeSamplingParams(
    model: Model,
    request: [String: AnyCodable]?
) -> [String: AnyCodable]? {
    guard model.samplingParams != nil || request != nil else { return nil }
    return (model.samplingParams ?? [:]).merging(request ?? [:]) { _, requestValue in requestValue }
}

/// v0.70.0: GPT-5.5 Codex doesn't support `.minimal` reasoning effort — the API rejects it.
/// Clamp `.minimal` to `.low` for that model family. Other clamping (xhigh→high) still flows
/// through `supportsXhigh` / `clampThinkingLevel` callers.
func clampForCodexCapability(model: Model, _ effort: ThinkingLevel?) -> ThinkingLevel? {
    guard let effort else { return nil }
    if model.id.contains("gpt-5.5") && effort == .minimal {
        return .low
    }
    return effort
}

func mapOpenAICompletionsSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAICompletionsOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let reasoningEffort = clampThinkingLevel(model: model, requested: options?.reasoning)
    return OpenAICompletionsOptions(
        temperature: options?.temperature,
        samplingParams: mergeSamplingParams(model: model, request: options?.samplingParams),
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        toolChoice: options?.toolChoice.map { $0 == .auto ? OpenAIToolChoice.auto : .none },
        reasoningEffort: reasoningEffort,
        thinkingBudgets: options?.thinkingBudgets,
        cacheRetention: options?.cacheRetention,
        sessionId: options?.sessionId,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

func mapOpenAIResponsesSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAIResponsesOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let reasoningEffort = clampThinkingLevel(model: model, requested: options?.reasoning)
    return OpenAIResponsesOptions(
        temperature: options?.temperature,
        samplingParams: mergeSamplingParams(model: model, request: options?.samplingParams),
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        cacheRetention: options?.cacheRetention,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId,
        transport: options?.transport,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        websocketConnectTimeoutMs: options?.websocketConnectTimeoutMs,
        toolChoice: options?.toolChoice.map { $0 == .auto ? OpenAIToolChoice.auto : .none }
    )
}

func mapOpenAICodexResponsesSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> OpenAICodexResponsesOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let reasoningEffort = clampThinkingLevel(model: model, requested: options?.reasoning)
    return OpenAICodexResponsesOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        reasoningEffort: reasoningEffort,
        cacheRetention: options?.cacheRetention,
        sessionId: options?.sessionId,
        transport: options?.transport,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        websocketConnectTimeoutMs: options?.websocketConnectTimeoutMs,
        toolChoice: options?.toolChoice.map { $0 == .auto ? OpenAIToolChoice.auto : .none }
    )
}

func mapAzureOpenAIResponsesSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> AzureOpenAIResponsesOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let reasoningEffort = clampThinkingLevel(model: model, requested: options?.reasoning)
    return AzureOpenAIResponsesOptions(
        temperature: options?.temperature,
        samplingParams: mergeSamplingParams(model: model, request: options?.samplingParams),
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        reasoningEffort: reasoningEffort,
        sessionId: options?.sessionId,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs,
        toolChoice: options?.toolChoice.map { $0 == .auto ? OpenAIToolChoice.auto : .none }
    )
}

func mapGoogleSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> GoogleOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let thinking = buildGoogleThinkingConfig(model: model, options: options)
    return GoogleOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        headers: options?.headers,
        thinking: thinking,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

func mapGoogleSimpleOptionsValidated(model: Model, options: SimpleStreamOptions?, apiKey: String) throws -> GoogleOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let thinking = try buildGoogleThinkingConfigValidated(model: model, options: options)
    return GoogleOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        headers: options?.headers,
        toolChoice: options?.toolChoice?.rawValue,
        thinking: thinking,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

func mapGoogleVertexSimpleOptions(model: Model, options: SimpleStreamOptions?, apiKey: String) -> GoogleVertexOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let thinking = buildGoogleThinkingConfig(model: model, options: options)
    return GoogleVertexOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        headers: options?.headers,
        thinking: thinking,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

func mapGoogleVertexSimpleOptionsValidated(model: Model, options: SimpleStreamOptions?, apiKey: String) throws -> GoogleVertexOptions {
    let maxTokens = options?.maxTokens ?? model.maxTokens
    let thinking = try buildGoogleThinkingConfigValidated(model: model, options: options)
    return GoogleVertexOptions(
        temperature: options?.temperature,
        maxTokens: maxTokens,
        signal: options?.signal,
        apiKey: apiKey,
        httpClient: options?.httpClient,
        headers: options?.headers,
        toolChoice: options?.toolChoice?.rawValue,
        thinking: thinking,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries,
        maxRetryDelayMs: options?.maxRetryDelayMs
    )
}

func buildGoogleThinkingConfig(model: Model, options: SimpleStreamOptions?) -> GoogleOptions.ThinkingConfig? {
    guard model.reasoning else { return nil }
    guard let reasoning = options?.reasoning else { return nil }
    let clamped = clampThinkingLevel(model: model, requested: reasoning) ?? reasoning
    if model.id.contains("3-pro") || model.id.contains("3-flash") {
        return GoogleOptions.ThinkingConfig(
            enabled: true,
            budgetTokens: nil,
            level: googleThinkingLevel(for: clamped, modelId: model.id)
        )
    }
    let budget = googleThinkingBudget(modelId: model.id, effort: clamped, customBudgets: options?.thinkingBudgets)
    return GoogleOptions.ThinkingConfig(
        enabled: true,
        budgetTokens: budget,
        level: nil
    )
}

func buildGoogleThinkingConfigValidated(model: Model, options: SimpleStreamOptions?) throws -> GoogleOptions.ThinkingConfig? {
    guard model.reasoning else { return nil }
    guard let reasoning = options?.reasoning else { return nil }
    let level = clampThinkingLevel(model: model, requested: reasoning)
    let resolved = try resolveGoogleThinkingLevel(model: model, level: level.map(ModelThinkingLevel.init) ?? .off)
    let clamped = ThinkingLevel(rawValue: resolved.rawValue)!
    if model.id.lowercased().range(of: #"gemini-3(?:\.\d+)?-(?:pro|flash)|gemma-?4"#, options: .regularExpression) != nil {
        return GoogleOptions.ThinkingConfig(
            enabled: true,
            budgetTokens: nil,
            level: googleThinkingLevel(for: clamped, modelId: model.id)
        )
    }
    let budget = googleThinkingBudget(modelId: model.id, effort: clamped, customBudgets: options?.thinkingBudgets)
    return GoogleOptions.ThinkingConfig(
        enabled: true,
        budgetTokens: budget,
        level: nil
    )
}

func googleThinkingBudget(modelId: String, effort: ThinkingLevel, customBudgets: ThinkingBudgets?) -> Int {
    if let custom = customBudgets?[effort] {
        return custom
    }
    let clamped = clampThinkingLevel(effort) ?? effort
    if modelId.contains("2.5-pro") {
        let budgets: ThinkingBudgets = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 32768,
        ]
        return budgets[clamped] ?? -1
    }
    if modelId.contains("2.5-flash") {
        let budgets: ThinkingBudgets = [
            .minimal: 128,
            .low: 2048,
            .medium: 8192,
            .high: 24576,
        ]
        return budgets[clamped] ?? -1
    }
    return -1
}

func mapBedrockSimpleOptions(model: Model, options: SimpleStreamOptions?) -> BedrockOptions {
    let baseMaxTokens = options?.maxTokens ?? model.maxTokens
    let reasoning = clampThinkingLevel(model: model, requested: options?.reasoning)

    let bedrockClaudeIdentifier = "\(model.id) \(model.name)".lowercased()
    if let reasoning, (bedrockClaudeIdentifier.contains("anthropic.claude") || bedrockClaudeIdentifier.contains("anthropic/claude") || bedrockClaudeIdentifier.contains("claude")) {
        let adjusted = adjustMaxTokensForThinking(
            baseMaxTokens: baseMaxTokens,
            modelMaxTokens: model.maxTokens,
            reasoningLevel: reasoning,
            customBudgets: options?.thinkingBudgets
        )
        return BedrockOptions(
            temperature: options?.temperature,
            maxTokens: adjusted.maxTokens,
            signal: options?.signal,
            toolChoice: options?.toolChoice.map { $0 == .auto ? BedrockToolChoice.auto : .none },
        reasoning: reasoning,
            thinkingBudgets: mergeThinkingBudgets(options?.thinkingBudgets, reasoning: reasoning, thinkingBudget: adjusted.thinkingBudget),
            cacheRetention: options?.cacheRetention,
            headers: options?.headers,
            onPayload: options?.onPayload,
            onResponse: options?.onResponse,
            timeoutMs: options?.timeoutMs,
            maxRetries: options?.maxRetries
        )
    }

    return BedrockOptions(
        temperature: options?.temperature,
        maxTokens: baseMaxTokens,
        signal: options?.signal,
        toolChoice: options?.toolChoice.map { $0 == .auto ? BedrockToolChoice.auto : .none },
        reasoning: reasoning,
        thinkingBudgets: options?.thinkingBudgets,
        cacheRetention: options?.cacheRetention,
        headers: options?.headers,
        onPayload: options?.onPayload,
        onResponse: options?.onResponse,
        timeoutMs: options?.timeoutMs,
        maxRetries: options?.maxRetries
    )
}

func adjustMaxTokensForThinking(
    baseMaxTokens: Int?,
    modelMaxTokens: Int,
    reasoningLevel: ThinkingLevel,
    customBudgets: ThinkingBudgets?
) -> (maxTokens: Int, thinkingBudget: Int) {
    var thinkingBudget = thinkingBudgetForLevel(reasoningLevel, custom: customBudgets)
    let maxTokens = baseMaxTokens.map { min($0 + thinkingBudget, modelMaxTokens) } ?? modelMaxTokens
    if maxTokens <= thinkingBudget {
        thinkingBudget = clampThinkingBudgetToAnswerRoom(thinkingBudget, ceiling: maxTokens)
    }
    return (maxTokens, thinkingBudget)
}

func mergeThinkingBudgets(_ budgets: ThinkingBudgets?, reasoning: ThinkingLevel, thinkingBudget: Int) -> ThinkingBudgets? {
    var merged = budgets ?? [:]
    let clamped = clampThinkingLevel(reasoning) ?? reasoning
    merged[clamped] = thinkingBudget
    return merged
}

public enum StreamError: Error, LocalizedError, Sendable {
    case missingApiKey(String)
    case noApiProvider(String)
    case providerRequest(statusCode: Int?, headers: [String: String]?, message: String)
    case retryDelayExceedsMaximum(requestedMs: Double, maximumMs: Double, providerMessage: String)
    case requestAborted
    case unsupportedHTTPClient(String)
    case invalidUUIDTimestamp
    case uuidSequenceExhausted
    case invalidHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for provider: \(provider)"
        case .noApiProvider(let api):
            return "No API provider registered for api: \(api)"
        case .providerRequest(_, _, let message):
            return message
        case .retryDelayExceedsMaximum(let requestedMs, let maximumMs, let providerMessage):
            let requestedSeconds = String(format: "%.0f", ceil(requestedMs / 1_000))
            let maximumSeconds = String(format: "%.0f", ceil(maximumMs / 1_000))
            return "Server requested \(requestedSeconds)s retry delay (max: \(maximumSeconds)s). \(providerMessage)"
        case .requestAborted:
            return "Request aborted"
        case .unsupportedHTTPClient(let adapter):
            return "\(adapter) does not support a custom HTTP client"
        case .invalidUUIDTimestamp:
            return "UUIDv7 timestamp must be an integer between 0 and 281474976710655"
        case .uuidSequenceExhausted:
            return "UUIDv7 generator sequence exhausted"
        case .invalidHTTPResponse:
            return "Provider returned an invalid HTTP response"
        }
    }
}

public let defaultThinkingBudgets: ThinkingBudgets = [.minimal: 1024, .low: 2048, .medium: 8192, .high: 16384]

public func thinkingBudgetForLevel(_ level: ThinkingLevel, custom: ThinkingBudgets? = nil) -> Int {
    let clamped = clampThinkingLevel(level) ?? level
    return custom?[clamped] ?? defaultThinkingBudgets[clamped]!
}

public func clampThinkingBudgetToAnswerRoom(_ budget: Int, ceiling: Int) -> Int {
    min(budget, max(0, ceiling - minimumAnswerTokens))
}
