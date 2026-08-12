import Foundation
import PiSwiftAI
import PiSwiftAgent

public func encodeSessionEvent(_ event: AgentSessionEvent) -> [String: Any] {
    switch event {
    case .agent(let agentEvent):
        return encodeAgentEvent(agentEvent)
    case .agentSettled:
        return ["type": "agent_settled"]
    case .autoCompactionStart(let reason):
        return [
            "type": "auto_compaction_start",
            "reason": reason.rawValue,
        ]
    case .autoCompactionEnd(let result, let aborted, let willRetry):
        var dict: [String: Any] = [
            "type": "auto_compaction_end",
            "aborted": aborted,
            "willRetry": willRetry,
        ]
        if let result {
            dict["result"] = [
                "summary": result.summary,
                "firstKeptEntryId": result.firstKeptEntryId,
                "tokensBefore": result.tokensBefore,
                "details": result.details?.jsonValue as Any,
            ]
        }
        return dict
    case .autoRetryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
        return [
            "type": "auto_retry_start",
            "attempt": attempt,
            "maxAttempts": maxAttempts,
            "delayMs": delayMs,
            "errorMessage": errorMessage,
        ]
    case .autoRetryEnd(let success, let attempt, let finalError):
        return [
            "type": "auto_retry_end",
            "success": success,
            "attempt": attempt,
            "finalError": finalError as Any,
        ]
    }
}

func encodeAgentEvent(_ event: AgentEvent) -> [String: Any] {
    switch event {
    case .agentStart:
        return ["type": event.type]
    case .agentEnd(let messages):
        return [
            "type": event.type,
            "messages": messages.map { encodeAgentMessageDict($0) },
        ]
    case .turnStart:
        return ["type": event.type]
    case .turnEnd(let message, let toolResults):
        return [
            "type": event.type,
            "message": encodeAgentMessageDict(message),
            "toolResults": toolResults.map { toolResultToDict($0) },
        ]
    case .messageStart(let message):
        return ["type": event.type, "message": encodeAgentMessageDict(message)]
    case .messageUpdate(_, let assistantMessageEvent):
        // Streaming wire contract: message_update contains only a usable delta event.
        // The outer object is
        // {"type":"message_update","assistantMessageEvent":{...}}.
        // Delta objects use `type`; content-block events also use `contentIndex`;
        // text/thinking deltas use `delta`; their end events use `content`;
        // tool-call events use `toolCallId`/`toolName`, argument chunks use `delta`,
        // and tool_call_end uses the authoritative `toolCall` object. Done/error
        // events use `reason`, and error can include `errorMessage`. No cumulative
        // `message` or `partial` assistant snapshot is emitted here. Clients assemble
        // updates after message_start and replace the result with message_end.
        return [
            "type": event.type,
            "assistantMessageEvent": encodeAssistantMessageEventDelta(assistantMessageEvent),
        ]
    case .messageEnd(let message):
        return ["type": event.type, "message": encodeAgentMessageDict(message)]
    case .toolExecutionStart(let toolCallId, let toolName, let args):
        return [
            "type": event.type,
            "toolCallId": toolCallId,
            "toolName": toolName,
            "args": args.mapValues { $0.value },
        ]
    case .toolExecutionUpdate(let toolCallId, let toolName, let args, let partialResult):
        return [
            "type": event.type,
            "toolCallId": toolCallId,
            "toolName": toolName,
            "args": args.mapValues { $0.value },
            "partialResult": toolResultResultToDict(partialResult),
        ]
    case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError):
        return [
            "type": event.type,
            "toolCallId": toolCallId,
            "toolName": toolName,
            "result": toolResultResultToDict(result),
            "isError": isError,
        ]
    }
}

private func toolResultToDict(_ message: ToolResultMessage) -> [String: Any] {
    [
        "toolCallId": message.toolCallId,
        "toolName": message.toolName,
        "content": message.content.map { contentBlockToDict($0) },
        "details": message.details?.jsonValue as Any,
        "isError": message.isError,
        "timestamp": message.timestamp,
    ]
}

private func toolResultResultToDict(_ result: AgentToolResult) -> [String: Any] {
    [
        "content": result.content.map { contentBlockToDict($0) },
        "details": result.details?.jsonValue as Any,
    ]
}

private func toolCall(at contentIndex: Int, in partial: AssistantMessage) -> ToolCall? {
    guard partial.content.indices.contains(contentIndex),
          case .toolCall(let toolCall) = partial.content[contentIndex] else {
        return nil
    }
    return toolCall
}

private func encodeToolCall(_ toolCall: ToolCall) -> [String: Any] {
    contentBlockToDict(.toolCall(toolCall))
}

private func encodeAssistantMessageEventDelta(_ event: AssistantMessageEvent) -> [String: Any] {
    switch event {
    case .start:
        return ["type": "start"]
    case .textStart(let contentIndex, _):
        return ["type": "text_start", "contentIndex": contentIndex]
    case .textDelta(let contentIndex, let delta, _):
        return ["type": "text_delta", "contentIndex": contentIndex, "delta": delta]
    case .textEnd(let contentIndex, let content, _):
        return ["type": "text_end", "contentIndex": contentIndex, "content": content]
    case .thinkingStart(let contentIndex, _):
        return ["type": "thinking_start", "contentIndex": contentIndex]
    case .thinkingDelta(let contentIndex, let delta, _):
        return ["type": "thinking_delta", "contentIndex": contentIndex, "delta": delta]
    case .thinkingEnd(let contentIndex, let content, _):
        return ["type": "thinking_end", "contentIndex": contentIndex, "content": content]
    case .toolCallStart(let contentIndex, let partial):
        var result: [String: Any] = ["type": "tool_call_start", "contentIndex": contentIndex]
        if let toolCall = toolCall(at: contentIndex, in: partial) {
            result["toolCallId"] = toolCall.id
            result["toolName"] = toolCall.name
        }
        return result
    case .toolCallDelta(let contentIndex, let delta, let partial):
        var result: [String: Any] = [
            "type": "tool_call_delta",
            "contentIndex": contentIndex,
            "delta": delta,
        ]
        if let toolCall = toolCall(at: contentIndex, in: partial) {
            result["toolCallId"] = toolCall.id
            result["toolName"] = toolCall.name
        }
        return result
    case .toolCallEnd(let contentIndex, let toolCall, _):
        return [
            "type": "tool_call_end",
            "contentIndex": contentIndex,
            "toolCallId": toolCall.id,
            "toolName": toolCall.name,
            "toolCall": encodeToolCall(toolCall),
        ]
    case .done(let reason, _):
        return ["type": "done", "reason": reason.rawValue]
    case .error(let reason, let error):
        var result: [String: Any] = ["type": "error", "reason": reason.rawValue]
        if let errorMessage = error.errorMessage {
            result["errorMessage"] = errorMessage
        }
        return result
    }
}
