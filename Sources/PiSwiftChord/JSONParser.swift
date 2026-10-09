import Foundation

extension JSONValue {
    /// Parses strict JSON text. Ports the chord strict boundary in `json.ts`.
    /// A lone surrogate escape throws because Swift strings cannot store it.
    public init(jsonText: String) throws {
        try self.init(jsonData: Data(jsonText.utf8))
    }
    /// Parses UTF-8 JSON bytes. Error offsets count bytes from the start.
    public init(jsonData: Data) throws {
        var parser = JSONParser(bytes: Array(jsonData))
        self = try parser.document()
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    func error(_ reason: String) -> JSONValueError { .invalidJSON(offset: index, reason: reason) }
    mutating func whitespace() {
        while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }
    mutating func take(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }
    mutating func document() throws -> JSONValue {
        let result = try value()
        whitespace()
        guard index == bytes.count else { throw error("Expected end of document") }
        return result
    }
    mutating func value() throws -> JSONValue {
        whitespace()
        guard let byte = current else { throw error("Expected a JSON value") }
        switch byte {
        case 110: try literal("null"); return .null
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 34: return .string(try string())
        case 91: return try array()
        case 123: return try object()
        case 45, 48...57: return try number()
        default: throw error("Expected a JSON value")
        }
    }
    mutating func literal(_ word: String) throws {
        for byte in word.utf8 {
            guard take(byte) else { throw error("Invalid literal") }
        }
    }
    mutating func array() throws -> JSONValue {
        index += 1
        whitespace()
        var values: [JSONValue] = []
        if take(93) { return .array(values) }
        while true {
            values.append(try value())
            whitespace()
            if take(93) { return .array(values) }
            guard take(44) else { throw error("Expected comma or closing bracket") }
        }
    }
    mutating func object() throws -> JSONValue {
        index += 1
        whitespace()
        var object = JSONObject()
        if take(125) { return .object(object) }
        while true {
            whitespace()
            let key = try string()
            whitespace()
            guard take(58) else { throw error("Expected colon") }
            object[key] = try value()
            whitespace()
            if take(125) { return .object(object) }
            guard take(44) else { throw error("Expected comma or closing brace") }
        }
    }
    mutating func number() throws -> JSONValue {
        let start = index
        _ = take(45)
        if !take(48) {
            guard let byte = current, (49...57).contains(byte) else { throw error("Expected integer digits") }
            digits()
        }
        if take(46) {
            guard let byte = current, (48...57).contains(byte) else { throw error("Expected fraction digits") }
            digits()
        }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            guard let byte = current, (48...57).contains(byte) else { throw error("Expected exponent digits") }
            digits()
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let number = Double(text) else { throw error("Invalid number") }
        guard number.isFinite else { throw JSONValueError.nonFiniteNumber }
        return .number(number)
    }
    mutating func digits() {
        while let byte = current, (48...57).contains(byte) { index += 1 }
    }
    mutating func string() throws -> String {
        guard take(34) else { throw error("Expected string") }
        var result = ""
        while let byte = current {
            if take(34) { return result }
            guard byte >= 32 else { throw error("Raw control character in string") }
            if byte != 92 {
                let start = index
                while let next = current, next >= 32, next != 34, next != 92 { index += 1 }
                guard let segment = String(bytes: bytes[start..<index], encoding: .utf8) else {
                    throw JSONValueError.invalidJSON(offset: start, reason: "Invalid UTF-8 in string")
                }
                result += segment
                continue
            }
            let escapeOffset = index
            index += 1
            guard let escape = current else { throw error("Unterminated escape") }
            index += 1
            switch escape {
            case 34: result += "\""
            case 92: result += "\\"
            case 47: result += "/"
            case 98: result += "\u{8}"
            case 102: result += "\u{c}"
            case 110: result += "\n"
            case 114: result += "\r"
            case 116: result += "\t"
            case 117:
                let high = try hexQuad()
                if (0xD800...0xDBFF).contains(high) {
                    guard current == 92, index + 1 < bytes.count, bytes[index + 1] == 117 else {
                        throw JSONValueError.loneSurrogate(offset: escapeOffset)
                    }
                    let lowOffset = index
                    index += 2
                    let low = try hexQuad()
                    guard (0xDC00...0xDFFF).contains(low) else {
                        throw JSONValueError.loneSurrogate(offset: lowOffset)
                    }
                    result.unicodeScalars.append(Unicode.Scalar(0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00)!)
                } else if (0xDC00...0xDFFF).contains(high) {
                    throw JSONValueError.loneSurrogate(offset: escapeOffset)
                } else { result.unicodeScalars.append(Unicode.Scalar(high)!) }
            default: throw JSONValueError.invalidJSON(offset: index - 1, reason: "Invalid string escape")
            }
        }
        throw error("Unterminated string")
    }
    mutating func hexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw error("Incomplete Unicode escape") }
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 65 + 10)
            case 97...102: digit = UInt32(byte - 97 + 10)
            default: throw error("Invalid Unicode escape")
            }
            result = result * 16 + digit
            index += 1
        }
        return result
    }
}
