import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private final class ManualWarmingClock: Sendable {
    private struct Waiter: Sendable {
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State: Sendable {
        var now: Int64 = 0
        var waiters: [Waiter] = []
    }

    private let state = LockedState(State())

    var clock: CacheWarmingClock {
        CacheWarmingClock(
            nowMs: { self.state.withLock { $0.now } },
            sleepMs: { delay in
                try await withCheckedThrowingContinuation { continuation in
                    let due = self.state.withLock { state -> Bool in
                        guard delay > 0 else { return true }
                        state.waiters.append(Waiter(deadline: state.now + delay, continuation: continuation))
                        return false
                    }
                    if due { continuation.resume() }
                }
            }
        )
    }

    func advance(by delta: Int64) async {
        for _ in 0..<10 { await Task.yield() }
        let ready = state.withLock { state -> [Waiter] in
            state.now += delta
            let ready = state.waiters.filter { $0.deadline <= state.now }
            state.waiters.removeAll { $0.deadline <= state.now }
            return ready
        }
        for waiter in ready { waiter.continuation.resume() }
        for _ in 0..<200 { await Task.yield() }
    }
}

private func waitForWarming(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
}

private let warmingModel = Model(
    id: "claude-opus-4-6", name: "Claude Opus", api: .anthropicMessages,
    provider: "anthropic", baseUrl: "https://example.invalid", reasoning: true,
    input: [.text], cost: ModelCost(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
    contextWindow: 200_000, maxTokens: 16_000,
    compat: OpenAICompat(forceAdaptiveThinking: true),
    promptCache: ModelPromptCache(short: 300, long: 3_600)
)

private let warmingUsage = Usage(
    input: 0, output: 1, cacheRead: 100, cacheWrite: 0, totalTokens: 101,
    cost: UsageCost(cacheRead: 0.01, total: 0.01)
)

private func warmingResponse(
    model: Model = warmingModel, stopReason: StopReason = .length,
    usage: Usage = warmingUsage
) -> AssistantMessage {
    AssistantMessage(
        content: [], api: model.api, provider: model.provider, model: model.id,
        usage: usage, stopReason: stopReason, timestamp: 0
    )
}

private func warmingSession(promptTokens: Int = 100_000) -> SessionManager {
    let session = SessionManager.inMemory()
    var usage = warmingUsage
    usage.cacheRead = promptTokens
    usage.output = 10
    usage.totalTokens = promptTokens + 10
    session.appendMessage(.assistant(warmingResponse(usage: usage)))
    return session
}

private final class WarmingHarness: Sendable {
    struct State: Sendable {
        var mode: CacheWarmingMode
        var calls: [SimpleStreamOptions] = []
        var events: [CacheWarmingDecisionEvent] = []
        var warmed: [UsageEntry] = []
        var current = true
    }

    let state: LockedState<State>
    let session: SessionManager
    let warmer: CacheWarmer

    init(
        mode: CacheWarmingMode = .idle,
        promptTokens: Int = 100_000,
        decide: (@Sendable (CacheWarmingDecisionEvent) async throws -> CacheWarmingAction)? = nil,
        response: @escaping @Sendable (Model) async throws -> AssistantMessage = { warmingResponse(model: $0) }
    ) {
        let state = LockedState(State(mode: mode))
        let clock = ManualWarmingClock()
        let session = warmingSession(promptTokens: promptTokens)
        self.state = state
        self.session = session
        self.warmer = CacheWarmer(
            stream: { model, _, options in
                state.withLock { $0.calls.append(options) }
                return try await response(model)
            },
            sessionManager: session,
            getMode: { state.withLock { $0.mode } },
            decide: { event in
                state.withLock { $0.events.append(event) }
                return try await decide?(event) ?? event.action
            },
            onWarmed: { entry in state.withLock { $0.warmed.append(entry) } },
            clock: clock.clock
        )
        self.manualClock = clock
    }

    private let manualClock: ManualWarmingClock

    func advance(by delta: Int64) async { await manualClock.advance(by: delta) }
    var calls: [SimpleStreamOptions] { state.withLock { $0.calls } }
    var events: [CacheWarmingDecisionEvent] { state.withLock { $0.events } }
    var warmed: [UsageEntry] { state.withLock { $0.warmed } }
    func start(model: Model = warmingModel, options: SimpleStreamOptions = SimpleStreamOptions()) async {
        await warmer.start(CacheWarmRequest(model: model, context: Context(messages: []), options: options)) {
            self.state.withLock { $0.current }
        }
    }
}

@Test func cacheWarmingEligibilityAndTiming() {
    var long = SimpleStreamOptions(cacheRetention: .long)
    #expect(getPromptCacheTtlMs(model: warmingModel) == 300_000)
    #expect(getPromptCacheTtlMs(model: warmingModel, options: long) == 3_600_000)
    long.cacheRetention = CacheRetention.none
    #expect(getPromptCacheTtlMs(model: warmingModel, options: long) == nil)
    #expect(getPromptCacheTtlMs(model: warmingModel, environment: ["PI_CACHE_RETENTION": "long"]) == 3_600_000)
    #expect(getCacheWarmingDelayMs(300_000) == 270_000)
    #expect(getCacheWarmingDelayMs(60_000) == 50_000)
    #expect(getCacheWarmingDelayMs(10_000) == nil)
    #expect(isCacheWarmReplayable(model: warmingModel, options: SimpleStreamOptions(reasoning: .medium)))
    let budget = Model(
        id: "budget", name: "Budget", api: .anthropicMessages,
        provider: "anthropic", baseUrl: "", reasoning: true, input: [.text],
        cost: warmingModel.cost, contextWindow: 200_000, maxTokens: 16_000,
        promptCache: ModelPromptCache(short: 300)
    )
    #expect(!isCacheWarmReplayable(model: budget, options: SimpleStreamOptions(reasoning: .medium)))
    #expect(isCacheWarmReplayable(model: budget))
}

@Test func cacheWarmingReplaysProfitableRequestAndRecordsUsage() async {
    let harness = WarmingHarness()
    let originalToken = CancellationToken()
    await harness.start(options: SimpleStreamOptions(
        signal: originalToken, reasoning: .high, sessionId: "s"
    ))
    await harness.advance(by: 270_000)
    await waitForWarming { !harness.warmed.isEmpty }
    #expect(harness.calls.count == 1)
    #expect(harness.calls.first?.maxTokens == 1)
    #expect(harness.calls.first?.maxRetries == 0)
    #expect(harness.calls.first?.sessionId == "s")
    #expect(harness.calls.first?.reasoning == .high)
    #expect(harness.calls.first?.signal !== originalToken)
    #expect(harness.events.first?.action == .warm)
    #expect(harness.events.first?.missCost == 0.575)
    #expect(abs((harness.events.first?.warmCost ?? 0) - 0.050025) < 0.000001)
    #expect(harness.warmed.first?.kind == "cache_warm")
    await harness.advance(by: 270_000)
    #expect(harness.calls.count == 2)
    await harness.warmer.cancel()
}

@Test func cacheWarmingStopsAfterDelayedTimerAndDecision() async {
    let late = WarmingHarness()
    await late.start()
    await late.advance(by: 285_001)
    #expect(late.calls.isEmpty)
    #expect(await late.warmer.status().reason == "cache refresh deadline missed")

    let decisionClock = ManualWarmingClock()
    let session = warmingSession()
    let calls = LockedState(0)
    let warmer = CacheWarmer(
        stream: { model, _, _ in
            calls.withLock { $0 += 1 }
            return warmingResponse(model: model)
        },
        sessionManager: session, getMode: { .idle },
        decide: { event in
            await decisionClock.advance(by: 15_001)
            return event.action
        },
        clock: decisionClock.clock
    )
    await warmer.start(CacheWarmRequest(model: warmingModel, context: Context(messages: []), options: SimpleStreamOptions())) { true }
    await decisionClock.advance(by: 270_000)
    await waitForWarming { await warmer.status().reason == "cache refresh deadline missed" }
    #expect(calls.withLock { $0 } == 0)
    let status = await warmer.status()
    #expect(status.reason == "cache refresh deadline missed", "\(status)")
}

@Test func cacheWarmingEconomicsAndExtensionOverrides() async {
    let unprofitable = WarmingHarness(promptTokens: 5_000)
    await unprofitable.start()
    await unprofitable.advance(by: 270_000)
    #expect(unprofitable.calls.isEmpty)
    #expect(await unprofitable.warmer.status().decision?.action == .stop)

    let forced = WarmingHarness(promptTokens: 5_000, decide: { _ in .warm })
    await forced.start()
    await forced.advance(by: 270_000)
    await waitForWarming { !forced.warmed.isEmpty }
    #expect(forced.calls.count == 1)
    #expect(forced.warmed.first?.note == "extension override")
    await forced.warmer.cancel()

    let vetoed = WarmingHarness(decide: { _ in .stop })
    await vetoed.start()
    await vetoed.advance(by: 270_000)
    #expect(vetoed.calls.isEmpty)
    #expect(await vetoed.warmer.status().extensionOverride == true)

    let unavailable = WarmingHarness(promptTokens: 0)
    await unavailable.start()
    #expect(await unavailable.warmer.status().reason == "cache economics unavailable")
    await unavailable.advance(by: 270_000)
    #expect(unavailable.calls.isEmpty)
}

@Test func cacheWarmingStopsOnUnsupportedRequestsAndContextChanges() async {
    let harness = WarmingHarness()
    harness.state.withLock { $0.mode = .off }
    await harness.start()
    #expect(await harness.warmer.status().reason == "cache warming disabled")
    harness.state.withLock { $0.mode = .idle }
    let unknown = Model(
        id: "unknown", name: "Unknown", api: .anthropicMessages,
        provider: "anthropic", baseUrl: "", reasoning: true, input: [.text],
        cost: warmingModel.cost, contextWindow: 200_000, maxTokens: 16_000
    )
    await harness.start(model: unknown)
    #expect(await harness.warmer.status().reason == "cache lifetime unavailable")
    await harness.start(model: unknown, options: SimpleStreamOptions(cacheRetention: CacheRetention.none))
    #expect(await harness.warmer.status().reason == "request disabled prompt caching")
    await harness.start()
    harness.state.withLock { $0.current = false }
    #expect(await harness.warmer.status().reason == "conversation context changed")
    await harness.advance(by: 270_000)
    #expect(harness.calls.isEmpty)

    let streaming = WarmingHarness(mode: .streaming, promptTokens: 400_000)
    await streaming.start()
    await streaming.warmer.onAgentSettled()
    #expect(await streaming.warmer.status().reason == "agent run settled")

    let changedMode = WarmingHarness()
    await changedMode.start()
    changedMode.state.withLock { $0.mode = .off }
    await changedMode.warmer.onModeChanged()
    #expect(await changedMode.warmer.status().reason == "cache warming disabled")
}

@Test func cacheWarmingCancelsReplacedRequestAndSkipsFailure() async {
    let harness = WarmingHarness(response: { model in
        warmingResponse(model: model, stopReason: .error)
    })
    await harness.start()
    await harness.advance(by: 270_000)
    #expect(harness.warmed.isEmpty)
    let oldToken = harness.calls.first?.signal
    await harness.start()
    #expect(oldToken?.isCancelled == true)
    await harness.warmer.cancel()
}

@Test func cacheWarmingAbortsInFlightReplacedRequest() async {
    let pending = LockedState<CheckedContinuation<AssistantMessage, Never>?>(nil)
    let harness = WarmingHarness(response: { model in
        await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
        }
    })
    await harness.start()
    await harness.advance(by: 270_000)
    await waitForWarming { pending.withLock { $0 != nil } }
    let oldToken = harness.calls.first?.signal
    await harness.start()
    #expect(oldToken?.isCancelled == true)
    let release = pending.withLock { continuation -> CheckedContinuation<AssistantMessage, Never>? in
        let saved = continuation
        continuation = nil
        return saved
    }
    release?.resume(returning: warmingResponse())
    await harness.warmer.cancel()
    for _ in 0..<100 { await Task.yield() }
    #expect(harness.warmed.isEmpty)
    #expect(harness.calls.count == 1)
}

@Test func cacheWarmingFormatsStatusAndUsage() {
    let decision = CacheWarmingDecision(
        phase: .idle, warmCost: 0.013, missCost: 0.621,
        continuationProbability: 0.6, expectedSavings: 0.36,
        economicsAvailable: true, action: .warm
    )
    #expect(formatCacheWarmingStatus(
        CacheWarmingStatus(state: .scheduled, nextWarmAt: 222_000, decision: decision), nowMs: 0
    ) == "Decision in 3m 42s (60% continuation probability, expected savings $0.360 >= $0.050 -> warm)")
    var usage = warmingUsage
    usage.cost = UsageCost(input: 0.00004, output: 0.00005, cacheRead: 0.02940725, total: 0.02949725)
    let entry = UsageEntry(
        id: "u", timestamp: "", kind: "cache_warm", provider: "anthropic",
        model: "claude-opus-4-6", usage: usage, note: "extension override"
    )
    #expect(formatCacheWarmingUsage(entry) == "Cache warmed (extension override): $0.029497")
}
