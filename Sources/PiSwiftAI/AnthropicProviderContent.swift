import Foundation

/// Block types `AssistantMessage.content` models. A reply holding any other type, such as a
/// server tool call or its result, keeps its wire blocks in `providerContent`.
private let anthropicModeledBlockTypes: Set<String> = ["text", "thinking", "redacted_thinking", "tool_use", "fallback"]

/// Rebuilds the reply's wire content blocks from stream events.
struct AnthropicRawContent {
    private var blocks: [Int: [String: Any]] = [:]
    /// Streamed string fields by block, kept apart so each delta appends in place.
    private var strings: [Int: [String: String]] = [:]
    private var citations: [Int: [Any]] = [:]

    mutating func start(index: Int, block: [String: Any]) {
        blocks[index] = block
    }

    mutating func apply(index: Int, delta: [String: Any]) {
        guard blocks[index] != nil else { return }
        switch delta["type"] as? String {
        case "text_delta": append(delta["text"], to: "text", index: index)
        case "thinking_delta": append(delta["thinking"], to: "thinking", index: index)
        case "signature_delta": append(delta["signature"], to: "signature", index: index)
        case "input_json_delta": append(delta["partial_json"], to: "input", index: index)
        case "citations_delta":
            if let citation = delta["citation"] { citations[index, default: []].append(citation) }
        default:
            break
        }
    }

    private mutating func append(_ value: Any?, to field: String, index: Int) {
        strings[index, default: [:]][field, default: ""] += value as? String ?? ""
    }

    mutating func stop(index: Int) {
        guard var block = blocks[index] else { return }
        for (field, value) in strings.removeValue(forKey: index) ?? [:] {
            if field != "input" {
                block[field] = (block[field] as? String ?? "") + value
            } else if let data = value.data(using: .utf8), let input = try? JSONSerialization.jsonObject(with: data) {
                block["input"] = input
            }
        }
        if let added = citations.removeValue(forKey: index) {
            block["citations"] = (block["citations"] as? [Any] ?? []) + added
        }
        blocks[index] = block
    }

    /// The reply's blocks in order.
    var content: [[String: Any]] {
        blocks.sorted { $0.key < $1.key }.map { $0.value.filter { !($0.value is NSNull) } }
    }

    /// The reply's blocks, or nil when `AssistantMessage.content` represents all of them.
    /// Cited text counts as unmodeled: `TextContent` has no field for citations, and a reply can
    /// cite an earlier search without a new server tool call.
    var unmodeledContent: [[String: Any]]? {
        let content = content
        guard content.contains(where: { block in
            !anthropicModeledBlockTypes.contains(block["type"] as? String ?? "")
                || (block["citations"] as? [Any])?.isEmpty == false
        }) else { return nil }
        return content
    }
}

/// Whether the API accepts `block` in a request. It rejects text without visible characters,
/// and a `fallback` block is a response-only marker.
private func anthropicCanReplay(_ block: [String: Any]) -> Bool {
    switch block["type"] as? String {
    case "fallback": return false
    case "text": return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    default: return true
    }
}

private let anthropicProviderContentMarker = "\u{E000}pi-provider-content:"

/// The wire blocks to replay for `assistant`, or nil when it is converted from `content`.
/// Server tool results only replay to the model that produced them.
func anthropicProviderContent(_ assistant: AssistantMessage, model: Model) -> [[String: Any]]? {
    guard assistant.provider == model.provider, assistant.api == model.api, assistant.model == model.id,
          assistant.responseId != nil,
          let stored = assistant.providerContent?.value as? [[String: Any]] else { return nil }
    let blocks = stored.filter(anthropicCanReplay)
    return blocks.isEmpty ? nil : blocks
}

/// Stands in for the assistant's content until the encoded body is patched, since the SDK's
/// content types cannot hold server tool blocks.
func anthropicProviderContentPlaceholder(_ assistant: AssistantMessage) -> String {
    anthropicProviderContentMarker + (assistant.responseId ?? "")
}

/// Replaces each replayed assistant message's placeholder with its wire blocks.
func restoreAnthropicProviderContent(_ body: Data, model: Model, messages: [Message]) throws -> Data {
    let replies = anthropicProviderContentByResponse(model: model, messages: messages)
    guard !replies.isEmpty else { return body }
    var payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    guard let wireMessages = payload["messages"] as? [[String: Any]] else { return body }
    payload["messages"] = wireMessages.map { restoreAnthropicProviderContent($0, replies: replies) }
    return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
}

func anthropicProviderContentByResponse(model: Model, messages: [Message]) -> [String: [[String: Any]]] {
    var replies: [String: [[String: Any]]] = [:]
    for message in messages {
        guard case .assistant(let assistant) = message, let id = assistant.responseId,
              let blocks = anthropicProviderContent(assistant, model: model) else { continue }
        replies[id] = blocks
    }
    return replies
}

func restoreAnthropicProviderContent(_ message: [String: Any], replies: [String: [[String: Any]]]) -> [String: Any] {
    guard message["role"] as? String == "assistant", let blocks = message["content"] as? [[String: Any]],
          blocks.count == 1, let text = blocks[0]["text"] as? String, text.hasPrefix(anthropicProviderContentMarker),
          var content = replies[String(text.dropFirst(anthropicProviderContentMarker.count))], !content.isEmpty
    else { return message }
    if let cacheControl = blocks[0]["cache_control"] { content[content.count - 1]["cache_control"] = cacheControl }
    var restored = message
    restored["content"] = content
    return restored
}
