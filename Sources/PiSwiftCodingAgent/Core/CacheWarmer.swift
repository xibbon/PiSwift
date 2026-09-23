import Foundation
import PiSwiftAI

private let maxWarmingAgeMs: Int64 = 60 * 60_000
private let maxIdleWarmingAgeMs: Int64 = 30 * 60_000
private let minimumExpectedSavings = 0.05
private let idleContinuationProbability = 0.15

/// Returns the delay before a cache refresh. The refresh retains at least ten seconds of TTL.
public func getCacheWarmingDelayMs(_ ttlMs: Int64) -> Int64? {
    guard ttlMs > 10_000 else { return nil }
    return max(1, min(Int64(Double(ttlMs) * 0.9), ttlMs - 10_000))
}

/// Returns the lifetime of the request's prompt-cache retention tier.
public func getPromptCacheTtlMs(
    model: Model,
    options: SimpleStreamOptions? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int64? {
    let retention = options?.cacheRetention
        ?? (environment["PI_CACHE_RETENTION"] == "long" ? CacheRetention.long : .short)
    switch retention {
    case .none:
        return nil
    case .short:
        return model.promptCache?.short.map { Int64($0) * 1_000 }
    case .long:
        return model.promptCache?.long.map { Int64($0) * 1_000 }
    }
}

/// Anthropic budget-based thinking can change the prompt-cache key when replayed with one output token.
public func isCacheWarmReplayable(model: Model, options: SimpleStreamOptions? = nil) -> Bool {
    if options?.reasoning == nil || model.api != .anthropicMessages { return true }
    return model.compat?.forceAdaptiveThinking == true
}

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

public struct CacheWarmingDecisionEvent: HookEvent, Sendable, Equatable {
    public let type = "cache_warming_decision"
    public var warmCost: Double
    public var missCost: Double
    public var continuationProbability: Double
    public var action: CacheWarmingAction

    public init(warmCost: Double, missCost: Double, continuationProbability: Double, action: CacheWarmingAction) {
        self.warmCost = warmCost
        self.missCost = missCost
        self.continuationProbability = continuationProbability
        self.action = action
    }
}

public enum CacheWarmingState: String, Sendable, Equatable {
    case inactive
    case scheduled
    case refreshing
}

public struct CacheWarmingStatus: Sendable, Equatable {
    public var state: CacheWarmingState
    public var reason: String?
    public var nextWarmAt: Int64?
    public var decision: CacheWarmingDecision?
    public var extensionOverride: Bool?

    public init(
        state: CacheWarmingState, reason: String? = nil, nextWarmAt: Int64? = nil,
        decision: CacheWarmingDecision? = nil, extensionOverride: Bool? = nil
    ) {
        self.state = state
        self.reason = reason
        self.nextWarmAt = nextWarmAt
        self.decision = decision
        self.extensionOverride = extensionOverride
    }
}

public struct CacheWarmRequest: Sendable {
    public var model: Model
    public var context: Context
    public var options: SimpleStreamOptions

    public init(model: Model, context: Context, options: SimpleStreamOptions) {
        self.model = model
        self.context = context
        self.options = options
    }
}

/// An injectable clock. Timer tasks can be cancelled without retaining a dispatch timer.
public struct CacheWarmingClock: Sendable {
    public var nowMs: @Sendable () -> Int64
    public var sleepMs: @Sendable (Int64) async throws -> Void

    public init(
        nowMs: @escaping @Sendable () -> Int64,
        sleepMs: @escaping @Sendable (Int64) async throws -> Void
    ) {
        self.nowMs = nowMs
        self.sleepMs = sleepMs
    }

    public static let system = CacheWarmingClock(
        nowMs: { Int64(Date().timeIntervalSince1970 * 1_000) },
        sleepMs: { ms in try await Task.sleep(for: .milliseconds(ms)) }
    )
}

/// Keeps one exact provider request's prompt-cache entry warm during a run or idle period.
public actor CacheWarmer {
    public typealias Stream = @Sendable (Model, Context, SimpleStreamOptions) async throws -> AssistantMessage
    public typealias Decision = @Sendable (CacheWarmingDecisionEvent) async throws -> CacheWarmingAction

    private struct Run {
        var id: UUID
        var request: CacheWarmRequest
        var isCurrent: @Sendable () -> Bool
        var ttlMs: Int64
        var delayMs: Int64
        var refreshDeadlineAt: Int64
        var startedAt: Int64
        var token: CancellationToken
        var phase: CacheWarmingPhase
        var nextWarmAt: Int64
        var extensionOverride: Bool
        var timer: Task<Void, Never>?
    }

    private let stream: Stream
    private let sessionManager: SessionManager
    private let getMode: @Sendable () -> CacheWarmingMode
    private let decide: Decision
    private let onWarmed: (@Sendable (UsageEntry) async -> Void)?
    private let clock: CacheWarmingClock
    private var run: Run?
    private var inactive = CacheWarmingStatus(state: .inactive, reason: "waiting for first request")

    public init(
        stream: @escaping Stream,
        sessionManager: SessionManager,
        getMode: @escaping @Sendable () -> CacheWarmingMode,
        decide: @escaping Decision = { $0.action },
        onWarmed: (@Sendable (UsageEntry) async -> Void)? = nil,
        clock: CacheWarmingClock = .system
    ) {
        self.stream = stream
        self.sessionManager = sessionManager
        self.getMode = getMode
        self.decide = decide
        self.onWarmed = onWarmed
        self.clock = clock
    }

    public func status() -> CacheWarmingStatus {
        if getMode() == .off { return CacheWarmingStatus(state: .inactive, reason: "cache warming disabled") }
        guard let run else { return inactive }
        if !run.isCurrent() { return CacheWarmingStatus(state: .inactive, reason: "conversation context changed") }
        let decision = evaluate(run)
        let refreshing = run.timer == nil
        if !decision.economicsAvailable && !refreshing {
            return CacheWarmingStatus(state: .inactive, reason: "cache economics unavailable")
        }
        return CacheWarmingStatus(
            state: refreshing ? .refreshing : .scheduled,
            nextWarmAt: run.nextWarmAt,
            decision: decision,
            extensionOverride: run.extensionOverride
        )
    }

    /// A new real request replaces the prior warming run.
    public func start(_ request: CacheWarmRequest, isCurrent: @escaping @Sendable () -> Bool) {
        clearRun()
        if getMode() == .off {
            stop("cache warming disabled")
            return
        }
        if !isCacheWarmReplayable(model: request.model, options: request.options) {
            stop("request cannot be replayed safely")
            return
        }
        guard let ttlMs = getPromptCacheTtlMs(model: request.model, options: request.options) else {
            stop(request.options.cacheRetention == CacheRetention.none
                ? "request disabled prompt caching" : "cache lifetime unavailable")
            return
        }
        guard let delayMs = getCacheWarmingDelayMs(ttlMs) else {
            stop("cache lifetime unavailable")
            return
        }
        let now = clock.nowMs()
        run = Run(
            id: UUID(), request: request, isCurrent: isCurrent,
            ttlMs: ttlMs, delayMs: delayMs, refreshDeadlineAt: 0, startedAt: now,
            token: CancellationToken(), phase: .streaming, nextWarmAt: 0,
            extensionOverride: false, timer: nil
        )
        schedule()
    }

    public func onAgentSettled() {
        guard var active = run else { return }
        if getMode() == .streaming {
            stop("agent run settled")
            return
        }
        active.phase = .idle
        run = active
        let deadline = active.startedAt + maxIdleWarmingAgeMs
        if active.nextWarmAt > deadline || clock.nowMs() >= deadline {
            stop("30-minute idle safety limit reached")
        }
    }

    public func onModeChanged() {
        guard let run, let reason = modeStopReason(run) else { return }
        stop(reason)
    }

    public func cancel() {
        stop("inactive")
    }

    private func clearRun() {
        guard let active = run else { return }
        run = nil
        active.timer?.cancel()
        active.token.cancel()
    }

    private func stop(
        _ reason: String,
        decision: CacheWarmingDecision? = nil,
        extensionOverride: Bool? = nil
    ) {
        clearRun()
        inactive = CacheWarmingStatus(
            state: .inactive, reason: reason, decision: decision,
            extensionOverride: extensionOverride
        )
    }

    private func schedule() {
        guard var active = run else { return }
        active.extensionOverride = false
        let now = clock.nowMs()
        active.nextWarmAt = now + active.delayMs
        active.refreshDeadlineAt = active.nextWarmAt + (active.ttlMs - active.delayMs) / 2
        let horizon = active.startedAt + (active.phase == .idle ? maxIdleWarmingAgeMs : maxWarmingAgeMs)
        if active.nextWarmAt > horizon || now >= horizon {
            stop(active.phase == .idle
                ? "30-minute idle safety limit reached" : "one-hour safety limit reached")
            return
        }
        let id = active.id
        let delay = max(0, active.nextWarmAt - now)
        active.timer = Task { [clock] in
            do {
                try await clock.sleepMs(delay)
                guard !Task.isCancelled else { return }
                await self.refresh(id)
            } catch {
                // Cancellation is expected when the request or session changes.
            }
        }
        run = active
    }

    private func refresh(_ id: UUID) async {
        guard var active = run, active.id == id else { return }
        active.timer = nil
        run = active
        guard validate(id), !refreshDeadlineMissed() else { return }
        let decision = evaluate(active)
        let event = CacheWarmingDecisionEvent(
            warmCost: decision.warmCost, missCost: decision.missCost,
            continuationProbability: decision.continuationProbability,
            action: decision.action
        )
        var action = decision.action
        do {
            action = try await decide(event)
        } catch {
            // Extension failures leave the built-in decision in place.
        }
        guard validate(id), !refreshDeadlineMissed() else { return }
        let extensionOverride = action != decision.action
        if action == .stop {
            stop(
                extensionOverride ? "stopped by extension"
                    : (decision.economicsAvailable
                        ? "expected savings below threshold" : "cache economics unavailable"),
                decision: decision,
                extensionOverride: extensionOverride
            )
            return
        }
        guard var current = run, current.id == id else { return }
        current.extensionOverride = extensionOverride
        run = current
        var options = current.request.options
        options.maxTokens = 1
        options.maxRetries = 0
        options.signal = current.token
        do {
            let message = try await stream(current.request.model, current.request.context, options)
            if validate(id), message.stopReason != .error, message.stopReason != .aborted {
                let entryId = sessionManager.appendUsage(
                    "cache_warm", message.provider, message.responseModel ?? message.model,
                    message.usage, note: extensionOverride ? "extension override" : nil
                )
                if let onWarmed, case .usage(let entry)? = sessionManager.getEntry(entryId) {
                    await onWarmed(entry)
                }
            }
        } catch {
            // Cache warming is best effort and must not affect the agent run.
        }
        if run?.id == id { schedule() }
    }

    private func refreshDeadlineMissed() -> Bool {
        guard let run else { return true }
        if clock.nowMs() <= run.refreshDeadlineAt { return false }
        stop("cache refresh deadline missed")
        return true
    }

    private func validate(_ id: UUID) -> Bool {
        guard let run, run.id == id else { return false }
        if let reason = modeStopReason(run) ?? (!run.isCurrent() ? "conversation context changed" : nil) {
            stop(reason)
            return false
        }
        return true
    }

    private func modeStopReason(_ run: Run) -> String? {
        if getMode() == .off { return "cache warming disabled" }
        if getMode() == .streaming && run.phase == .idle { return "agent run settled" }
        return nil
    }

    private func evaluate(_ run: Run) -> CacheWarmingDecision {
        let promptTokens = lastPromptTokens(sessionManager.getBranch())
        let hitCost = price(run.request.model, cacheRead: promptTokens)
        let missCost = run.request.model.cost.cacheWrite > 0
            ? price(run.request.model, cacheWrite: promptTokens)
            : price(run.request.model, input: promptTokens)
        let warmCost = price(run.request.model, output: 1, cacheRead: promptTokens)
        let loss = max(0, missCost - hitCost)
        let probability = run.phase == .idle ? idleContinuationProbability : 1
        let available = promptTokens > 0 && (hitCost > 0 || missCost > 0)
        let savings = probability * loss - warmCost
        return CacheWarmingDecision(
            phase: run.phase, warmCost: warmCost, missCost: loss,
            continuationProbability: probability, expectedSavings: savings,
            economicsAvailable: available,
            action: savings >= minimumExpectedSavings ? .warm : .stop
        )
    }
}

private func lastPromptTokens(_ entries: [SessionEntry]) -> Int {
    for entry in entries.reversed() {
        if case .message(let item) = entry, case .assistant(let message) = item.message {
            return message.usage.input + message.usage.cacheRead + message.usage.cacheWrite
        }
    }
    return 0
}

private func price(
    _ model: Model, input: Int = 0, output: Int = 0,
    cacheRead: Int = 0, cacheWrite: Int = 0
) -> Double {
    var usage = Usage(
        input: input, output: output, cacheRead: cacheRead,
        cacheWrite: cacheWrite, totalTokens: 0
    )
    return calculateCost(model: model, usage: &usage).total
}

private func dollars(_ amount: Double) -> String {
    amount < 0
        ? "-$" + String(format: "%.3f", abs(amount))
        : "$" + String(format: "%.3f", amount)
}

private func economics(_ decision: CacheWarmingDecision) -> String {
    if !decision.economicsAvailable { return "cache economics unavailable" }
    let probability = Int((decision.continuationProbability * 100).rounded())
    let probabilityText = decision.phase == .streaming
        ? "\(probability)% continuation probability while agent is running"
        : "\(probability)% continuation probability"
    let comparison = decision.action == .warm ? ">=" : "<"
    return "\(probabilityText), expected savings \(dollars(decision.expectedSavings)) \(comparison) $0.050"
}

/// One-line diagnostic for the session display.
public func formatCacheWarmingStatus(
    _ status: CacheWarmingStatus,
    nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
) -> String {
    guard let decision = status.decision,
          status.state != .inactive || decision.economicsAvailable || status.extensionOverride == true else {
        return "Inactive (\(status.reason ?? "unknown reason"))"
    }
    let detail = status.extensionOverride == true
        ? "extension override, \(economics(decision))"
        : "\(economics(decision)) -> \(decision.action.rawValue)"
    switch status.state {
    case .inactive:
        return "Stopped (\(detail))"
    case .refreshing:
        return "Warming cache (\(detail))"
    case .scheduled:
        guard let next = status.nextWarmAt, next > nowMs else {
            return "Decision now (\(detail))"
        }
        var seconds = (next - nowMs + 999) / 1_000
        let hours = seconds / 3_600
        seconds %= 3_600
        let minutes = seconds / 60
        seconds %= 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return "Decision in \(parts.joined(separator: " ")) (\(detail))"
    }
}

/// One-line transcript notice for persisted cache warming usage.
public func formatCacheWarmingUsage(_ entry: UsageEntry) -> String {
    let note = entry.note.map { " (\($0))" } ?? ""
    var cost = String(format: "%.6f", entry.usage.cost.total)
    if let dot = cost.firstIndex(of: ".") {
        while cost.last == "0" && cost.distance(from: dot, to: cost.endIndex) > 4 {
            cost.removeLast()
        }
    }
    return "Cache warmed\(note): $\(cost)"
}
