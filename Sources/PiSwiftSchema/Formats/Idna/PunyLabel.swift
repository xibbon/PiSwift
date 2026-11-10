// Port of packages/schema/src/formats/typebox/idna/label/puny.ts, pi-mono v1.5.2.
import Foundation

enum IdnaPunyLabel {
    // IsPunyLabel
    static func isPunyLabel(_ value: String) -> Bool {
        if !IdnaPuny.isAcePrefixed(value) { return false }
        let body = IdnaPuny.aceBody(value).lowercased()
        if Array(body.utf16).lastIndex(of: 45) == 0 { return false }
        guard let decoded = IdnaPuny.decode(body) else { return false }
        if !IdnaPattern.reNonAscii(decoded) { return false }
        return IdnaUnicodeLabel.isUnicodeLabel(decoded)
    }
}
