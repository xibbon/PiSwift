import PiSwiftAI
import PiSwiftChord

public struct ConversationStreamOptions: Sendable {
    public var transport: Transport?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var headers: [String: String]?
    public var metadata: JSONObject?
    public var cacheRetention: CacheRetention?
    public var deferred: DeferredRequest?
    public init(transport: Transport? = nil, timeoutMs: Int? = nil, maxRetries: Int? = nil,
                maxRetryDelayMs: Int? = nil, headers: [String: String]? = nil, metadata: JSONObject? = nil,
                cacheRetention: CacheRetention? = nil, deferred: DeferredRequest? = nil) {
        self.transport = transport; self.timeoutMs = timeoutMs; self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs; self.headers = headers; self.metadata = metadata
        self.cacheRetention = cacheRetention; self.deferred = deferred
    }
}

public struct ConversationRetryPolicy: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var maxRetries: Int
    public var baseDelayMs: Int64
    public var maxAgentDelayMs: Int64?
    public init(enabled: Bool = true, maxRetries: Int = 3, baseDelayMs: Int64 = 2000, maxAgentDelayMs: Int64? = 60000) {
        self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs; self.maxAgentDelayMs = maxAgentDelayMs
    }
}
public struct RetryPolicyOverrides: Sendable {
    public var enabled: Bool?
    public var maxRetries: Int?
    public var baseDelayMs: Int64?
    public var maxAgentDelayMs: Int64?
    public init(enabled: Bool? = nil, maxRetries: Int? = nil, baseDelayMs: Int64? = nil, maxAgentDelayMs: Int64? = nil) {
        self.enabled = enabled; self.maxRetries = maxRetries; self.baseDelayMs = baseDelayMs; self.maxAgentDelayMs = maxAgentDelayMs
    }
}
public struct CompactionPolicy: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var reserveTokens: Int
    public var keepRecentTokens: Int
    public var backgroundTokens: Int
    public init(enabled: Bool = true, reserveTokens: Int = 16384, keepRecentTokens: Int = 20000, backgroundTokens: Int = 32768) {
        self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens; self.backgroundTokens = backgroundTokens
    }
}
public struct CompactionPolicyOverrides: Sendable {
    public var enabled: Bool?
    public var reserveTokens: Int?
    public var keepRecentTokens: Int?
    public var backgroundTokens: Int?
    public init(enabled: Bool? = nil, reserveTokens: Int? = nil, keepRecentTokens: Int? = nil, backgroundTokens: Int? = nil) {
        self.enabled = enabled; self.reserveTokens = reserveTokens; self.keepRecentTokens = keepRecentTokens; self.backgroundTokens = backgroundTokens
    }
}
public struct ProgressPolicy: Sendable, Equatable, Codable {
    public var partialIntervalMs: Int64
    public var outputIntervalMs: Int64
    public init(partialIntervalMs: Int64 = 100, outputIntervalMs: Int64 = 100) {
        self.partialIntervalMs = partialIntervalMs; self.outputIntervalMs = outputIntervalMs
    }
}
public struct ProgressPolicyOverrides: Sendable {
    public var partialIntervalMs: Int64?
    public var outputIntervalMs: Int64?
    public init(partialIntervalMs: Int64? = nil, outputIntervalMs: Int64? = nil) {
        self.partialIntervalMs = partialIntervalMs; self.outputIntervalMs = outputIntervalMs
    }
}
public let defaultRetryPolicy = ConversationRetryPolicy()
public let defaultCompactionPolicy = CompactionPolicy()
public let defaultProgressPolicy = ProgressPolicy()

public struct HarnessSettings: Sendable {
    public var extensions: [Extension]?
    public var stream: ConversationStreamOptions?
    public var retry: RetryPolicyOverrides?
    public var compaction: CompactionPolicyOverrides?
    public var progress: ProgressPolicyOverrides?
    public var toolExecution: ToolExecutionMode?
    public var steeringMode: QueueMode?
    public var followUpMode: QueueMode?
    public var contextRetentionMs: Int64?
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
    public init(_ read: @escaping @Sendable () -> HarnessSettings?) { self.read = read }
    public func resolve() -> Settings { resolveSettings(read()) }
}
public struct Settings: Sendable {
    public var extensions: [Extension]?
    public var stream: ConversationStreamOptions
    public var retry: ConversationRetryPolicy
    public var compaction: CompactionPolicy
    public var progress: ProgressPolicy
    public var toolExecution: ToolExecutionMode
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var contextRetentionMs: Int64
}
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
