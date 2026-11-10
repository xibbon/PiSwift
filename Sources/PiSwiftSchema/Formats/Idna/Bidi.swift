// Port of packages/schema/src/formats/typebox/idna/format/bidi.ts, pi-mono v1.5.2.
import Foundation

enum IdnaBidi {
    private enum BidiClass { case l, r, al, an, en, on, nsm }

    // /^(?:R|AL|AN|EN|ES|CS|ET|ON|BN|NSM)$/,
    // /^(?:L|EN|ES|CS|ET|ON|BN|NSM)$/ and /^(?:R|AL|AN)$/
    // Hand-written finite membership checks avoid regex construction or backtracking.
    private static func rtlAllowed(_ c: BidiClass) -> Bool { c != .l }
    private static func ltrAllowed(_ c: BidiClass) -> Bool { c != .r && c != .al && c != .an }
    private static func rtlClass(_ c: BidiClass) -> Bool { c == .r || c == .al || c == .an }

    // HasBidiChars
    static func hasBidiChars(_ value: String) -> Bool {
        if IdnaPuny.isAcePrefixed(value) {
            guard let decoded = IdnaPuny.decode(IdnaPuny.aceBody(value).lowercased()) else { return false }
            return hasRightToLeftCharacters(decoded)
        }
        return hasRightToLeftCharacters(value)
    }

    // GetBidiClass. The commented-out ES/CS upstream branches remain absent.
    private static func getBidiClass(_ scalar: Unicode.Scalar) -> BidiClass {
        let cp = scalar.value
        if IdnaPattern.reEuropeanNumber(cp) { return .en }
        if IdnaPattern.reArabicIndicDigit(cp) { return .an }
        if IdnaPattern.reMarkNonspacing(scalar) { return .nsm }
        if IdnaPattern.reScriptHebrew(scalar) { return .r }
        if IdnaPattern.reScriptArabicLetter(scalar) { return .al }
        if IdnaPattern.reLetter(scalar) { return .l }
        return .on
    }

    // HasRightToLeftCharacters: JavaScript for...of iterates code points.
    static func hasRightToLeftCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { rtlClass(getBidiClass($0)) }
    }

    // SatisfiesBidiRule. Trailing-class checks are commented out upstream.
    static func satisfiesBidiRule(_ value: String) -> Bool {
        var isRtl = false
        var sawEN = false
        var sawAN = false
        var isFirst = true
        for scalar in value.unicodeScalars {
            let bidiClass = getBidiClass(scalar)
            if isFirst {
                if bidiClass != .l && bidiClass != .r && bidiClass != .al { return false }
                isRtl = bidiClass == .r || bidiClass == .al
                isFirst = false
            }
            if !(isRtl ? rtlAllowed(bidiClass) : ltrAllowed(bidiClass)) { return false }
            if bidiClass == .en { sawEN = true }
            else if bidiClass == .an { sawAN = true }
        }
        if isRtl && sawEN && sawAN { return false }
        return true
    }
}
