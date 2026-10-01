import Foundation
import CoreFoundation

/// JSON value with object members retained in source order.
public indirect enum OrderedJSON: Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public subscript(_ name: String) -> OrderedJSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == name }?.1
    }
    public var objectEntries: [(String, OrderedJSON)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public static func parse(_ text: String) throws -> OrderedJSON {
        try parse(text, allowDuplicateKeys: false)
    }
    /// Opt in to JSON.parse's last-value rule for repeated object keys.
    public static func parse(_ text: String, allowDuplicateKeys: Bool) throws -> OrderedJSON {
        var parser = Parser(Array(text.utf8), allowDuplicateKeys: allowDuplicateKeys)
        let value = try parser.value()
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw OrderedJSONError.invalid }
        return value
    }
    public func serialized(escapeSlashes: Bool = true) -> String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value
        case .string(let value): Self.quote(value, escapeSlashes: escapeSlashes)
        case .array(let values): "[" + values.map { $0.serialized(escapeSlashes: escapeSlashes) }.joined(separator: ",") + "]"
        case .object(let pairs): "{" + pairs.map { Self.quote($0.0, escapeSlashes: escapeSlashes) + ":" + $0.1.serialized(escapeSlashes: escapeSlashes) }.joined(separator: ",") + "}"
        }
    }
    public static func fromFoundation(_ value: Any) -> OrderedJSON {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.stringValue)
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? [Any] { return .array(value.map(fromFoundation)) }
        if let value = value as? [String: Any] {
            return .object(value.keys.sorted().map { ($0, fromFoundation(value[$0]!)) })
        }
        return .null
    }
    private static func quote(_ value: String, escapeSlashes: Bool) -> String {
        let options: JSONSerialization.WritingOptions = escapeSlashes ? [] : [.withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: options),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
public enum OrderedJSONError: Error { case invalid }

private struct Parser {
    let bytes: [UInt8]
    let allowDuplicateKeys: Bool
    var index = 0
    init(_ bytes: [UInt8], allowDuplicateKeys: Bool) {
        self.bytes = bytes
        self.allowDuplicateKeys = allowDuplicateKeys
    }
    mutating func whitespace() {
        while index < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }
    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        if index < bytes.count && bytes[index] == byte { index += 1; return true }
        return false
    }
    mutating func value() throws -> OrderedJSON {
        whitespace()
        guard index < bytes.count else { throw OrderedJSONError.invalid }
        switch bytes[index] {
        case 123: return try object()
        case 91: return try array()
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default: return .number(try number())
        }
    }
    mutating func object() throws -> OrderedJSON {
        guard take(123) else { throw OrderedJSONError.invalid }
        var pairs: [(String, OrderedJSON)] = []
        if take(125) { return .object(pairs) }
        repeat {
            let name = try string()
            guard take(58) else { throw OrderedJSONError.invalid }
            let member = try value()
            if let existing = pairs.firstIndex(where: { $0.0 == name }) {
                guard allowDuplicateKeys else { throw OrderedJSONError.invalid }
                // JSON.parse retains the first key position and the last value.
                pairs[existing].1 = member
            } else { pairs.append((name, member)) }
            if take(125) { return .object(pairs) }
        } while take(44)
        throw OrderedJSONError.invalid
    }
    mutating func array() throws -> OrderedJSON {
        guard take(91) else { throw OrderedJSONError.invalid }
        var items: [OrderedJSON] = []
        if take(93) { return .array(items) }
        repeat {
            items.append(try value())
            if take(93) { return .array(items) }
        } while take(44)
        throw OrderedJSONError.invalid
    }
    mutating func string() throws -> String {
        whitespace()
        guard index < bytes.count, bytes[index] == 34 else { throw OrderedJSONError.invalid }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                let data = Data(bytes[start..<index])
                guard let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else { throw OrderedJSONError.invalid }
                return string
            }
            if byte < 32 { throw OrderedJSONError.invalid }
        }
        throw OrderedJSONError.invalid
    }
    mutating func number() throws -> String {
        let start = index
        if index < bytes.count && bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw OrderedJSONError.invalid }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw OrderedJSONError.invalid }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            guard index < bytes.count && (48...57).contains(bytes[index]) else { throw OrderedJSONError.invalid }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            guard index < bytes.count && (48...57).contains(bytes[index]) else { throw OrderedJSONError.invalid }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard bytes[index...].starts(with: expected) else { throw OrderedJSONError.invalid }
        index += expected.count
    }
}
