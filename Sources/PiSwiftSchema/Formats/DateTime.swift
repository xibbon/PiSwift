// Port of packages/schema/src/formats/typebox/date_time.ts at pi-mono v1.5.2.
func isDateTime(_ value: String) -> Bool {
    // Upstream: value.split(/T/i). Split on ASCII T/t only.
    let u = Array(value.utf16)
    guard let index = u.firstIndex(where: { $0 == 84 || $0 == 116 }),
          !u[(index + 1)...].contains(where: { $0 == 84 || $0 == 116 }) else { return false }
    return isDate(String(decoding: u[..<index], as: UTF16.self))
        && isTime(String(decoding: u[(index + 1)...], as: UTF16.self))
}
