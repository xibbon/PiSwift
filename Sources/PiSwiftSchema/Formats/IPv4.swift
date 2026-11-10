// Port of packages/schema/src/formats/typebox/ipv4.ts at pi-mono v1.5.2.
import Foundation

enum IPv4Pattern {
    // Upstream: /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/
    static let regex = try? NSRegularExpression(pattern: "\\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\z", options: [])
}

func isIPv4(_ value: String) -> Bool {
    return formatFullMatch(IPv4Pattern.regex, value)
}
