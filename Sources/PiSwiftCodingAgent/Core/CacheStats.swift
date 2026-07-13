import Foundation
import PiSwiftAI

/// Prompt-cache TTL. Idle gaps longer than this are useful context when presenting a miss.
public let CACHE_TTL_MS: Int64 = 5 * 60 * 1_000

/// Per-turn misses at or below this are cache breakpoint granularity noise.
private let cacheMissNoiseFloorTokens = 1_024

/// A significant prompt-cache miss detected relative to the preceding request.
public struct CacheMiss: Sendable, Equatable {
    public var missedTokens: Int
    public var missedCost: Double
    public var idleMs: Int64
    public var modelChanged: Bool

    public init(missedTokens: Int, missedCost: Double, idleMs: Int64, modelChanged: Bool) {
        self.missedTokens = missedTokens
        self.missedCost = missedCost
        self.idleMs = idleMs
        self.modelChanged = modelChanged
    }
}

/// Cumulative prompt-cache waste for a session branch.
public struct CacheWasteTotals: Sendable, Equatable {
    public var missedTokens: Int
    public var missedCost: Double
    public var missCount: Int

    public init(missedTokens: Int = 0, missedCost: Double = 0, missCount: Int = 0) {
        self.missedTokens = missedTokens
        self.missedCost = missedCost
        self.missCount = missCount
    }
}

private struct PreviousCacheRequest {
    var promptTokens: Int
    var modelKey: String
    var timestamp: Int64
    var reportedCache: Bool
}

private func cacheMiss(
    previous: PreviousCacheRequest?,
    message: AssistantMessage,
    modelRegistry: ModelRegistry
) -> CacheMiss? {
    let usage = message.usage
    let promptTokens = usage.input + usage.cacheRead + usage.cacheWrite
    guard let previous,
          promptTokens > 0,
          usage.cacheRead + usage.cacheWrite > 0 || previous.reportedCache
    else {
        return nil
    }

    let missedTokens = min(previous.promptTokens, promptTokens) - usage.cacheRead
    guard missedTokens > cacheMissNoiseFloorTokens else { return nil }

    let paidTokens = usage.input + usage.cacheWrite
    let paidPerToken = paidTokens > 0
        ? (usage.cost.input + usage.cost.cacheWrite) / Double(paidTokens)
        : 0
    let readPerToken: Double
    if usage.cacheRead > 0 {
        readPerToken = usage.cost.cacheRead / Double(usage.cacheRead)
    } else {
        readPerToken = (modelRegistry.find(message.provider, message.model)?.cost.cacheRead ?? 0) / 1_000_000
    }

    return CacheMiss(
        missedTokens: missedTokens,
        missedCost: Double(missedTokens) * max(0, paidPerToken - readPerToken),
        idleMs: max(0, message.timestamp - previous.timestamp),
        modelChanged: "\(message.provider)/\(message.model)" != previous.modelKey
    )
}

private func previousCacheRequest(_ message: AssistantMessage, previouslyReportedCache: Bool) -> PreviousCacheRequest? {
    let usage = message.usage
    let promptTokens = usage.input + usage.cacheRead + usage.cacheWrite
    guard promptTokens > 0 else { return nil }
    return PreviousCacheRequest(
        promptTokens: promptTokens,
        modelKey: "\(message.provider)/\(message.model)",
        timestamp: message.timestamp,
        reportedCache: previouslyReportedCache || usage.cacheRead + usage.cacheWrite > 0
    )
}

private func scanCacheMisses(
    _ entries: [SessionEntry],
    modelRegistry: ModelRegistry
) -> (previous: PreviousCacheRequest?, totals: CacheWasteTotals, misses: [String: CacheMiss]) {
    var previous: PreviousCacheRequest?
    var totals = CacheWasteTotals()
    var misses: [String: CacheMiss] = [:]

    for entry in entries {
        switch entry {
        case .compaction, .branchSummary:
            previous = nil
        case .message(let messageEntry):
            guard case .assistant(let message) = messageEntry.message else { continue }
            if let miss = cacheMiss(previous: previous, message: message, modelRegistry: modelRegistry) {
                totals.missedTokens += miss.missedTokens
                totals.missedCost += miss.missedCost
                totals.missCount += 1
                misses[messageEntry.id] = miss
            }
            previous = previousCacheRequest(message, previouslyReportedCache: previous?.reportedCache ?? false) ?? previous
        default:
            continue
        }
    }

    return (previous, totals, misses)
}

/// Computes prompt tokens re-billed despite appearing in the immediately preceding request.
public func computeCacheWaste(_ entries: [SessionEntry], modelRegistry: ModelRegistry) -> CacheWasteTotals {
    scanCacheMisses(entries, modelRegistry: modelRegistry).totals
}

/// Returns significant cache misses keyed by their persisted assistant-message entry IDs.
public func collectCacheMisses(_ entries: [SessionEntry], modelRegistry: ModelRegistry) -> [String: CacheMiss] {
    scanCacheMisses(entries, modelRegistry: modelRegistry).misses
}

/// Detects the significant miss for an assistant response that has not yet been persisted.
public func detectCacheMiss(
    _ entries: [SessionEntry],
    message: AssistantMessage,
    modelRegistry: ModelRegistry
) -> CacheMiss? {
    cacheMiss(previous: scanCacheMisses(entries, modelRegistry: modelRegistry).previous, message: message, modelRegistry: modelRegistry)
}
