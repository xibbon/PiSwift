import Foundation

/// A JSON tree. Port of chord `JsonValue`, `packages/chord/src/types.ts`.
public enum JSONValue: Sendable, Equatable {
    /// JSON null.
    case null
    /// A JSON Boolean.
    case bool(Bool)
    /// A JavaScript number. Strict JSON requires a finite value.
    case number(Double)
    /// A string with Unicode scalar identity.
    case string(String)
    /// An ordered array of values.
    case array([JSONValue])
    /// An object with JavaScript key order.
    case object(JSONObject)

    /// Compares trees. Object order is ignored; string scalars must match.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a == b
        default: false
        }
    }
    /// Port of chord `isJsonValue`, `json.ts`. Checks all numbers for finiteness.
    public var isStrictJSON: Bool {
        switch self {
        case .number(let value): value.isFinite
        case .array(let values): values.allSatisfy(\.isStrictJSON)
        case .object(let value): value.values.allSatisfy(\.isStrictJSON)
        default: true
        }
    }
    /// Returns true for JSON null.
    public var isNull: Bool { if case .null = self { true } else { false } }
    /// Returns the Boolean, or nil for another case.
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    /// Returns the number, or nil for another case.
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    /// Returns an exactly representable integer, or nil.
    public var intValue: Int? { numberValue.flatMap { Int(exactly: $0) } }
    /// Returns an exactly representable 64-bit integer, or nil.
    public var int64Value: Int64? { numberValue.flatMap { Int64(exactly: $0) } }
    /// Returns the string, or nil for another case.
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    /// Returns the array, or nil for another case.
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    /// Returns the object, or nil for another case.
    public var objectValue: JSONObject? { if case .object(let value) = self { value } else { nil } }
    /// Gets an object member, or nil for a missing key or another case.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    /// Gets an array element, or nil for an invalid index or another case.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
    /// Takes out the array payload during mutation, then puts it back on all exits.
    package mutating func withArray<R>(_ body: (inout [JSONValue]) throws -> R) rethrows -> R? {
        // End the match before mutation. A guard-case keeps a hidden payload
        // reference alive through the call in a debug build.
        var values: [JSONValue]
        switch self {
        case .array(let payload): values = payload
        default: return nil
        }
        self = .null
        defer { self = .array(values) }
        return try body(&values)
    }
    /// Takes out the object payload during mutation, then puts it back on all exits.
    package mutating func withObject<R>(_ body: (inout JSONObject) throws -> R) rethrows -> R? {
        var object: JSONObject
        switch self {
        case .object(let payload): object = payload
        default: return nil
        }
        self = .null
        defer { self = .object(object) }
        return try body(&object)
    }
    /// Writes the same compact text as JavaScript `JSON.stringify` for strict JSON.
    public func jsonText() throws -> String {
        guard isStrictJSON else { throw JSONValueError.nonFiniteNumber }
        return rendered()
    }
    func rendered() -> String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): Self.numberText(value)
        case .string(let value): Self.quote(value)
        case .array(let values): "[" + values.map { $0.rendered() }.joined(separator: ",") + "]"
        case .object(let object): "{" + object.map { Self.quote($0.key) + ":" + $0.value.rendered() }.joined(separator: ",") + "}"
        }
    }
    private static func numberText(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == .infinity { return "Infinity" }
        if value == -.infinity { return "-Infinity" }
        if value == 0 { return "0" }
        let sign = value < 0 ? "-" : ""
        let parts = String(abs(value)).lowercased().split(separator: "e")
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        var digits = Array(mantissa.joined())
        var n = mantissa[0].count + exponent
        while digits.first == "0" { digits.removeFirst(); n -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let text = String(digits)
        if k <= n && n <= 21 { return sign + text + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 {
            return sign + String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        }
        if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + text }
        let tail = k > 1 ? "." + String(digits.dropFirst()) : ""
        return sign + String(digits[0]) + tail + "e" + (n - 1 >= 0 ? "+" : "-") + String(abs(n - 1))
    }
    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0...31:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension JSONValue: CustomStringConvertible, CustomDebugStringConvertible {
    /// JSON text. Non-finite numbers use diagnostic names here only.
    public var description: String { rendered() }
    /// JSON text. Non-finite numbers use diagnostic names here only.
    public var debugDescription: String { rendered() }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    /// Creates JSON null from a literal.
    public init(nilLiteral: ()) { self = .null }
    /// Creates a Boolean from a literal.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Creates a JavaScript number from an integer literal.
    public init(integerLiteral value: Int64) { self = .number(Double(value)) }
    /// Creates a number from a floating-point literal.
    public init(floatLiteral value: Double) { self = .number(value) }
    /// Creates a string from a literal.
    public init(stringLiteral value: String) { self = .string(value) }
    /// Creates an array from a literal.
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// Creates an object from literal members in JavaScript key order.
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

/// Errors at the strict JSON boundary. Ports chord `copyJson` errors in `json.ts`.
public enum JSONValueError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Invalid JSON at a UTF-8 byte offset.
    case invalidJSON(offset: Int, reason: String)
    /// A number is NaN or infinite.
    case nonFiniteNumber
    /// A UTF-16 surrogate has no valid partner at a UTF-8 byte offset.
    case loneSurrogate(offset: Int)
    /// An encoded integer cannot be stored exactly as a Double.
    case unsafeInteger
    /// A plain text error description.
    public var description: String {
        switch self {
        case .invalidJSON(let offset, let reason): "Invalid JSON at byte \(offset): \(reason)"
        case .nonFiniteNumber: "Value contains a non-finite number and is not strict JSON"
        case .loneSurrogate(let offset): "Lone surrogate at byte \(offset)"
        case .unsafeInteger: "Integer cannot be represented exactly as a JSON number"
        }
    }
}
