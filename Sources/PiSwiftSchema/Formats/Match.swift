// Shared format matching support for packages/schema/src/formats/typebox at pi-mono v1.5.2.
import Foundation

@inline(__always)
func formatFullMatch(_ regex: NSRegularExpression?, _ value: String) -> Bool {
    guard let regex else { return false }
    let length = value.utf16.count
    let range = NSRange(location: 0, length: length)
    guard let match = regex.firstMatch(in: value, range: range) else { return false }
    return match.range.location == 0 && match.range.length == length
}

@inline(__always)
func formatMatch(_ regex: NSRegularExpression?, _ value: String) -> NSTextCheckingResult? {
    guard let regex else { return nil }
    return regex.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count))
}

@inline(__always)
func formatAsciiDecimal(_ units: ArraySlice<UInt16>) -> Int? {
    var number = 0
    for unit in units {
        guard unit >= 48 && unit <= 57 else { return nil }
        number = number * 10 + Int(unit - 48)
    }
    return number
}

// A test asserts this at startup so OS-specific ICU pattern failures are visible.
var standardFormatPatternsCompiled: Bool {
    [DurationPattern.regex, EmailPattern.regex, IPv4Pattern.regex, IPv6Pattern.regex,
     JsonPointerPattern.regex, JsonPointerUriFragmentPattern.regex,
     RelativeJsonPointerPattern.regex, UriPattern.regex, UriReferencePattern.regex,
     UriTemplatePattern.regex, UuidPattern.regex].allSatisfy { $0 != nil } && iriPatternCompiled
}
