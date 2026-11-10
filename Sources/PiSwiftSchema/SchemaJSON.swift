// JSON text support for packages/schema/src/compiler.ts at pi-mono v1.5.2.
import Foundation

/// An error in a JSON value or its Foundation representation.
public enum SchemaJSONError: Error, Sendable, Equatable {
    case invalidUTF8
    case invalidJSON
    case loneSurrogate
    case unsupportedFoundationValue
    case nestingTooDeep
}

extension SchemaValue {
    /// Parses a JSON string and preserves object member order.
    public static func parse(json: String) throws -> SchemaValue {
        var parser = SchemaJSONParser(bytes: Array(json.utf8))
        return try parser.parse()
    }

    /// Parses UTF-8 JSON data and preserves object member order.
    public static func parse(json: Data) throws -> SchemaValue {
        let bytes = Array(json)
        let string = String(decoding: bytes, as: UTF8.self)
        guard string.utf8.elementsEqual(bytes) else { throw SchemaJSONError.invalidUTF8 }
        return try parse(json: string)
    }

    /// Returns JSON using JavaScript JSON.stringify conventions.
    public func stringify() -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Self.jsonNumber(value)
        case .string(let value): return Self.jsonString(value)
        case .array(let values): return "[" + values.map { $0.stringify() }.joined(separator: ",") + "]"
        case .object(let object):
            // JavaScript enumerates array-index keys before other own keys.
            let members = Array(object)
            let indexed = members.compactMap { item -> (UInt32, SchemaObject.Element)? in
                guard let index = Self.arrayIndex(item.key) else { return nil }
                return (index, item)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            let others = members.filter { Self.arrayIndex($0.key) == nil }
            return "{" + (indexed + others).map { Self.jsonString($0.key) + ":" + $0.value.stringify() }.joined(separator: ",") + "}"
        }
    }

    private static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              (key == "0" || key.utf8.first != 48), let value = UInt32(key), value < UInt32.max else { return nil }
        return value
    }

    private static func jsonString(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 8: output += "\\b"
            case 9: output += "\\t"
            case 10: output += "\\n"
            case 12: output += "\\f"
            case 13: output += "\\r"
            case 0..<32: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    private static func jsonNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        guard value != 0 else { return "0" }
        let negative = value < 0
        let representation = String(abs(value)).lowercased()
        let parts = representation.split(separator: "e", omittingEmptySubsequences: false)
        let exponent = parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        let mantissa = String(parts[0])
        let decimal = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count
        var digits = mantissa.filter { $0 != "." }
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }
        let position = decimal + exponent
        let sign = negative ? "-" : ""
        if position > 0 && position <= 21 {
            if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
            let split = digits.index(digits.startIndex, offsetBy: position)
            return sign + digits[..<split] + "." + digits[split...]
        }
        if position <= 0 && position > -6 {
            return sign + "0." + String(repeating: "0", count: -position) + digits
        }
        let rest = digits.dropFirst()
        let scientific = String(digits.prefix(1)) + (rest.isEmpty ? "" : "." + rest)
        let power = position - 1
        return sign + scientific + "e" + (power >= 0 ? "+" : "") + String(power)
    }
}

private struct SchemaJSONParser {
    let bytes: [UInt8]
    var offset = 0

    mutating func parse() throws -> SchemaValue {
        let result = try value(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw SchemaJSONError.invalidJSON }
        return result
    }
    mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
    mutating func value(depth: Int) throws -> SchemaValue {
        guard depth <= 512 else { throw SchemaJSONError.nestingTooDeep }
        whitespace()
        guard offset < bytes.count else { throw SchemaJSONError.invalidJSON }
        switch bytes[offset] {
        case 110: try literal("null"); return .null
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 34: return .string(try string())
        case 91:
            offset += 1; whitespace()
            var values: [SchemaValue] = []
            if consume(93) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1)); whitespace()
                if consume(93) { return .array(values) }
                guard consume(44) else { throw SchemaJSONError.invalidJSON }
            }
        case 123:
            offset += 1; whitespace()
            var object = SchemaObject()
            if consume(125) { return .object(object) }
            while true {
                whitespace()
                guard offset < bytes.count, bytes[offset] == 34 else { throw SchemaJSONError.invalidJSON }
                let key = try string(); whitespace()
                guard consume(58) else { throw SchemaJSONError.invalidJSON }
                object[key] = try value(depth: depth + 1); whitespace()
                if consume(125) { return .object(object) }
                guard consume(44) else { throw SchemaJSONError.invalidJSON }
            }
        case 45, 48...57: return try number()
        default: throw SchemaJSONError.invalidJSON
        }
    }
    mutating func literal(_ literal: StaticString) throws {
        for index in 0..<literal.utf8CodeUnitCount {
            guard consume(literal.utf8Start[index]) else { throw SchemaJSONError.invalidJSON }
        }
    }
    mutating func string() throws -> String {
        guard consume(34) else { throw SchemaJSONError.invalidJSON }
        var result: [UInt8] = []
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 {
                return String(decoding: result, as: UTF8.self)
            }
            guard byte >= 32 else { throw SchemaJSONError.invalidJSON }
            if byte != 92 { result.append(byte); continue }
            guard offset < bytes.count else { throw SchemaJSONError.invalidJSON }
            let escape = bytes[offset]; offset += 1
            switch escape {
            case 34, 47, 92: result.append(escape)
            case 98: result.append(8)
            case 102: result.append(12)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 117:
                let first = try hex4()
                var code = first
                if (0xD800...0xDBFF).contains(first) {
                    guard consume(92), consume(117) else { throw SchemaJSONError.loneSurrogate }
                    let second = try hex4()
                    guard (0xDC00...0xDFFF).contains(second) else { throw SchemaJSONError.loneSurrogate }
                    code = 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(first) { throw SchemaJSONError.loneSurrogate }
                guard let scalar = Unicode.Scalar(code) else { throw SchemaJSONError.invalidJSON }
                result.append(contentsOf: String(scalar).utf8)
            default: throw SchemaJSONError.invalidJSON
            }
        }
        throw SchemaJSONError.invalidJSON
    }
    mutating func hex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard offset < bytes.count else { throw SchemaJSONError.invalidJSON }
            let byte = bytes[offset]; offset += 1
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw SchemaJSONError.invalidJSON
            }
            value = value * 16 + digit
        }
        return value
    }
    mutating func number() throws -> SchemaValue {
        let start = offset
        _ = consume(45)
        if !consume(48) {
            guard offset < bytes.count, (49...57).contains(bytes[offset]) else { throw SchemaJSONError.invalidJSON }
            offset += 1
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
        }
        if consume(46) {
            let first = offset
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
            guard first != offset else { throw SchemaJSONError.invalidJSON }
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            let first = offset
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
            guard first != offset else { throw SchemaJSONError.invalidJSON }
        }
        guard let value = Double(String(decoding: bytes[start..<offset], as: UTF8.self)) else { throw SchemaJSONError.invalidJSON }
        return .number(value)
    }
}
