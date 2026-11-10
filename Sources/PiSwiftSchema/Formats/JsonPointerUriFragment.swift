// Port of packages/schema/src/formats/typebox/json_pointer_uri_fragment.ts at pi-mono v1.5.2.
import Foundation

enum JsonPointerUriFragmentPattern {
    // Upstream: /^#(?:\/(?:[a-z0-9_\-.!$&'()*+,;:=@]|%[0-9a-f]{2}|~0|~1)*)*$/i
    static let regex = try? NSRegularExpression(pattern: "\\A#(?:\\/(?:[a-z0-9_\\-.!$&'()*+,;:=@]|%[0-9a-f]{2}|~0|~1)*)*\\z", options: .caseInsensitive)
}

func isJsonPointerUriFragment(_ value: String) -> Bool {
    // JavaScript /i without /u does not fold non-ASCII characters into ASCII classes.
    guard value.utf16.allSatisfy({ $0 < 128 }) else { return false }
    return formatFullMatch(JsonPointerUriFragmentPattern.regex, value)
}
