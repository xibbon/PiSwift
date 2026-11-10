// Port of packages/schema/src/formats/typebox/iri_reference.ts at pi-mono v1.5.2.
func isIriReference(_ value: String) -> Bool {
    // Upstream: /[\x00-\x20\x7F\\]|%(?![0-9a-fA-F]{2})/ and /^[a-zA-Z][a-zA-Z0-9+\-.]*\/\//.
    let u = Array(value.utf16)
    for (i, c) in u.enumerated() {
        if c <= 0x20 || c == 0x7F || c == 92 { return false }
        if c == 37 && (i + 2 >= u.count || !formatHex(u[i + 1]) || !formatHex(u[i + 2])) { return false }
    }
    if let malformedEnd = formatSchemePrefixEnd(u), malformedEnd + 1 < u.count,
       u[malformedEnd] == 47, u[malformedEnd + 1] == 47 { return false }
    return formatCanParseURL(value, base: true)
}
