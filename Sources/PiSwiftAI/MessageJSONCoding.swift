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
        return ["type": "toolCall", "id": call.id, "name": call.name, "arguments": call.arguments.mapValues { $0.value }]
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
        return .toolCall(ToolCall(id: id, name: name, arguments: anyArgs))
    default:
        return nil
    }
}

public func usageToJSONObject(_ usage: Usage) -> [String: Any] {
    [
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
}

public func usageFromJSONObject(_ dict: [String: Any]) -> Usage {
    let input = dict["input"] as? Int ?? 0
    let output = dict["output"] as? Int ?? 0
    let cacheRead = dict["cacheRead"] as? Int ?? 0
    let cacheWrite = dict["cacheWrite"] as? Int ?? 0
    let totalTokens = dict["totalTokens"] as? Int ?? (input + output + cacheRead + cacheWrite)
    var usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: totalTokens)
    if let cost = dict["cost"] as? [String: Any] {
        usage.cost.input = cost["input"] as? Double ?? 0
        usage.cost.output = cost["output"] as? Double ?? 0
        usage.cost.cacheRead = cost["cacheRead"] as? Double ?? 0
        usage.cost.cacheWrite = cost["cacheWrite"] as? Double ?? 0
        usage.cost.total = cost["total"] as? Double ?? 0
    }
    return usage
}
