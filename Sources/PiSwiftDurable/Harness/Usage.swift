import PiSwiftAI
import PiSwiftChord

/// Usage totals for one conversation. Model keys are provider/model ID pairs.
public struct UsageState: Sendable, Codable {
    /// The model service used by this harness or task.
    public var models: [String: Usage]
    /// The tool registrations or live tool slots in this value.
    public var tools: [String: Usage]
    /// Creates model and tool usage totals indexed by name.
    public init(models: [String: Usage] = [:], tools: [String: Usage] = [:]) { self.models = models; self.tools = tools }
    /// Decodes this value from its durable JSON representation.
    public init(from decoder: any Decoder) throws {
        let object = try recordObject(decoder)
        let models: JSONObject = try recordRequired(object, "models")
        let tools: JSONObject = try recordRequired(object, "tools")
        self.models = try Dictionary(uniqueKeysWithValues: models.map { ($0.key, try durableUsage($0.value)) })
        self.tools = try Dictionary(uniqueKeysWithValues: tools.map { ($0.key, try durableUsage($0.value)) })
    }
    /// Encodes this value with the durable JSON representation.
    public func encode(to encoder: any Encoder) throws {
        try JSONObject([("models", .object(JSONObject(models.map { ($0.key, usageValue($0.value)) }))),
                        ("tools", .object(JSONObject(tools.map { ($0.key, usageValue($0.value)) })))]).encode(to: encoder)
    }
}

/// Each conversation records only its own spend. A fork starts with empty totals.
public let UsageDoc = try! ConversationDocToken<UsageState>(
    kind: "pi.usage", version: 1, fork: .initial,
    initial: { UsageState() }, checkpointWhen: { _, _, _ in true }
)

/// Selects model or tool usage in the conversation usage document.
public enum UsageBucket: String, Sendable {
    /// Selects the usage totals of model requests.
    case models
    /// Selects the usage totals of tool execution.
    case tools
}

/// Call this in the same commit that appends the response or tool result.
public func recordUsage(tx: Transaction, conversationId: ConversationID, bucket: UsageBucket,
                        key: String, usage: Usage) async throws {
    let draft = try await tx.doc(UsageDoc, conversationId: conversationId)
    guard let totals = try draft.child(bucket.rawValue) else {
        throw DocumentDefinitionError("Usage bucket is missing")
    }
    if let current = try totals.get(key) {
        var total = try durableUsage(current)
        addUsage(total: &total, usage: usage)
        try assignJSON(target: totals, key: key, value: usageValue(total))
    } else {
        try totals.set(key, usageValue(usage))
    }
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
    /// The provider session identifier retained for this conversation.
    public var sessionId: String
    /// Records the provider session ID for this conversation.
    public init(sessionId: String) { self.sessionId = sessionId }
    /// Returns a new fake service with the same options and no recorded calls.
    public static func fresh(timestampMs: Int64? = nil) throws -> ProviderState {
        ProviderState(sessionId: try uuidv7(timestampMs: timestampMs))
    }
}

private func durableUsage(_ value: JSONValue) throws -> Usage {
    guard let object = value.objectValue else { throw DocumentDefinitionError("Usage must be an object") }
    let cost: JSONObject = try recordRequired(object, "cost")
    return Usage(input: try recordRequired(object, "input"), output: try recordRequired(object, "output"),
                 cacheRead: try recordRequired(object, "cacheRead"), cacheWrite: try recordRequired(object, "cacheWrite"),
                 cacheWrite1h: try recordOptional(object, "cacheWrite1h"), reasoning: try recordOptional(object, "reasoning"),
                 totalTokens: try recordRequired(object, "totalTokens"),
                 cost: UsageCost(input: try recordRequired(cost, "input"), output: try recordRequired(cost, "output"),
                                 cacheRead: try recordRequired(cost, "cacheRead"), cacheWrite: try recordRequired(cost, "cacheWrite"),
                                 total: try recordRequired(cost, "total")))
}
private func usageValue(_ usage: Usage) -> JSONValue {
    var object: JSONObject = ["input": .number(Double(usage.input)), "output": .number(Double(usage.output)),
        "cacheRead": .number(Double(usage.cacheRead)), "cacheWrite": .number(Double(usage.cacheWrite)),
        "totalTokens": .number(Double(usage.totalTokens)), "cost": .object([
            "input": .number(usage.cost.input), "output": .number(usage.cost.output), "cacheRead": .number(usage.cost.cacheRead),
            "cacheWrite": .number(usage.cost.cacheWrite), "total": .number(usage.cost.total)])]
    if let value = usage.cacheWrite1h { object["cacheWrite1h"] = .number(Double(value)) }
    if let value = usage.reasoning { object["reasoning"] = .number(Double(value)) }
    return .object(object)
}
