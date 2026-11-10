// Port of packages/schema/src/formats/typebox/duration.ts at pi-mono v1.5.2.
import Foundation

enum DurationPattern {
    // Upstream: /^P((\d+Y(\d+M(\d+D)?)?|\d+M(\d+D)?|\d+D)(T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S))?|T(\d+H(\d+M(\d+S)?)?|\d+M(\d+S)?|\d+S)|\d+W)$/
    static let regex = try? NSRegularExpression(pattern: "\\AP(([0-9]+Y([0-9]+M([0-9]+D)?)?|[0-9]+M([0-9]+D)?|[0-9]+D)(T([0-9]+H([0-9]+M([0-9]+S)?)?|[0-9]+M([0-9]+S)?|[0-9]+S))?|T([0-9]+H([0-9]+M([0-9]+S)?)?|[0-9]+M([0-9]+S)?|[0-9]+S)|[0-9]+W)\\z", options: [])
}

func isDuration(_ value: String) -> Bool {
    return formatFullMatch(DurationPattern.regex, value)
}
