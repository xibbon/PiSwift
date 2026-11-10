// ECMAScript RegExp `u` syntax for typebox/regex.ts at pi-mono v1.5.2.
// ECMA-262 §22.2.1 syntax and early errors, with Node 22 as runtime oracle.
// The explicit `groups` stack implements recursive Disjunction/Alternative/Term
// parsing without using the Swift call stack. `openGroup` parses GroupSpecifier,
// `scanQuantifier` parses Quantifier, `scanClass` parses CharacterClass, and
// `scanEscape` parses AtomEscape and ClassEscape. Each scan advances the cursor,
// so validation is linear in the UTF-16 input length.
import Foundation

struct RegexSyntax {
    private let units: [UInt16]
    private var i = 0
    private var groups: [Bool] = [] // assertion groups cannot be quantified
    private var captures = 0
    private var numericRefs: [Int] = []
    private var names: Set<[UInt16]> = []
    private var namedRefs: [[UInt16]] = []
    private var canQuantify = false

    init(_ value: String) { units = Array(value.utf16) }

    mutating func isValid() -> Bool {
        while i < units.count {
            switch units[i] {
            case 40: guard openGroup() else { return false }
            case 41:
                guard let assertion = groups.popLast() else { return false }
                i += 1; canQuantify = !assertion
            case 91:
                i += 1
                guard scanClass() else { return false }
                canQuantify = true
            case 92:
                i += 1
                guard let assertion = scanEscape(inClass: false) else { return false }
                canQuantify = !assertion
            case 42,43,63,123:
                guard canQuantify, scanQuantifier() else { return false }
                canQuantify = false
            case 94,36,124: i += 1; canQuantify = false
            case 93,125: return false
            default: i += 1; canQuantify = true
            }
        }
        return groups.isEmpty && !numericRefs.contains(where: { $0 > captures })
            && !namedRefs.contains(where: { !names.contains($0) })
    }

    private mutating func openGroup() -> Bool {
        i += 1
        var assertion = false
        if at(63) {
            i += 1
            if at(58) { i += 1 }
            else if at(61) || at(33) { i += 1; assertion = true }
            else if at(60) {
                i += 1
                if at(61) || at(33) { i += 1; assertion = true }
                else {
                    guard let name = scanName(), names.insert(name).inserted else { return false }
                    captures += 1
                }
            } else { return false } // Node 22 rejects scoped modifiers.
        } else { captures += 1 }
        groups.append(assertion)
        canQuantify = false
        return true
    }

    private mutating func scanQuantifier() -> Bool {
        if at(123) {
            i += 1
            let minStart = i
            guard scanDecimal() != nil else { return false }
            let minRange = minStart..<i
            var maxRange: Range<Int>?
            if at(44) {
                i += 1
                let maxStart = i
                if scanDecimal() != nil { maxRange = maxStart..<i }
            } else { maxRange = minRange }
            guard at(125) else { return false }
            i += 1
            if let maxRange, decimalGreater(minRange, maxRange) { return false }
        } else { i += 1 }
        if at(63) { i += 1 }
        return true
    }

    private func decimalGreater(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        var aa = a.lowerBound, bb = b.lowerBound
        while aa + 1 < a.upperBound && units[aa] == 48 { aa += 1 }
        while bb + 1 < b.upperBound && units[bb] == 48 { bb += 1 }
        let alen = a.upperBound - aa, blen = b.upperBound - bb
        if alen != blen { return alen > blen }
        for offset in 0..<alen {
            if units[aa + offset] != units[bb + offset] { return units[aa + offset] > units[bb + offset] }
        }
        return false
    }

    private mutating func scanDecimal() -> Int? {
        let start = i
        var result = 0
        while i < units.count && (48...57).contains(units[i]) {
            let digit = Int(units[i] - 48)
            result = result > (Int.max - digit) / 10 ? Int.max : result * 10 + digit
            i += 1
        }
        return i > start ? result : nil
    }

    // Returns true for an assertion, false for an atom, nil for invalid syntax.
    private mutating func scanEscape(inClass: Bool) -> Bool? {
        guard i < units.count else { return nil }
        let c = units[i]; i += 1
        switch c {
        case 100,68,115,83,119,87: return false // dDsSwW
        case 98: return !inClass // b
        case 66: return inClass ? nil : true // B
        case 102,110,114,116,118: return false // fnrtv
        case 99: // cA
            guard i < units.count, letter(units[i]) else { return nil }
            i += 1; return false
        case 120: return scanHex(2) == nil ? nil : false
        case 117: return scanUnicodeEscape() == nil ? nil : false
        case 112,80: // p{...}, P{...}
            guard at(123) else { return nil }
            i += 1
            let start = i
            while i < units.count && units[i] != 125 {
                let c = units[i]
                guard letter(c) || (48...57).contains(c) || c == 95 || c == 61 else { return nil }
                i += 1
            }
            guard at(125), i > start else { return nil }
            let expression = String(decoding: units[start..<i], as: UTF16.self)
            i += 1
            return RegexProperties.accepts(expression) ? false : nil
        case 107 where !inClass: // k<name>
            guard at(60) else { return nil }
            i += 1
            guard let name = scanName() else { return nil }
            namedRefs.append(name)
            return false
        case 48:
            if i < units.count && (48...57).contains(units[i]) { return nil }
            return false
        case 49...57 where !inClass:
            i -= 1
            guard let n = scanDecimal() else { return nil }
            numericRefs.append(n)
            return false
        case 45 where inClass: return false
        case 47,94,36,92,46,42,43,63,40,41,91,93,123,125,124: return false
        default: return nil
        }
    }

    private mutating func scanClass() -> Bool {
        if at(94) { i += 1 }
        while i < units.count {
            if at(93) { i += 1; return true }
            guard let first = scanClassAtom() else { return false }
            if at(45) && i + 1 < units.count && units[i + 1] != 93 {
                i += 1
                guard let second = scanClassAtom(), first != UInt32.max, second != UInt32.max, first <= second else { return false }
            }
        }
        return false
    }

    // UInt32.max means a character class escape; it cannot be a range endpoint.
    private mutating func scanClassAtom() -> UInt32? {
        guard i < units.count else { return nil }
        if at(92) {
            i += 1
            guard i < units.count else { return nil }
            let c = units[i]
            if [100,68,115,83,119,87,112,80].contains(c) {
                return scanEscape(inClass: true) == nil ? nil : UInt32.max
            }
            if c == 98 { i += 1; return 8 }
            if c == 45 { i += 1; return 45 }
            if c == 48 { i += 1; return 0 }
            if c == 120 { i += 1; return scanHex(2) }
            if c == 117 {
                i += 1
                guard let first = scanUnicodeEscape() else { return nil }
                if (0xD800...0xDBFF).contains(first), i + 1 < units.count,
                   units[i] == 92, units[i + 1] == 117 {
                    let saved = i
                    i += 2
                    if let low = scanUnicodeEscape(), (0xDC00...0xDFFF).contains(low) {
                        return 0x10000 + ((first - 0xD800) << 10) + low - 0xDC00
                    }
                    i = saved
                }
                return first
            }
            guard scanEscape(inClass: true) != nil else { return nil }
            if c == 99 { return UInt32(units[i - 1] & 31) }
            if c == 102 { return 12 }
            if c == 110 { return 10 }
            if c == 114 { return 13 }
            if c == 116 { return 9 }
            if c == 118 { return 11 }
            return UInt32(c)
        }
        let c = UInt32(units[i]); i += 1
        if (0xD800...0xDBFF).contains(c), i < units.count,
           (0xDC00...0xDFFF).contains(UInt32(units[i])) {
            let low = UInt32(units[i]); i += 1
            return 0x10000 + ((c - 0xD800) << 10) + low - 0xDC00
        }
        return c
    }

    private mutating func scanUnicodeEscape() -> UInt32? {
        if at(123) {
            i += 1
            let start = i
            var value: UInt32 = 0
            while i < units.count, let h = hex(units[i]) {
                if value > 0x10FFFF / 16 { return nil }
                value = value * 16 + h
                if value > 0x10FFFF { return nil }
                i += 1
            }
            guard i > start, at(125) else { return nil }
            i += 1
            return value
        }
        return scanHex(4)
    }
    private mutating func scanHex(_ count: Int) -> UInt32? {
        guard i + count <= units.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<count {
            guard let h = hex(units[i]) else { return nil }
            value = value * 16 + h; i += 1
        }
        return value
    }
    private mutating func scanName() -> [UInt16]? {
        var name: [UInt16] = []
        while i < units.count && units[i] != 62 {
            let value: UInt32
            if units[i] == 92 {
                i += 1
                guard at(117) else { return nil }
                i += 1
                guard let escaped = scanUnicodeEscape() else { return nil }
                value = escaped
            } else {
                let first = UInt32(units[i]); i += 1
                if (0xD800...0xDBFF).contains(first), i < units.count,
                   (0xDC00...0xDFFF).contains(UInt32(units[i])) {
                    value = 0x10000 + ((first - 0xD800) << 10) + UInt32(units[i]) - 0xDC00
                    i += 1
                } else { value = first }
            }
            guard let scalar = Unicode.Scalar(value) else { return nil }
            let allowed = name.isEmpty
                ? (value == 36 || value == 95 || scalar.properties.isIDStart)
                : (value == 36 || value == 95 || value == 0x200C || value == 0x200D || scalar.properties.isIDContinue)
            guard allowed else { return nil }
            name.append(contentsOf: String(scalar).utf16)
        }
        guard !name.isEmpty, at(62) else { return nil }
        i += 1
        return name
    }
    private func at(_ value: UInt16) -> Bool { i < units.count && units[i] == value }
    private func letter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
    private func hex(_ c: UInt16) -> UInt32? {
        if (48...57).contains(c) { return UInt32(c - 48) }
        if (65...70).contains(c) { return UInt32(c - 65 + 10) }
        if (97...102).contains(c) { return UInt32(c - 97 + 10) }
        return nil
    }
}

private enum RegexProperties {
    // Exact spellings accepted by Node 22.23.1 / Unicode 17.0 for candidate
    // aliases from Unicode PropertyAliases.txt and PropertyValueAliases.txt.
    // Source decisions: Fixtures/generated/regex-properties-node22.json.
    private static let bare = Set("""
        AHex ASCII ASCII_Hex_Digit Alpha Alphabetic Any Assigned Bidi_C Bidi_Control Bidi_M Bidi_Mirrored C CI CWCF CWCM CWKCF CWL CWT CWU Case_Ignorable Cased Cased_Letter Cc Cf Changes_When_Casefolded Changes_When_Casemapped Changes_When_Lowercased Changes_When_NFKC_Casefolded Changes_When_Titlecased Changes_When_Uppercased Close_Punctuation Cn Co Combining_Mark Connector_Punctuation Control Cs Currency_Symbol DI Dash Dash_Punctuation Decimal_Number Default_Ignorable_Code_Point Dep Deprecated Dia Diacritic EBase EComp EMod EPres Emoji Emoji_Component Emoji_Modifier Emoji_Modifier_Base Emoji_Presentation Enclosing_Mark Ext ExtPict Extended_Pictographic Extender Final_Punctuation Format General_Category=Uppercase_Letter Gr_Base Gr_Ext Grapheme_Base Grapheme_Extend Hex Hex_Digit IDC IDS IDSB IDST IDS_Binary_Operator IDS_Trinary_Operator ID_Continue ID_Start Ideo Ideographic Initial_Punctuation Join_C Join_Control L LC LOE Letter Letter_Number Line_Separator Ll Lm Lo Logical_Order_Exception Lower Lowercase Lowercase_Letter Lt Lu M Mark Math Math_Symbol Mc Me Mn Modifier_Letter Modifier_Symbol N NChar Nd Nl No Noncharacter_Code_Point Nonspacing_Mark Number Open_Punctuation Other Other_Letter Other_Number Other_Punctuation Other_Symbol P Paragraph_Separator Pat_Syn Pat_WS Pattern_Syntax Pattern_White_Space Pc Pd Pe Pf Pi Po Private_Use Ps Punctuation QMark Quotation_Mark RI Radical Regional_Indicator S SD STerm Sc Script=Greek Sentence_Terminal Separator Sk Sm So Soft_Dotted Space_Separator Spacing_Mark Surrogate Symbol Term Terminal_Punctuation Titlecase_Letter UIdeo Unassigned Unified_Ideograph Upper Uppercase Uppercase_Letter VS Variation_Selector WSpace White_Space XIDC XIDS XID_Continue XID_Start Z Zl Zp Zs cntrl digit gc=Lu punct scx=Grek space
        """.split(separator: " ").map(String.init))
    private static let generalCategories = Set("""
        C Cased_Letter Cc Cf Close_Punctuation Cn Co Combining_Mark Connector_Punctuation Control Cs Currency_Symbol Dash_Punctuation Decimal_Number Enclosing_Mark Final_Punctuation Format Initial_Punctuation L LC Letter Letter_Number Line_Separator Ll Lm Lo Lowercase_Letter Lt Lu M Mark Math_Symbol Mc Me Mn Modifier_Letter Modifier_Symbol N Nd Nl No Nonspacing_Mark Number Open_Punctuation Other Other_Letter Other_Number Other_Punctuation Other_Symbol P Paragraph_Separator Pc Pd Pe Pf Pi Po Private_Use Ps Punctuation S Sc Separator Sk Sm So Space_Separator Spacing_Mark Surrogate Symbol Titlecase_Letter Unassigned Uppercase_Letter Z Zl Zp Zs cntrl digit punct
        """.split(separator: " ").map(String.init))
    private static let scripts = Set("""
        Adlam Adlm Aghb Ahom Anatolian_Hieroglyphs Arab Arabic Armenian Armi Armn Avestan Avst Bali Balinese Bamu Bamum Bass Bassa_Vah Batak Batk Beng Bengali Berf Beria_Erfe Bhaiksuki Bhks Bopo Bopomofo Brah Brahmi Brai Braille Bugi Buginese Buhd Buhid Cakm Canadian_Aboriginal Cans Cari Carian Caucasian_Albanian Chakma Cham Cher Cherokee Chorasmian Chrs Common Copt Coptic Cpmn Cprt Cuneiform Cypriot Cypro_Minoan Cyrillic Cyrl Deseret Deva Devanagari Diak Dives_Akuru Dogr Dogra Dsrt Dupl Duployan Egyp Egyptian_Hieroglyphs Elba Elbasan Elym Elymaic Ethi Ethiopic Gara Garay Geor Georgian Glag Glagolitic Gong Gonm Goth Gothic Gran Grantha Greek Grek Gujarati Gujr Gukh Gunjala_Gondi Gurmukhi Guru Gurung_Khema Han Hang Hangul Hani Hanifi_Rohingya Hano Hanunoo Hatr Hatran Hebr Hebrew Hira Hiragana Hluw Hmng Hmnp Hung Imperial_Aramaic Inherited Inscriptional_Pahlavi Inscriptional_Parthian Ital Java Javanese Kaithi Kali Kana Kannada Katakana Kawi Kayah_Li Khar Kharoshthi Khitan_Small_Script Khmer Khmr Khoj Khojki Khudawadi Kirat_Rai Kits Knda Krai Kthi Lana Lao Laoo Latin Latn Lepc Lepcha Limb Limbu Lina Linb Linear_A Linear_B Lisu Lyci Lycian Lydi Lydian Mahajani Mahj Maka Makasar Malayalam Mand Mandaic Mani Manichaean Marc Marchen Masaram_Gondi Medefaidrin Medf Meetei_Mayek Mend Mende_Kikakui Merc Mero Meroitic_Cursive Meroitic_Hieroglyphs Miao Mlym Modi Mong Mongolian Mro Mroo Mtei Mult Multani Myanmar Mymr Nabataean Nag_Mundari Nagm Nand Nandinagari Narb Nbat New_Tai_Lue Newa Nko Nkoo Nshu Nushu Nyiakeng_Puachue_Hmong Ogam Ogham Ol_Chiki Ol_Onal Olck Old_Hungarian Old_Italic Old_North_Arabian Old_Permic Old_Persian Old_Sogdian Old_South_Arabian Old_Turkic Old_Uyghur Onao Oriya Orkh Orya Osage Osge Osma Osmanya Ougr Pahawh_Hmong Palm Palmyrene Pau_Cin_Hau Pauc Perm Phag Phags_Pa Phli Phlp Phnx Phoenician Plrd Prti Psalter_Pahlavi Qaac Qaai Rejang Rjng Rohg Runic Runr Samaritan Samr Sarb Saur Saurashtra Sgnw Sharada Shavian Shaw Shrd Sidd Siddham Sidetic Sidt SignWriting Sind Sinh Sinhala Sogd Sogdian Sogo Sora Sora_Sompeng Soyo Soyombo Sund Sundanese Sunu Sunuwar Sylo Syloti_Nagri Syrc Syriac Tagalog Tagb Tagbanwa Tai_Le Tai_Tham Tai_Viet Tai_Yo Takr Takri Tale Talu Tamil Taml Tang Tangsa Tangut Tavt Tayo Telu Telugu Tfng Tglg Thaa Thaana Thai Tibetan Tibt Tifinagh Tirh Tirhuta Tnsa Todhri Todr Tolong_Siki Tols Toto Tulu_Tigalari Tutg Ugar Ugaritic Unknown Vai Vaii Vith Vithkuqi Wancho Wara Warang_Citi Wcho Xpeo Xsux Yezi Yezidi Yi Yiii Zanabazar_Square Zanb Zinh Zyyy Zzzz
        """.split(separator: " ").map(String.init))
    static func accepts(_ expression: String) -> Bool {
        let parts = expression.split(separator: "=", omittingEmptySubsequences: false)
        if parts.count == 1 { return bare.contains(expression) }
        if parts.count != 2 { return false }
        let name = String(parts[0]), value = String(parts[1])
        if name == "gc" || name == "General_Category" { return generalCategories.contains(value) }
        if name == "sc" || name == "Script" || name == "scx" || name == "Script_Extensions" {
            return scripts.contains(value)
        }
        return false
    }
}
