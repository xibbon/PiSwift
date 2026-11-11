import Testing
import PiSwiftAI

private func warmingModel(
    api: Api = .anthropicMessages, adaptive: Bool = false,
    cost: ModelCost = ModelCost(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
    cache: ModelPromptCache? = ModelPromptCache(short: 300, long: 3_600)
) -> Model {
    Model(id: "warming-test", name: "Warming test", api: api, provider: "anthropic",
          baseUrl: "https://example.invalid", reasoning: true, input: [.text], cost: cost,
          contextWindow: 200_000, maxTokens: 8_192,
          compat: OpenAICompat(forceAdaptiveThinking: adaptive), promptCache: cache)
}

@Suite struct CacheWarmingPolicyTests {
    @Test func constantsAndDelay() {
        #expect(CacheWarmingPolicy.cacheWarmingMaxAgeMs == 3_600_000)
        #expect(CacheWarmingPolicy.cacheWarmingMaxIdleAgeMs == 1_800_000)
        #expect(CacheWarmingPolicy.cacheWarmingMinimumExpectedSavings == 0.05)
        #expect(CacheWarmingPolicy.cacheWarmingIdleContinuationProbability == 0.15)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(300_000) == 270_000)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(60_000) == 50_000)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(10_001) == 1)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(10_000) == nil)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(0) == nil)
        #expect(CacheWarmingPolicy.getCacheWarmingDelayMs(-1) == nil)
    }

    @Test func retentionAndScopedEnvironment() {
        let model = warmingModel()
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(cacheRetention: .short)) == 300_000)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(cacheRetention: .long)) == 3_600_000)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(cacheRetention: CacheRetention.none)) == nil)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(env: ["PI_CACHE_RETENTION": "long"])) == 3_600_000)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(env: ["PI_CACHE_RETENTION": "short"])) == 300_000)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: model, options: SimpleStreamOptions(env: ["PI_CACHE_RETENTION": "long"], cacheRetention: .short)) == 300_000)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: warmingModel(cache: nil)) == nil)
        #expect(CacheWarmingPolicy.getPromptCacheTtlMs(model: warmingModel(cache: ModelPromptCache(short: 300)), options: SimpleStreamOptions(cacheRetention: .long)) == nil)
    }

    @Test func replaySafety() {
        #expect(!CacheWarmingPolicy.isCacheWarmingReplayable(model: warmingModel(), options: SimpleStreamOptions(reasoning: .medium)))
        #expect(CacheWarmingPolicy.isCacheWarmingReplayable(model: warmingModel()))
        #expect(CacheWarmingPolicy.isCacheWarmingReplayable(model: warmingModel(adaptive: true), options: SimpleStreamOptions(reasoning: .medium)))
        #expect(CacheWarmingPolicy.isCacheWarmingReplayable(model: warmingModel(api: .openAIResponses), options: SimpleStreamOptions(reasoning: .medium)))
    }

    @Test func requestOptionsPreserveSource() {
        let originalSignal = CancellationToken()
        let refreshSignal = CancellationToken()
        var original = SimpleStreamOptions(env: ["SCOPE": "test"], maxTokens: 1_000,
                                           signal: originalSignal, reasoning: .high,
                                           cacheRetention: .long, sessionId: "session", maxRetries: 4)
        original.disableContinuation = false
        let refresh = CacheWarmingPolicy.getCacheWarmingRequestOptions(original, signal: refreshSignal)
        #expect(refresh.maxTokens == 1)
        #expect(refresh.maxRetries == 0)
        #expect(refresh.disableContinuation == true)
        #expect(refresh.signal === refreshSignal)
        #expect(refresh.env == original.env)
        #expect(refresh.reasoning == .high)
        #expect(refresh.cacheRetention == .long)
        #expect(refresh.sessionId == "session")
        #expect(original.maxTokens == 1_000)
        #expect(original.maxRetries == 4)
        #expect(original.disableContinuation == false)
        #expect(original.signal === originalSignal)
    }

    @Test func economicDecisions() {
        let streaming = CacheWarmingPolicy.evaluateCacheWarming(model: warmingModel(), promptTokens: 100_000, phase: .streaming)
        #expect(abs(streaming.warmCost - 0.050025) < 1e-12)
        #expect(abs(streaming.missCost - 0.575) < 1e-12)
        #expect(streaming.continuationProbability == 1)
        #expect(abs(streaming.expectedSavings - 0.524975) < 1e-12)
        #expect(streaming.economicsAvailable)
        #expect(streaming.action == .warm)
        let idle = CacheWarmingPolicy.evaluateCacheWarming(model: warmingModel(), promptTokens: 100_000, phase: .idle)
        #expect(idle.phase == .idle)
        #expect(idle.continuationProbability == 0.15)
        #expect(abs(idle.expectedSavings - 0.036225) < 1e-12)
        #expect(idle.action == .stop)
        let noWrite = warmingModel(cost: ModelCost(input: 5, output: 0, cacheRead: 0.5, cacheWrite: 0))
        #expect(abs(CacheWarmingPolicy.evaluateCacheWarming(model: noWrite, promptTokens: 100_000, phase: .streaming).missCost - 0.45) < 1e-12)
        let noTokens = CacheWarmingPolicy.evaluateCacheWarming(model: warmingModel(), promptTokens: 0, phase: .streaming)
        #expect(!noTokens.economicsAvailable)
        #expect(noTokens.action == .stop)
        let free = warmingModel(cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        #expect(!CacheWarmingPolicy.evaluateCacheWarming(model: free, promptTokens: 100_000, phase: .streaming).economicsAvailable)
    }

    @Test func savingsThresholdAndNonnegativeMissCost() {
        let boundary = warmingModel(cost: ModelCost(input: 1, output: 0, cacheRead: 0, cacheWrite: 0))
        #expect(CacheWarmingPolicy.evaluateCacheWarming(model: boundary, promptTokens: 50_001, phase: .streaming).action == .warm)
        #expect(CacheWarmingPolicy.evaluateCacheWarming(model: boundary, promptTokens: 49_999, phase: .streaming).action == .stop)
        let expensiveRead = warmingModel(cost: ModelCost(input: 1, output: 0, cacheRead: 2, cacheWrite: 0))
        #expect(CacheWarmingPolicy.evaluateCacheWarming(model: expensiveRead, promptTokens: 100_000, phase: .streaming).missCost == 0)
    }
}
