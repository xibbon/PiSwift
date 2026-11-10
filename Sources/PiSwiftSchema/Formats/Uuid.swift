// Port of packages/schema/src/formats/typebox/uuid.ts at pi-mono v1.5.2.
import Foundation

enum UuidPattern {
    // Upstream: /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i
    static let regex = try? NSRegularExpression(pattern: "\\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\\z", options: .caseInsensitive)
}

func isUuid(_ value: String) -> Bool {
    // JavaScript /i without /u does not fold non-ASCII characters into ASCII classes.
    guard value.utf16.allSatisfy({ $0 < 128 }) else { return false }
    return formatFullMatch(UuidPattern.regex, value)
}
