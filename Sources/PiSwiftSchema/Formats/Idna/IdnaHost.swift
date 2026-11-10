// Port of packages/schema/src/formats/typebox/idna/hostname.ts, pi-mono v1.5.2.
import Foundation

enum IdnaHostname {
    private static func isValidLabelLength(_ value: String) -> Bool {
        let length = value.utf16.count
        return length > 0 && length <= 63
    }
    private static func isLabel(_ value: String) -> Bool {
        isValidLabelLength(value) && (IdnaPunyLabel.isPunyLabel(value) || IdnaAsciiLabel.isAsciiLabel(value))
    }
    // IsHostname
    static func isHostname(_ value: String) -> Bool {
        let length = value.utf16.count
        if length == 0 || length > 253 { return false }
        if value.utf16.last == 46 { return false }
        return idnaSplitLabels(value).allSatisfy { isLabel($0) }
    }
}

func idnaIsHostname(_ value: String) -> Bool { IdnaHostname.isHostname(value) }

// JavaScript String.split(".") splits UTF-16 units, not Swift grapheme clusters.
func idnaSplitLabels(_ value: String) -> [String] {
    var labels: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
        if scalar.value == 46 {
            labels.append(String(current))
            current = String.UnicodeScalarView()
        } else { current.append(scalar) }
    }
    labels.append(String(current))
    return labels
}
