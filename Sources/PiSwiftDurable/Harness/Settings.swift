import PiSwiftAI
import PiSwiftChord

/// Provider request options stored with a conversation.
public struct ConversationStreamOptions: Sendable, Codable {
    /// The model transport selected for the request.
    public var transport: Transport?
    /// The model request timeout in milliseconds.
    public var timeoutMs: Int?
    /// The maximum number of retry attempts.
    public var maxRetries: Int?
    /// The maximum retry delay in milliseconds.
    public var maxRetryDelayMs: Int?
    /// Additional headers sent with model requests.
    public var headers: [String: String]?
    /// Application metadata sent with a model request.
    public var metadata: JSONObject?
    /// The provider cache retention policy.
    public var cacheRetention: CacheRetention?
    /// The pending deferred response state, when present.
    public var deferred: DeferredRequest?
    /// Selects provider request overrides for this conversation.
    public init(transport: Transport? = nil, timeoutMs: Int? = nil, maxRetries: Int? = nil,
                maxRetryDelayMs: Int? = nil, headers: [String: String]? = nil, metadata: JSONObject? = nil,
                cacheRetention: CacheRetention? = nil, deferred: DeferredRequest? = nil) {
        self.transport = transport; self.timeoutMs = timeoutMs; self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs; self.headers = headers; self.metadata = metadata
        self.cacheRetention = cacheRetention; self.deferred = deferred
    }
    private enum CodingKeys: String, CodingKey {
        case transport, timeoutMs, maxRetries, maxRetryDelayMs, headers, metadata, cacheRetention, deferred
    }
    private struct DeferredValue: Codable { let window: DeferredWindow? }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let transport = try c.decodeIfPresent(String.self, forKey: .transport)
        if let transport, Transport(rawValue: transport) == nil {
            throw DecodingError.dataCorruptedError(forKey: .transport, in: c, debugDescription: "Unknown transport")
        }
        let cache = try c.decodeIfPresent(String.self, forKey: .cacheRetention)
        if let cache, CacheRetention(rawValue: cache) == nil {
            throw DecodingError.dataCorruptedError(forKey: .cacheRetention, in: c, debugDescription: "Unknown cache retention")
        }
        self.transport = transport.flatMap(Transport.init(rawValue:))
        timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries)
        maxRetryDelayMs = try c.decodeIfPresent(Int.self, forKey: .maxRetryDelayMs)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        metadata = try c.decodeIfPresent(JSONObject.self, forKey: .metadata)
        cacheRetention = cache.flatMap(CacheRetention.init(rawValue:))
        deferred = try c.decodeIfPresent(DeferredValue.self, forKey: .deferred).map { DeferredRequest(window: $0.window) }
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(transport?.rawValue, forKey: .transport)
        try c.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try c.encodeIfPresent(maxRetryDelayMs, forKey: .maxRetryDelayMs)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(cacheRetention?.rawValue, forKey: .cacheRetention)
        try c.encodeIfPresent(deferred.map { DeferredValue(window: $0.window) }, forKey: .deferred)
    }
}

/// Resolved retry limits and delays for model requests.
public struct ConversationRetryPolicy: Sendable, Equatable, Codable {
    /// Whether this policy is active.
    public var enabled: Bool
    /// The maximum number of retry attempts.
    public var maxRetries: Int
    /// Initial retry delay in milliseconds.
    public var baseDelayMs: Int64
    /// The maximum provider-requested retry delay in milliseconds.
    public var maxAgentDelayMs: Int64?
    /// Sets concrete retry limits and delay values.
    public init(enabled: Bool = true, maxRetries: Int = 3, baseDelayMs: Int64 = 2000, maxAgentDelayMs: Int64? = 60000) {
        self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs; self.maxAgentDelayMs = maxAgentDelayMs
    }
}
/// Optional request retry settings. Absent fields use the default policy.
public struct RetryPolicyOverrides: Sendable {
    /// Whether this policy is active.
    public var enabled: Bool?
    /// The maximum number of retry attempts.
    public var maxRetries: Int?
    /// Initial retry delay in milliseconds.
    public var baseDelayMs: Int64?
    /// The maximum provider-requested retry delay in milliseconds.
    public var maxAgentDelayMs: Int64?
    /// Selects optional retry policy fields to replace their defaults.
    public init(enabled: Bool? = nil, maxRetries: Int? = nil, baseDelayMs: Int64? = nil, maxAgentDelayMs: Int64? = nil) {
        self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs; self.maxAgentDelayMs = maxAgentDelayMs
    }
}
/// Resolved thresholds and token budgets for automatic compaction.
public struct CompactionPolicy: Sendable, Equatable, Codable {
    /// Whether this policy is active.
    public var enabled: Bool
    /// Token budget left free for the next model response.
    public var reserveTokens: Int
    /// Token budget for recent context retained after compaction.
    public var keepRecentTokens: Int
    /// Token budget reserved for a background compaction.
    public var backgroundTokens: Int
    /// Sets concrete token budgets and the automatic compaction switch.
    public init(enabled: Bool = true, reserveTokens: Int = 16384, keepRecentTokens: Int = 20000, backgroundTokens: Int = 32768) {
        self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens; self.backgroundTokens = backgroundTokens
    }
}
/// Optional compaction settings. Absent fields use the harness defaults.
public struct CompactionPolicyOverrides: Sendable {
    /// Whether this policy is active.
    public var enabled: Bool?
    /// Token budget left free for the next model response.
    public var reserveTokens: Int?
    /// Token budget for recent context retained after compaction.
    public var keepRecentTokens: Int?
    /// Token budget reserved for a background compaction.
    public var backgroundTokens: Int?
    /// Selects optional compaction policy fields to replace their defaults.
    public init(enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil, backgroundTokens: Int? = nil) {
        self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens; self.backgroundTokens = backgroundTokens
    }
}
/// Publication intervals for partial model messages and tool output.
public struct ProgressPolicy: Sendable, Equatable, Codable {
    /// Minimum interval between partial model message publications, in milliseconds.
    public var partialIntervalMs: Int64
    /// Minimum interval between tool output publications, in milliseconds.
    public var outputIntervalMs: Int64
    /// Sets the intervals for partial-message and tool-output publication.
    public init(partialIntervalMs: Int64 = 100, outputIntervalMs: Int64 = 100) {
        self.partialIntervalMs = partialIntervalMs; self.outputIntervalMs = outputIntervalMs
    }
}
/// Optional publication intervals. Absent fields use the default policy.
public struct ProgressPolicyOverrides: Sendable {
    /// Minimum interval between partial model message publications, in milliseconds.
    public var partialIntervalMs: Int64?
    /// Minimum interval between tool output publications, in milliseconds.
    public var outputIntervalMs: Int64?
    /// Selects optional publication intervals to replace their defaults.
    public init(partialIntervalMs: Int64? = nil, outputIntervalMs: Int64? = nil) {
        self.partialIntervalMs = partialIntervalMs; self.outputIntervalMs = outputIntervalMs
    }
}
/// The default retry policy used when the host supplies no override.
public let defaultRetryPolicy = ConversationRetryPolicy()
/// The default compaction policy used when the host supplies no override.
public let defaultCompactionPolicy = CompactionPolicy()
/// The default progress policy used when the host supplies no override.
public let defaultProgressPolicy = ProgressPolicy()

/// Optional host settings. Unspecified fields use the default policies.
public struct HarnessSettings: Sendable {
    /// The default extension selection for conversations with no stored selection.
    public var extensions: [Extension]?
    /// Optional host settings for model transport and request limits.
    public var stream: ConversationStreamOptions?
    /// The current scheduled request retry, when present.
    public var retry: RetryPolicyOverrides?
    /// Host overrides for automatic compaction thresholds.
    public var compaction: CompactionPolicyOverrides?
    /// Host overrides for message and output publication intervals.
    public var progress: ProgressPolicyOverrides?
    /// The default policy for parallel or sequential tool calls.
    public var toolExecution: ToolExecutionMode?
    /// How steering inputs are admitted at the next boundary.
    public var steeringMode: QueueMode?
    /// How queued follow-up inputs are admitted at the next boundary.
    public var followUpMode: QueueMode?
    /// How long reusable model context can remain cached, in milliseconds.
    public var contextRetentionMs: Int64?
    /// Selects host defaults and optional request, compaction, and queue policies.
    public init(extensions: [Extension]? = nil, stream: ConversationStreamOptions? = nil,
                retry: RetryPolicyOverrides? = nil, compaction: CompactionPolicyOverrides? = nil,
                progress: ProgressPolicyOverrides? = nil, toolExecution: ToolExecutionMode? = nil,
                steeringMode: QueueMode? = nil, followUpMode: QueueMode? = nil, contextRetentionMs: Int64? = nil) {
        self.extensions = extensions; self.stream = stream; self.retry = retry; self.compaction = compaction
        self.progress = progress; self.toolExecution = toolExecution; self.steeringMode = steeringMode
        self.followUpMode = followUpMode; self.contextRetentionMs = contextRetentionMs
    }
}

/// Each call reads the current host settings. Store this provider, not a resolved copy.
public struct HarnessSettingsProvider: Sendable {
    private let read: @Sendable () -> HarnessSettings?
    /// Stores a callback read each time the harness resolves live settings.
    public init(_ read: @escaping @Sendable () -> HarnessSettings?) { self.read = read }
    /// Reads the current settings callback and fills unspecified policies with defaults.
    public func resolve() -> Settings { resolveSettings(read()) }
}
/// Harness settings with concrete default retry, compaction, and progress policies.
public struct Settings: Sendable {
    /// The default extension selection used by agent resolution.
    public var extensions: [Extension]?
    /// Optional host settings for model transport and request limits.
    public var stream: ConversationStreamOptions
    /// The retry policy after host overrides and defaults are resolved.
    public var retry: ConversationRetryPolicy
    /// The compaction policy after host overrides and defaults are resolved.
    public var compaction: CompactionPolicy
    /// The publication policy after host overrides and defaults are resolved.
    public var progress: ProgressPolicy
    /// The default policy for parallel or sequential tool calls.
    public var toolExecution: ToolExecutionMode
    /// How steering inputs are admitted at the next boundary.
    public var steeringMode: QueueMode
    /// How queued follow-up inputs are admitted at the next boundary.
    public var followUpMode: QueueMode
    /// How long reusable model context can remain cached, in milliseconds.
    public var contextRetentionMs: Int64
}
/// Fills unspecified retry, compaction, and progress fields with their defaults.
public func resolveSettings(_ settings: HarnessSettings? = nil) -> Settings {
    let retry = settings?.retry
    let compact = settings?.compaction
    return Settings(extensions: settings?.extensions, stream: settings?.stream ?? .init(),
        retry: .init(enabled: retry?.enabled ?? true, maxRetries: retry?.maxRetries ?? 3,
                     baseDelayMs: retry?.baseDelayMs ?? 2000, maxAgentDelayMs: retry?.maxAgentDelayMs ?? 60000),
        compaction: .init(enabled: compact?.enabled ?? true, reserveTokens: compact?.reserveTokens ?? 16384,
                         keepRecentTokens: compact?.keepRecentTokens ?? 20000, backgroundTokens: compact?.backgroundTokens ?? 32768),
        progress: .init(partialIntervalMs: settings?.progress?.partialIntervalMs ?? 100,
                        outputIntervalMs: settings?.progress?.outputIntervalMs ?? 100),
        toolExecution: settings?.toolExecution ?? .parallel,
        steeringMode: settings?.steeringMode ?? .oneAtATime, followUpMode: settings?.followUpMode ?? .oneAtATime,
        contextRetentionMs: settings?.contextRetentionMs ?? 600000)
}
