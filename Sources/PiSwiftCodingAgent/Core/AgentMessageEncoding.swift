import Foundation
import PiSwiftAI
import PiSwiftAgent

public func encodeAgentMessageDict(_ message: AgentMessage) -> [String: Any] {
    switch message {
    case .system(let system):
        return systemMessageToJSONObject(system)
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
        return assistantMessageToJSONObject(assistant)
    case .toolResult(let result):
        var dict: [String: Any] = [
            "role": "toolResult",
            "toolCallId": result.toolCallId,
            "toolName": result.toolName,
            "content": result.content.map { contentBlockToDict($0) },
            "details": result.details?.jsonValue as Any,
            "isError": result.isError,
            "timestamp": result.timestamp,
        ]
        if let usage = result.usage { dict["usage"] = usageToJSONObject(usage) }
        if let nested = result.nestedCalls { dict["nestedCalls"] = nestedToolCallsToJSONObject(nested) }
        return dict
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

/// Encode a message while retaining ordered system sections.
public func encodeAgentMessageJSON(_ message: AgentMessage) -> OrderedJSON {
    if case .system(let system) = message { return systemMessageToOrderedJSON(system) }
    return OrderedJSON.fromFoundation(encodeAgentMessageDict(message))
}
