import Foundation
import CoreFoundation
import PiSwiftAI

/// Format raw read arguments for display. This does not change tool execution arguments.
public func formatReadLineRange(offset: AnyCodable?, limit: AnyCodable?) -> String {
    let offset = offset?.jsonValue
    let limit = limit?.jsonValue
    let offsetMissing = offset == nil || offset is NSNull
    let limitMissing = limit == nil || limit is NSNull
    if offsetMissing && limitMissing { return "" }
    guard let start = offsetMissing ? 1 : parseReadLineNumber(offset) else { return "" }
    if limitMissing { return ":" + readLineNumberText(start) }
    guard let count = parseReadLineNumber(limit) else { return "" }
    let end = start + count - 1
    return ":" + readLineNumberText(start) + (end == 0 ? "" : "-" + readLineNumberText(end))
}

private func parseReadLineNumber(_ value: Any?) -> Double? {
    let number: Double?
    if let string = value as? String {
        // Use ECMAScript whitespace and number syntax, including radix prefixes.
        let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        let text = string.trimmingCharacters(in: whitespace)
        if text.range(of: #"^0[xX][0-9a-fA-F]+$"#, options: .regularExpression) != nil {
            number = Double(text.lowercased() + "p0")
        } else if text.range(of: #"^0[bB][01]+$|^0[oO][0-7]+$"#, options: .regularExpression) != nil {
            let width = text.dropFirst().first?.lowercased() == "b" ? 1 : 3
            var bits = text.dropFirst(2).map { digit in
                let binary = String(digit.wholeNumberValue ?? 0, radix: 2)
                return String(repeating: "0", count: width - binary.count) + binary
            }.joined()
            bits = String(repeating: "0", count: (4 - bits.count % 4) % 4) + bits
            let bytes = Array(bits.utf8)
            let hex = stride(from: 0, to: bytes.count, by: 4).map { index in
                let digit = bytes[index..<(index + 4)].reduce(0) { $0 * 2 + Int($1 - 48) }
                return String(digit, radix: 16)
            }.joined()
            number = Double("0x" + hex + "p0")
        } else if text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                             options: .regularExpression) != nil {
            number = Double(text)
        } else {
            number = nil
        }
    } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
        number = value.doubleValue
    } else {
        number = nil
    }
    guard let number, number.isFinite else { return nil }
    return number
}

// Use JavaScript's decimal and exponent thresholds. Swift retains a trailing .0
// for integers and uses exponent notation for some values that JavaScript expands.
private func readLineNumberText(_ value: Double) -> String {
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    if value == 0 { return "0" }
    let sign = value < 0 ? "-" : ""
    let parts = String(abs(value)).lowercased().split(separator: "e")
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    var digits = Array(mantissa.joined())
    var position = mantissa[0].count + exponent
    while digits.first == "0" { digits.removeFirst(); position -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let count = digits.count
    let text = String(digits)
    if count <= position && position <= 21 {
        return sign + text + String(repeating: "0", count: position - count)
    }
    if 0 < position && position <= 21 {
        return sign + String(digits.prefix(position)) + "." + String(digits.dropFirst(position))
    }
    if -6 < position && position <= 0 {
        return sign + "0." + String(repeating: "0", count: -position) + text
    }
    let tail = count > 1 ? "." + String(digits.dropFirst()) : ""
    return sign + String(digits[0]) + tail + "e" + (position - 1 >= 0 ? "+" : "-") + String(abs(position - 1))
}
