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
        enum Step {
            case value(SchemaValue)
            case text(String)
        }
        var pending: [Step] = [.value(self)]
        var output = ""
        while let step = pending.popLast() {
            switch step {
            case .text(let text): output += text
            case .value(let value):
                switch value {
                case .null: output += "null"
                case .bool(let boolean): output += boolean ? "true" : "false"
                case .number(let number): output += Self.jsonNumber(number)
                case .string(let text): output += Self.jsonString(text)
                case .array(let values):
                    output += "["
                    pending.append(.text("]"))
                    for index in values.indices.reversed() {
                        pending.append(.value(values[index]))
                        if index > 0 { pending.append(.text(",")) }
                    }
                case .object(let object):
                    output += "{"
                    pending.append(.text("}"))
                    // SchemaObject already iterates in JavaScript property order.
                    let members = Array(object)
                    for index in members.indices.reversed() {
                        let member = members[index]
                        pending.append(.value(member.value))
                        pending.append(.text(":"))
                        pending.append(.text(Self.jsonString(member.key)))
                        if index > 0 { pending.append(.text(",")) }
                    }
                }
            }
        }
        return output
    }

    /// Returns JSON with JavaScript JSON.stringify's space indentation.
    public func stringify(indent: Int) -> String {
        let width = min(max(indent, 0), 10)
        guard width > 0 else { return stringify() }
        enum Step {
            case value(SchemaValue, Int)
            case text(String)
        }
        var pending: [Step] = [.value(self, 0)]
        var output = ""
        while let step = pending.popLast() {
            switch step {
            case .text(let text): output += text
            case .value(let value, let depth):
                let current = String(repeating: " ", count: width * depth)
                let next = String(repeating: " ", count: width * (depth + 1))
                switch value {
                case .null: output += "null"
                case .bool(let boolean): output += boolean ? "true" : "false"
                case .number(let number): output += Self.jsonNumber(number)
                case .string(let string): output += Self.jsonString(string)
                case .array(let values):
                    guard !values.isEmpty else { output += "[]"; continue }
                    output += "[\n"
                    pending.append(.text("\n" + current + "]"))
                    for index in values.indices.reversed() {
                        pending.append(.value(values[index], depth + 1))
                        pending.append(.text(next))
                        if index > 0 { pending.append(.text(",\n")) }
                    }
                case .object(let object):
                    let members = Array(object)
                    guard !members.isEmpty else { output += "{}"; continue }
                    output += "{\n"
                    pending.append(.text("\n" + current + "}"))
                    for index in members.indices.reversed() {
                        let member = members[index]
                        pending.append(.value(member.value, depth + 1))
                        pending.append(.text(next + Self.jsonString(member.key) + ": "))
                        if index > 0 { pending.append(.text(",\n")) }
                    }
                }
            }
        }
        return output
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

    private enum Frame {
        case array([SchemaValue])
        case object(SchemaObject, String)
    }

    mutating func parse() throws -> SchemaValue {
        var frames: [Frame] = []
        var current: SchemaValue? = nil
        while true {
            if current == nil {
                guard frames.count <= schemaMaximumValueDepth else { throw SchemaJSONError.nestingTooDeep }
                whitespace()
                guard offset < bytes.count else { throw SchemaJSONError.invalidJSON }
                switch bytes[offset] {
                case 110: try literal("null"); current = .null
                case 116: try literal("true"); current = .bool(true)
                case 102: try literal("false"); current = .bool(false)
                case 34: current = .string(try string())
                case 91:
                    guard frames.count < schemaMaximumValueDepth else { throw SchemaJSONError.nestingTooDeep }
                    offset += 1; whitespace()
                    if consume(93) { current = .array([]) }
                    else { frames.append(.array([])) }
                case 123:
                    guard frames.count < schemaMaximumValueDepth else { throw SchemaJSONError.nestingTooDeep }
                    offset += 1; whitespace()
                    if consume(125) { current = .object(SchemaObject()) }
                    else { frames.append(.object(SchemaObject(), try objectKey())) }
                case 45, 48...57: current = try number()
                default: throw SchemaJSONError.invalidJSON
                }
                if current == nil { continue }
            }
            guard let value = current else { throw SchemaJSONError.invalidJSON }
            guard let frame = frames.popLast() else {
                whitespace()
                guard offset == bytes.count else { throw SchemaJSONError.invalidJSON }
                return value
            }
            whitespace()
            switch frame {
            case .array(var values):
                values.append(value)
                if consume(93) { current = .array(values) }
                else {
                    guard consume(44) else { throw SchemaJSONError.invalidJSON }
                    frames.append(.array(values)); current = nil
                }
            case .object(var object, let key):
                object[key] = value
                if consume(125) { current = .object(object) }
                else {
                    guard consume(44) else { throw SchemaJSONError.invalidJSON }
                    frames.append(.object(object, try objectKey())); current = nil
                }
            }
        }
    }
    mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
    mutating func objectKey() throws -> String {
        whitespace()
        guard offset < bytes.count, bytes[offset] == 34 else { throw SchemaJSONError.invalidJSON }
        let key = try string()
        whitespace()
        guard consume(58) else { throw SchemaJSONError.invalidJSON }
        return key
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
