// Port of packages/schema/src/formats/typebox/date.ts at pi-mono v1.5.2.
private let formatDays = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

private func isLeapYear(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

func isDate(_ value: String) -> Bool {
    // Upstream: /^(\d\d\d\d)-(\d\d)-(\d\d)$/; ASCII UTF-16 parser.
    let u = Array(value.utf16)
    guard u.count == 10, u[4] == 45, u[7] == 45,
          let year = formatAsciiDecimal(u[0..<4]),
          let month = formatAsciiDecimal(u[5..<7]),
          let day = formatAsciiDecimal(u[8..<10]),
          (1...12).contains(month) else { return false }
    return day >= 1 && day <= (month == 2 && isLeapYear(year) ? 29 : formatDays[month])
}
