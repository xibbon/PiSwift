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
    case .messageUpdate(let message, let assistantMessageEvent):
        return [
            "type": event.type,
            "message": encodeAgentMessageDict(message),
            "assistantMessageEvent": assistantMessageEventType(assistantMessageEvent),
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

private func assistantMessageEventType(_ event: AssistantMessageEvent) -> String {
    switch event {
    case .start:
        return "start"
    case .textStart:
        return "text_start"
    case .textDelta:
        return "text_delta"
    case .textEnd:
        return "text_end"
    case .thinkingStart:
        return "thinking_start"
    case .thinkingDelta:
        return "thinking_delta"
    case .thinkingEnd:
        return "thinking_end"
    case .toolCallStart:
        return "tool_call_start"
    case .toolCallDelta:
        return "tool_call_delta"
    case .toolCallEnd:
        return "tool_call_end"
    case .done:
        return "done"
    case .error:
        return "error"
    }
}
