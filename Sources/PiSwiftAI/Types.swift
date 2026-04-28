import Foundation

public enum Api: String, Sendable {
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case openAICodexResponses = "openai-codex-responses"
    case azureOpenAIResponses = "azure-openai-responses"
    case anthropicMessages = "anthropic-messages"
    case bedrockConverseStream = "bedrock-converse-stream"
    case googleGenerativeAI = "google-generative-ai"
    case googleGeminiCli = "google-gemini-cli"
    case googleVertex = "google-vertex"
    case mistralConversations = "mistral-conversations"
}

public enum KnownProvider: String, Sendable {
    case openai
    case openaiCodex = "openai-codex"
    case azureOpenAIResponses = "azure-openai-responses"
    case anthropic
    case amazonBedrock = "amazon-bedrock"
    case githubCopilot = "github-copilot"
    case xai
    case groq
    case cerebras
    case openrouter
    case minimax
    case minimaxCn = "minimax-cn"
    case huggingface
    case kimiCoding = "kimi-coding"
    case google
    case googleGeminiCli = "google-gemini-cli"
    case googleAntigravity = "google-antigravity"
    case googleVertex = "google-vertex"
    case vercelAiGateway = "vercel-ai-gateway"
    case zai
    case mistral
    case opencode
    case opencodeGo = "opencode-go"
}

public typealias Provider = String

public enum ThinkingLevel: String, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public typealias ReasoningEffort = ThinkingLevel
public typealias ThinkingBudgets = [ThinkingLevel: Int]

public enum CacheRetention: String, Sendable {
    case none
    case short
    case long
}

public enum Transport: String, Sendable {
    case sse
    case websocket
    case auto
}

public struct StreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var transport: Transport?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: AnyCodable]?
    /// v0.67.6: invoked after each provider response is received and before stream
    /// consumption begins. Use for status/header inspection (telemetry, extension hooks).
    public var onResponse: ResponseHandler?
    /// v0.70.1: provider SDK request timeout (milliseconds). Forwarded to OpenAI/Azure/Anthropic
    /// SDK request options so long-running local inference isn't capped at SDK defaults.
    public var timeoutMs: Int?
    /// v0.70.1: provider SDK max retries. Forwarded to provider SDK retry config.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        transport: Transport? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: AnyCodable]? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.transport = transport
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.headers = headers
        self.onPayload = onPayload
        self.maxRetryDelayMs = maxRetryDelayMs
        self.metadata = metadata
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public struct SimpleStreamOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var transport: Transport?
    public var reasoning: ThinkingLevel?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: AnyCodable]?
    /// v0.67.6: invoked after each provider response is received and before stream consumption.
    public var onResponse: ResponseHandler?
    /// v0.70.1: provider SDK request timeout (ms).
    public var timeoutMs: Int?
    /// v0.70.1: provider SDK max retries.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        transport: Transport? = nil,
        reasoning: ThinkingLevel? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: AnyCodable]? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.transport = transport
        self.reasoning = reasoning
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.thinkingBudgets = thinkingBudgets
        self.headers = headers
        self.onPayload = onPayload
        self.maxRetryDelayMs = maxRetryDelayMs
        self.metadata = metadata
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public struct PayloadSnapshot: Sendable {
    public let json: String

    public init(json: String) {
        self.json = json
    }
}

public typealias PayloadHandler = @Sendable (PayloadSnapshot) -> Void

/// v0.67.6: snapshot of the provider HTTP response surfaced via `onResponse`.
/// Exposes status and headers so callers (e.g., extensions, telemetry) can inspect
/// transport-level signals before stream consumption begins.
public struct ResponseSnapshot: Sendable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

public typealias ResponseHandler = @Sendable (ResponseSnapshot) -> Void

/// v0.67.6: thinking display mode for Anthropic and Bedrock. Defaults to `summarized`
/// so Opus 4.7 / Mythos Preview keep returning thinking text. Set to `omitted` to skip
/// thinking streaming for faster time-to-first-text-token.
public enum ThinkingDisplay: String, Sendable {
    case summarized
    case omitted
}

public enum OpenAICompatMaxTokensField: String, Sendable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

public enum OpenAICompatThinkingFormat: String, Sendable {
    case openai
    case zai
    case qwen
    case qwenChatTemplate = "qwen-chat-template"
    case openrouter
    /// v0.70.1: DeepSeek V4 sends `thinking: { type: "enabled" }` plus `reasoning_effort` and
    /// expects `reasoning_content` on replayed assistant messages.
    case deepseek
}

/// v0.68.0: opt-in cache_control formats for OpenAI-compatible providers that expose
/// Anthropic-style prompt caching via `cache_control` markers (e.g., OpenCode/OpenCode Go
/// Qwen 3.5/3.6 Plus).
public enum OpenAICompatCacheControlFormat: String, Sendable {
    case anthropic
}

public struct OpenRouterRouting: Sendable {
    public var only: [String]?
    public var order: [String]?

    public init(only: [String]? = nil, order: [String]? = nil) {
        self.only = only
        self.order = order
    }
}

public struct VercelGatewayRouting: Sendable {
    public var only: [String]?
    public var order: [String]?

    public init(only: [String]? = nil, order: [String]? = nil) {
        self.only = only
        self.order = order
    }
}

public struct OpenAICompat: Sendable {
    public var supportsStore: Bool?
    public var supportsDeveloperRole: Bool?
    public var supportsReasoningEffort: Bool?
    public var supportsUsageInStreaming: Bool?
    public var maxTokensField: OpenAICompatMaxTokensField?
    public var requiresToolResultName: Bool?
    public var requiresAssistantAfterToolResult: Bool?
    public var requiresThinkingAsText: Bool?
    public var requiresMistralToolIds: Bool?
    public var thinkingFormat: OpenAICompatThinkingFormat?
    public var openRouterRouting: OpenRouterRouting?
    public var vercelGatewayRouting: VercelGatewayRouting?
    public var supportsStrictMode: Bool?
    /// Maps thinking levels to provider-specific reasoning effort values.
    /// When set, the mapped value is sent instead of the standard level string.
    public var reasoningEffortMap: [ThinkingLevel: String]?
    /// v0.70.0: when false, the provider opts out of long-retention cache fields
    /// (e.g., `prompt_cache_retention: "24h"`) even when long retention is requested.
    /// Default behavior (nil) is to send long-retention fields when requested.
    public var supportsLongCacheRetention: Bool?
    /// v0.70.0: when false, strict OpenAI-compatible proxies omit the underscore-containing
    /// `session_id` header while still sending other session-affinity headers.
    public var sendSessionIdHeader: Bool?
    /// v0.70.0: when false, Anthropic-compatible providers omit per-tool `eager_input_streaming`
    /// and use the legacy fine-grained-tool-streaming beta header instead.
    public var supportsEagerToolInputStreaming: Bool?
    /// v0.68.0: cache-control marker format for Anthropic-style prompt caching exposed by
    /// OpenAI-compatible providers (e.g., OpenCode Qwen 3.5/3.6 Plus).
    public var cacheControlFormat: OpenAICompatCacheControlFormat?
    /// v0.68.0: when true, OpenAI-compatible Chat Completions sends aligned session-affinity
    /// headers (`session_id`, `x-client-request-id`, `x-session-affinity`) derived from `sessionId`.
    public var sendSessionAffinityHeaders: Bool?
    /// v0.70.1: when true, replayed assistant messages must include a `reasoning_content` field
    /// (DeepSeek V4 requirement). Empty `reasoning_content` is injected if no thinking content exists.
    public var requiresReasoningContentOnAssistantMessages: Bool?

    public init(
        supportsStore: Bool? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsUsageInStreaming: Bool? = nil,
        maxTokensField: OpenAICompatMaxTokensField? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        requiresThinkingAsText: Bool? = nil,
        requiresMistralToolIds: Bool? = nil,
        thinkingFormat: OpenAICompatThinkingFormat? = nil,
        openRouterRouting: OpenRouterRouting? = nil,
        vercelGatewayRouting: VercelGatewayRouting? = nil,
        supportsStrictMode: Bool? = nil,
        reasoningEffortMap: [ThinkingLevel: String]? = nil,
        supportsLongCacheRetention: Bool? = nil,
        sendSessionIdHeader: Bool? = nil,
        supportsEagerToolInputStreaming: Bool? = nil,
        cacheControlFormat: OpenAICompatCacheControlFormat? = nil,
        sendSessionAffinityHeaders: Bool? = nil,
        requiresReasoningContentOnAssistantMessages: Bool? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.maxTokensField = maxTokensField
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresMistralToolIds = requiresMistralToolIds
        self.thinkingFormat = thinkingFormat
        self.openRouterRouting = openRouterRouting
        self.vercelGatewayRouting = vercelGatewayRouting
        self.supportsStrictMode = supportsStrictMode
        self.reasoningEffortMap = reasoningEffortMap
        self.supportsLongCacheRetention = supportsLongCacheRetention
        self.sendSessionIdHeader = sendSessionIdHeader
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.cacheControlFormat = cacheControlFormat
        self.sendSessionAffinityHeaders = sendSessionAffinityHeaders
        self.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
    }
}

public struct ModelCost: Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public enum ModelInput: String, Sendable {
    case text
    case image
}

public struct Model: Sendable {
    public let id: String
    public let name: String
    public let api: Api
    public let provider: Provider
    public let baseUrl: String
    public let reasoning: Bool
    public let input: [ModelInput]
    public let cost: ModelCost
    public let contextWindow: Int
    public let maxTokens: Int
    public let headers: [String: String]?
    public let compat: OpenAICompat?

    public init(
        id: String,
        name: String,
        api: Api,
        provider: Provider,
        baseUrl: String,
        reasoning: Bool,
        input: [ModelInput],
        cost: ModelCost,
        contextWindow: Int,
        maxTokens: Int,
        headers: [String: String]? = nil,
        compat: OpenAICompat? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseUrl = baseUrl
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
        self.compat = compat
    }
}

public struct UsageCost: Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }
}

public struct Usage: Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var totalTokens: Int
    public var cost: UsageCost

    public init(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        totalTokens: Int,
        cost: UsageCost = UsageCost()
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

public enum StopReason: String, Sendable {
    case stop
    case length
    case toolUse
    case error
    case aborted
}

public struct TextContent: Sendable {
    public let type: String = "text"
    public var text: String
    public var textSignature: String?

    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

public struct ThinkingContent: Sendable {
    public let type: String = "thinking"
    public var thinking: String
    public var thinkingSignature: String?
    /// When true, the thinking content was redacted by safety filters. The opaque
    /// encrypted payload is stored in `thinkingSignature` so it can be passed back
    /// to the API for multi-turn continuity.
    public var redacted: Bool?

    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

public struct ImageContent: Sendable {
    public let type: String = "image"
    public let data: String
    public let mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Sendable {
    public let type: String = "toolCall"
    public var id: String
    public var name: String
    public var arguments: [String: AnyCodable]
    public var thoughtSignature: String?

    public init(id: String, name: String, arguments: [String: AnyCodable], thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

public enum ContentBlock: Sendable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case image(ImageContent)
    case toolCall(ToolCall)
}

public struct UserMessage: Sendable {
    public let role: String = "user"
    public var content: UserContent
    public var timestamp: Int64

    public init(content: UserContent, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.content = content
        self.timestamp = timestamp
    }
}

public enum UserContent: Sendable {
    case text(String)
    case blocks([ContentBlock])
}

public struct AssistantMessage: Sendable {
    public let role: String = "assistant"
    public var content: [ContentBlock]
    public var api: Api
    public var provider: Provider
    public var model: String
    /// Provider-specific response/message identifier when the upstream API exposes one.
    public var responseId: String?
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Int64

    public init(
        content: [ContentBlock],
        api: Api,
        provider: Provider,
        model: String,
        responseId: String? = nil,
        usage: Usage,
        stopReason: StopReason,
        errorMessage: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.responseId = responseId
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public struct ToolResultMessage: Sendable {
    public let role: String = "toolResult"
    public var toolCallId: String
    public var toolName: String
    public var content: [ContentBlock]
    public var details: AnyCodable?
    public var isError: Bool
    public var timestamp: Int64

    public init(
        toolCallId: String,
        toolName: String,
        content: [ContentBlock],
        details: AnyCodable? = nil,
        isError: Bool,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
    }
}

public enum Message: Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var role: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .toolResult:
            return "toolResult"
        }
    }
}

public struct AITool: Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]

    public init(name: String, description: String, parameters: [String: AnyCodable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct Context: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [AITool]?

    public init(systemPrompt: String? = nil, messages: [Message], tools: [AITool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolCallStart(contentIndex: Int, partial: AssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    case error(reason: StopReason, error: AssistantMessage)
}

public enum OpenAIToolChoice: Sendable {
    case auto
    case none
    case required
    case function(String)
}

public struct OpenAICompletionsOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var toolChoice: OpenAIToolChoice?
    public var reasoningEffort: ThinkingLevel?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        toolChoice: OpenAIToolChoice? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
        self.headers = headers
        self.onPayload = onPayload
    }
}

public enum OpenAIReasoningSummary: String, Sendable {
    case auto
    case detailed
    case concise
}

public enum OpenAIServiceTier: String, Sendable {
    case auto
    case defaultTier = "default"
    case flex
    case priority
    case onDemand = "on_demand"
}

public enum OpenAICodexReasoningSummary: String, Sendable {
    case auto
    case concise
    case detailed
    case off
    case on
}

public enum OpenAICodexTextVerbosity: String, Sendable {
    case low
    case medium
    case high
}

public struct OpenAIResponsesOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var cacheRetention: CacheRetention?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAIReasoningSummary?
    public var serviceTier: OpenAIServiceTier?
    public var sessionId: String?
    public var transport: Transport?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        cacheRetention: CacheRetention? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        serviceTier: OpenAIServiceTier? = nil,
        sessionId: String? = nil,
        transport: Transport? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.cacheRetention = cacheRetention
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.serviceTier = serviceTier
        self.sessionId = sessionId
        self.transport = transport
        self.headers = headers
        self.onPayload = onPayload
    }
}

public struct AzureOpenAIResponsesOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAIReasoningSummary?
    public var sessionId: String?
    public var headers: [String: String]?
    public var azureApiVersion: String?
    public var azureResourceName: String?
    public var azureBaseUrl: String?
    public var azureDeploymentName: String?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        sessionId: String? = nil,
        headers: [String: String]? = nil,
        azureApiVersion: String? = nil,
        azureResourceName: String? = nil,
        azureBaseUrl: String? = nil,
        azureDeploymentName: String? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.sessionId = sessionId
        self.headers = headers
        self.azureApiVersion = azureApiVersion
        self.azureResourceName = azureResourceName
        self.azureBaseUrl = azureBaseUrl
        self.azureDeploymentName = azureDeploymentName
        self.onPayload = onPayload
    }
}

public struct OpenAICodexResponsesOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAICodexReasoningSummary?
    public var textVerbosity: OpenAICodexTextVerbosity?
    public var include: [String]?
    public var sessionId: String?
    public var transport: Transport?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?
    /// v0.67.1: forward configured serviceTier to Codex Responses requests so users can choose
    /// flex / priority pricing tiers. v0.67.67: trust the explicitly requested tier when the API
    /// echoes the default — keeps cost accounting aligned with the caller-selected tier.
    public var serviceTier: OpenAIServiceTier?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAICodexReasoningSummary? = nil,
        textVerbosity: OpenAICodexTextVerbosity? = nil,
        include: [String]? = nil,
        sessionId: String? = nil,
        transport: Transport? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil,
        serviceTier: OpenAIServiceTier? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.textVerbosity = textVerbosity
        self.include = include
        self.sessionId = sessionId
        self.transport = transport
        self.headers = headers
        self.onPayload = onPayload
        self.serviceTier = serviceTier
    }
}

public enum GoogleThinkingLevel: String, Sendable {
    case unspecified = "THINKING_LEVEL_UNSPECIFIED"
    case minimal = "MINIMAL"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
}

public struct GoogleOptions: Sendable {
    public struct ThinkingConfig: Sendable {
        public var enabled: Bool
        public var budgetTokens: Int?
        public var level: GoogleThinkingLevel?

        public init(enabled: Bool, budgetTokens: Int? = nil, level: GoogleThinkingLevel? = nil) {
            self.enabled = enabled
            self.budgetTokens = budgetTokens
            self.level = level
        }
    }

    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var headers: [String: String]?
    public var toolChoice: String?
    public var thinking: ThinkingConfig?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        headers: [String: String]? = nil,
        toolChoice: String? = nil,
        thinking: ThinkingConfig? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.headers = headers
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.onPayload = onPayload
    }
}

public struct GoogleGeminiCliOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var maxRetryDelayMs: Int?
    public var headers: [String: String]?
    public var toolChoice: String?
    public var thinking: GoogleOptions.ThinkingConfig?
    public var sessionId: String?
    public var projectId: String?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        maxRetryDelayMs: Int? = nil,
        headers: [String: String]? = nil,
        toolChoice: String? = nil,
        thinking: GoogleOptions.ThinkingConfig? = nil,
        sessionId: String? = nil,
        projectId: String? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.maxRetryDelayMs = maxRetryDelayMs
        self.headers = headers
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.sessionId = sessionId
        self.projectId = projectId
        self.onPayload = onPayload
    }
}

public struct GoogleVertexOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var headers: [String: String]?
    public var toolChoice: String?
    public var thinking: GoogleOptions.ThinkingConfig?
    public var project: String?
    public var location: String?
    public var onPayload: PayloadHandler?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        headers: [String: String]? = nil,
        toolChoice: String? = nil,
        thinking: GoogleOptions.ThinkingConfig? = nil,
        project: String? = nil,
        location: String? = nil,
        onPayload: PayloadHandler? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.headers = headers
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.project = project
        self.location = location
        self.onPayload = onPayload
    }
}

public enum AnthropicToolChoice: Sendable {
    case auto
    case any
    case none
    case tool(name: String)
}

public struct AnthropicOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var thinkingEnabled: Bool?
    public var thinkingBudgetTokens: Int?
    /// Adaptive thinking effort level. When set on models that support adaptive
    /// thinking (e.g. Opus 4.6, Sonnet 4.6, Opus 4.7), this takes precedence over
    /// `thinkingBudgetTokens` and maps to an appropriate token budget.
    public var effort: ThinkingLevel?
    public var interleavedThinking: Bool?
    public var toolChoice: AnthropicToolChoice?
    public var metadata: [String: AnyCodable]?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?
    /// v0.67.6: thinking display mode. `summarized` (default) returns thinking text;
    /// `omitted` skips thinking streaming for faster time-to-first-text-token.
    public var thinkingDisplay: ThinkingDisplay?
    /// v0.67.6: invoked after the provider response is received and before stream consumption.
    public var onResponse: ResponseHandler?
    /// v0.70.1: SDK request timeout (ms).
    public var timeoutMs: Int?
    /// v0.70.1: SDK max retries.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        thinkingEnabled: Bool? = nil,
        thinkingBudgetTokens: Int? = nil,
        effort: ThinkingLevel? = nil,
        interleavedThinking: Bool? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        metadata: [String: AnyCodable]? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil,
        thinkingDisplay: ThinkingDisplay? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.effort = effort
        self.interleavedThinking = interleavedThinking
        self.toolChoice = toolChoice
        self.metadata = metadata
        self.headers = headers
        self.onPayload = onPayload
        self.thinkingDisplay = thinkingDisplay
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public enum BedrockToolChoice: Sendable {
    case auto
    case any
    case none
    case tool(name: String)
}

public struct BedrockOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var region: String?
    public var profile: String?
    public var toolChoice: BedrockToolChoice?
    public var reasoning: ThinkingLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var interleavedThinking: Bool?
    public var cacheRetention: CacheRetention?
    public var headers: [String: String]?
    public var onPayload: PayloadHandler?
    /// v0.62.0: AWS Cost Explorer split cost allocation tags forwarded as Converse `requestMetadata`.
    public var requestMetadata: [String: String]?
    /// v0.67.6: thinking display mode. `summarized` (default) returns thinking text;
    /// `omitted` skips thinking streaming for faster time-to-first-text-token.
    public var thinkingDisplay: ThinkingDisplay?
    /// v0.67.6: invoked after the provider response is received and before stream consumption.
    public var onResponse: ResponseHandler?
    /// v0.70.1: SDK request timeout (ms).
    public var timeoutMs: Int?
    /// v0.70.1: SDK max retries.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        region: String? = nil,
        profile: String? = nil,
        toolChoice: BedrockToolChoice? = nil,
        reasoning: ThinkingLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        interleavedThinking: Bool? = nil,
        cacheRetention: CacheRetention? = nil,
        headers: [String: String]? = nil,
        onPayload: PayloadHandler? = nil,
        requestMetadata: [String: String]? = nil,
        thinkingDisplay: ThinkingDisplay? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.region = region
        self.profile = profile
        self.toolChoice = toolChoice
        self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets
        self.interleavedThinking = interleavedThinking
        self.cacheRetention = cacheRetention
        self.headers = headers
        self.onPayload = onPayload
        self.requestMetadata = requestMetadata
        self.thinkingDisplay = thinkingDisplay
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public final class CancellationToken: Sendable {
    private let state = LockedState(false)

    public init() {}

    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}
