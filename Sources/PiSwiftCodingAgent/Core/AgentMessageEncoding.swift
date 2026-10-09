import Foundation
import PiSwiftAI
import PiSwiftAgent

public func encodeAgentMessageDict(_ message: AgentMessage) -> [String: Any] {
    switch message {
    case .system(let system): return messageToJSONObject(.system(system))
    case .user(let user): return messageToJSONObject(.user(user))
    case .assistant(let assistant): return messageToJSONObject(.assistant(assistant))
    case .toolResult(let result): return messageToJSONObject(.toolResult(result))
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

/// Encode a message with system section and tool argument order.
public func encodeAgentMessageJSON(_ message: AgentMessage) -> OrderedJSON {
    if let message = message.asMessage { return messageToOrderedJSON(message) }
    return OrderedJSON.fromFoundation(encodeAgentMessageDict(message))
}
