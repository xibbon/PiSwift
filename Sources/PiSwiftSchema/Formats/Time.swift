// Port of packages/schema/src/formats/typebox/time.ts at pi-mono v1.5.2.
func isTime(_ value: String, strictTimeZone: Bool = true) -> Bool {
    // Upstream: /^(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:([Zz])|([+-])(\d\d):(\d\d))?$/.
    let u = Array(value.utf16)
    guard u.count >= 8, u[2] == 58, u[5] == 58,
          let hr = formatAsciiDecimal(u[0..<2]),
          let min = formatAsciiDecimal(u[3..<5]),
          let sec = formatAsciiDecimal(u[6..<8]) else { return false }
    var i = 8
    if i < u.count && u[i] == 46 {
        i += 1
        let start = i
        while i < u.count && u[i] >= 48 && u[i] <= 57 { i += 1 }
        if i == start { return false }
    }
    var tzSign = 1
    var tzH = 0
    var tzM = 0
    var hasZone = false
    if i < u.count {
        hasZone = true
        if (u[i] == 90 || u[i] == 122) && i + 1 == u.count {
            i += 1
        } else {
            guard i + 6 == u.count, u[i] == 43 || u[i] == 45, u[i + 3] == 58,
                  let h = formatAsciiDecimal(u[(i + 1)..<(i + 3)]),
                  let m = formatAsciiDecimal(u[(i + 4)..<(i + 6)]) else { return false }
            tzSign = u[i] == 45 ? -1 : 1
            tzH = h
            tzM = m
            i += 6
        }
    }
    guard i == u.count, (!strictTimeZone || hasZone), hr <= 23, min <= 59, sec <= 60,
          tzH <= 23, tzM <= 59 else { return false }
    if sec < 60 { return true }
    let totalUtcMin = hr * 60 + min - tzSign * (tzH * 60 + tzM)
    return ((totalUtcMin % 1440) + 1440) % 1440 == 1439
}
