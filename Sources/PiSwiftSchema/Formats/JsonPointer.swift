// Port of packages/schema/src/formats/typebox/json_pointer.ts at pi-mono v1.5.2.
import Foundation

enum JsonPointerPattern {
    // Upstream: /^(?:\/(?:[^~/]|~0|~1)*)*$/
    static let regex = try? NSRegularExpression(pattern: "\\A(?:\\/(?:[^~/]|~0|~1)*)*\\z", options: [])
}

func isJsonPointer(_ value: String) -> Bool {
    return formatFullMatch(JsonPointerPattern.regex, value)
}
