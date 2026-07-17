import Foundation
import PiSwiftAI
import PiSwiftAgent

public func encodeAgentMessageDict(_ message: AgentMessage) -> [String: Any] {
    switch message {
    case .user(let user):
        var dict: [String: Any] = [
            "role": "user",
            "timestamp": user.timestamp,
        ]
        switch user.content {
        case .text(let text):
            dict["content"] = text
        case .blocks(let blocks):
            dict["content"] = blocks.map { contentBlockToDict($0) }
        }
        return dict
    case .assistant(let assistant):
        return [
            "role": "assistant",
            "content": assistant.content.map { contentBlockToDict($0) },
            "api": assistant.api.rawValue,
            "provider": assistant.provider,
            "model": assistant.model,
            "usage": encodeUsage(assistant.usage),
            "stopReason": assistant.stopReason.rawValue,
            "timestamp": assistant.timestamp,
            "errorMessage": assistant.errorMessage as Any,
        ]
    case .toolResult(let result):
        return [
            "role": "toolResult",
            "toolCallId": result.toolCallId,
            "toolName": result.toolName,
            "content": result.content.map { contentBlockToDict($0) },
            "details": result.details?.jsonValue as Any,
            "isError": result.isError,
            "timestamp": result.timestamp,
        ]
    case .custom(let custom):
        var dict: [String: Any] = ["role": custom.role, "timestamp": custom.timestamp]
        if let payload = custom.payload?.jsonValue as? [String: Any] {
            for (key, value) in payload {
                dict[key] = value
            }
        }
        return dict
    }
}

private func encodeUsage(_ usage: Usage) -> [String: Any] {
    usageToJSONObject(usage)
}
