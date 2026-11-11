/// Shared prompt-cache refresh policy for library clients.
public enum CacheWarmingPolicy {
    /// Maximum age of cache warming during an agent run, in milliseconds.
    public static let cacheWarmingMaxAgeMs: Int64 = 60 * 60_000
    /// Maximum age of cache warming after an agent run, in milliseconds.
    public static let cacheWarmingMaxIdleAgeMs: Int64 = 30 * 60_000
    /// Minimum expected savings, in dollars, required for a refresh.
    public static let cacheWarmingMinimumExpectedSavings = 0.05
    /// Estimated probability of a new request before an idle cache entry expires.
    public static let cacheWarmingIdleContinuationProbability = 0.15

    public enum CacheWarmingAction: String, Sendable, Equatable {
        case warm
        case stop
    }

    public enum CacheWarmingPhase: String, Sendable, Equatable {
        case streaming
        case idle
    }

    public struct CacheWarmingDecision: Sendable, Equatable {
        public var phase: CacheWarmingPhase
        public var warmCost: Double
        public var missCost: Double
        public var continuationProbability: Double
        public var expectedSavings: Double
        public var economicsAvailable: Bool
        public var action: CacheWarmingAction

        public init(
            phase: CacheWarmingPhase, warmCost: Double, missCost: Double,
            continuationProbability: Double, expectedSavings: Double,
            economicsAvailable: Bool, action: CacheWarmingAction
        ) {
            self.phase = phase
            self.warmCost = warmCost
            self.missCost = missCost
            self.continuationProbability = continuationProbability
            self.expectedSavings = expectedSavings
            self.economicsAvailable = economicsAvailable
            self.action = action
        }
    }

    /// Refreshes at 90 percent of the TTL, with at least ten seconds before expiry.
    public static func getCacheWarmingDelayMs(_ ttlMs: Int64) -> Int64? {
        guard ttlMs > 10_000 else { return nil }
        return max(1, min(Int64(Double(ttlMs) * 0.9), ttlMs - 10_000))
    }

    /// Returns the lifetime of the cache tier used by the request.
    public static func getPromptCacheTtlMs(model: Model, options: SimpleStreamOptions? = nil) -> Int64? {
        let retention = options?.cacheRetention
            ?? (getProviderEnvValue("PI_CACHE_RETENTION", env: options?.env) == "long" ? .long : .short)
        let seconds: Int?
        switch retention {
        case .none: return nil
        case .short: seconds = model.promptCache?.short
        case .long: seconds = model.promptCache?.long
        }
        return seconds.map { Int64($0) * 1_000 }
    }

    /// Budget-based Anthropic thinking cannot safely use a one-token replay.
    public static func isCacheWarmingReplayable(model: Model, options: SimpleStreamOptions? = nil) -> Bool {
        if options?.reasoning == nil || model.api != .anthropicMessages { return true }
        return model.compat?.forceAdaptiveThinking == true
    }

    /// Copies request options and sets the limits required for a cache refresh.
    public static func getCacheWarmingRequestOptions(
        _ options: SimpleStreamOptions, signal: CancellationToken
    ) -> SimpleStreamOptions {
        var result = options
        result.maxTokens = 1
        result.disableContinuation = true
        result.maxRetries = 0
        result.signal = signal
        return result
    }

    /// Calculates whether a refresh is expected to save at least the minimum cost.
    public static func evaluateCacheWarming(
        model: Model, promptTokens: Int, phase: CacheWarmingPhase
    ) -> CacheWarmingDecision {
        let hitCost = cacheWarmingPrice(model, cacheRead: promptTokens)
        let missPrice = model.cost.cacheWrite > 0
            ? cacheWarmingPrice(model, cacheWrite: promptTokens)
            : cacheWarmingPrice(model, input: promptTokens)
        let warmCost = cacheWarmingPrice(model, output: 1, cacheRead: promptTokens)
        let missCost = max(0, missPrice - hitCost)
        let probability = phase == .idle ? cacheWarmingIdleContinuationProbability : 1
        let expectedSavings = probability * missCost - warmCost
        return CacheWarmingDecision(
            phase: phase, warmCost: warmCost, missCost: missCost,
            continuationProbability: probability, expectedSavings: expectedSavings,
            economicsAvailable: promptTokens > 0 && (hitCost > 0 || missPrice > 0),
            action: expectedSavings >= cacheWarmingMinimumExpectedSavings ? .warm : .stop
        )
    }

    private static func cacheWarmingPrice(
        _ model: Model, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> Double {
        var usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: 0)
        return calculateCost(model: model, usage: &usage).total
    }
}
