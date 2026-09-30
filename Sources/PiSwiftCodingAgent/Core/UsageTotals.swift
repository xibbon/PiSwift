import PiSwiftAI

public struct UsageTotals: Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var cost: Double = 0

    public init() {}

    public mutating func add(_ usage: Usage) {
        input += usage.input
        output += usage.output
        cacheRead += usage.cacheRead
        cacheWrite += usage.cacheWrite
        cost += usage.cost.total
    }
}

public func combineUsage(_ first: Usage, _ second: Usage) -> Usage {
    Usage(
        input: first.input + second.input,
        output: first.output + second.output,
        cacheRead: first.cacheRead + second.cacheRead,
        cacheWrite: first.cacheWrite + second.cacheWrite,
        cacheWrite1h: first.cacheWrite1h == nil && second.cacheWrite1h == nil ? nil : (first.cacheWrite1h ?? 0) + (second.cacheWrite1h ?? 0),
        reasoning: first.reasoning == nil && second.reasoning == nil ? nil : (first.reasoning ?? 0) + (second.reasoning ?? 0),
        totalTokens: first.totalTokens + second.totalTokens,
        cost: UsageCost(
            input: first.cost.input + second.cost.input,
            output: first.cost.output + second.cost.output,
            cacheRead: first.cost.cacheRead + second.cost.cacheRead,
            cacheWrite: first.cost.cacheWrite + second.cost.cacheWrite,
            total: first.cost.total + second.cost.total
        )
    )
}

public struct UsageCostBreakdownEntry: Sendable {
    public var key: String
    public var cost: Double
    public var tokens: Int
}

public func getUsageCostBreakdown(_ entries: [SessionEntry]) -> [UsageCostBreakdownEntry] {
    var totals: [String: UsageTotals] = [:]
    for entry in entries {
        var key: String?
        var usage: Usage?
        switch entry {
        case .message(let message):
            switch message.message {
            case .assistant(let assistant):
                key = "\(assistant.provider)/\(assistant.responseModel ?? assistant.model)"
                usage = assistant.usage
            case .toolResult(let result):
                if let resultUsage = result.usage { key = "Tools/summaries"; usage = resultUsage }
            default: break
            }
        case .usage(let record):
            key = "\(record.provider)/\(record.model)"
            usage = record.usage
        case .branchSummary(let summary):
            if let summaryUsage = summary.usage { key = "Tools/summaries"; usage = summaryUsage }
        case .compaction(let compaction):
            if let summaryUsage = compaction.usage { key = "Tools/summaries"; usage = summaryUsage }
        default: break
        }
        if let key, let usage { totals[key, default: UsageTotals()].add(usage) }
    }
    return totals.map { key, total in
        UsageCostBreakdownEntry(key: key, cost: total.cost,
                                tokens: total.input + total.output + total.cacheRead + total.cacheWrite)
    }.filter { $0.cost > 0 || $0.tokens > 0 }.sorted { $0.cost > $1.cost }
}
