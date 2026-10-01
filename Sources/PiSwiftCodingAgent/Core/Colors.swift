import Foundation

public enum ColorError: LocalizedError, Sendable, Equatable {
    case invalidColorValue(String)
    case invalidIndex(Double)
    case nonFinite(String)
    case outOfRange(String, Double)
    case negativeChroma(Double)

    public var errorDescription: String? {
        switch self {
        case .invalidColorValue(let value):
            "Invalid color value: \(value)"
        case .invalidIndex(let value):
            "ANSI color index must be an integer from 0 to 255: \(value)"
        case .nonFinite(let name):
            "\(name) must be finite"
        case .outOfRange(let name, let value):
            "\(name) must be between 0 and \(["r", "g", "b"].contains(name) ? 255 : 1): \(value)"
        case .negativeChroma(let value):
            "c must not be negative: \(value)"
        }
    }
}

public struct IndexedColor: Sendable, Equatable {
    public let index: Int
}

public struct RgbColorValue: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct OklchChannels: Sendable, Equatable {
    public let l: Double
    public let c: Double
    public let h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

public struct OklchColorValue: Sendable, Equatable {
    public let l: Double
    public let c: Double
    public let h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

public struct OkhslChannels: Sendable, Equatable {
    public let h: Double
    public let s: Double
    public let l: Double

    public init(h: Double, s: Double, l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }
}

/// A concrete color. Each case can be converted to sRGB.
public enum Color: Sendable, Equatable {
    case indexed(IndexedColor)
    case rgb(RgbColorValue)
    case oklch(OklchColorValue)
}

public enum TerminalColorMode: String, Sendable {
    case color256 = "256color"
    case truecolor
}

public enum ColorMixSpace: String, Sendable {
    case oklch
    case srgb
}

public struct TextAttributes: Sendable, Equatable {
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var inverse: Bool
    public var strikethrough: Bool

    public init(
        bold: Bool = false, dim: Bool = false, italic: Bool = false,
        underline: Bool = false, inverse: Bool = false, strikethrough: Bool = false
    ) {
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strikethrough = strikethrough
    }
}

public struct TextStyle: Sendable, Equatable {
    public var fg: Color?
    public var bg: Color?
    public var attributes: TextAttributes

    public var bold: Bool { get { attributes.bold } set { attributes.bold = newValue } }
    public var dim: Bool { get { attributes.dim } set { attributes.dim = newValue } }
    public var italic: Bool { get { attributes.italic } set { attributes.italic = newValue } }
    public var underline: Bool { get { attributes.underline } set { attributes.underline = newValue } }
    public var inverse: Bool { get { attributes.inverse } set { attributes.inverse = newValue } }
    public var strikethrough: Bool { get { attributes.strikethrough } set { attributes.strikethrough = newValue } }

    public init(fg: Color? = nil, bg: Color? = nil, attributes: TextAttributes = TextAttributes()) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }

    public init(fg: Color? = nil, bg: Color? = nil,
                bold: Bool = false, dim: Bool = false, italic: Bool = false,
                underline: Bool = false, inverse: Bool = false, strikethrough: Bool = false) {
        self.init(fg: fg, bg: bg, attributes: TextAttributes(
            bold: bold, dim: dim, italic: italic, underline: underline,
            inverse: inverse, strikethrough: strikethrough))
    }
}

private func requireFinite(_ value: Double, _ name: String) throws {
    guard value.isFinite else { throw ColorError.nonFinite(name) }
}

public func indexedColor(_ index: Double) throws -> Color {
    guard index.isFinite, index.rounded(.towardZero) == index, (0...255).contains(index) else {
        throw ColorError.invalidIndex(index)
    }
    return .indexed(IndexedColor(index: Int(index)))
}

public func indexedColor(_ index: Int) throws -> Color { try indexedColor(Double(index)) }

public func rgbColor(_ r: Double, _ g: Double, _ b: Double) throws -> Color {
    for (name, value) in [("r", r), ("g", g), ("b", b)] {
        try requireFinite(value, name)
        guard (0...255).contains(value) else { throw ColorError.outOfRange(name, value) }
    }
    return .rgb(RgbColorValue(r: r, g: g, b: b))
}

private func normalizedHue(_ h: Double) -> Double {
    (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
}

public func oklchColor(_ l: Double, _ c: Double, _ h: Double) throws -> Color {
    try requireFinite(l, "l")
    try requireFinite(c, "c")
    try requireFinite(h, "h")
    guard (0...1).contains(l) else { throw ColorError.outOfRange("l", l) }
    guard c >= 0 else { throw ColorError.negativeChroma(c) }
    return .oklch(OklchColorValue(l: l, c: c, h: normalizedHue(h)))
}

public func okhslColor(_ h: Double, _ s: Double, _ l: Double) throws -> Color {
    try requireFinite(h, "h")
    try requireFinite(s, "s")
    try requireFinite(l, "l")
    guard (0...1).contains(s) else { throw ColorError.outOfRange("s", s) }
    guard (0...1).contains(l) else { throw ColorError.outOfRange("l", l) }
    let rgb = OklabMath.okhslToRgb(hue: h, saturation: s, lightness: l)
    return .rgb(RgbColorValue(r: rgb.r, g: rgb.g, b: rgb.b))
}

private let colorNumberPattern = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?"#
private func captures(_ pattern: String, _ value: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
          match.range == NSRange(value.startIndex..<value.endIndex, in: value) else { return nil }
    return (0..<match.numberOfRanges).map { number in
        guard let range = Range(match.range(at: number), in: value) else { return nil }
        return String(value[range])
    }
}

public func parseColor(_ value: Int) throws -> Color { try indexedColor(value) }
public func parseColor(_ value: Double) throws -> Color { try indexedColor(value) }

public func parseColor(_ value: String) throws -> Color {
    if let match = captures(#"^#([\da-f]{3}|[\da-f]{6})$"#, value), let raw = match[1] {
        let digits = raw.count == 3 ? raw.map { "\($0)\($0)" }.joined() : raw
        let r = Int(digits.prefix(2), radix: 16)!
        let g = Int(digits.dropFirst(2).prefix(2), radix: 16)!
        let b = Int(digits.dropFirst(4).prefix(2), radix: 16)!
        return try rgbColor(Double(r), Double(g), Double(b))
    }
    let number = colorNumberPattern
    if let match = captures("^oklch\\(\\s*(\(number))(%)?\\s+(\(number))\\s+(\(number))(?:deg)?\\s*\\)$", value),
       let l = match[1].flatMap(Double.init), let c = match[3].flatMap(Double.init), let h = match[4].flatMap(Double.init) {
        return try oklchColor(l / (match[2] == nil ? 1 : 100), c, h)
    }
    if let match = captures("^okhsl\\(\\s*(\(number))(?:deg)?\\s+(\(number))(%)?\\s+(\(number))(%)?\\s*\\)$", value),
       let h = match[1].flatMap(Double.init), let s = match[2].flatMap(Double.init), let l = match[4].flatMap(Double.init) {
        return try okhslColor(h, s / (match[3] == nil ? 1 : 100), l / (match[5] == nil ? 1 : 100))
    }
    throw ColorError.invalidColorValue(value)
}

private let basicColors: [RgbColorValue] = [
    .init(r: 0, g: 0, b: 0), .init(r: 128, g: 0, b: 0),
    .init(r: 0, g: 128, b: 0), .init(r: 128, g: 128, b: 0),
    .init(r: 0, g: 0, b: 128), .init(r: 128, g: 0, b: 128),
    .init(r: 0, g: 128, b: 128), .init(r: 192, g: 192, b: 192),
    .init(r: 128, g: 128, b: 128), .init(r: 255, g: 0, b: 0),
    .init(r: 0, g: 255, b: 0), .init(r: 255, g: 255, b: 0),
    .init(r: 0, g: 0, b: 255), .init(r: 255, g: 0, b: 255),
    .init(r: 0, g: 255, b: 255), .init(r: 255, g: 255, b: 255),
]
private let cubeValues: [Double] = [0, 95, 135, 175, 215, 255]
private let grayValues: [Double] = (0..<24).map { Double(8 + 10 * $0) }

private func indexedToRgb(_ index: Int) -> RgbColorValue {
    if index < 16 { return basicColors[index] }
    if index < 232 {
        let cube = index - 16
        return .init(r: cubeValues[cube / 36], g: cubeValues[(cube % 36) / 6], b: cubeValues[cube % 6])
    }
    let gray = Double(8 + (index - 232) * 10)
    return .init(r: gray, g: gray, b: gray)
}

private func isInSrgbGamut(_ linear: [Double]) -> Bool {
    linear.allSatisfy { $0 >= -1e-7 && $0 <= 1 + 1e-7 }
}

private func oklchToRgb(_ color: OklchColorValue) -> RgbColorValue {
    let angle = color.h * .pi / 180
    let a = cos(angle)
    let b = sin(angle)
    func atChroma(_ c: Double) -> [Double] { OklabMath.oklabToLinearSrgb([color.l, c * a, c * b]) }
    let direct = atChroma(color.c)
    if isInSrgbGamut(direct) {
        let rgb = OklabMath.linearSrgbToRgb(direct)
        return .init(r: rgb.r, g: rgb.g, b: rgb.b)
    }
    var linear = atChroma(0)
    var low = 0.0
    var high = color.c
    for _ in 0..<20 {
        let chroma = (low + high) / 2
        let candidate = atChroma(chroma)
        if isInSrgbGamut(candidate) {
            low = chroma
            linear = candidate
        } else {
            high = chroma
        }
    }
    let rgb = OklabMath.linearSrgbToRgb(linear)
    return .init(r: rgb.r, g: rgb.g, b: rgb.b)
}

public func colorToRgb(_ color: Color) -> RgbColorValue {
    switch color {
    case .indexed(let value): indexedToRgb(value.index)
    case .rgb(let value): value
    case .oklch(let value): oklchToRgb(value)
    }
}

public func colorToOklch(_ color: Color) -> OklchChannels {
    if case .oklch(let value) = color { return .init(l: value.l, c: value.c, h: value.h) }
    let rgb = colorToRgb(color)
    let lab = OklabMath.rgbToOklab(.init(r: rgb.r, g: rgb.g, b: rgb.b))
    return .init(l: lab[0], c: hypot(lab[1], lab[2]), h: normalizedHue(atan2(lab[2], lab[1]) * 180 / .pi))
}

public func colorToOkhsl(_ color: Color) -> OkhslChannels {
    let rgb = colorToRgb(color)
    let channels = OklabMath.rgbToOkhsl(.init(r: rgb.r, g: rgb.g, b: rgb.b))
    return .init(h: channels.h, s: channels.s, l: channels.l)
}

public func colorToHex(_ color: Color) -> String {
    let rgb = colorToRgb(color)
    func channel(_ value: Double) -> String { String(format: "%02x", Int(floor(value + 0.5))) }
    return "#\(channel(rgb.r))\(channel(rgb.g))\(channel(rgb.b))"
}

public func mixColors(_ first: Color, _ second: Color, amount: Double, space: ColorMixSpace = .oklch) throws -> Color {
    try requireFinite(amount, "amount")
    guard (0...1).contains(amount) else { throw ColorError.outOfRange("amount", amount) }
    switch space {
    case .srgb:
        let a = colorToRgb(first)
        let b = colorToRgb(second)
        return try rgbColor(a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
    case .oklch:
        let a = colorToOklch(first)
        let b = colorToOklch(second)
        let firstHue = a.c < 1e-7 ? b.h : a.h
        let secondHue = b.c < 1e-7 ? firstHue : b.h
        let hueDelta = (secondHue - firstHue + 540).truncatingRemainder(dividingBy: 360) - 180
        return try oklchColor(a.l + (b.l - a.l) * amount, a.c + (b.c - a.c) * amount, firstHue + hueDelta * amount)
    }
}

private func closestIndex(_ values: [Double], _ target: Double) -> Int {
    var result = 0
    var distance = Double.infinity
    for index in values.indices {
        let candidate = abs(target - values[index])
        if candidate < distance { result = index; distance = candidate }
    }
    return result
}

private func colorDistance(_ first: RgbColorValue, _ second: RgbColorValue) -> Double {
    pow(first.r - second.r, 2) * 0.299 + pow(first.g - second.g, 2) * 0.587 + pow(first.b - second.b, 2) * 0.114
}

public func rgbToAnsi256(_ color: RgbColorValue) -> Int {
    let r = closestIndex(cubeValues, color.r)
    let g = closestIndex(cubeValues, color.g)
    let b = closestIndex(cubeValues, color.b)
    let cube = RgbColorValue(r: cubeValues[r], g: cubeValues[g], b: cubeValues[b])
    let cubeIndex = 16 + 36 * r + 6 * g + b
    let gray = floor(0.299 * color.r + 0.587 * color.g + 0.114 * color.b + 0.5)
    let grayIndex = closestIndex(grayValues, gray)
    let grayValue = grayValues[grayIndex]
    let spread = max(color.r, color.g, color.b) - min(color.r, color.g, color.b)
    if spread < 10 && colorDistance(color, .init(r: grayValue, g: grayValue, b: grayValue)) < colorDistance(color, cube) {
        return 232 + grayIndex
    }
    return cubeIndex
}

private func colorAnsi(_ color: Color, _ mode: TerminalColorMode, background: Bool) -> String {
    let code = background ? 48 : 38
    if case .indexed(let value) = color { return "\u{001B}[\(code);5;\(value.index)m" }
    let rgb = colorToRgb(color)
    if mode == .truecolor {
        return "\u{001B}[\(code);2;\(Int(floor(rgb.r + 0.5)));\(Int(floor(rgb.g + 0.5)));\(Int(floor(rgb.b + 0.5)))m"
    }
    return "\u{001B}[\(code);5;\(rgbToAnsi256(rgb))m"
}

public func foregroundAnsi(_ color: Color, _ mode: TerminalColorMode) -> String { colorAnsi(color, mode, background: false) }
public func backgroundAnsi(_ color: Color, _ mode: TerminalColorMode) -> String { colorAnsi(color, mode, background: true) }

public func styleText(_ text: String, options: TextStyle, mode: TerminalColorMode) -> String {
    styleTextWithAnsi(text, fgAnsi: options.fg.map { foregroundAnsi($0, mode) },
                      bgAnsi: options.bg.map { backgroundAnsi($0, mode) }, options: options.attributes)
}

public func styleTextWithAnsi(_ text: String, fgAnsi: String?, bgAnsi: String?, options: TextAttributes) -> String {
    var prefix = ""
    var suffix = ""
    if let fgAnsi, !fgAnsi.isEmpty { prefix += fgAnsi; suffix = "\u{001B}[39m" }
    if let bgAnsi, !bgAnsi.isEmpty { prefix += bgAnsi; suffix = "\u{001B}[49m" + suffix }
    if options.bold { prefix += "\u{001B}[1m" }
    if options.dim { prefix += "\u{001B}[2m" }
    if options.bold || options.dim { suffix = "\u{001B}[22m" + suffix }
    if options.italic { prefix += "\u{001B}[3m"; suffix = "\u{001B}[23m" + suffix }
    if options.underline { prefix += "\u{001B}[4m"; suffix = "\u{001B}[24m" + suffix }
    if options.inverse { prefix += "\u{001B}[7m"; suffix = "\u{001B}[27m" + suffix }
    if options.strikethrough { prefix += "\u{001B}[9m"; suffix = "\u{001B}[29m" + suffix }
    return prefix + text + suffix
}
