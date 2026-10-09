import PiSwiftAI

/// Usage totals for one conversation. Model keys are provider/model ID pairs.
public struct UsageState: Sendable {
    public var models: [String: Usage]
    public var tools: [String: Usage]
    public init(models: [String: Usage] = [:], tools: [String: Usage] = [:]) { self.models = models; self.tools = tools }
}

/// Adds all counters. An optional counter is retained once either side reports it.
public func addUsage(total: inout Usage, usage: Usage) {
    total.input += usage.input; total.output += usage.output
    total.cacheRead += usage.cacheRead; total.cacheWrite += usage.cacheWrite
    total.totalTokens += usage.totalTokens
    if let value = usage.cacheWrite1h { total.cacheWrite1h = (total.cacheWrite1h ?? 0) + value }
    if let value = usage.reasoning { total.reasoning = (total.reasoning ?? 0) + value }
    total.cost.input += usage.cost.input; total.cost.output += usage.cost.output
    total.cost.cacheRead += usage.cost.cacheRead; total.cost.cacheWrite += usage.cost.cacheWrite
    total.cost.total += usage.cost.total
}

/// Adds each bucket without special treatment of names such as __proto__.
public func addUsageState(sum: inout UsageState, state: UsageState) {
    for (key, value) in state.models {
        if var total = sum.models[key] { addUsage(total: &total, usage: value); sum.models[key] = total }
        else { sum.models[key] = value }
    }
    for (key, value) in state.tools {
        if var total = sum.tools[key] { addUsage(total: &total, usage: value); sum.tools[key] = total }
        else { sum.tools[key] = value }
    }
}

/// Persisted provider identity. Document policy belongs to the later Session slice.
public struct ProviderState: Sendable, Equatable, Codable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
    public static func fresh(timestampMs: Int64? = nil) throws -> ProviderState {
        ProviderState(sessionId: try uuidv7(timestampMs: timestampMs))
    }
}
