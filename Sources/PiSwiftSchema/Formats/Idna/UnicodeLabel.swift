// Port of packages/schema/src/formats/typebox/idna/label/unicode.ts, pi-mono v1.5.2.
import Foundation

enum IdnaUnicodeLabel {
    // ExceedsMaxALabelLength
    private static func exceedsMaxALabelLength(_ value: String) -> Bool {
        guard IdnaPattern.reNonAscii(value) else { return false }
        guard let encoded = IdnaPuny.encode(value) else { return true }
        return encoded.utf16.count + 4 > 63
    }

    // HasInvalidHyphens. Indexes are code points, as in upstream [...value].
    private static func hasInvalidHyphens(_ chars: [Unicode.Scalar]) -> Bool {
        if chars.first?.value == 45 || chars.last?.value == 45 { return true }
        return chars.count >= 4 && chars[2].value == 45 && chars[3].value == 45
    }

    // IsUnicodeLabel
    static func isUnicodeLabel(_ value: String) -> Bool {
        if exceedsMaxALabelLength(value) { return false }
        if IdnaBidi.hasRightToLeftCharacters(value) && !IdnaBidi.satisfiesBidiRule(value) { return false }
        let chars = Array(value.unicodeScalars)
        let codePoints = chars.map(\.value)
        let length = codePoints.count
        if hasInvalidHyphens(chars) { return false }
        if let first = chars.first, IdnaPattern.reCombiningMark(first) { return false }
        var hasJapanese = false
        for i in 0..<length {
            let codePoint = codePoints[i]
            let char = chars[i]
            if IdnaPattern.reRFC5892Disallowed(codePoint) { return false }
            if !IdnaPattern.rePermittedCategory(char) { return false }
            if IdnaPattern.reScriptJapanese(char) { hasJapanese = true }
            let prev: UInt32? = i > 0 ? codePoints[i - 1] : nil
            let next: UInt32? = i + 1 < length ? codePoints[i + 1] : nil
            switch codePoint {
            case 0x00B7: // MIDDLE DOT
                if prev != 0x006C || next != 0x006C { return false }
            case 0x0375: // Greek KERAIA
                if i + 1 >= length || !IdnaPattern.reScriptGreek(chars[i + 1]) { return false }
            case 0x05F3, 0x05F4: // Hebrew GERESH
                if i == 0 || !IdnaPattern.reScriptHebrew(chars[i - 1]) { return false }
            case 0x200C: // ZWNJ, including upstream's deliberately partial joining rule
                guard let prev else { return false }
                if prev < 0x80 && !IdnaPattern.reVirama(prev) { return false }
            case 0x200D: // ZWJ
                guard let prev, IdnaPattern.reVirama(prev) else { return false }
            case 0x30FB: break // Katakana middle dot, checked after loop
            default: break
            }
        }
        if codePoints.contains(0x30FB) && !hasJapanese { return false }
        return true
    }
}
