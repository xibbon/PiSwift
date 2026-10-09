/// Token estimates for the current transcript.
public struct ContextUsageEstimate: Sendable, Equatable {
    public var tokens: Int
    public var usageTokens: Int
    public var trailingTokens: Int
    public var lastUsageIndex: Int?

    public init(tokens: Int, usageTokens: Int, trailingTokens: Int, lastUsageIndex: Int?) {
        self.tokens = tokens
        self.usageTokens = usageTokens
        self.trailingTokens = trailingTokens
        self.lastUsageIndex = lastUsageIndex
    }
}

// Keep the existing internal estimate assertions source compatible.
func == (lhs: ContextUsageEstimate, rhs: Int) -> Bool { lhs.tokens == rhs }

public func calculateContextTokens(_ usage: Usage) -> Int {
    usage.totalTokens == 0 ? usage.input + usage.output + usage.cacheRead + usage.cacheWrite : usage.totalTokens
}

public func estimateTextTokens(_ text: String) -> Int {
    estimateCharacterTokens(text.utf16.count)
}

public func estimateTextAndImageContentTokens(_ text: String) -> Int {
    estimateTextTokens(text)
}

public func estimateTextAndImageContentTokens(_ content: [ContentBlock]) -> Int {
    var chars = 0
    for block in content {
        switch block {
        case .text(let text): chars += text.text.utf16.count
        case .image: chars += 4_800
        case .thinking, .toolCall: break
        }
    }
    return estimateCharacterTokens(chars)
}

public func estimateMessageTokens(_ message: Message) -> Int {
    switch message {
    case .system(let system):
        let removed = system.toolsRemoved?.isEmpty == false ? systemMessageToOrderedJSON(system)["toolsRemoved"] : nil
        return estimateTextTokens(getSystemMessageText(system)) + estimateToolsTokens(system.toolsAdded) +
            (removed.map { estimateTextTokens($0.serialized(escapeSlashes: false)) } ?? 0)
    case .user(let user):
        switch user.content {
        case .text(let text): return estimateTextTokens(text)
        case .blocks(let content): return estimateContentTokens(content)
        }
    case .assistant(let assistant): return estimateContentTokens(assistant.content)
    case .toolResult(let result): return estimateContentTokens(result.content)
    }
}

public func estimateContextTokens(_ context: TranscriptContext) -> ContextUsageEstimate {
    estimateContextTokens(context.messages)
}

public func estimateContextTokens(_ messages: [Message]) -> ContextUsageEstimate {
    var latestTimestamp = Int64.min
    var usageInfo: (index: Int, tokens: Int)?
    for (index, message) in messages.enumerated() {
        let timestamp: Int64
        switch message {
        case .system(let item): timestamp = item.timestamp
        case .user(let item): timestamp = item.timestamp
        case .assistant(let item):
            timestamp = item.timestamp
            // Keep the existing rule for negative provider totals.
            let amount = item.usage.totalTokens > 0 ? item.usage.totalTokens :
                item.usage.input + item.usage.output + item.usage.cacheRead + item.usage.cacheWrite
            if timestamp >= latestTimestamp && item.stopReason != .aborted && item.stopReason != .error && amount > 0 {
                usageInfo = (index, amount)
            }
        case .toolResult(let item): timestamp = item.timestamp
        }
        latestTimestamp = max(latestTimestamp, timestamp)
    }
    if let usageInfo {
        let trailingTokens = messages.dropFirst(usageInfo.index + 1).reduce(0) { $0 + estimateMessageTokens($1) }
        return ContextUsageEstimate(tokens: usageInfo.tokens + trailingTokens, usageTokens: usageInfo.tokens,
                                    trailingTokens: trailingTokens, lastUsageIndex: usageInfo.index)
    }
    let tokens = messages.reduce(0) { $0 + estimateMessageTokens($1) }
    return ContextUsageEstimate(tokens: tokens, usageTokens: 0, trailingTokens: tokens, lastUsageIndex: nil)
}

private func estimateCharacterTokens(_ chars: Int) -> Int { (2 * chars + 6) / 7 }

// Swift permits all block kinds in each role. Keep the previous estimates for
// block combinations that the upstream message types do not permit.
private func estimateContentTokens(_ content: [ContentBlock]) -> Int {
    var chars = 0
    for block in content {
        switch block {
        case .text(let text): chars += text.text.utf16.count
        case .thinking(let thinking): chars += thinking.thinking.utf16.count
        case .image: chars += 4_800
        case .toolCall(let call): chars += call.name.utf16.count + jsonString(from: call.arguments).utf16.count
        }
    }
    return estimateCharacterTokens(chars)
}

private func estimateToolsTokens(_ list: [AITool]?) -> Int {
    guard let list, !list.isEmpty else { return 0 }
    let system = SystemMessage(content: .text(""), toolsAdded: list)
    return systemMessageToOrderedJSON(system)["toolsAdded"].map {
        estimateTextTokens($0.serialized(escapeSlashes: false))
    } ?? 0
}
