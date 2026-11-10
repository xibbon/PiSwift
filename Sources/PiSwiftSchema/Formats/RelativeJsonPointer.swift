// Port of packages/schema/src/formats/typebox/relative_json_pointer.ts at pi-mono v1.5.2.
import Foundation

enum RelativeJsonPointerPattern {
    // Upstream: /^(?:0|[1-9][0-9]*)(?:#|(?:\/(?:[^~/]|~0|~1)*)*)$/
    static let regex = try? NSRegularExpression(pattern: "\\A(?:0|[1-9][0-9]*)(?:#|(?:\\/(?:[^~/]|~0|~1)*)*)\\z", options: [])
}

func isRelativeJsonPointer(_ value: String) -> Bool {
    return formatFullMatch(RelativeJsonPointerPattern.regex, value)
}
