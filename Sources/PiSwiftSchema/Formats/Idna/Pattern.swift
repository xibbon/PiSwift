// Port of packages/schema/src/formats/typebox/idna/pattern/pattern.ts, pi-mono v1.5.2.
import Foundation

// Each upstream regexp is a single-code-point test or a short ASCII rule. These
// predicates have bounded work per scalar and do not backtrack. The script
// predicates use ICU Unicode properties, compiled once; a failed compile is
// visible to tests as a false result instead of terminating the process.
enum IdnaPattern {
    // /^(?!-).*(?<!-)$/
    static func reRuleHyphenPlacement(_ value: String) -> Bool {
        let units = Array(value.utf16)
        return units.first != 45 && units.last != 45 && !units.contains(where: { $0 == 10 || $0 == 13 || $0 == 0x2028 || $0 == 0x2029 })
    }
    // /^(?!..--)/
    static func reRuleNotReservedAce(_ value: String) -> Bool {
        let units = Array(value.utf16)
        return units.count < 4 || units[2] != 45 || units[3] != 45
    }
    // /^[a-zA-Z0-9-]*$/
    static func reAsciiLDH(_ value: String) -> Bool {
        value.utf16.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    // /^\p{ASCII}*$/u
    static func reAscii(_ value: String) -> Bool { value.utf16.allSatisfy { $0 < 128 } }
    // /[^\p{ASCII}]/u
    static func reNonAscii(_ value: String) -> Bool { value.utf16.contains { $0 >= 128 } }
    // /[\u{d800}-\u{dbff}]/u (unused by the tagged validation path)
    static func reHighSurrogate(_ cp: UInt32) -> Bool { (0xD800...0xDBFF).contains(cp) }
    // /[\u{1f1e6}-\u{1f1ff}]/u
    static func reRegionalIndicator(_ cp: UInt32) -> Bool { (0x1F1E6...0x1F1FF).contains(cp) }
    // /[\u{fe00}-\u{fe0f}]/u
    static func reVariationSelector(_ cp: UInt32) -> Bool { (0xFE00...0xFE0F).contains(cp) }
    // /\u{200d}/u
    static func reZeroWidthJoiner(_ cp: UInt32) -> Bool { cp == 0x200D }
    // /[0-9]/
    static func reAsciiDigit(_ cp: UInt32) -> Bool { (48...57).contains(cp) }
    // /[\u{0660}-\u{0669}]/u
    static func reArabicIndicDigit(_ cp: UInt32) -> Bool { (0x660...0x669).contains(cp) }
    // /[\u{06f0}-\u{06f9}]/u
    static func reExtArabicIndicDigit(_ cp: UInt32) -> Bool { (0x6F0...0x6F9).contains(cp) }
    // /[\u{002e}\u{002c}\u{003a}\u{002f}]/u
    static func reCommonSeparator(_ cp: UInt32) -> Bool { [0x2E, 0x2C, 0x3A, 0x2F].contains(cp) }
    // /[\u{002d}\u{002b}]/u
    static func reEuropeanSeparator(_ cp: UInt32) -> Bool { cp == 0x2D || cp == 0x2B }

    // /\p{Mn}/u, /\p{Mc}/u, /\p{Me}/u, /[\p{Mn}\p{Mc}\p{Me}]/u
    static func reMarkNonspacing(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .nonspacingMark }
    static func reMarkSpacingCombining(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .spacingMark }
    static func reMarkEnclosing(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .enclosingMark }
    static func reCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        reMarkNonspacing(scalar) || reMarkSpacingCombining(scalar) || reMarkEnclosing(scalar)
    }
    // /\p{L}/u, /\p{Nd}/u
    static func reLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }
    static func reNumberDecimal(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.generalCategory == .decimalNumber }

    private static func compile(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }
    private static let greek = compile("\\p{Script=Greek}")
    private static let hebrew = compile("\\p{Script=Hebrew}")
    private static let japanese = compile("[\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Han}]")
    private static let arabicLetter = compile("[\\p{Script=Arabic}\\p{Script=Syriac}\\p{Script=Thaana}\\p{Script=Mandaic}]")
    static var allScriptPatternsCompiled: Bool {
        greek != nil && hebrew != nil && japanese != nil && arabicLetter != nil
    }
    private static func matches(_ pattern: NSRegularExpression?, _ scalar: Unicode.Scalar) -> Bool {
        let string = String(scalar)
        return pattern?.firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil
    }
    // /\p{Script=Greek}/u
    static func reScriptGreek(_ scalar: Unicode.Scalar) -> Bool { matches(greek, scalar) }
    // /\p{Script=Hebrew}/u
    static func reScriptHebrew(_ scalar: Unicode.Scalar) -> Bool { matches(hebrew, scalar) }
    // /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u
    static func reScriptJapanese(_ scalar: Unicode.Scalar) -> Bool { matches(japanese, scalar) }
    // /[\p{Script=Arabic}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Mandaic}]/u
    static func reScriptArabicLetter(_ scalar: Unicode.Scalar) -> Bool { matches(arabicLetter, scalar) }

    // /[\u{094d}\u{09cd}\u{0a4d}\u{0acd}\u{0b4d}\u{0bcd}\u{0c4d}\u{0ccd}\u{0d3b}\u{0d3c}\u{0d4d}\u{0dca}\u{1b44}\u{1baa}\u{1bab}\u{a9c0}\u{11046}\u{1107f}\u{110b9}\u{11133}\u{11134}\u{111c0}\u{11235}\u{1134d}\u{11442}\u{114c2}\u{115bf}\u{1163f}\u{116b6}\u{11c3f}\u{11d44}\u{11d45}]/u
    private static let virama: Set<UInt32> = [0x094D,0x09CD,0x0A4D,0x0ACD,0x0B4D,0x0BCD,0x0C4D,0x0CCD,0x0D3B,0x0D3C,0x0D4D,0x0DCA,0x1B44,0x1BAA,0x1BAB,0xA9C0,0x11046,0x1107F,0x110B9,0x11133,0x11134,0x111C0,0x11235,0x1134D,0x11442,0x114C2,0x115BF,0x1163F,0x116B6,0x11C3F,0x11D44,0x11D45]
    static func reVirama(_ cp: UInt32) -> Bool { virama.contains(cp) }
    // /[\u{0640}\u{07fa}\u{302e}\u{302f}\u{3031}\u{3032}\u{3033}\u{3034}\u{3035}\u{303b}]/u
    private static let disallowed: Set<UInt32> = [0x0640,0x07FA,0x302E,0x302F,0x3031,0x3032,0x3033,0x3034,0x3035,0x303B]
    static func reRFC5892Disallowed(_ cp: UInt32) -> Bool { disallowed.contains(cp) }
    // /[\u{00b7}\u{0375}\u{05f3}\u{05f4}\u{200c}\u{200d}\u{30fb}]/u
    private static let contexto: Set<UInt32> = [0x00B7,0x0375,0x05F3,0x05F4,0x200C,0x200D,0x30FB]
    static func reContextoExceptions(_ cp: UInt32) -> Bool { contexto.contains(cp) }
    // /[\u{00df}\u{03c2}\u{06fd}\u{06fe}\u{0f0b}\u{3007}]/u
    private static let pvalid: Set<UInt32> = [0x00DF,0x03C2,0x06FD,0x06FE,0x0F0B,0x3007]
    static func rePvalidExceptions(_ cp: UInt32) -> Bool { pvalid.contains(cp) }
    // /[0-9]|[\u{06f0}-\u{06f9}]/u
    static func reEuropeanNumber(_ cp: UInt32) -> Bool { reAsciiDigit(cp) || reExtArabicIndicDigit(cp) }
    // /\p{L}|[\u{002d}\u{002b}]|[\u{002e}\u{002c}\u{003a}\u{002f}]|\p{Nd}|\p{Mn}|\p{Mc}|[contexto]|[pvalid]/u
    static func rePermittedCategory(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        return reLetter(scalar) || reEuropeanSeparator(cp) || reCommonSeparator(cp) || reNumberDecimal(scalar)
            || reMarkNonspacing(scalar) || reMarkSpacingCombining(scalar) || reContextoExceptions(cp) || rePvalidExceptions(cp)
    }
}
