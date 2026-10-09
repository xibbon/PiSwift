import Foundation

public func messageToJSONObject(_ message: Message) -> [String: Any] {
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
            dict["content"] = blocks.map { contentBlockToJSONObject($0) }
        }
        return dict
    case .assistant(let assistant):
        return assistantMessageToJSONObject(assistant)
    case .toolResult(let result):
        var dict: [String: Any] = [
            "role": "toolResult",
            "toolCallId": result.toolCallId,
            "toolName": result.toolName,
            "content": result.content.map { contentBlockToJSONObject($0) },
            "details": result.details?.jsonValue as Any,
            "isError": result.isError,
            "timestamp": result.timestamp,
        ]
        if let usage = result.usage { dict["usage"] = usageToJSONObject(usage) }
        if let nested = result.nestedCalls { dict["nestedCalls"] = nestedToolCallsToJSONObject(nested) }
        if let durationMs = result.durationMs { dict["durationMs"] = durationMs }
        return dict
    }
}

/// Encode a message with system section and tool argument order.
public func messageToOrderedJSON(_ message: Message) -> OrderedJSON {
    if case .system(let system) = message { return systemMessageToOrderedJSON(system) }
    let base = OrderedJSON.fromFoundation(messageToJSONObject(message))
    switch message {
    case .assistant(let assistant): return assistantMessageToOrderedJSON(assistant)
    case .toolResult(let result):
        var overrides: [String: OrderedJSON] = ["content": .array(result.content.map(contentBlockToOrderedJSON))]
        if let nested = result.nestedCalls { overrides["nestedCalls"] = nestedToolCallsToOrderedJSON(nested) }
        var object = messageToJSONObject(message)
        object.removeValue(forKey: "durationMs")
        let ordered = replacingJSONMembers(OrderedJSON.fromFoundation(object), with: overrides)
        guard let durationMs = result.durationMs, case .object(var members) = ordered else { return ordered }
        members.append(("durationMs", .number(String(durationMs))))
        return .object(members)
    case .user(let user):
        if case .blocks(let blocks) = user.content {
            return replacingJSONMembers(base, with: ["content": .array(blocks.map(contentBlockToOrderedJSON))])
        }
        return base
    case .system: return base
    }
}

public func messageFromJSONObject(_ dict: [String: Any], ordered: OrderedJSON? = nil) -> Message? {
    guard let role = dict["role"] as? String else { return nil }
    switch role {
    case "system":
        let content: SystemContent
        if let text = dict["content"] as? String { content = .text(text) }
        else if let blocks = dict["content"] as? [[String: Any]] {
            content = .blocks(blocks.compactMap { block in
                guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
                return TextContent(text: text, textSignature: block["textSignature"] as? String)
            })
        } else { content = .text("") }
        let sections: SystemPromptSections? = ordered?["sections"]?.objectEntries.map { pairs in
            SystemPromptSections(pairs.map { (name: $0.0, value: $0.1.stringValue) })
        }
        let added: [AITool]? = (dict["toolsAdded"] as? [[String: Any]])?.compactMap { item in
            guard let name = item["name"] as? String, let description = item["description"] as? String,
                  let parameters = item["parameters"] as? [String: Any] else { return nil }
            let sampling: ConstrainedSampling?
            if let value = item["constrainedSampling"] as? Bool, !value { sampling = .disabled }
            else if let config = item["constrainedSampling"] as? [String: Any], let type = config["type"] as? String {
                if type == "json_schema", let strict = config["strict"] as? String,
                   let level = ConstrainedSamplingStrictness(rawValue: strict) {
                    sampling = .jsonSchema(strict: level)
                } else if type == "grammar", let variants = config["variants"] as? [String: String] {
                    sampling = .grammar(variants: Dictionary(uniqueKeysWithValues: variants.compactMap { key, value in
                        GrammarFormat(rawValue: key).map { ($0, value) }
                    }))
                } else { sampling = nil }
            } else { sampling = nil }
            return AITool(name: name, description: description, parameters: parameters.mapValues(AnyCodable.init), constrainedSampling: sampling)
        }
        let removed = (dict["toolsRemoved"] as? [[String: Any]])?.compactMap { ($0["name"] as? String).map(ToolReference.init(name:)) }
        return .system(SystemMessage(content: content, sections: sections, toolsAdded: added, toolsRemoved: removed,
                                     timestamp: (dict["timestamp"] as? NSNumber)?.int64Value ?? 0))
    case "user":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let contentValue = dict["content"]
        let content: UserContent
        if let text = contentValue as? String {
            content = .text(text)
        } else if let blocks = contentValue as? [Any] {
            let contentBlocks = blocks.enumerated().compactMap { index, block -> ContentBlock? in
                guard let dict = block as? [String: Any] else { return nil }
                return contentBlockFromJSONObject(dict, ordered: ordered?["content"]?[index])
            }
            content = .blocks(contentBlocks)
        } else {
            content = .text("")
        }
        return .user(UserMessage(content: content, timestamp: timestamp))
    case "assistant":
        return .assistant(assistantMessageFromJSONObject(dict, ordered: ordered))
    case "toolResult":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let toolCallId = dict["toolCallId"] as? String ?? ""
        let toolName = dict["toolName"] as? String ?? ""
        let isError = dict["isError"] as? Bool ?? false
        let details = dict["details"].map { AnyCodable($0) }
        let contentBlocks = (dict["content"] as? [Any] ?? []).enumerated().compactMap { index, block -> ContentBlock? in
            guard let dict = block as? [String: Any] else { return nil }
            return contentBlockFromJSONObject(dict, ordered: ordered?["content"]?[index])
        }
        let toolResult = ToolResultMessage(toolCallId: toolCallId, toolName: toolName, content: contentBlocks, details: details,
                                           usage: (dict["usage"] as? [String: Any]).map(usageFromJSONObject),
                                           nestedCalls: (dict["nestedCalls"] as? [String: Any]).flatMap { nestedToolCallsFromJSONObject($0, ordered: ordered?["nestedCalls"]) },
                                           isError: isError, timestamp: timestamp, durationMs: dict["durationMs"] as? Int)
        return .toolResult(toolResult)
    default:
        return nil
    }
}
