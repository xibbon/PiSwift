import Foundation
import CoreFoundation
import PiSwiftAI
import PiSwiftChord

/// Errors from the optional typed message view and Foundation bridge.
public enum DurableJSONBridgeError: Error, Sendable, Equatable {
    case unsupportedFoundationValue
    case invalidMessage(index: Int)
}

/// Converts a JSON tree for A0's message decoder. Object order is supplied separately.
/// Foundation dictionaries can merge canonically equivalent keys. Use OrderedJSON
/// for order and scalar key identity, and keep the original tree for storage.
public func foundationJSON(from value: JSONValue) throws -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let value): return NSNumber(value: value)
    case .number(let value):
        guard value.isFinite else { throw JSONValueError.nonFiniteNumber }
        return NSNumber(value: value)
    case .string(let value): return value
    case .array(let values): return try values.map(foundationJSON)
    case .object(let object):
        var result: [String: Any] = [:]
        for (key, value) in object { result[key] = try foundationJSON(from: value) }
        return result
    }
}

/// Converts Foundation JSON to a tree. Foundation supplies no object key order.
public func durableJSON(fromFoundation value: Any) throws -> JSONValue {
    if value is NSNull { return .null }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
        guard value.doubleValue.isFinite else { throw JSONValueError.nonFiniteNumber }
        return .number(value.doubleValue)
    }
    if let value = value as? String { return .string(value) }
    if let value = value as? [Any] { return .array(try value.map { try durableJSON(fromFoundation: $0) }) }
    if let value = value as? [String: Any] {
        return .object(try JSONObject(value.keys.sorted().map { ($0, try durableJSON(fromFoundation: value[$0]!)) }))
    }
    throw DurableJSONBridgeError.unsupportedFoundationValue
}

/// Converts a JSON tree to A0's ordered message representation.
public func orderedJSON(from value: JSONValue) throws -> OrderedJSON {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .number: return .number(try value.jsonText())
    case .string(let value): return .string(value)
    case .array(let values): return .array(try values.map(orderedJSON))
    case .object(let object): return .object(try object.map { ($0.key, try orderedJSON(from: $0.value)) })
    }
}

/// Converts A0's ordered representation to a JSON tree.
/// Number text uses CH1's strict parser, including its finite Double check.
public func durableJSON(fromOrdered value: OrderedJSON) throws -> JSONValue {
    switch value {
    case .null: return .null
    case .bool(let value): return .bool(value)
    case .number(let text):
        let parsed = try JSONValue(jsonText: text)
        guard case .number = parsed else { throw DurableJSONBridgeError.unsupportedFoundationValue }
        return parsed
    case .string(let value): return .string(value)
    case .array(let values): return .array(try values.map { try durableJSON(fromOrdered: $0) })
    case .object(let pairs): return .object(try JSONObject(pairs.map { ($0.0, try durableJSON(fromOrdered: $0.1)) }))
    }
}

extension EntryRecord {
    /// Decodes the model messages through A0. Returns nil when model is absent.
    /// The stored JSON remains lossless, including fields unknown to A0.
    public func messages() throws -> [Message]? {
        try model?.enumerated().map { index, value in
            guard let object = try foundationJSON(from: value) as? [String: Any],
                  let message = messageFromJSONObject(object, ordered: try orderedJSON(from: value)) else {
                throw DurableJSONBridgeError.invalidMessage(index: index)
            }
            return message
        }
    }

    /// Builds an entry with model messages encoded by A0 in source order.
    public static func withMessages(
        id: EntryID, conversationId: ConversationID, kind: String, messages: [Message],
        data: JSONValue? = nil, head: EntryID? = nil, edits: [ContextEdit]? = nil,
        byTaskId: TaskID? = nil
    ) throws -> EntryRecord {
        EntryRecord(id: id, conversationId: conversationId, kind: kind,
                    model: try encodeMessages(messages), data: data, head: head,
                    edits: edits, byTaskId: byTaskId)
    }

    /// Encodes typed messages to opaque JSON values for a record or draft.
    public static func encodeMessages(_ messages: [Message]) throws -> [JSONValue] {
        try messages.map { try durableJSON(fromOrdered: messageToOrderedJSON($0)) }
    }
}
