import Foundation
import PiSwiftAI
import PiSwiftAgent

public func encodeSessionEvent(_ event: AgentSessionEvent) -> [String: Any] {
    encodeSessionEventObject(event)
}

private func encodeSessionEventObject(_ event: AgentSessionEvent) -> [String: Any] {
    switch event {
    case .agent(let agentEvent):
        return encodeAgentEvent(agentEvent)
    case .nestedToolExecution(let nested):
        switch nested {
        case .start(let toolCallId, let toolName, let args, let parentToolCallId):
            return ["type": "tool_execution_start", "toolCallId": toolCallId,
                    "toolName": toolName, "args": args.mapValues { $0.value },
                    "parentToolCallId": parentToolCallId]
        case .update(let toolCallId, let toolName, let args, let partialResult, let parentToolCallId):
            return ["type": "tool_execution_update", "toolCallId": toolCallId,
                    "toolName": toolName, "args": args.mapValues { $0.value },
                    "partialResult": toolResultResultToDict(partialResult),
                    "parentToolCallId": parentToolCallId]
        case .end(let toolCallId, let toolName, let result, let isError, let parentToolCallId):
            return ["type": "tool_execution_end", "toolCallId": toolCallId,
                    "toolName": toolName, "result": toolResultResultToDict(result),
                    "isError": isError, "parentToolCallId": parentToolCallId]
        }
    case .entryAppended(let entry):
        let data = encodeSessionEntry(entry).data(using: .utf8) ?? Data()
        return ["type": "entry_appended", "entry": (try? JSONSerialization.jsonObject(with: data)) ?? [:]]
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

/// JSON transport form with system section and tool argument order.
public func encodeSessionEventJSON(_ event: AgentSessionEvent) -> String {
    let dict = encodeSessionEvent(event)
    var overrides: [String: OrderedJSON] = [:]
    switch event {
    case .agent(let agentEvent):
        switch agentEvent {
        case .agentEnd(let messages): overrides["messages"] = .array(messages.map(encodeAgentMessageJSON))
        case .turnEnd(let message, let results):
            overrides["message"] = encodeAgentMessageJSON(message)
            overrides["toolResults"] = .array(results.map { result in
                replacingJSONMembers(OrderedJSON.fromFoundation(toolResultToDict(result)), with: resultMessageOverrides(result))
            })
        case .messageStart(let message), .messageEnd(let message): overrides["message"] = encodeAgentMessageJSON(message)
        case .messageUpdate(_, let delta):
            if case .toolCallEnd(_, let call, _) = delta {
                overrides["assistantMessageEvent"] = replacingJSONMembers(OrderedJSON.fromFoundation(encodeAssistantMessageEventDelta(delta)),
                    with: ["toolCall": contentBlockToOrderedJSON(.toolCall(call))])
            }
        case .toolExecutionStart(_, _, let args): overrides["args"] = toolArgumentsToOrderedJSON(args)
        case .toolExecutionUpdate(_, _, let args, let result):
            overrides["args"] = toolArgumentsToOrderedJSON(args)
            overrides["partialResult"] = orderedToolResult(result)
        case .toolExecutionEnd(_, _, let result, _, _): overrides["result"] = orderedToolResult(result)
        default: break
        }
    case .nestedToolExecution(let nested):
        switch nested {
        case .start(_, _, let args, _): overrides["args"] = toolArgumentsToOrderedJSON(args)
        case .update(_, _, let args, let result, _):
            overrides["args"] = toolArgumentsToOrderedJSON(args)
            overrides["partialResult"] = orderedToolResult(result)
        case .end(_, _, let result, _, _): overrides["result"] = orderedToolResult(result)
        }
    case .entryAppended(let entry): overrides["entry"] = try? OrderedJSON.parse(encodeSessionEntry(entry))
    default: break
    }
    return replacingJSONMembers(OrderedJSON.fromFoundation(dict), with: overrides).serialized()
}

private func resultMessageOverrides(_ result: ToolResultMessage) -> [String: OrderedJSON] {
    var overrides: [String: OrderedJSON] = ["content": .array(result.content.map(contentBlockToOrderedJSON))]
    if let nested = result.nestedCalls { overrides["nestedCalls"] = nestedToolCallsToOrderedJSON(nested) }
    return overrides
}

private func orderedToolResult(_ result: AgentToolResult) -> OrderedJSON {
    replacingJSONMembers(OrderedJSON.fromFoundation(toolResultResultToDict(result)),
        with: ["content": .array(result.content.map(contentBlockToOrderedJSON))])
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
        // Keep cumulative usage, but omit cumulative message and partial snapshots.
        var result: [String: Any] = [
            "type": event.type,
            "assistantMessageEvent": encodeAssistantMessageEventDelta(assistantMessageEvent),
        ]
        if case .assistant(let assistant) = message {
            result["usage"] = usageToJSONObject(assistant.usage)
        }
        return result
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
    case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError, _):
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
    var object: [String: Any] = [
        "toolCallId": message.toolCallId,
        "toolName": message.toolName,
        "content": message.content.map { contentBlockToDict($0) },
        "details": message.details?.jsonValue as Any,
        "isError": message.isError,
        "timestamp": message.timestamp,
    ]
    if let usage = message.usage { object["usage"] = usageToJSONObject(usage) }
    if let nested = message.nestedCalls { object["nestedCalls"] = nestedToolCallsToJSONObject(nested) }
    return object
}

private func toolResultResultToDict(_ result: AgentToolResult) -> [String: Any] {
    var object: [String: Any] = [
        "content": result.content.map { contentBlockToDict($0) },
        "details": result.details?.jsonValue as Any,
    ]
    if let structured = result.structuredContent { object["structuredContent"] = structured.value }
    if let isError = result.isError { object["isError"] = isError }
    return object
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
        var result: [String: Any] = ["type": "toolcall_start", "contentIndex": contentIndex]
        if let toolCall = toolCall(at: contentIndex, in: partial) {
            result["id"] = toolCall.id
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
