// Adaptation of Node 22 WHATWG URL.canParse used by url.ts, iri.ts, iri_reference.ts at pi-mono v1.5.2.
// The TypeBox sources delegate to URL.canParse. This parser keeps the relevant acceptance checks in Swift.
// Special-scheme hosts that need UTS 46 mapping or validation can be accepted
// where Node rejects them; this target ships no UTS 46 table.
@inline(__always)
func formatHex(_ c: UInt16) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
@inline(__always)
private func formatAlpha(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
@inline(__always)
private func formatSchemeCharacter(_ c: UInt16) -> Bool {
    formatAlpha(c) || (48...57).contains(c) || c == 43 || c == 45 || c == 46
}

func formatSchemePrefixEnd(_ units: [UInt16]) -> Int? {
    guard let first = units.first, formatAlpha(first) else { return nil }
    var i = 1
    while i < units.count && formatSchemeCharacter(units[i]) { i += 1 }
    return i
}

func formatSchemeEnd(_ units: [UInt16]) -> Int? {
    guard let first = units.first, formatAlpha(first) else { return nil }
    var i = 1
    while i < units.count && formatSchemeCharacter(units[i]) { i += 1 }
    return i < units.count && units[i] == 58 ? i : nil
}

func formatCanParseURL(_ value: String, base: Bool = false) -> Bool {
    let source = Array(value.utf16)
    // WHATWG strips leading and trailing C0 controls and spaces and strips tab/newline within input.
    var start = 0
    var end = source.count
    while start < end && source[start] <= 0x20 { start += 1 }
    while end > start && source[end - 1] <= 0x20 { end -= 1 }
    let units = source[start..<end].filter { $0 != 9 && $0 != 10 && $0 != 13 }
    if units.isEmpty { return base }
    guard let schemeEnd = formatSchemeEnd(units) else {
        if !base { return false }
        // The supplied base is http://example.com. Backslash is a separator for this special scheme.
        if units.first == 92 { return formatCanParseURL(String(decoding: units.map { $0 == 92 ? 47 : $0 }, as: UTF16.self), base: true) }
        return formatAuthorityIsValid(units, relative: true)
    }
    let scheme = String(decoding: units[..<schemeEnd], as: UTF16.self).lowercased()
    let tail = Array(units[(schemeEnd + 1)...])
    if ["http", "https", "ftp", "ws", "wss"].contains(scheme) {
        if base && scheme == "http" && !(tail.starts(with: [47,47]) || tail.starts(with: [92,92]) || tail.starts(with: [47,92]) || tail.starts(with: [92,47])) {
            return true
        }
        var j = 0
        while j < tail.count && (tail[j] == 47 || tail[j] == 92) { j += 1 }
        return j < tail.count && formatAuthorityIsValid(Array(tail[j...]), relative: false)
    }
    if scheme == "file" {
        let normalized = tail.map { $0 == 92 ? UInt16(47) : $0 }
        if normalized.starts(with: [47,47]) {
            let rest = Array(normalized.dropFirst(2))
            if rest.isEmpty || rest[0] == 47 || rest[0] == 63 || rest[0] == 35 { return true }
            let stop = rest.firstIndex(where: { $0 == 47 || $0 == 63 || $0 == 35 }) ?? rest.count
            let authority = rest[..<stop]
            if authority.contains(64) { return false }
            if authority.count == 2 && formatAlpha(authority[0]) && (authority[1] == 58 || authority[1] == 124) { return true }
            if authority.first != 91 && authority.contains(58) { return false }
            if authority.first == 91 && authority.last != 93 { return false }
            return formatAuthorityIsValid(rest, relative: false)
        }
        return true
    }
    if tail.starts(with: [47,47]) {
        // WHATWG permits an empty host for a non-special scheme.
        let rest = Array(tail.dropFirst(2))
        if rest.isEmpty || rest[0] == 47 || rest[0] == 63 || rest[0] == 35 { return true }
        return formatAuthorityIsValid(rest, relative: false, opaque: true)
    }
    return true
}

private func formatAuthorityIsValid(_ input: [UInt16], relative: Bool, opaque: Bool = false) -> Bool {
    var authority = input
    if relative {
        if !input.starts(with: [47,47]) { return true }
        var firstHost = 2
        while firstHost < input.count && input[firstHost] == 47 { firstHost += 1 }
        authority = Array(input[firstHost...])
    }
    let stop = authority.firstIndex(where: { $0 == 47 || $0 == 63 || $0 == 35 || (!opaque && $0 == 92) }) ?? authority.count
    authority = Array(authority[..<stop])
    if let at = authority.lastIndex(of: 64) { authority = Array(authority[(at + 1)...]) }
    guard !authority.isEmpty else { return false }
    if authority.first == 91 {
        guard let close = authority.firstIndex(of: 93), close > 1 else { return false }
        let host = String(decoding: authority[1..<close], as: UTF16.self)
        guard isIPv6(host) else { return false }
        return close + 1 == authority.count || (authority[close + 1] == 58 && formatPort(authority[(close + 2)...]))
    }
    if let colon = authority.lastIndex(of: 58) {
        guard formatPort(authority[(colon + 1)...]) else { return false }
        authority = Array(authority[..<colon])
    }
    guard !authority.isEmpty, !authority.contains(58) else { return false }
    if authority.contains(where: { $0 <= 0x20 || $0 == 35 || $0 == 47 || $0 == 63 || $0 == 64 || $0 == 91 || $0 == 92 || $0 == 93 || $0 == 127 }) { return false }
    if opaque { return true }
    guard let decoded = formatDecodedHost(authority) else { return false }
    return !formatEndsInNumber(decoded) || formatIPv4IsValid(decoded)
}

private func formatPort(_ units: ArraySlice<UInt16>) -> Bool {
    if units.isEmpty { return true }
    var value = 0
    for c in units {
        guard (48...57).contains(c) else { return false }
        value = min(65536, value * 10 + Int(c - 48))
    }
    return value <= 65535
}

private func formatDecodedHost(_ units: [UInt16]) -> String? {
    let source = String(decoding: units, as: UTF16.self)
    let input = Array(source.utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(input.count)
    var i = 0
    while i < input.count {
        if input[i] == 37 {
            guard i + 2 < input.count, let h = formatHexValue(input[i + 1]),
                  let l = formatHexValue(input[i + 2]) else { return nil }
            bytes.append(h * 16 + l)
            i += 3
        } else {
            bytes.append(input[i])
            i += 1
        }
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
    if decoded.utf8.contains(where: { byte in
        if byte <= 0x20 || byte == 0x7f { return true }
        switch byte {
        case 35, 37, 47, 58, 60, 62, 63, 64, 91, 92, 93, 94, 124: return true
        default: return false
        }
    }) {
        return nil
    }
    // U+2028..U+202E are disallowed in every UTS 46 mapping version.
    if decoded.unicodeScalars.contains(where: { (0x2028...0x202E).contains($0.value) }) { return nil }
    // U+0300..U+033F map to themselves. A label starting with one of these
    // marks fails the ToASCII leading-Mark validity rule even with CheckHyphens off.
    for label in decoded.unicodeScalars.split(whereSeparator: { [0x2E, 0xFF0E, 0x3002, 0xFF61].contains($0.value) }) {
        if let first = label.first, (0x0300...0x033F).contains(first.value),
           first.properties.generalCategory == .nonspacingMark { return nil }
        // CheckJoiners=true: ZWJ needs an immediately preceding Virama.
        // ASCII maps only to ASCII here, so an ASCII predecessor cannot qualify.
        var previous: Unicode.Scalar?
        for scalar in label {
            if scalar.value == 0x200D && (previous.map { $0.value < 128 } ?? true) { return nil }
            previous = scalar
        }
    }
    // WHATWG domain-to-ASCII sets IgnoreInvalidPunycode=false. A malformed
    // ACE label fails even without the UTS 46 mapping table.
    for label in decoded.unicodeScalars.split(whereSeparator: { [0x2E, 0xFF0E, 0x3002, 0xFF61].contains($0.value) }) {
        let text = String(String.UnicodeScalarView(label))
        // Bound the decoder's indexed insertions. Longer ACE labels remain in
        // the recorded UTS 46 difference class until the full parser lands.
        if IdnaPuny.isAcePrefixed(text), text.utf16.count <= 256,
           text.utf8.allSatisfy({ $0 < 128 }) {
            let lowercase = String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
            guard let body = IdnaPuny.decode(IdnaPuny.aceBody(lowercase)), !body.isEmpty else { return nil }
        }
    }
    return decoded
}

@inline(__always)
private func formatHexValue(_ byte: UInt8) -> UInt8? {
    if (48...57).contains(byte) { return byte - 48 }
    if (65...70).contains(byte) { return byte - 55 }
    if (97...102).contains(byte) { return byte - 87 }
    return nil
}

// WHATWG URL Standard §3.5: “ends in a number”, IPv4 parsing, and IPv4 number parsing.
private func formatEndsInNumber(_ host: String) -> Bool {
    var parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.last?.isEmpty == true && parts.count > 1 { parts.removeLast() }
    guard let last = parts.last, !last.isEmpty else { return false }
    if last.utf8.allSatisfy({ (48...57).contains($0) }) { return true }
    return formatIPv4Number(last) != nil
}

private func formatIPv4IsValid(_ host: String) -> Bool {
    var parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.last?.isEmpty == true && parts.count > 1 { parts.removeLast() }
    guard !parts.isEmpty, parts.count <= 4 else { return false }
    var numbers: [UInt64] = []
    for part in parts {
        guard let number = formatIPv4Number(part) else { return false }
        numbers.append(number)
    }
    for number in numbers.dropLast() where number > 255 { return false }
    let lastLimit: UInt64 = UInt64(1) << (8 * (5 - numbers.count))
    return numbers[numbers.count - 1] < lastLimit
}

private func formatIPv4Number(_ input: Substring) -> UInt64? {
    let bytes = Array(input.utf8)
    guard !bytes.isEmpty else { return nil }
    var radix: UInt64 = 10
    var start = 0
    if bytes.count >= 2 && bytes[0] == 48 && (bytes[1] == 120 || bytes[1] == 88) {
        radix = 16
        start = 2
    } else if bytes.count >= 2 && bytes[0] == 48 {
        radix = 8
        start = 1
    }
    if start == bytes.count { return 0 }
    var number: UInt64 = 0
    for byte in bytes[start...] {
        guard let digit = formatHexValue(byte), UInt64(digit) < radix else { return nil }
        let (product, overflow1) = number.multipliedReportingOverflow(by: radix)
        let (sum, overflow2) = product.addingReportingOverflow(UInt64(digit))
        guard !overflow1 && !overflow2 else { return nil }
        number = sum
    }
    return number
}
