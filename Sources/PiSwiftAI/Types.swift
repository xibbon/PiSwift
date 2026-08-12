import Foundation

private struct ModelStringCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

public enum Api: String, Sendable, Codable {
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

public enum ImagesApi: String, Sendable {
    case openrouterImages = "openrouter-images"
}

public enum KnownProvider: String, Sendable {
    case openai
    case openaiCodex = "openai-codex"
    case azureOpenAIResponses = "azure-openai-responses"
    case antLing = "ant-ling"
    case anthropic
    case amazonBedrock = "amazon-bedrock"
    case githubCopilot = "github-copilot"
    case nvidia
    case xai
    case groq
    case cerebras
    case baseten
    case openrouter
    case qwenTokenPlan = "qwen-token-plan"
    case qwenTokenPlanCn = "qwen-token-plan-cn"
    case qwenTokenPlanIndividual = "qwen-token-plan-individual"
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
    case zaiCodingCn = "zai-coding-cn"
    case mistral
    case opencode
    case opencodeGo = "opencode-go"
    case fireworks
    case deepseek
    case moonshotai
    case moonshotaiCn = "moonshotai-cn"
    case together
    case cloudflareWorkersAi = "cloudflare-workers-ai"
    case cloudflareAiGateway = "cloudflare-ai-gateway"
    case xiaomi
    case xiaomiTokenPlanCn = "xiaomi-token-plan-cn"
    case xiaomiTokenPlanAms = "xiaomi-token-plan-ams"
    case xiaomiTokenPlanSgp = "xiaomi-token-plan-sgp"
}

public typealias Provider = String

public enum KnownImagesProvider: String, Sendable {
    case openrouter
}

public typealias ImagesProvider = String

public enum ThinkingLevel: String, Sendable, Codable, CodingKeyRepresentable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public var codingKey: any CodingKey {
        ModelStringCodingKey(stringValue: rawValue)!
    }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(rawValue: codingKey.stringValue)
    }
}

public enum ModelThinkingLevel: String, Sendable, Codable, CodingKeyRepresentable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public var codingKey: any CodingKey {
        ModelStringCodingKey(stringValue: rawValue)!
    }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(rawValue: codingKey.stringValue)
    }

    public init(_ level: ThinkingLevel) {
        switch level {
        case .minimal:
            self = .minimal
        case .low:
            self = .low
        case .medium:
            self = .medium
        case .high:
            self = .high
        case .xhigh:
            self = .xhigh
        case .max:
            self = .max
        }
    }

    public var thinkingLevel: ThinkingLevel? {
        switch self {
        case .off:
            return nil
        case .minimal:
            return .minimal
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .xhigh:
            return .xhigh
        case .max:
            return .max
        }
    }
}

public typealias ReasoningEffort = ThinkingLevel
public typealias ThinkingBudgets = [ThinkingLevel: Int]
public typealias ThinkingLevelMap = [ModelThinkingLevel: String?]
/// Provider request headers. A present key with a `nil` value suppresses a
/// provider or API default header with the same case-insensitive name.
public typealias ProviderHeaders = [String: String?]

public enum CacheRetention: String, Sendable {
    case none
    case short
    case long
}

public enum Transport: String, Sendable {
    case sse
    case websocket
    case websocketCached = "websocket-cached"
    case auto
}

public struct StreamOptions: Sendable {
    public var temperature: Double?
    /// Arbitrary sampling parameters merged into the request body as-is, after the named request
    /// fields, so keys here override them. Lets custom OpenAI-compatible servers (llama.cpp, vLLM,
    /// SGLang, ...) receive parameters pi does not model, e.g. `top_p`, `top_k`, `min_p`,
    /// `repetition_penalty`. Merged over `Model.samplingParams` per key. Only applied by
    /// OpenAI-compatible adapters (completions, responses, Azure responses); other APIs ignore it.
    public var samplingParams: [String: AnyCodable]?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    /// Optional per-request HTTP executor. Providers that cannot use it reject the request.
    public var httpClient: (any ProviderHTTPClient)?
    public var transport: Transport?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: AnyCodable]?
    /// v0.67.6: invoked after each provider response is received and before stream
    /// consumption begins. Use for status/header inspection (telemetry, extension hooks).
    public var onResponse: ResponseHandler?
    /// v0.70.1: provider SDK request timeout (milliseconds). Forwarded to OpenAI/Azure/Anthropic
    /// SDK request options so long-running local inference isn't capped at SDK defaults.
    public var timeoutMs: Int?
    /// v0.79.4: WebSocket connection/open handshake timeout for providers with WebSocket transports.
    public var websocketConnectTimeoutMs: Int?
    /// v0.70.1: provider SDK max retries. Forwarded to provider SDK retry config.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        samplingParams: [String: AnyCodable]? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        transport: Transport? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: AnyCodable]? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        websocketConnectTimeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.samplingParams = samplingParams
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.transport = transport
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.headers = headers
        self.onPayload = onPayload
        self.maxRetryDelayMs = maxRetryDelayMs
        self.metadata = metadata
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.websocketConnectTimeoutMs = websocketConnectTimeoutMs
        self.maxRetries = maxRetries
    }
}

public struct SimpleStreamOptions: Sendable {
    public var temperature: Double?
    public var samplingParams: [String: AnyCodable]?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    /// Optional per-request HTTP executor. Providers that cannot use it reject the request.
    public var httpClient: (any ProviderHTTPClient)?
    public var transport: Transport?
    public var reasoning: ThinkingLevel?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var thinkingBudgets: ThinkingBudgets?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: AnyCodable]?
    /// v0.67.6: invoked after each provider response is received and before stream consumption.
    public var onResponse: ResponseHandler?
    /// v0.70.1: provider SDK request timeout (ms).
    public var timeoutMs: Int?
    /// v0.79.4: WebSocket connection/open handshake timeout for providers with WebSocket transports.
    public var websocketConnectTimeoutMs: Int?
    /// v0.70.1: provider SDK max retries.
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        samplingParams: [String: AnyCodable]? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        transport: Transport? = nil,
        reasoning: ThinkingLevel? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: AnyCodable]? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        websocketConnectTimeoutMs: Int? = nil,
        maxRetries: Int? = nil
    ) {
        self.temperature = temperature
        self.samplingParams = samplingParams
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
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
        self.websocketConnectTimeoutMs = websocketConnectTimeoutMs
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
public typealias ImagesResponseHandler = @Sendable (ResponseSnapshot) -> Void

/// v0.67.6: thinking display mode for Anthropic and Bedrock. Defaults to `summarized`
/// so Opus 4.7 / Mythos Preview keep returning thinking text. Set to `omitted` to skip
/// thinking streaming for faster time-to-first-text-token.
public enum ThinkingDisplay: String, Sendable {
    case summarized
    case omitted
}

public enum OpenAICompatMaxTokensField: String, Sendable, Codable {
    case maxCompletionTokens = "max_completion_tokens"
    case maxTokens = "max_tokens"
}

public enum OpenAICompatThinkingFormat: String, Sendable, Codable {
    case openai
    case zai
    case qwen
    case chatTemplate = "chat-template"
    case qwenChatTemplate = "qwen-chat-template"
    case openrouter
    /// v0.70.1: DeepSeek V4 sends `thinking: { type: "enabled" }` plus `reasoning_effort` and
    /// expects `reasoning_content` on replayed assistant messages.
    case deepseek
    case together
    /// Baseten uses configurable `chat_template_args` and `reasoning_effort` when supported.
    case baseten
    case stringThinking = "string-thinking"
    case antLing = "ant-ling"
}

/// A JSON-compatible value for an OpenAI chat-template kwarg.
public enum ChatTemplateKwargValue: Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    /// Resolves from Pi's requested thinking state. `omitWhenOff` only applies to effort.
    case variable(ChatTemplateKwargVariable, omitWhenOff: Bool = false)

    private enum VariableCodingKeys: String, CodingKey {
        case variable = "$var"
        case omitWhenOff
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            let container = try decoder.container(keyedBy: VariableCodingKeys.self)
            self = .variable(
                try container.decode(ChatTemplateKwargVariable.self, forKey: .variable),
                omitWhenOff: try container.decodeIfPresent(Bool.self, forKey: .omitWhenOff) ?? false
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .variable(let variable, let omitWhenOff):
            var container = encoder.container(keyedBy: VariableCodingKeys.self)
            try container.encode(variable, forKey: .variable)
            if omitWhenOff {
                try container.encode(true, forKey: .omitWhenOff)
            }
        }
    }
}

public enum ChatTemplateKwargVariable: String, Sendable, Codable {
    case thinkingEnabled = "thinking.enabled"
    case thinkingEffort = "thinking.effort"
}

/// v0.68.0: opt-in cache_control formats for OpenAI-compatible providers that expose
/// Anthropic-style prompt caching via `cache_control` markers (e.g., OpenCode/OpenCode Go
/// Qwen 3.5/3.6 Plus).
public enum OpenAICompatCacheControlFormat: String, Sendable, Codable {
    case anthropic
}

public enum SessionAffinityFormat: String, Sendable, Codable, Equatable {
    case openai
    case openaiNosession = "openai-nosession"
    case openrouter
}

public enum DeferredToolsMode: String, Sendable, Codable, Equatable {
    case kimi
}

/// v0.67.0: full OpenRouter provider-selection routing.
///
/// See https://openrouter.ai/docs/guides/routing/provider-selection for upstream docs.
/// All fields map directly to the JSON payload OpenRouter expects under `provider: { ... }`.
public struct OpenRouterRouting: Sendable, Codable {
    /// Whether to allow backup providers to serve requests. Default: true.
    public var allowFallbacks: Bool?
    /// Whether to filter providers to only those that support all parameters in the request.
    public var requireParameters: Bool?
    /// "allow" (default): permit providers that may store/train on data.
    /// "deny": only use providers that don't collect user data.
    public var dataCollection: String?
    /// Restrict routing to only ZDR (Zero Data Retention) endpoints.
    public var zdr: Bool?
    /// Restrict routing to only models that allow text distillation.
    public var enforceDistillableText: Bool?
    /// Ordered list of provider names/slugs to try in sequence, falling back if unavailable.
    public var order: [String]?
    /// List of provider names/slugs exclusively allowed for this request.
    public var only: [String]?
    /// List of provider names/slugs to skip.
    public var ignore: [String]?
    /// Quantization levels to filter by (e.g., "fp16", "bf16", "fp8", "int8", "int4").
    public var quantizations: [String]?
    /// Sorting strategy. String form ("price" / "throughput" / "latency") or structured.
    public var sort: OpenRouterRoutingSort?
    /// Maximum price per million tokens (USD).
    public var maxPrice: OpenRouterRoutingPrice?
    /// Preferred minimum throughput (tokens/second). Number → applies to p50.
    public var preferredMinThroughput: OpenRouterRoutingPercentile?
    /// Preferred maximum latency (seconds). Number → applies to p50.
    public var preferredMaxLatency: OpenRouterRoutingPercentile?

    public init(
        allowFallbacks: Bool? = nil,
        requireParameters: Bool? = nil,
        dataCollection: String? = nil,
        zdr: Bool? = nil,
        enforceDistillableText: Bool? = nil,
        order: [String]? = nil,
        only: [String]? = nil,
        ignore: [String]? = nil,
        quantizations: [String]? = nil,
        sort: OpenRouterRoutingSort? = nil,
        maxPrice: OpenRouterRoutingPrice? = nil,
        preferredMinThroughput: OpenRouterRoutingPercentile? = nil,
        preferredMaxLatency: OpenRouterRoutingPercentile? = nil
    ) {
        self.allowFallbacks = allowFallbacks
        self.requireParameters = requireParameters
        self.dataCollection = dataCollection
        self.zdr = zdr
        self.enforceDistillableText = enforceDistillableText
        self.order = order
        self.only = only
        self.ignore = ignore
        self.quantizations = quantizations
        self.sort = sort
        self.maxPrice = maxPrice
        self.preferredMinThroughput = preferredMinThroughput
        self.preferredMaxLatency = preferredMaxLatency
    }

    private enum CodingKeys: String, CodingKey {
        case allowFallbacks = "allow_fallbacks"
        case requireParameters = "require_parameters"
        case dataCollection = "data_collection"
        case zdr
        case enforceDistillableText = "enforce_distillable_text"
        case order
        case only
        case ignore
        case quantizations
        case sort
        case maxPrice = "max_price"
        case preferredMinThroughput = "preferred_min_throughput"
        case preferredMaxLatency = "preferred_max_latency"
    }
}

/// Sorting metric. Either a bare string ("price"/"throughput"/"latency") or a structured
/// object with `by` and `partition`.
public enum OpenRouterRoutingSort: Sendable, Codable {
    case named(String)
    case structured(by: String?, partition: String?)

    private enum CodingKeys: String, CodingKey {
        case by
        case partition
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            self = .named(value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .structured(
            by: try container.decodeIfPresent(String.self, forKey: .by),
            partition: try container.decodeIfPresent(String.self, forKey: .partition)
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .named(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .structured(let by, let partition):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(by, forKey: .by)
            try container.encodeIfPresent(partition, forKey: .partition)
        }
    }
}

public struct OpenRouterRoutingPrice: Sendable, Codable {
    public var prompt: Double?
    public var completion: Double?
    public var image: Double?
    public var audio: Double?
    public var request: Double?

    public init(prompt: Double? = nil, completion: Double? = nil, image: Double? = nil, audio: Double? = nil, request: Double? = nil) {
        self.prompt = prompt
        self.completion = completion
        self.image = image
        self.audio = audio
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case completion
        case image
        case audio
        case request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try Self.decodePrice(.prompt, from: container)
        completion = try Self.decodePrice(.completion, from: container)
        image = try Self.decodePrice(.image, from: container)
        audio = try Self.decodePrice(.audio, from: container)
        request = try Self.decodePrice(.request, from: container)
    }

    private static func decodePrice(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

/// Numeric value applies to p50; structured form lets callers set per-percentile cutoffs.
public enum OpenRouterRoutingPercentile: Sendable, Codable {
    case scalar(Double)
    case percentiles(p50: Double?, p75: Double?, p90: Double?, p99: Double?)

    private enum CodingKeys: String, CodingKey {
        case p50
        case p75
        case p90
        case p99
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(Double.self) {
            self = .scalar(value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .percentiles(
            p50: try container.decodeIfPresent(Double.self, forKey: .p50),
            p75: try container.decodeIfPresent(Double.self, forKey: .p75),
            p90: try container.decodeIfPresent(Double.self, forKey: .p90),
            p99: try container.decodeIfPresent(Double.self, forKey: .p99)
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .scalar(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .percentiles(let p50, let p75, let p90, let p99):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(p50, forKey: .p50)
            try container.encodeIfPresent(p75, forKey: .p75)
            try container.encodeIfPresent(p90, forKey: .p90)
            try container.encodeIfPresent(p99, forKey: .p99)
        }
    }
}

public struct VercelGatewayRouting: Sendable, Codable {
    public var only: [String]?
    public var order: [String]?
    public var allowFallbacks: Bool?

    public init(only: [String]? = nil, order: [String]? = nil, allowFallbacks: Bool? = nil) {
        self.only = only
        self.order = order
        self.allowFallbacks = allowFallbacks
    }
}

public struct OpenAICompat: Sendable, Codable {
    public var supportsStore: Bool?
    public var supportsDeveloperRole: Bool?
    public var supportsReasoningEffort: Bool?
    public var supportsUsageInStreaming: Bool?
    /// Whether streamed responses include `finish_reason`.
    /// When false, Pi infers `stop` or `toolUse` when the stream ends. Default: true.
    public var supportsFinishReason: Bool?
    public var supportsTemperature: Bool?
    public var maxTokensField: OpenAICompatMaxTokensField?
    public var requiresToolResultName: Bool?
    public var requiresAssistantAfterToolResult: Bool?
    public var requiresThinkingAsText: Bool?
    public var requiresMistralToolIds: Bool?
    public var thinkingFormat: OpenAICompatThinkingFormat?
    /// Kwargs sent as `chat_template_kwargs` for the `.chatTemplate` thinking format.
    public var chatTemplateKwargs: [String: ChatTemplateKwargValue]?
    /// Arguments to send as `chat_template_args` when `thinkingFormat` is `.baseten`.
    public var chatTemplateArgs: [String: ChatTemplateKwargValue]?
    public var openRouterRouting: OpenRouterRouting?
    public var vercelGatewayRouting: VercelGatewayRouting?
    /// Whether the provider supports top-level `thinking_token_budget` to cap reasoning tokens
    /// when it uses vLLM. Default: false.
    public var supportsThinkingTokenBudget: Bool?
    /// Whether to emit OpenAI custom tools with Lark or regex grammar formats.
    /// When false, grammar-constrained tools use normal function tools. Default: false.
    /// The generated model catalog enables this option for capable models.
    public var supportsOpenAIGrammarTools: Bool?
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
    /// v0.79.4 compat metadata retained from upstream generated model data.
    public var supportsCacheControlOnTools: Bool?
    /// Whether the provider supports strict JSON-schema function tools.
    public var supportsStrictTools: Bool?
    public var forceAdaptiveThinking: Bool?
    public var zaiToolStream: Bool?
    public var allowEmptySignature: Bool?
    public var deferredToolsMode: DeferredToolsMode?
    public var sessionAffinityFormat: SessionAffinityFormat?
    public var supportsToolSearch: Bool?
    /// Whether the model accepts `prompt_cache_options` for OpenAI GPT-5.6+ explicit prompt caching.
    /// Older OpenAI models reject this parameter. Default: false.
    public var supportsExplicitPromptCacheMode: Bool?
    public var supportsToolReferences: Bool?

    public init(
        supportsStore: Bool? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsUsageInStreaming: Bool? = nil,
        supportsFinishReason: Bool? = nil,
        supportsTemperature: Bool? = nil,
        maxTokensField: OpenAICompatMaxTokensField? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        requiresThinkingAsText: Bool? = nil,
        requiresMistralToolIds: Bool? = nil,
        thinkingFormat: OpenAICompatThinkingFormat? = nil,
        chatTemplateKwargs: [String: ChatTemplateKwargValue]? = nil,
        chatTemplateArgs: [String: ChatTemplateKwargValue]? = nil,
        openRouterRouting: OpenRouterRouting? = nil,
        vercelGatewayRouting: VercelGatewayRouting? = nil,
        supportsThinkingTokenBudget: Bool? = nil,
        supportsOpenAIGrammarTools: Bool? = nil,
        supportsStrictMode: Bool? = nil,
        reasoningEffortMap: [ThinkingLevel: String]? = nil,
        supportsLongCacheRetention: Bool? = nil,
        sendSessionIdHeader: Bool? = nil,
        supportsEagerToolInputStreaming: Bool? = nil,
        cacheControlFormat: OpenAICompatCacheControlFormat? = nil,
        sendSessionAffinityHeaders: Bool? = nil,
        requiresReasoningContentOnAssistantMessages: Bool? = nil,
        supportsCacheControlOnTools: Bool? = nil,
        supportsStrictTools: Bool? = nil,
        forceAdaptiveThinking: Bool? = nil,
        zaiToolStream: Bool? = nil,
        allowEmptySignature: Bool? = nil,
        deferredToolsMode: DeferredToolsMode? = nil,
        sessionAffinityFormat: SessionAffinityFormat? = nil,
        supportsToolSearch: Bool? = nil,
        supportsExplicitPromptCacheMode: Bool? = nil,
        supportsToolReferences: Bool? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.supportsFinishReason = supportsFinishReason
        self.supportsTemperature = supportsTemperature
        self.maxTokensField = maxTokensField
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresMistralToolIds = requiresMistralToolIds
        self.thinkingFormat = thinkingFormat
        self.chatTemplateKwargs = chatTemplateKwargs
        self.chatTemplateArgs = chatTemplateArgs
        self.openRouterRouting = openRouterRouting
        self.vercelGatewayRouting = vercelGatewayRouting
        self.supportsThinkingTokenBudget = supportsThinkingTokenBudget
        self.supportsOpenAIGrammarTools = supportsOpenAIGrammarTools
        self.supportsStrictMode = supportsStrictMode
        self.reasoningEffortMap = reasoningEffortMap
        self.supportsLongCacheRetention = supportsLongCacheRetention
        self.sendSessionIdHeader = sendSessionIdHeader
        self.supportsEagerToolInputStreaming = supportsEagerToolInputStreaming
        self.cacheControlFormat = cacheControlFormat
        self.sendSessionAffinityHeaders = sendSessionAffinityHeaders
        self.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
        self.supportsCacheControlOnTools = supportsCacheControlOnTools
        self.supportsStrictTools = supportsStrictTools
        self.forceAdaptiveThinking = forceAdaptiveThinking
        self.zaiToolStream = zaiToolStream
        self.allowEmptySignature = allowEmptySignature
        self.deferredToolsMode = deferredToolsMode
        self.sessionAffinityFormat = sessionAffinityFormat
        self.supportsToolSearch = supportsToolSearch
        self.supportsExplicitPromptCacheMode = supportsExplicitPromptCacheMode
        self.supportsToolReferences = supportsToolReferences
    }
}

public protocol ModelCostRates: Sendable {
    var input: Double { get }
    var output: Double { get }
    var cacheRead: Double { get }
    var cacheWrite: Double { get }
}

public struct ModelCostTier: ModelCostRates, Sendable, Codable {
    public var inputTokensAbove: Int
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(inputTokensAbove: Int, input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.inputTokensAbove = inputTokensAbove
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct ModelCost: ModelCostRates, Sendable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var tiers: [ModelCostTier]?

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tiers = nil
    }

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, tiers: [ModelCostTier]? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.tiers = tiers
    }
}

public enum ModelInput: String, Sendable, Codable {
    case text
    case image
}

public struct Model: Sendable, Codable {
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
    /// Arbitrary sampling parameters merged into the request body as-is, after the named request
    /// fields, so keys here override them. Lets custom OpenAI-compatible servers (llama.cpp, vLLM,
    /// SGLang, ...) receive parameters pi does not model, e.g. `top_p`, `top_k`, `min_p`,
    /// `repetition_penalty`. Merged over `Model.samplingParams` per key. Only applied by
    /// OpenAI-compatible adapters (completions, responses, Azure responses); other APIs ignore it.
    public let samplingParams: [String: AnyCodable]?
    public let headers: ProviderHeaders?
    public let compat: OpenAICompat?
    public let thinkingLevelMap: ThinkingLevelMap?

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
        samplingParams: [String: AnyCodable]? = nil,
        headers: ProviderHeaders? = nil,
        compat: OpenAICompat? = nil,
        thinkingLevelMap: ThinkingLevelMap? = nil
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
        self.samplingParams = samplingParams
        self.headers = headers
        self.compat = compat
        self.thinkingLevelMap = thinkingLevelMap
    }
}

public struct ImagesModel: Sendable {
    public let id: String
    public let name: String
    public let api: ImagesApi
    public let provider: ImagesProvider
    public let baseUrl: String
    public let input: [ModelInput]
    public let output: [ModelInput]
    public let cost: ModelCost
    public let headers: ProviderHeaders?

    public init(
        id: String,
        name: String,
        api: ImagesApi,
        provider: ImagesProvider,
        baseUrl: String,
        input: [ModelInput],
        output: [ModelInput],
        cost: ModelCost,
        headers: ProviderHeaders? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseUrl = baseUrl
        self.input = input
        self.output = output
        self.cost = cost
        self.headers = headers
    }
}

public struct ImagesOptions: Sendable {
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var onPayload: PayloadHandler?
    public var onResponse: ImagesResponseHandler?
    public var headers: ProviderHeaders?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var metadata: [String: AnyCodable]?

    public init(
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ImagesResponseHandler? = nil,
        headers: ProviderHeaders? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.headers = headers
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.metadata = metadata
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
    /// Reasoning/thinking tokens reported by the provider; a subset of `output`.
    public var reasoning: Int?
    public var totalTokens: Int
    public var cost: UsageCost

    public init(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int? = nil,
        totalTokens: Int,
        cost: UsageCost = UsageCost()
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

public enum StopReason: String, Sendable {
    case pending
    case stop
    case length
    case toolUse
    case error
    case aborted
    case deferred
}

public struct DeferredHandle: Sendable {
    public var provider: String
    public var modelId: String
    public var api: String
    /// Provider token, such as a response id or batch id plus row id.
    public var id: String
    /// Unix timestamp in milliseconds.
    public var expiresAt: Int64?
    /// Poll delay in milliseconds.
    public var pollAfterMs: Int?
    /// Provider conversion data required to reconstruct the final assistant message.
    public var data: AnyCodable?

    public init(
        provider: String,
        modelId: String,
        api: String,
        id: String,
        expiresAt: Int64? = nil,
        pollAfterMs: Int? = nil,
        data: AnyCodable? = nil
    ) {
        self.provider = provider
        self.modelId = modelId
        self.api = api
        self.id = id
        self.expiresAt = expiresAt
        self.pollAfterMs = pollAfterMs
        self.data = data
    }
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

public struct ImagesContext: Sendable {
    public var input: [ContentBlock]

    public init(input: [ContentBlock]) {
        self.input = input
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

public struct AssistantMessageDiagnostic: Sendable, Equatable {
    public var type: String
    public var timestamp: Int64
    public var details: [String: AnyCodable]

    public init(type: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000), details: [String: AnyCodable]) {
        self.type = type
        self.timestamp = timestamp
        self.details = details
    }
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
    public var deferred: DeferredHandle?
    public var errorMessage: String?
    /// Provider's own unmapped stop-reason string, preserved for diagnostics.
    public var rawStopReason: String?
    public var diagnostics: [AssistantMessageDiagnostic]?
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
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        deferred: DeferredHandle? = nil,
        rawStopReason: String? = nil,
        diagnostics: [AssistantMessageDiagnostic]? = nil
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.responseId = responseId
        self.usage = usage
        self.stopReason = stopReason
        self.deferred = deferred
        self.errorMessage = errorMessage
        self.rawStopReason = rawStopReason
        self.diagnostics = diagnostics
        self.timestamp = timestamp
    }
}

public struct AssistantImages: Sendable {
    public var api: ImagesApi
    public var provider: ImagesProvider
    public var model: String
    public var responseId: String?
    public var output: [ContentBlock]
    public var usage: Usage?
    public var stopReason: StopReason
    public var errorMessage: String?
    public var timestamp: Int64

    public init(
        api: ImagesApi,
        provider: ImagesProvider,
        model: String,
        responseId: String? = nil,
        output: [ContentBlock] = [],
        usage: Usage? = nil,
        stopReason: StopReason,
        errorMessage: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.api = api
        self.provider = provider
        self.model = model
        self.responseId = responseId
        self.output = output
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
    /// Usage from the tool execution itself, if available. Not part of main LLM context accounting.
    public var usage: Usage?
    public var addedToolNames: [String]?
    public var isError: Bool
    public var timestamp: Int64

    public init(
        toolCallId: String,
        toolName: String,
        content: [ContentBlock],
        details: AnyCodable? = nil,
        usage: Usage? = nil,
        addedToolNames: [String]? = nil,
        isError: Bool,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.usage = usage
        self.addedToolNames = addedToolNames
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

public enum GrammarFormat: String, Sendable, Hashable {
    case openAILark = "openai_lark"
    case openAIRegex = "openai_regex"
}

public enum ConstrainedSamplingStrictness: String, Sendable {
    case prefer
    case require
}

/// Provider-side constrained sampling for a tool.
/// `.disabled` corresponds to upstream's explicit `constrainedSampling: false`, which opts a tool
/// out even when the model supports constrained sampling.
public enum ConstrainedSampling: Sendable {
    case disabled
    case jsonSchema(strict: ConstrainedSamplingStrictness)
    case grammar(variants: [GrammarFormat: String])
}

public struct AITool: Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]
    public var constrainedSampling: ConstrainedSampling?

    public init(
        name: String,
        description: String,
        parameters: [String: AnyCodable],
        constrainedSampling: ConstrainedSampling? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.constrainedSampling = constrainedSampling
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
    public var samplingParams: [String: AnyCodable]?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var toolChoice: OpenAIToolChoice?
    public var reasoningEffort: ThinkingLevel?
    public var thinkingBudgets: ThinkingBudgets?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        samplingParams: [String: AnyCodable]? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        toolChoice: OpenAIToolChoice? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        thinkingBudgets: ThinkingBudgets? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.samplingParams = samplingParams
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
        self.thinkingBudgets = thinkingBudgets
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.headers = headers
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
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
    public var samplingParams: [String: AnyCodable]?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var cacheRetention: CacheRetention?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAIReasoningSummary?
    public var serviceTier: OpenAIServiceTier?
    public var sessionId: String?
    public var transport: Transport?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var websocketConnectTimeoutMs: Int?

    public init(
        temperature: Double? = nil,
        samplingParams: [String: AnyCodable]? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        cacheRetention: CacheRetention? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        serviceTier: OpenAIServiceTier? = nil,
        sessionId: String? = nil,
        transport: Transport? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil,
        websocketConnectTimeoutMs: Int? = nil
    ) {
        self.temperature = temperature
        self.samplingParams = samplingParams
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.cacheRetention = cacheRetention
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.serviceTier = serviceTier
        self.sessionId = sessionId
        self.transport = transport
        self.headers = headers
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.websocketConnectTimeoutMs = websocketConnectTimeoutMs
    }
}

public struct AzureOpenAIResponsesOptions: Sendable {
    public var temperature: Double?
    public var samplingParams: [String: AnyCodable]?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAIReasoningSummary?
    public var sessionId: String?
    public var headers: ProviderHeaders?
    public var azureApiVersion: String?
    public var azureResourceName: String?
    public var azureBaseUrl: String?
    public var azureDeploymentName: String?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        samplingParams: [String: AnyCodable]? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAIReasoningSummary? = nil,
        sessionId: String? = nil,
        headers: ProviderHeaders? = nil,
        azureApiVersion: String? = nil,
        azureResourceName: String? = nil,
        azureBaseUrl: String? = nil,
        azureDeploymentName: String? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.samplingParams = samplingParams
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.sessionId = sessionId
        self.headers = headers
        self.azureApiVersion = azureApiVersion
        self.azureResourceName = azureResourceName
        self.azureBaseUrl = azureBaseUrl
        self.azureDeploymentName = azureDeploymentName
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }
}

public struct OpenAICodexResponsesOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var reasoningEffort: ThinkingLevel?
    public var reasoningSummary: OpenAICodexReasoningSummary?
    public var textVerbosity: OpenAICodexTextVerbosity?
    public var include: [String]?
    public var cacheRetention: CacheRetention?
    public var sessionId: String?
    public var transport: Transport?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var websocketConnectTimeoutMs: Int?
    /// v0.67.1: forward configured serviceTier to Codex Responses requests so users can choose
    /// flex / priority pricing tiers. v0.67.67: trust the explicitly requested tier when the API
    /// echoes the default — keeps cost accounting aligned with the caller-selected tier.
    public var serviceTier: OpenAIServiceTier?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        reasoningEffort: ThinkingLevel? = nil,
        reasoningSummary: OpenAICodexReasoningSummary? = nil,
        textVerbosity: OpenAICodexTextVerbosity? = nil,
        include: [String]? = nil,
        cacheRetention: CacheRetention? = nil,
        sessionId: String? = nil,
        transport: Transport? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        serviceTier: OpenAIServiceTier? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil,
        websocketConnectTimeoutMs: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.textVerbosity = textVerbosity
        self.include = include
        self.cacheRetention = cacheRetention
        self.sessionId = sessionId
        self.transport = transport
        self.headers = headers
        self.onPayload = onPayload
        self.serviceTier = serviceTier
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.websocketConnectTimeoutMs = websocketConnectTimeoutMs
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
    public var httpClient: (any ProviderHTTPClient)?
    public var headers: ProviderHeaders?
    public var toolChoice: String?
    public var thinking: ThinkingConfig?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        headers: ProviderHeaders? = nil,
        toolChoice: String? = nil,
        thinking: ThinkingConfig? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.headers = headers
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }
}

public struct GoogleGeminiCliOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var maxRetryDelayMs: Int?
    public var headers: ProviderHeaders?
    public var toolChoice: String?
    public var thinking: GoogleOptions.ThinkingConfig?
    public var sessionId: String?
    public var projectId: String?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        maxRetryDelayMs: Int? = nil,
        headers: ProviderHeaders? = nil,
        toolChoice: String? = nil,
        thinking: GoogleOptions.ThinkingConfig? = nil,
        sessionId: String? = nil,
        projectId: String? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil
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
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public struct GoogleVertexOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var headers: ProviderHeaders?
    public var toolChoice: String?
    public var thinking: GoogleOptions.ThinkingConfig?
    public var project: String?
    public var location: String?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        headers: ProviderHeaders? = nil,
        toolChoice: String? = nil,
        thinking: GoogleOptions.ThinkingConfig? = nil,
        project: String? = nil,
        location: String? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.headers = headers
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.project = project
        self.location = location
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
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
    public var httpClient: (any ProviderHTTPClient)?
    public var thinkingEnabled: Bool?
    public var thinkingBudgetTokens: Int?
    /// Adaptive thinking effort level. When set on models that support adaptive
    /// thinking (e.g. Opus 4.6, Sonnet 4.6, Opus 4.7), this takes precedence over
    /// `thinkingBudgetTokens` and maps to an appropriate token budget. `.max` requests
    /// unconstrained adaptive thinking where supported.
    public var effort: ThinkingLevel?
    public var interleavedThinking: Bool?
    public var toolChoice: AnthropicToolChoice?
    public var metadata: [String: AnyCodable]?
    public var headers: ProviderHeaders?
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
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        thinkingEnabled: Bool? = nil,
        thinkingBudgetTokens: Int? = nil,
        effort: ThinkingLevel? = nil,
        interleavedThinking: Bool? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        metadata: [String: AnyCodable]? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        thinkingDisplay: ThinkingDisplay? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
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
        self.maxRetryDelayMs = maxRetryDelayMs
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
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    /// v0.62.0: AWS Cost Explorer split cost allocation tags forwarded as Converse `requestMetadata`.
    public var requestMetadata: [String: String]?
    /// v0.67.67: Bedrock bearer-token auth. Bypasses SigV4 when present unless
    /// `AWS_BEDROCK_SKIP_AUTH=1` is set.
    public var bearerToken: String?
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
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        requestMetadata: [String: String]? = nil,
        bearerToken: String? = nil,
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
        self.bearerToken = bearerToken
        self.thinkingDisplay = thinkingDisplay
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
    }
}

public struct MistralOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    /// "auto" | "none" | "any" | "required" | { type: function, name: ... }
    public var toolChoice: AnyCodable?
    /// "reasoning" for Magistral models that use prompt-mode reasoning.
    public var promptMode: String?
    /// "high" | "none" for mistral-small-2603 / mistral-small-latest.
    public var reasoningEffort: String?
    public var sessionId: String?
    public var headers: ProviderHeaders?
    public var onPayload: PayloadHandler?
    public var onResponse: ResponseHandler?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?

    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        signal: CancellationToken? = nil,
        apiKey: String? = nil,
        httpClient: (any ProviderHTTPClient)? = nil,
        toolChoice: AnyCodable? = nil,
        promptMode: String? = nil,
        reasoningEffort: String? = nil,
        sessionId: String? = nil,
        headers: ProviderHeaders? = nil,
        onPayload: PayloadHandler? = nil,
        onResponse: ResponseHandler? = nil,
        timeoutMs: Int? = nil,
        maxRetries: Int? = nil,
        maxRetryDelayMs: Int? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.toolChoice = toolChoice
        self.promptMode = promptMode
        self.reasoningEffort = reasoningEffort
        self.sessionId = sessionId
        self.headers = headers
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
    }
}

public final class CancellationToken: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var handlers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = LockedState(State())

    public init() {}

    public func cancel() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.isCancelled else { return [] }
            state.isCancelled = true
            let handlers = Array(state.handlers.values)
            state.handlers.removeAll()
            return handlers
        }
        for handler in handlers {
            handler()
        }
    }

    public var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UUID? {
        var invokeImmediately = false
        let id = state.withLock { state -> UUID? in
            guard !state.isCancelled else {
                invokeImmediately = true
                return nil
            }
            let id = UUID()
            state.handlers[id] = handler
            return id
        }
        if invokeImmediately {
            handler()
        }
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        state.withLock { state in
            state.handlers.removeValue(forKey: id)
        }
    }
}
