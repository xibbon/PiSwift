// Port of packages/schema/src/formats/typebox/iri.ts at pi-mono v1.5.2.
import Foundation

private enum IriPatterns {
    // Upstream: /\[[vV][0-9a-fA-F]+\.[^\]]+\]/
    static let ipvFuture = try? NSRegularExpression(pattern: #"\[[vV][0-9a-fA-F]+\.[^\]]+\]"#)
}

var iriPatternCompiled: Bool { IriPatterns.ipvFuture != nil }

private func narrowIpvFuture(_ value: String) -> String {
    // Upstream counts UTF-16 code units.
    guard value.utf16.count < 2048, let regex = IriPatterns.ipvFuture,
          let match = formatMatch(regex, value), let range = Range(match.range, in: value) else { return value }
    var copy = value
    copy.replaceSubrange(range, with: "[::1]")
    return copy
}

func isIri(_ value: String) -> Bool {
    // Upstream: /[\x00-\x20<>^`{|}\\]/ and /%(?![0-9a-fA-F]{2})/.
    let u = Array(value.utf16)
    for (i, c) in u.enumerated() {
        if c <= 0x20 { return false }
        switch c {
        case 60, 62, 92, 94, 96, 123, 124, 125: return false
        default: break
        }
        if c == 37 && (i + 2 >= u.count || !formatHex(u[i + 1]) || !formatHex(u[i + 2])) { return false }
    }
    return formatCanParseURL(narrowIpvFuture(value))
}
