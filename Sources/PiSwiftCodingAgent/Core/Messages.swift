import Foundation
import PiSwiftAI
import PiSwiftAgent

public let COMPACTION_SUMMARY_PREFIX = """
The conversation history before this point was compacted into the following summary:

<summary>
"""

public let COMPACTION_SUMMARY_SUFFIX = """
</summary>
"""

public let BRANCH_SUMMARY_PREFIX = """
The following is a summary of a branch that this conversation came back from:

<summary>
"""

public let BRANCH_SUMMARY_SUFFIX = "</summary>"

public struct BashExecutionMessage: Sendable {
    public var command: String
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?
    public var timestamp: Int64

    public init(
        command: String,
        output: String,
        exitCode: Int?,
        cancelled: Bool,
        truncated: Bool,
        fullOutputPath: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.truncated = truncated
        self.fullOutputPath = fullOutputPath
        self.timestamp = timestamp
    }
}

public struct HookMessage: Sendable {
    public var customType: String
    public var content: HookMessageContent
    public var display: Bool
    public var details: AnyCodable?
    public var timestamp: Int64

    public init(
        customType: String,
        content: HookMessageContent,
        display: Bool,
        details: AnyCodable? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.customType = customType
        self.content = content
        self.display = display
        self.details = details
        self.timestamp = timestamp
    }
}

public enum HookMessageContent: Sendable {
    case text(String)
    case blocks([ContentBlock])
}

public struct BranchSummaryMessage: Sendable {
    public var summary: String
    public var fromId: String?
    public var timestamp: Int64

    public init(summary: String, fromId: String? = nil, timestamp: Int64) {
        self.summary = summary
        self.fromId = fromId
        self.timestamp = timestamp
    }
}

public struct CompactionSummaryMessage: Sendable {
    public var summary: String
    public var tokensBefore: Int
    public var timestamp: Int64

    public init(summary: String, tokensBefore: Int, timestamp: Int64) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.timestamp = timestamp
    }
}

public func bashExecutionToText(_ message: BashExecutionMessage) -> String {
    var text = "Ran `\(message.command)`\n"
    if !message.output.isEmpty {
        text += "```\n\(message.output)\n```"
    } else {
        text += "(no output)"
    }
    if message.cancelled {
        text += "\n\n(command cancelled)"
    } else if let exitCode = message.exitCode, exitCode != 0 {
        text += "\n\nCommand exited with code \(exitCode)"
    }
    if message.truncated, let path = message.fullOutputPath {
        text += "\n\n[Output truncated. Full output: \(path)]"
    }
    return text
}

public func createBranchSummaryMessage(summary: String, fromId: String? = nil, timestamp: String) -> BranchSummaryMessage {
    let ts = ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return BranchSummaryMessage(summary: summary, fromId: fromId, timestamp: Int64(ts * 1000))
}

public func createCompactionSummaryMessage(summary: String, tokensBefore: Int, timestamp: String) -> CompactionSummaryMessage {
    let ts = ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return CompactionSummaryMessage(summary: summary, tokensBefore: tokensBefore, timestamp: Int64(ts * 1000))
}

public func createHookMessage(
    customType: String,
    content: HookMessageContent,
    display: Bool,
    details: AnyCodable?,
    timestamp: String
) -> HookMessage {
    let ts = ISO8601DateFormatter().date(from: timestamp)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return HookMessage(customType: customType, content: content, display: display, details: details, timestamp: Int64(ts * 1000))
}

public func convertToLlm(_ messages: [AgentMessage]) -> [Message] {
    var output: [Message] = []
    for message in messages {
        switch message {
        case .user(let user):
            output.append(.user(user))
        case .assistant(let assistant):
            output.append(.assistant(assistant))
        case .toolResult(let toolResult):
            output.append(.toolResult(toolResult))
        case .custom(let custom):
            switch custom.role {
            case "bashExecution":
                if let bash = decodeBashExecutionMessage(custom) {
                    let content = UserContent.text(bashExecutionToText(bash))
                    output.append(.user(UserMessage(content: content, timestamp: bash.timestamp)))
                }
            case "hookMessage":
                if let hook = decodeHookMessage(custom) {
                    switch hook.content {
                    case .text(let text):
                        output.append(.user(UserMessage(content: .text(text), timestamp: hook.timestamp)))
                    case .blocks(let blocks):
                        output.append(.user(UserMessage(content: .blocks(blocks), timestamp: hook.timestamp)))
                    }
                }
            case "branchSummary":
                if let summary = decodeBranchSummaryMessage(custom) {
                    let text = BRANCH_SUMMARY_PREFIX + summary.summary + BRANCH_SUMMARY_SUFFIX
                    output.append(.user(UserMessage(content: .text(text), timestamp: summary.timestamp)))
                }
            case "compactionSummary":
                if let summary = decodeCompactionSummaryMessage(custom) {
                    let text = COMPACTION_SUMMARY_PREFIX + summary.summary + COMPACTION_SUMMARY_SUFFIX
                    output.append(.user(UserMessage(content: .text(text), timestamp: summary.timestamp)))
                }
            default:
                continue
            }
        }
    }
    return output
}

public func filterImagesFromMessages(_ messages: [Message]) -> (messages: [Message], filtered: Int) {
    var filteredCount = 0
    let filteredMessages = messages.map { message -> Message in
        switch message {
        case .user(var user):
            switch user.content {
            case .blocks(let blocks):
                let (filteredBlocks, removed) = filterImageBlocks(blocks)
                filteredCount += removed
                user.content = .blocks(filteredBlocks)
                return .user(user)
            default:
                return message
            }
        case .toolResult(var toolResult):
            let (filteredBlocks, removed) = filterImageBlocks(toolResult.content)
            filteredCount += removed
            toolResult.content = filteredBlocks
            return .toolResult(toolResult)
        default:
            return message
        }
    }
    return (filteredMessages, filteredCount)
}

private func filterImageBlocks(_ blocks: [ContentBlock]) -> (blocks: [ContentBlock], removed: Int) {
    var removed = 0
    let filtered = blocks.filter { block in
        if case .image = block {
            removed += 1
            return false
        }
        return true
    }
    return (filtered, removed)
}

public func makeBashExecutionAgentMessage(_ message: BashExecutionMessage) -> AgentMessage {
    let payload: [String: Any] = [
        "command": message.command,
        "output": message.output,
        "exitCode": message.exitCode as Any,
        "cancelled": message.cancelled,
        "truncated": message.truncated,
        "fullOutputPath": message.fullOutputPath as Any,
    ]
    return .custom(AgentCustomMessage(role: "bashExecution", payload: AnyCodable(payload), timestamp: message.timestamp))
}

public func makeBranchSummaryAgentMessage(_ message: BranchSummaryMessage) -> AgentMessage {
    var payload: [String: Any] = ["summary": message.summary]
    if let fromId = message.fromId { payload["fromId"] = fromId }
    return .custom(AgentCustomMessage(role: "branchSummary", payload: AnyCodable(payload), timestamp: message.timestamp))
}

public func makeCompactionSummaryAgentMessage(_ message: CompactionSummaryMessage) -> AgentMessage {
    let payload: [String: Any] = [
        "summary": message.summary,
        "tokensBefore": message.tokensBefore,
    ]
    return .custom(AgentCustomMessage(role: "compactionSummary", payload: AnyCodable(payload), timestamp: message.timestamp))
}

public func makeHookAgentMessage(_ message: HookMessage) -> AgentMessage {
    let payload = hookMessagePayload(message)
    return .custom(AgentCustomMessage(role: "hookMessage", payload: AnyCodable(payload), timestamp: message.timestamp))
}

public enum AgentCustomDecoded: Sendable {
    case bashExecution(BashExecutionMessage)
    case hookMessage(HookMessage)
    case branchSummary(BranchSummaryMessage)
    case compactionSummary(CompactionSummaryMessage)
    case unknown(role: String, payload: AnyCodable?)
}

public extension AgentCustomMessage {
    func decode() -> AgentCustomDecoded {
        switch role {
        case "bashExecution":
            if let message = decodeBashExecutionMessage(self) {
                return .bashExecution(message)
            }
            return .unknown(role: role, payload: payload)
        case "hookMessage":
            if let message = decodeHookMessage(self) {
                return .hookMessage(message)
            }
            return .unknown(role: role, payload: payload)
        case "branchSummary":
            if let message = decodeBranchSummaryMessage(self) {
                return .branchSummary(message)
            }
            return .unknown(role: role, payload: payload)
        case "compactionSummary":
            if let message = decodeCompactionSummaryMessage(self) {
                return .compactionSummary(message)
            }
            return .unknown(role: role, payload: payload)
        default:
            return .unknown(role: role, payload: payload)
        }
    }
}

private func hookMessagePayload(_ message: HookMessage) -> [String: Any] {
    var payload: [String: Any] = [
        "customType": message.customType,
        "display": message.display,
    ]
    if let details = message.details?.value {
        payload["details"] = details
    }
    switch message.content {
    case .text(let text):
        payload["content"] = text
    case .blocks(let blocks):
        payload["content"] = blocks.map { contentBlockToDict($0) }
    }
    return payload
}

private func decodeBashExecutionMessage(_ custom: AgentCustomMessage) -> BashExecutionMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let command = payload["command"] as? String ?? ""
    let output = payload["output"] as? String ?? ""
    let exitCode = payload["exitCode"] as? Int
    let cancelled = payload["cancelled"] as? Bool ?? false
    let truncated = payload["truncated"] as? Bool ?? false
    let fullOutputPath = payload["fullOutputPath"] as? String
    return BashExecutionMessage(
        command: command,
        output: output,
        exitCode: exitCode,
        cancelled: cancelled,
        truncated: truncated,
        fullOutputPath: fullOutputPath,
        timestamp: custom.timestamp
    )
}

private func decodeHookMessage(_ custom: AgentCustomMessage) -> HookMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let customType = payload["customType"] as? String ?? ""
    let display = payload["display"] as? Bool ?? true
    let details = payload["details"].map { AnyCodable($0) }

    let contentValue = payload["content"]
    let content: HookMessageContent
    if let text = contentValue as? String {
        content = .text(text)
    } else if let blocksArray = contentValue as? [Any] {
        content = .blocks(blocksArray.compactMap { dict in
            guard let dict = dict as? [String: Any] else { return nil }
            return contentBlockFromDict(dict)
        })
    } else {
        content = .text("")
    }

    return HookMessage(customType: customType, content: content, display: display, details: details, timestamp: custom.timestamp)
}

private func decodeBranchSummaryMessage(_ custom: AgentCustomMessage) -> BranchSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let fromId = payload["fromId"] as? String
    return BranchSummaryMessage(summary: summary, fromId: fromId, timestamp: custom.timestamp)
}

private func decodeCompactionSummaryMessage(_ custom: AgentCustomMessage) -> CompactionSummaryMessage? {
    guard let payload = custom.payload?.value as? [String: Any] else { return nil }
    let summary = payload["summary"] as? String ?? ""
    let tokensBefore = payload["tokensBefore"] as? Int ?? 0
    return CompactionSummaryMessage(summary: summary, tokensBefore: tokensBefore, timestamp: custom.timestamp)
}

// Content-block serialization has a single source of truth in PiSwiftAI
// (`contentBlockToJSONObject` / `contentBlockFromJSONObject`). These thin aliases preserve the
// in-module call sites and the public `contentBlockFromDict` API surface.
func contentBlockToDict(_ block: ContentBlock) -> [String: Any] {
    contentBlockToJSONObject(block)
}

public func contentBlockFromDict(_ dict: [String: Any]) -> ContentBlock? {
    contentBlockFromJSONObject(dict)
}
