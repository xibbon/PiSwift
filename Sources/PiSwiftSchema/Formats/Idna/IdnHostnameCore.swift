// Port of packages/schema/src/formats/typebox/idna/idn-hostname.ts, pi-mono v1.5.2.
import Foundation

enum IdnaIdnHostname {
    private static func isValidLabelLength(_ value: String) -> Bool {
        let length = value.utf16.count
        return length > 0 && length <= 63
    }
    private static func isLabel(_ value: String) -> Bool {
        isValidLabelLength(value) && (IdnaPunyLabel.isPunyLabel(value) || IdnaUnicodeLabel.isUnicodeLabel(value))
    }
    // NormalizeHostname. Upstream patterns:
    // /[\uff01-\uff5e]/g, /[\u00ad\u034f\u180b-\u180d\u200b\ufe00-\ufe0f\u{e0100}-\u{e01ef}]/gu,
    // /[\u002E\u3002\uFF0E\uFF61]/g. Each is a linear scalar mapping.
    private static func normalizeHostname(_ value: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let cp = scalar.value
            if (0xFF01...0xFF5E).contains(cp), let ascii = Unicode.Scalar(cp - 0xFEE0) { mapped.append(ascii) }
            else { mapped.append(scalar) }
        }
        let nfc = String(mapped).precomposedStringWithCanonicalMapping
        var output = String.UnicodeScalarView()
        for scalar in nfc.unicodeScalars {
            let cp = scalar.value
            if cp == 0x00AD || cp == 0x034F || (0x180B...0x180D).contains(cp) || cp == 0x200B
                || (0xFE00...0xFE0F).contains(cp) || (0xE0100...0xE01EF).contains(cp) { continue }
            if cp == 0x002E || cp == 0x3002 || cp == 0xFF0E || cp == 0xFF61 { output.append(".") }
            else { output.append(scalar) }
        }
        return String(output)
    }
    // IsIdnHostname
    static func isIdnHostname(_ value: String) -> Bool {
        if value.utf16.isEmpty || value.utf16.contains(32) { return false }
        let normalized = normalizeHostname(value)
        if normalized.utf16.count > 253 { return false }
        let labels = idnaSplitLabels(normalized)
        let hasBidiChars = labels.contains { IdnaBidi.hasBidiChars($0) }
        return labels.allSatisfy { isLabel($0) && (!hasBidiChars || IdnaBidi.satisfiesBidiRule($0)) }
    }
}

func idnaIsIdnHostname(_ value: String) -> Bool { IdnaIdnHostname.isIdnHostname(value) }
