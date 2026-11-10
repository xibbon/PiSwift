// Port support for packages/schema/src/shared.ts at pi-mono v1.5.2.
import Foundation
import Synchronization

// NSRegularExpression is immutable after compilation. The mutex protects the cache.
private enum SchemaRegexCache {
    private static let entries = Mutex<[[UInt16]: NSRegularExpression]>([:])
    private static let limit = 256

    static func regex(_ source: String) throws -> NSRegularExpression {
        let key = Array(source.utf16)
        return try entries.withLock { cache in
            if let cached = cache[key] { return cached }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: translateSchemaRegex(source))
            } catch {
                let reason = hasUnterminatedCharacterClass(source) ? ": Unterminated character class" : ""
                throw SchemaCompileError.invalidPattern("Invalid regular expression: /\(source)/\(reason)")
            }
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = regex
            return regex
        }
    }
}

/// Compiles a schema pattern with ECMAScript-compatible character classes.
func schemaCompileRegex(_ pattern: String) throws -> NSRegularExpression {
    try SchemaRegexCache.regex(pattern)
}

func schemaRegexMatches(_ pattern: String, _ value: String) -> Bool {
    guard let regex = try? schemaCompileRegex(pattern) else { return false }
    return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

// ECMAScript's character classes are not the same as ICU's Unicode defaults.
private func translateSchemaRegex(_ source: String) -> String {
    let units = Array(source.unicodeScalars)
    let word = "A-Za-z0-9_"
    let space = "\\x{9}-\\x{d}\\x{20}\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}\\x{feff}"
    var output = ""
    var index = 0
    var inClass = false
    while index < units.count {
        let unit = units[index]
        if unit == "\\", index + 1 < units.count {
            let next = units[index + 1]
            switch next {
            case "d": output += inClass ? "0-9" : "[0-9]"
            case "D": output += inClass ? "[^0-9]" : "[^0-9]"
            case "w": output += inClass ? word : "[\(word)]"
            case "W": output += "[^\(word)]"
            case "v": output += "\\x{b}"
            case "s": output += inClass ? space : "[\(space)]"
            case "S": output += "[^\(space)]"
            case "b":
                output += inClass ? "\\x{8}" : "(?:(?<![\(word)])(?=[\(word)])|(?<=[\(word)])(?![\(word)]))"
            case "B":
                output += inClass ? "B" : "(?:(?<![\(word)])(?![\(word)])|(?<=[\(word)])(?=[\(word)]))"
            case "u" where index + 2 < units.count && units[index + 2] == "{":
                output += "\\x"
            default:
                // In JavaScript's non-Unicode fallback, identity escapes such as
                // \q and \_ stand for the escaped character itself.
                let syntax = "dDwWsSbBfnrtvcuxpk0123456789\\.^$*+?()[]{}|/".unicodeScalars
                if syntax.contains(next) || (inClass && next == "-") {
                    output.unicodeScalars.append(unit)
                }
                output.unicodeScalars.append(next)
            }
            index += 2
            continue
        }
        if unit == "[" && !inClass {
            if index + 1 < units.count && units[index + 1] == "]" {
                output += "(?!)"; index += 2; continue
            }
            if index + 2 < units.count && units[index + 1] == "^" && units[index + 2] == "]" {
                output += "(?s:.)"; index += 3; continue
            }
            inClass = true
        } else if unit == "]" && inClass {
            inClass = false
        } else if !inClass {
            if unit == "^" { output += "\\A"; index += 1; continue }
            if unit == "$" { output += "\\z"; index += 1; continue }
            if unit == "." { output += "[^\\x{a}\\x{d}\\x{2028}\\x{2029}]"; index += 1; continue }
        }
        output.unicodeScalars.append(unit)
        index += 1
    }
    return output
}

private func hasUnterminatedCharacterClass(_ source: String) -> Bool {
    var inClass = false
    var escaped = false
    for scalar in source.unicodeScalars {
        if escaped { escaped = false; continue }
        if scalar == "\\" { escaped = true; continue }
        if scalar == "[" && !inClass { inClass = true }
        else if scalar == "]" && inClass { inClass = false }
    }
    return inClass
}
