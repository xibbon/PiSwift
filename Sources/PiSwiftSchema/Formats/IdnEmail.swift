// Port of packages/schema/src/formats/typebox/idn_email.ts, pi-mono v1.5.2.
import Foundation

// Upstream:
// /^(?:[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u{0080}-\u{10FFFF}-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\u{0080}-\u{10FFFF}-]+)*|"(?:[^"\\]|\\.)*")@[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62})(?<!-)(?:\.[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62})(?<!-))*$/iu
// This finite scanner follows the `u` code-point rules and has linear time.
// The upstream package entry point exports only `formats`; this function is internal.
func isIdnEmail(_ value: String) -> Bool {
    let scalars = Array(value.precomposedStringWithCanonicalMapping.unicodeScalars)
    let count = scalars.count
    var i = 0
    if i < count && scalars[i].value == 34 {
        i += 1
        var closed = false
        while i < count {
            let cp = scalars[i].value
            if cp == 34 { i += 1; closed = true; break }
            if cp == 92 {
                i += 1
                if i >= count || [10, 13, 0x2028, 0x2029].contains(scalars[i].value) { return false }
            }
            i += 1
        }
        if !closed { return false }
    } else {
        guard scanIdnEmailAtom(scalars, &i) else { return false }
        while i < count && scalars[i].value == 46 {
            i += 1
            guard scanIdnEmailAtom(scalars, &i) else { return false }
        }
    }
    if i >= count || scalars[i].value != 64 { return false }
    i += 1
    guard scanIdnEmailDomainLabel(scalars, &i) else { return false }
    while i < count && scalars[i].value == 46 {
        i += 1
        guard scanIdnEmailDomainLabel(scalars, &i) else { return false }
    }
    return i == count
}

private func isIdnEmailAtomScalar(_ cp: UInt32) -> Bool {
    if cp >= 0x80 { return true }
    return (65...90).contains(cp) || (97...122).contains(cp) || (48...57).contains(cp)
        || "!#$%&'*+/=?^_`{|}~-".unicodeScalars.contains(where: { $0.value == cp })
}

private func scanIdnEmailAtom(_ chars: [Unicode.Scalar], _ index: inout Int) -> Bool {
    let start = index
    while index < chars.count && isIdnEmailAtomScalar(chars[index].value) { index += 1 }
    return index > start
}

private func isIdnEmailDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}

private func scanIdnEmailDomainLabel(_ chars: [Unicode.Scalar], _ index: inout Int) -> Bool {
    guard index < chars.count, isIdnEmailDomainScalar(chars[index]) else { return false }
    index += 1
    var extra = 0
    while index < chars.count && extra < 62 {
        let cp = chars[index].value
        if cp != 45 && !isIdnEmailDomainScalar(chars[index]) { break }
        index += 1
        extra += 1
    }
    return chars[index - 1].value != 45
}
