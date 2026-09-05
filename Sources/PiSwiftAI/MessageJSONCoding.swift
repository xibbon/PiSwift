import Foundation

// MARK: - Canonical JSON-object codec for content blocks and usage
//
// Single source of truth for how a `ContentBlock` / `Usage` serializes to the JSON shape used by
// session persistence, session-event streaming, HTML export, and the proxy transport. Every
// consumer delegates here so a new or changed field can never be covered by one encoder and
// silently dropped by another (the class of bug that made redacted-thinking / reasoning-signature
// sessions unresumable). These emit/accept Foundation `[String: Any]` objects (JSONSerialization
// shape); Codable consumers bridge through `AnyCodable`.

public func contentBlockToJSONObject(_ block: ContentBlock) -> [String: Any] {
    switch block {
    case .text(let text):
        // `textSignature` carries provider reasoning-item references (OpenAI Responses
        // item ids, Gemini thought signatures). Dropping it corrupts resume for those
        // providers, so persist it whenever present.
        var dict: [String: Any] = ["type": "text", "text": text.text]
        if let signature = text.textSignature { dict["textSignature"] = signature }
        return dict
    case .thinking(let thinking):
        // `redacted` marks a `redacted_thinking` block whose `thinkingSignature` holds an
        // opaque encrypted payload (NOT a normal thinking signature). Losing the flag on
        // round-trip makes the outbound Anthropic path emit an invalid `thinking` block,
        // so the whole resumed conversation is rejected. Persist it.
        var dict: [String: Any] = ["type": "thinking", "thinking": thinking.thinking]
        if let signature = thinking.thinkingSignature { dict["thinkingSignature"] = signature }
        if let redacted = thinking.redacted { dict["redacted"] = redacted }
        return dict
    case .image(let image):
        return ["type": "image", "data": image.data, "mimeType": image.mimeType]
    case .toolCall(let call):
        var dict: [String: Any] = ["type": "toolCall", "id": call.id, "name": call.name, "arguments": call.arguments.mapValues { $0.value }]
        if let namespace = call.namespace { dict["namespace"] = namespace }
        if let signature = call.thoughtSignature { dict["thoughtSignature"] = signature }
        return dict
    }
}

public func contentBlockFromJSONObject(_ dict: [String: Any]) -> ContentBlock? {
    guard let type = dict["type"] as? String else { return nil }
    switch type {
    case "text":
        return .text(TextContent(
            text: dict["text"] as? String ?? "",
            textSignature: dict["textSignature"] as? String
        ))
    case "thinking":
        return .thinking(ThinkingContent(
            thinking: dict["thinking"] as? String ?? "",
            thinkingSignature: dict["thinkingSignature"] as? String,
            redacted: dict["redacted"] as? Bool
        ))
    case "image":
        guard let data = dict["data"] as? String else { return nil }
        return .image(ImageContent(data: data, mimeType: dict["mimeType"] as? String ?? ""))
    case "toolCall":
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        let args = dict["arguments"] as? [String: Any] ?? [:]
        let anyArgs = args.mapValues { AnyCodable($0) }
        return .toolCall(ToolCall(id: id, name: name, arguments: anyArgs, thoughtSignature: dict["thoughtSignature"] as? String, namespace: dict["namespace"] as? String))
    default:
        return nil
    }
}

public func usageToJSONObject(_ usage: Usage) -> [String: Any] {
    var result: [String: Any] = [
        "input": usage.input,
        "output": usage.output,
        "cacheRead": usage.cacheRead,
        "cacheWrite": usage.cacheWrite,
        "totalTokens": usage.totalTokens,
        "cost": [
            "input": usage.cost.input,
            "output": usage.cost.output,
            "cacheRead": usage.cost.cacheRead,
            "cacheWrite": usage.cost.cacheWrite,
            "total": usage.cost.total,
        ],
    ]
    if let reasoning = usage.reasoning { result["reasoning"] = reasoning }
    return result
}

public func usageFromJSONObject(_ dict: [String: Any]) -> Usage {
    let input = dict["input"] as? Int ?? 0
    let output = dict["output"] as? Int ?? 0
    let cacheRead = dict["cacheRead"] as? Int ?? 0
    let cacheWrite = dict["cacheWrite"] as? Int ?? 0
    let totalTokens = dict["totalTokens"] as? Int ?? (input + output + cacheRead + cacheWrite)
    var usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: dict["reasoning"] as? Int, totalTokens: totalTokens)
    if let cost = dict["cost"] as? [String: Any] {
        usage.cost.input = cost["input"] as? Double ?? 0
        usage.cost.output = cost["output"] as? Double ?? 0
        usage.cost.cacheRead = cost["cacheRead"] as? Double ?? 0
        usage.cost.cacheWrite = cost["cacheWrite"] as? Double ?? 0
        usage.cost.total = cost["total"] as? Double ?? 0
    }
    return usage
}

public func assistantMessageToJSONObject(_ message: AssistantMessage) -> [String: Any] {
    var result: [String: Any] = [
        "role": "assistant", "content": message.content.map(contentBlockToJSONObject),
        "api": message.api.rawValue, "provider": message.provider, "model": message.model,
        "usage": usageToJSONObject(message.usage), "stopReason": message.stopReason.rawValue,
        "timestamp": Int(message.timestamp),
    ]
    if let value = message.responseId { result["responseId"] = value }
    if let value = message.providerThinkingLevel { result["providerThinkingLevel"] = value }
    if let value = message.endTurn { result["endTurn"] = value }
    if let value = message.errorMessage { result["errorMessage"] = value }
    if let value = message.rawStopReason { result["rawStopReason"] = value }
    if let values = message.diagnostics {
        result["diagnostics"] = values.map { ["type": $0.type, "timestamp": Int($0.timestamp), "details": $0.details.mapValues(\.value)] as [String: Any] }
    }
    if let value = message.deferred {
        var deferred: [String: Any] = ["provider": value.provider, "modelId": value.modelId, "api": value.api, "id": value.id]
        if let expiresAt = value.expiresAt { deferred["expiresAt"] = expiresAt }
        if let pollAfterMs = value.pollAfterMs { deferred["pollAfterMs"] = pollAfterMs }
        if let data = value.data { deferred["data"] = data.value }
        result["deferred"] = deferred
    }
    return result
}

public func assistantMessageFromJSONObject(_ dict: [String: Any]) -> AssistantMessage {
    var message = AssistantMessage(
        content: (dict["content"] as? [[String: Any]] ?? []).compactMap(contentBlockFromJSONObject),
        api: Api(rawValue: dict["api"] as? String ?? "") ?? .openAIResponses,
        provider: dict["provider"] as? String ?? "", model: dict["model"] as? String ?? "",
        responseId: dict["responseId"] as? String,
        usage: usageFromJSONObject(dict["usage"] as? [String: Any] ?? [:]),
        stopReason: StopReason(rawValue: dict["stopReason"] as? String ?? "stop") ?? .stop,
        errorMessage: dict["errorMessage"] as? String,
        timestamp: (dict["timestamp"] as? NSNumber)?.int64Value ?? 0,
        rawStopReason: dict["rawStopReason"] as? String,
        diagnostics: (dict["diagnostics"] as? [[String: Any]])?.compactMap {
            guard let type = $0["type"] as? String else { return nil }
            return AssistantMessageDiagnostic(type: type, timestamp: ($0["timestamp"] as? NSNumber)?.int64Value ?? 0,
                details: ($0["details"] as? [String: Any] ?? [:]).mapValues(AnyCodable.init))
        },
        providerThinkingLevel: dict["providerThinkingLevel"] as? String,
        endTurn: dict["endTurn"] as? Bool
    )
    if let value = dict["deferred"] as? [String: Any], let provider = value["provider"] as? String,
       let modelId = value["modelId"] as? String, let api = value["api"] as? String, let id = value["id"] as? String {
        message.deferred = DeferredHandle(provider: provider, modelId: modelId, api: api, id: id,
            expiresAt: (value["expiresAt"] as? NSNumber)?.int64Value, pollAfterMs: value["pollAfterMs"] as? Int,
            data: value["data"].map(AnyCodable.init))
    }
    return message
}
