// Port of packages/schema/src/formats/typebox/uri_template.ts at pi-mono v1.5.2.
import Foundation

enum UriTemplatePattern {
    // Upstream: /^(?:(?:[^\x00-\x20"<>%\\^`{|}\x7f]|%[0-9a-f]{2})|\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9]\d{0,3}|\*)?)*\})*$/i
    static let regex = try? NSRegularExpression(pattern: "\\A(?:(?:[^\\x00-\\x20\"<>%\\\\^`{|}\\x7f]|%[0-9a-f]{2})|\\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9][0-9]{0,3}|\\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?:\\.(?:[a-z0-9_]|%[0-9a-f]{2})+)*(?::[1-9][0-9]{0,3}|\\*)?)*\\})*\\z", options: .caseInsensitive)
}

func isUriTemplate(_ value: String) -> Bool {
    // Unicode literals are permitted; variable expressions use ASCII classes under JS /i.
    var inExpression = false
    for unit in value.utf16 {
        if unit == 123 { inExpression = true }
        else if unit == 125 { inExpression = false }
        else if inExpression && unit >= 128 { return false }
    }
    return formatFullMatch(UriTemplatePattern.regex, value)
}
