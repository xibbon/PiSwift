import Foundation

/// Repair string escapes without changing text outside strings.
public func repairJSON(_ json: String) -> String {
    let bytes = Array(json.utf8)
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var inString = false
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if !inString {
            result.append(byte)
            if byte == 34 { inString = true }
        } else if byte == 34 {
            result.append(byte)
            inString = false
        } else if byte == 92 {
            if index + 5 < bytes.count, bytes[index + 1] == 117,
               bytes[(index + 2)...(index + 5)].allSatisfy(isJSONHexDigit) {
                result.append(contentsOf: bytes[index...(index + 5)])
                index += 5
            } else if index + 1 < bytes.count, [UInt8(34), 92, 47, 98, 102, 110, 114, 116].contains(bytes[index + 1]) {
                result.append(contentsOf: bytes[index...(index + 1)])
                index += 1
            } else {
                result.append(contentsOf: [92, 92])
            }
        } else if byte < 32 {
            switch byte {
            case 8: result.append(contentsOf: [92, 98])
            case 12: result.append(contentsOf: [92, 102])
            case 10: result.append(contentsOf: [92, 110])
            case 13: result.append(contentsOf: [92, 114])
            case 9: result.append(contentsOf: [92, 116])
            default:
                let hex = Array("0123456789abcdef".utf8)
                result.append(contentsOf: [92, 117, 48, 48, hex[Int(byte / 16)], hex[Int(byte % 16)]])
            }
        } else {
            result.append(byte)
        }
        index += 1
    }
    return String(decoding: result, as: UTF8.self)
}

private func isJSONHexDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
}

/// Use a stable diagnostic instead of Foundation's localized parser text.
public enum JSONParseError: Error, Sendable {
    case invalidJSON
}

public func parseJSONWithRepair(_ json: String) throws -> AnyCodable {
    try parsedJSONWithRepair(json).value
}

private func parsedJSONWithRepair(_ json: String) throws -> (value: AnyCodable, source: OrderedJSON) {
    // Foundation accepts trailing commas. Check strict syntax before decoding values.
    if let source = try? OrderedJSON.parse(json, allowDuplicateKeys: true),
       let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) {
        return (AnyCodable(value), source)
    }
    let repaired = repairJSON(json)
    guard repaired != json,
          let source = try? OrderedJSON.parse(repaired, allowDuplicateKeys: true),
          let value = try? JSONSerialization.jsonObject(with: Data(repaired.utf8), options: [.fragmentsAllowed]) else {
        throw JSONParseError.invalidJSON
    }
    return (AnyCodable(value), source)
}

/// JavaScript String.trim whitespace, used by the upstream parser guards.
func trimJavaScriptWhitespace(_ text: String) -> String {
    let whitespace = CharacterSet(charactersIn: "\u{9}\u{a}\u{b}\u{c}\u{d} \u{a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    return text.trimmingCharacters(in: whitespace)
}

/// Parse all final text. A failed call has no argument values or order metadata.
public func parseToolCallArguments(_ json: String?) -> (arguments: [String: AnyCodable], argumentsError: String?) {
    let parsed = finalArguments(json)
    return (parsed.arguments, parsed.error)
}

private func finalArguments(_ json: String?) -> (arguments: [String: AnyCodable], source: OrderedJSON?, error: String?) {
    guard let json, !trimJavaScriptWhitespace(json).isEmpty else { return ([:], nil, nil) }
    do {
        let parsed = try parsedJSONWithRepair(json)
        guard let object = parsed.value.value as? [String: Any] else {
            return ([:], nil, "Tool arguments must be a JSON object\n\nReceived arguments:\n\(json)")
        }
        let source = toolArgumentsSource(parsed.source)
        return (toolArgumentsWithOrder(object.mapValues(AnyCodable.init), argumentsJSON: source), source, nil)
    } catch {
        return ([:], nil, "Invalid JSON.\n\nReceived arguments:\n\(json)")
    }
}

/// Parse a full repaired object, then an incomplete object, then a repaired incomplete object.
public func parseStreamingJSON(_ partialJson: String?) -> [String: AnyCodable] {
    streamingArguments(partialJson).arguments
}

private func streamingArguments(_ json: String?) -> (arguments: [String: AnyCodable], source: OrderedJSON?) {
    guard let json, !trimJavaScriptWhitespace(json).isEmpty else { return ([:], nil) }
    if let parsed = try? parsedJSONWithRepair(json) {
        guard let object = parsed.value.value as? [String: Any] else { return ([:], nil) }
        let source = toolArgumentsSource(parsed.source)
        return (toolArgumentsWithOrder(object.mapValues(AnyCodable.init), argumentsJSON: source), source)
    }
    for text in [json, repairJSON(json)] {
        let trimmed = trimJavaScriptWhitespace(text)
        var parser = PartialJSONParser(bytes: Array(trimmed.utf8))
        guard let value = try? parser.value(), case .object(let pairs) = value else { continue }
        let object = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, partialJSONValue($0.1)) })
        let source = toolArgumentsSource(value)
        return (toolArgumentsWithOrder(object.mapValues(AnyCodable.init), argumentsJSON: source), source)
    }
    return ([:], nil)
}

extension ToolCall {
    /// Update the streaming snapshot. A final parse error stays attached to the call.
    public mutating func setArguments(from text: String) {
        let parsed = streamingArguments(text)
        arguments = parsed.arguments
        argumentsJSON = parsed.source
    }

    /// Replace the streaming snapshot with the strict final result.
    public mutating func finalizeArguments(from text: String) {
        let parsed = finalArguments(text)
        arguments = parsed.arguments
        argumentsJSON = parsed.source
        argumentsError = parsed.error
    }
}

/// Convert partial values without serializing the whole subtree at each level.
private func partialJSONValue(_ value: OrderedJSON) -> Any {
    switch value {
    case .object(let pairs): return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, partialJSONValue($0.1)) })
    case .array(let values): return values.map(partialJSONValue)
    case .string(let text): return text
    case .bool(let value): return value
    case .null: return NSNull()
    case .number(let text):
        if text == "NaN" { return Double.nan }
        if text == "Infinity" { return Double.infinity }
        if text == "-Infinity" { return -Double.infinity }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? NSNull()
    }
}

// Partial parsing follows partial-json 0.1.7, the dependency pinned by pi-mono v1.3.0.
// MIT License
// Copyright (c) 2023 Promplate Dev Team
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// One pass over incomplete input. Retain completed members when a child fails.
private struct PartialJSONParser {
    let bytes: [UInt8]
    let lastExponent: Int?
    let lastSlash: Int?
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.lastExponent = bytes.lastIndex(of: 101)
        self.lastSlash = bytes.lastIndex(of: 92)
    }

    mutating func whitespace() {
        while index < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> OrderedJSON {
        whitespace()
        guard index < bytes.count, depth < 512 else { throw JSONParseError.invalidJSON }
        depth += 1
        defer { depth -= 1 }
        switch bytes[index] {
        case 123: return object()
        case 91: return array()
        case 34: return .string(try string())
        default:
            for (word, value): (String, OrderedJSON) in [
                ("null", .null), ("true", .bool(true)), ("false", .bool(false)),
                ("Infinity", .number("Infinity")), ("-Infinity", .number("-Infinity")), ("NaN", .number("NaN")),
            ] {
                let token = Array(word.utf8)
                let remaining = bytes.count - index
                let count = min(token.count, remaining)
                if bytes[index..<(index + count)].elementsEqual(token.prefix(count)),
                   word != "-Infinity" || remaining > 1 {
                    index += token.count
                    return value
                }
            }
            return try number()
        }
    }

    mutating func number() throws -> OrderedJSON {
        let start = index
        while index < bytes.count && ![UInt8(44), 93, 125].contains(bytes[index]) { index += 1 }
        if let number = parsedNumber(start: start, end: index) { return number }
        // The dependency retries only at a lowercase exponent marker.
        if let exponent = lastExponent, exponent >= start, exponent < index,
           let number = parsedNumber(start: start, end: exponent) { return number }
        throw JSONParseError.invalidJSON
    }

    func parsedNumber(start: Int, end: Int) -> OrderedJSON? {
        let token = String(decoding: bytes[start..<end], as: UTF8.self)
        guard let parsed = try? OrderedJSON.parse(token), case .number = parsed else { return nil }
        return parsed
    }

    mutating func object() -> OrderedJSON {
        index += 1
        var pairs: [(String, OrderedJSON)] = []
        var positions: [String: Int] = [:]
        while true {
            whitespace()
            if index >= bytes.count { return .object(pairs) }
            if bytes[index] == 125 { index += 1; return .object(pairs) }
            do {
                let key = try string()
                whitespace()
                index += 1 // The partial-json dependency skips the separator without checking it.
                let member = try value()
                if let position = positions[key] { pairs[position].1 = member }
                else { positions[key] = pairs.count; pairs.append((key, member)) }
                whitespace()
                if index < bytes.count && bytes[index] == 44 { index += 1 }
            } catch {
                return .object(pairs)
            }
        }
    }

    mutating func array() -> OrderedJSON {
        index += 1
        var values: [OrderedJSON] = []
        while true {
            whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return .array(values) }
            do {
                values.append(try value())
                whitespace()
                if index < bytes.count && bytes[index] == 44 { index += 1 }
            } catch {
                return .array(values)
            }
        }
    }

    mutating func string() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 && !escaped {
                index += 1
                return try decodedString(Array(bytes[start..<index]))
            }
            escaped = byte == 92 ? !escaped : false
            index += 1
        }
        var token = Array(bytes[start..<(index - (escaped ? 1 : 0))])
        token.append(34)
        if let text = try? decodedString(token) { return text }
        // An invalid or incomplete escape in an open string is omitted, as upstream.
        guard let slash = lastSlash, slash >= start else { throw JSONParseError.invalidJSON }
        token = Array(bytes[start..<slash])
        token.append(34)
        return try decodedString(token)
    }

    func decodedString(_ token: [UInt8]) throws -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(token), options: [.fragmentsAllowed]) as? String else {
            throw JSONParseError.invalidJSON
        }
        return value
    }
}
