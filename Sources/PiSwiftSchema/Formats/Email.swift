// Port of packages/schema/src/formats/typebox/email.ts at pi-mono v1.5.2.
import Foundation

enum EmailPattern {
    // Upstream: /^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[^"\\]|\\[\x20-\x7e])*")@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*|\[(?:IPv6:[a-f0-9:]+|(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})\])$/i
    static let regex = try? NSRegularExpression(pattern: "\\A(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|\"(?:[^\"\\\\]|\\\\[\\x20-\\x7e])*\")@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*|\\[(?:IPv6:[a-f0-9:]+|(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?:\\.(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3})\\])\\z", options: .caseInsensitive)
}

func isEmail(_ value: String) -> Bool {
    // The quoted local part permits Unicode. Other classes are ASCII even under JS /i.
    let units = Array(value.utf16)
    if units.first == 34, let at = units.lastIndex(of: 64) {
        guard units[(at + 1)...].allSatisfy({ $0 < 128 }) else { return false }
    } else {
        guard units.allSatisfy({ $0 < 128 }) else { return false }
    }
    return formatFullMatch(EmailPattern.regex, value)
}
