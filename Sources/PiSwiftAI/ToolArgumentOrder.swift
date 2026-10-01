import Foundation

/// Return current values in stored order. Drop missing keys and append new keys sorted.
/// Without stored order, place JavaScript array-index keys first, then sort other keys.
public func orderedToolArguments(_ call: ToolCall) -> [(key: String, value: AnyCodable)] {
    orderedToolArguments(call.arguments, argumentsJSON: call.argumentsJSON)
}

/// Dictionary form for tool execution events and extension renderers.
public func orderedToolArguments(
    _ arguments: [String: AnyCodable], argumentsJSON: OrderedJSON? = nil
) -> [(key: String, value: AnyCodable)] {
    let source = argumentsJSON ?? toolArgumentsSource(arguments)
    let keys = orderedKeys(Array(arguments.keys), source: source)
    return keys.compactMap { key in arguments[key].map { (key, $0) } }
}

/// Retain order through the existing dictionary-based tool execution APIs.
/// This metadata does not change AnyCodable equality or provider request encoding.
public func toolArgumentsWithOrder(
    _ arguments: [String: AnyCodable], argumentsJSON: OrderedJSON?
) -> [String: AnyCodable] {
    guard let argumentsJSON, argumentsJSON.objectEntries != nil else { return arguments }
    return arguments.mapValues { value in
        var copy = value
        copy.toolArgumentsSource = argumentsJSON
        return copy
    }
}

/// Read the order metadata retained in a tool execution argument dictionary.
public func toolArgumentsSource(_ arguments: [String: AnyCodable]) -> OrderedJSON? {
    arguments.values.compactMap(\.toolArgumentsSource).first
}

/// Emit current values with stored object order, including nested objects.
public func toolArgumentsToOrderedJSON(
    _ arguments: [String: AnyCodable], argumentsJSON: OrderedJSON? = nil
) -> OrderedJSON {
    mergeArgumentOrder(OrderedJSON.fromFoundation(arguments.mapValues(\.value)),
                       source: argumentsJSON ?? toolArgumentsSource(arguments))
}

/// Capture JSON.parse property order, including its last-value rule for repeated keys.
public func parseToolArgumentsSource(_ text: String) -> OrderedJSON? {
    guard let value = try? OrderedJSON.parse(text, allowDuplicateKeys: true) else { return nil }
    return toolArgumentsSource(value)
}

/// Use an already parsed wire subtree without parsing its argument values again.
public func toolArgumentsSource(_ value: OrderedJSON) -> OrderedJSON? {
    guard value.objectEntries != nil else { return nil }
    return javascriptPropertyOrder(value)
}

func javascriptPropertyOrder(_ value: OrderedJSON) -> OrderedJSON {
    switch value {
    case .object(let pairs):
        let indices = pairs.filter { arrayIndex($0.0) != nil }.sorted { arrayIndex($0.0)! < arrayIndex($1.0)! }
        let strings = pairs.filter { arrayIndex($0.0) == nil }
        return .object((indices + strings).map { ($0.0, javascriptPropertyOrder($0.1)) })
    case .array(let values): return .array(values.map(javascriptPropertyOrder))
    default: return value
    }
}

private func arrayIndex(_ key: String) -> UInt32? {
    guard let value = UInt32(key), value < UInt32.max, String(value) == key else { return nil }
    return value
}

private func orderedKeys(_ keys: [String], source: OrderedJSON?) -> [String] {
    if let pairs = source?.objectEntries {
        let available = Set(keys)
        var seen: Set<String> = []
        let stored = pairs.map(\.0).filter { available.contains($0) && seen.insert($0).inserted }
        return stored + keys.filter { !seen.contains($0) }.sorted()
    }
    let indices = keys.filter { arrayIndex($0) != nil }.sorted { arrayIndex($0)! < arrayIndex($1)! }
    return indices + keys.filter { arrayIndex($0) == nil }.sorted()
}

private func mergeArgumentOrder(_ current: OrderedJSON, source: OrderedJSON?) -> OrderedJSON {
    switch current {
    case .object(let pairs):
        let values = Dictionary(uniqueKeysWithValues: pairs)
        return .object(orderedKeys(pairs.map(\.0), source: source).map { key in
            (key, mergeArgumentOrder(values[key]!, source: source?[key]))
        })
    case .array(let values):
        let original: [OrderedJSON]
        if case .array(let items) = source { original = items } else { original = [] }
        return .array(values.enumerated().map { index, value in
            mergeArgumentOrder(value, source: original.indices.contains(index) ? original[index] : nil)
        })
    default: return current
    }
}

/// Replace selected object members without changing the other members or their order.
public func replacingJSONMembers(_ value: OrderedJSON, with replacements: [String: OrderedJSON]) -> OrderedJSON {
    guard let pairs = value.objectEntries else { return value }
    return .object(pairs.map { ($0.0, replacements[$0.0] ?? $0.1) })
}

/// Test a decoded object before doing the second, order-preserving parse.
/// Ignore arbitrary details and payload objects, which can have unrelated field names.
public func jsonObjectCarriesToolArguments(_ object: [String: Any]) -> Bool {
    if object["type"] as? String == "toolCall" { return object["arguments"] is [String: Any] }
    if let type = object["type"] as? String, type.hasPrefix("tool_execution_"), object["args"] is [String: Any] { return true }
    if let calls = object["calls"] as? [[String: Any]], object["complete"] is Bool {
        return calls.contains { $0["arguments"] is [String: Any] }
    }
    for key in ["message", "entry", "systemMessage", "toolCall", "partial", "assistantMessageEvent", "nestedCalls", "result", "partialResult", "replacement"] {
        if let child = object[key] as? [String: Any], jsonObjectCarriesToolArguments(child) { return true }
    }
    for key in ["content", "messages", "toolResults"] {
        if let children = object[key] as? [[String: Any]], children.contains(where: jsonObjectCarriesToolArguments) { return true }
    }
    return false
}

/// Copy only tool argument objects into an existing JSON tree.
/// Session envelopes and unrelated field order retain their existing encoding.
public func replacingToolArgumentObjects(_ value: OrderedJSON, using ordered: OrderedJSON) -> OrderedJSON {
    switch value {
    case .object(let pairs):
        return .object(pairs.map { key, member in
            guard let source = ordered[key] else { return (key, member) }
            let type = value["type"]?.stringValue ?? ""
            let isCall = type == "toolCall" || type == "toolcall_end" || (value["status"] != nil && value["id"] != nil && value["name"] != nil)
            if source.objectEntries != nil,
               (key == "arguments" && isCall || key == "args" && type.hasPrefix("tool_execution_")) { return (key, source) }
            let paths: Set<String> = ["message", "entry", "partial", "toolCall", "assistantMessageEvent", "nestedCalls", "result", "partialResult", "replacement", "content", "messages", "toolResults", "calls"]
            guard paths.contains(key) else { return (key, member) }
            return (key, replacingToolArgumentObjects(member, using: source))
        })
    case .array(let items):
        return .array(items.enumerated().map { index, member in
            ordered[index].map { replacingToolArgumentObjects(member, using: $0) } ?? member
        })
    default: return value
    }
}
