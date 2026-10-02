import Foundation

// Port of pi-mono v1.0.0 system-theme.ts. Curves and solve order match upstream.
let systemThemeName = "system"
enum SystemThemeColor: Sendable, Equatable { case string(String), number(Int) }
struct SystemThemeInput: Sendable {
    var foreground: RgbColorValue? = nil
    var background: RgbColorValue? = nil
    var palette: [RgbColorValue]? = nil
    var saturation: Double? = nil
    var appearanceHint: ThemeAppearance? = nil
}
struct SystemThemeColors: Sendable {
    var colors: [String: SystemThemeColor]
    var dim: [String]
    var appearance: ThemeAppearance?
}
private struct SystemFamily: Sendable { let hue: Double; let min: Double; let max: Double; let slot: Int }
private let systemFamilies: [String: SystemFamily] = [
    "neutral": .init(hue: 231.49, min: 0.02, max: 0.08, slot: 8),
    "blue": .init(hue: 231.49, min: 0.1, max: 0.68, slot: 4),
    "green": .init(hue: 158.68, min: 0.1, max: 0.76, slot: 2),
    "red": .init(hue: 20, min: 0.1, max: 0.92, slot: 1),
    "yellow": .init(hue: 82.36, min: 0.5, max: 1, slot: 3),
    "orange": .init(hue: 52, min: 0.12, max: 0.85, slot: 3),
    "violet": .init(hue: 295, min: 0.2, max: 0.6, slot: 5),
    "calamine": .init(hue: 202.43, min: 0.1, max: 0.74, slot: 6),
    "thinkingSlate": .init(hue: 231.49, min: 0.08, max: 0.2, slot: 4),
    "thinkingBlue": .init(hue: 231.49, min: 0.2, max: 0.45, slot: 4),
    "thinkingPeriwinkle": .init(hue: 263.25, min: 0.3, max: 0.6, slot: 6),
    "thinkingViolet": .init(hue: 295, min: 0.4, max: 0.75, slot: 5),
    "thinkingMagenta": .init(hue: 337.5, min: 0.5, max: 0.85, slot: 13),
    "thinkingRed": .init(hue: 20, min: 0.95, max: 1, slot: 1),
]
private let systemTokenFamilies: [(String, String)] = [
    ("selectedBg", "blue"),
    ("searchMatchBg", "orange"),
    ("userMessageBg", "blue"),
    ("customMessageBg", "violet"),
    ("toolPendingBg", "neutral"),
    ("toolSuccessBg", "green"),
    ("toolErrorBg", "red"),
    ("text", "neutral"),
    ("userMessageText", "neutral"),
    ("customMessageText", "neutral"),
    ("toolTitle", "neutral"),
    ("syntaxOperator", "neutral"),
    ("syntaxPunctuation", "neutral"),
    ("muted", "neutral"),
    ("dim", "neutral"),
    ("thinkingText", "neutral"),
    ("toolOutput", "neutral"),
    ("mdLinkUrl", "neutral"),
    ("mdQuote", "neutral"),
    ("mdQuoteBorder", "neutral"),
    ("mdHr", "neutral"),
    ("mdCodeBlockBorder", "neutral"),
    ("toolDiffContext", "neutral"),
    ("syntaxComment", "neutral"),
    ("scrollbarTrack", "neutral"),
    ("scrollbarThumb", "neutral"),
    ("searchMatchText", "neutral"),
    ("borderMuted", "neutral"),
    ("accent", "violet"),
    ("borderAccent", "violet"),
    ("customMessageLabel", "violet"),
    ("mdCode", "violet"),
    ("mdListBullet", "violet"),
    ("syntaxType", "violet"),
    ("border", "blue"),
    ("mdLink", "blue"),
    ("syntaxKeyword", "blue"),
    ("syntaxVariable", "calamine"),
    ("success", "green"),
    ("mdCodeBlock", "green"),
    ("toolDiffAdded", "green"),
    ("bashMode", "green"),
    ("syntaxNumber", "green"),
    ("error", "red"),
    ("toolDiffRemoved", "red"),
    ("warning", "yellow"),
    ("mdHeading", "yellow"),
    ("syntaxFunction", "yellow"),
    ("syntaxString", "orange"),
    ("thinkingOff", "neutral"),
    ("thinkingMinimal", "thinkingSlate"),
    ("thinkingLow", "thinkingBlue"),
    ("thinkingMedium", "thinkingPeriwinkle"),
    ("thinkingHigh", "thinkingViolet"),
    ("thinkingXhigh", "thinkingMagenta"),
    ("thinkingMax", "thinkingRed"),
]
private let systemSlots = ["syntaxString": 2, "syntaxNumber": 5, "searchMatchBg": 3]
private struct SystemCurve: Sendable { let coefficients: [Double]; let reachable: [Double] }
private let systemLevels: [String: [ThemeAppearance: SystemCurve]] = [
    "panel": [
        .dark: .init(coefficients: [0.29131, -0.39746, 2.33185, -0.85524, -1.2076, 0.86276], reachable: [0, 0.979]),
        .light: .init(coefficients: [-3.74073, 27.94549, -78.44258, 112.6798, -79.60015, 22.11277], reachable: [0.348, 1]),
    ],
    "track": [
        .dark: .init(coefficients: [0.39028, -0.23015, 0.83573, 2.43829, -4.38292, 2.01582], reachable: [0, 0.946]),
        .light: .init(coefficients: [-5.24921, 38.37322, -107.28833, 152.10005, -106.17127, 29.18061], reachable: [0.368, 1]),
    ],
    "thinking0": [
        .dark: .init(coefficients: [0.52988, -0.05809, -0.30924, 4.63567, -6.52933, 2.89108], reachable: [0, 0.873]),
        .light: .init(coefficients: [-28.27749, 182.85284, -469.62416, 603.15916, -384.59976, 97.35147], reachable: [0.51, 1]),
    ],
    "thinking1": [
        .dark: .init(coefficients: [0.55278, -0.03667, -0.45659, 4.95347, -6.90265, 3.0706], reachable: [0, 0.858]),
        .light: .init(coefficients: [-37.10484, 235.86282, -596.62344, 754.3633, -474.00763, 118.3551], reachable: [0.535, 1]),
    ],
    "thinking2": [
        .dark: .init(coefficients: [0.57486, -0.01765, -0.58987, 5.25227, -7.27175, 3.25532], reachable: [0, 0.842]),
        .light: .init(coefficients: [-59.89653, 377.05024, -945.07843, 1182.03145, -734.96375, 181.68658], reachable: [0.556, 1]),
    ],
    "thinking3": [
        .dark: .init(coefficients: [0.59621, -0.00062, -0.71148, 5.53588, -7.6392, 3.44606], reachable: [0, 0.827]),
        .light: .init(coefficients: [-72.07122, 445.84082, -1099.57352, 1353.88793, -829.53392, 202.26164], reachable: [0.58, 1]),
    ],
    "thinking4": [
        .dark: .init(coefficients: [0.61691, 0.01462, -0.82288, 5.80651, -8.00641, 3.64333], reachable: [0, 0.811]),
        .light: .init(coefficients: [-110.14338, 674.21488, -1645.75941, 2004.32367, -1215.15899, 293.3183], reachable: [0.6, 1]),
    ],
    "thinking5": [
        .dark: .init(coefficients: [0.63702, 0.02826, -0.92498, 6.06465, -8.37246, 3.84651], reachable: [0, 0.795]),
        .light: .init(coefficients: [-175.47701, 1063.54495, -2570.70594, 3098.80776, -1860.15527, 444.76392], reachable: [0.62, 1]),
    ],
    "thinking6": [
        .dark: .init(coefficients: [0.65658, 0.04044, -1.01835, 6.30989, -8.73529, 4.05439], reachable: [0, 0.779]),
        .light: .init(coefficients: [-183.81712, 1094.70055, -2602.68539, 3088.71276, -1826.91131, 430.75931], reachable: [0.643, 1]),
    ],
    "subtle": [
        .dark: .init(coefficients: [0.56762, -0.02475, -0.5383, 5.12628, -7.10931, 3.17324], reachable: [0, 0.848]),
        .light: .init(coefficients: [-232.85459, 1376.54473, -3249.11801, 3827.91186, -2248.29472, 526.55751], reachable: [0.657, 1]),
    ],
    "thumb": [
        .dark: .init(coefficients: [0.60323, 0.00278, -0.73328, 5.57157, -7.68067, 3.46933], reachable: [0, 0.823]),
        .light: .init(coefficients: [-82.89897, 511.01355, -1255.98095, 1540.76821, -940.68087, 228.58523], reachable: [0.586, 1]),
    ],
    "readable": [
        .dark: .init(coefficients: [0.66937, 0.04704, -1.06871, 6.43941, -8.9332, 4.17229], reachable: [0, 0.77]),
        .light: .init(coefficients: [-1554.52576, 8733.56817, -19604.93507, 21977.72696, -12300.99599, 2749.81288], reachable: [0.751, 1]),
    ],
    "emphasis": [
        .dark: .init(coefficients: [0.7303, 0.07695, -1.31626, 7.1681, -10.14436, 4.92846], reachable: [0, 0.712]),
        .light: .init(coefficients: [-4948.31942, 26870.91986, -58334.48399, 63280.17197, -34298.01053, 7430.30146], reachable: [0.811, 1]),
    ],
    "textOnPanel": [
        .dark: .init(coefficients: [0.86713, 0.05232, -0.89428, 4.79014, -5.5432, 1.75023], reachable: [0, 0.542]),
        .light: .init(coefficients: [-8570.89457, 43954.60805, -90084.00702, 92220.6791, -47152.15802, 9632.27113], reachable: [0.867, 1]),
    ],
    "text": [
        .dark: .init(coefficients: [0.89242, 0.02311, -0.44862, 2.34417, -0.06084, -2.63844], reachable: [0, 0.5]),
        .light: .init(coefficients: [-2004.67048, 6664.47299, -6060.70202, -1792.61209, 5133.82359, -1939.85583], reachable: [0.894, 1]),
    ],
]
private let systemToolPanels = ["toolPendingBg", "toolSuccessBg", "toolErrorBg"]
private let systemMessagePanels = ["userMessageBg", "customMessageBg"]
private let systemPanels = ["userMessageBg", "toolPendingBg", "toolSuccessBg", "toolErrorBg", "selectedBg", "searchMatchBg", "customMessageBg"]
private let systemForeground = ["text", "userMessageText", "toolTitle"]
private struct SystemRule: Sendable { let token: String; let on: [String]; let level: String }
private let systemRules: [SystemRule] = {
    var rules: [SystemRule] = []
    func each(_ tokens: [String], _ surfaces: [String], _ level: String) {
        rules += tokens.map { .init(token: $0, on: surfaces, level: level) }
    }
    each(systemPanels, ["background"], "panel")
    each(["text"], ["background"], "text")
    each(["text"], ["selectedBg"], "textOnPanel")
    each(["userMessageText"], ["userMessageBg"], "textOnPanel")
    each(["toolTitle"], systemToolPanels, "textOnPanel")
    each(["accent", "success", "error", "warning"], ["background", "selectedBg"] + systemToolPanels, "readable")
    each(["muted"], ["background", "selectedBg", "customMessageBg"] + systemToolPanels, "readable")
    each(["dim"], ["background", "selectedBg", "customMessageBg"] + systemToolPanels, "subtle")
    each(["thinkingText"], ["background"], "readable")
    each(["customMessageText"], ["customMessageBg"] + systemToolPanels, "readable")
    each(["customMessageLabel"], ["background", "customMessageBg", "selectedBg"] + systemToolPanels, "readable")
    each(["toolOutput"], ["background"] + systemToolPanels, "readable")
    each(["mdHeading", "mdLink", "mdLinkUrl", "mdCode", "mdQuote", "mdCodeBlockBorder", "mdListBullet"], ["background"] + systemMessagePanels, "readable")
    each(["mdCodeBlock"], ["background"] + systemMessagePanels + systemToolPanels, "readable")
    each(["toolDiffAdded", "toolDiffRemoved", "toolDiffContext"], ["background"] + systemToolPanels, "readable")
    each(["syntaxComment", "syntaxKeyword", "syntaxFunction", "syntaxVariable", "syntaxString", "syntaxNumber", "syntaxType", "syntaxOperator", "syntaxPunctuation"], ["background"] + systemMessagePanels + systemToolPanels, "readable")
    each(["searchMatchText"], ["searchMatchBg"], "readable")
    each(["bashMode", "border", "borderAccent"], ["background"], "readable")
    each(["borderMuted"], ["background"], "subtle")
    each(["mdQuoteBorder", "mdHr"], ["background"] + systemMessagePanels + systemToolPanels, "readable")
    each(["scrollbarTrack"], ["background"], "track")
    each(["scrollbarThumb"], ["scrollbarTrack"], "thumb")
    for (index, token) in ["thinkingOff", "thinkingMinimal", "thinkingLow", "thinkingMedium", "thinkingHigh", "thinkingXhigh", "thinkingMax"].enumerated() {
        each([token], ["background"], "thinking\(index)")
    }
    return rules
}()
private let systemSolveOrder: [String] = {
    var order: [String] = []
    func visit(_ token: String) {
        if order.contains(token) { return }
        for rule in systemRules where rule.token == token {
            for surface in rule.on where surface != "background" { visit(surface) }
        }
        order.append(token)
    }
    for rule in systemRules { visit(rule.token) }
    return order
}()
private func systemLabLightness(_ color: RgbColorValue) -> Double { colorToOklch(.rgb(color)).l }
public func relativeLuminance(_ color: RgbColorValue) -> Double {
    func linear(_ channel: Double) -> Double {
        let value = channel / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
}
public func wcagContrast(_ first: RgbColorValue, _ second: RgbColorValue) -> Double {
    let a = relativeLuminance(first), b = relativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}
public func terminalAppearance(_ background: RgbColorValue, foreground: RgbColorValue? = nil) -> ThemeAppearance {
    let white = RgbColorValue(r: 255, g: 255, b: 255), black = RgbColorValue(r: 0, g: 0, b: 0)
    let whiteContrast = wcagContrast(white, background), blackContrast = wcagContrast(black, background)
    if let foreground {
        let foregroundL = systemLabLightness(foreground), backgroundL = systemLabLightness(background)
        if abs(foregroundL - backgroundL) > 0.05 {
            let appearance: ThemeAppearance = foregroundL > backgroundL ? .dark : .light
            if (appearance == .dark ? whiteContrast : blackContrast) >= 4.5 { return appearance }
        }
    }
    return whiteContrast >= blackContrast ? .dark : .light
}
private func systemBell(_ l: Double) -> Double {
    func gaussian(_ x: Double) -> Double { exp(-pow(x - 0.5, 2) / (2 * pow(0.25, 2))) }
    return (gaussian(l) - gaussian(0)) / (1 - gaussian(0))
}
private func systemSaturationCurve(_ family: SystemFamily, _ l: Double) -> Double {
    let floor = family.max > 0 ? family.min / family.max : 1
    return floor + (1 - floor) * systemBell(l)
}
private func systemLevelTarget(_ level: String, _ appearance: ThemeAppearance, _ surfaceL: Double) -> Double? {
    let curve = systemLevels[level]![appearance]!
    guard surfaceL >= curve.reachable[0], surfaceL <= curve.reachable[1] else { return nil }
    return curve.coefficients.enumerated().reduce(0) { $0 + $1.element * pow(surfaceL, Double($1.offset)) }
}
private func systemPaint(_ h: Double, _ s: Double, _ l: Double) -> RgbColorValue {
    // The recipe bounds saturation and lightness before this call.
    colorToRgb(try! okhslColor(h, s, l))
}
private struct SystemSourceColor: Sendable {
    let channels: OkhslChannels
    let chroma: Double
    var h: Double { channels.h }
    var s: Double { channels.s }
    var l: Double { channels.l }
}
private func systemSource(_ color: RgbColorValue) -> SystemSourceColor {
    .init(channels: colorToOkhsl(.rgb(color)), chroma: colorToOklch(.rgb(color)).c)
}
private func systemAnchored(_ source: SystemSourceColor, _ family: SystemFamily, _ l: Double, _ saturation: Double) -> RgbColorValue {
    let anchor = systemSaturationCurve(family, source.l)
    let falloff = anchor > 0 ? min(1, systemSaturationCurve(family, l) / anchor) : 1
    let color = systemPaint(source.h, source.s * falloff * saturation, l)
    let cap = source.chroma * falloff * saturation
    let channels = colorToOklch(.rgb(color))
    return channels.c <= cap ? color : colorToRgb(try! oklchColor(channels.l, cap, source.h))
}
private func systemTextContrast(_ color: RgbColorValue, _ surfaces: [RgbColorValue], _ lighter: Bool) -> RgbColorValue {
    func meets(_ candidate: RgbColorValue) -> Bool { surfaces.allSatisfy { wcagContrast(candidate, $0) >= 4.5 } }
    if meets(color) { return color }
    let source = colorToOkhsl(.rgb(color))
    func at(_ l: Double) -> RgbColorValue { systemPaint(source.h, source.s, l) }
    let extreme = lighter ? 1.0 : 0.0
    if !meets(at(extreme)) { return at(extreme) }
    var low = source.l, high = extreme
    for _ in 0..<20 {
        let middle = (low + high) / 2
        if meets(at(middle)) { high = middle } else { low = middle }
    }
    return at(high)
}
func generateSystemThemeColors(_ input: SystemThemeInput) -> SystemThemeColors {
    let saturation = min(1, max(0, input.saturation ?? 1))
    guard let background = input.background else {
        var colors: [String: SystemThemeColor] = [:], dim: [String] = []
        for (token, name) in systemTokenFamilies {
            if systemPanels.contains(token) { colors[token] = .string(""); continue }
            let neutral = name == "neutral"
            colors[token] = !neutral && saturation > 0 ? .number(systemSlots[token] ?? systemFamilies[name]!.slot) : .string("")
            if neutral && !systemForeground.contains(token) { dim.append(token) }
        }
        return .init(colors: colors, dim: dim, appearance: input.appearanceHint)
    }
    let palette = input.palette?.count == 16 ? input.palette!.map(systemSource) : nil
    let appearance = terminalAppearance(background, foreground: input.foreground)
    let lighter = appearance == .dark, extreme = appearance == .dark ? 1.0 : 0.0
    let backgroundL = systemLabLightness(background)
    func paint(_ token: String, _ labL: Double) -> RgbColorValue {
        let l = oklabToOkhslLightness(labL)
        let name = systemTokenFamilies.first { $0.0 == token }!.1
        let family = systemFamilies[name]!
        if let palette { return systemAnchored(palette[systemSlots[token] ?? family.slot], family, l, saturation) }
        return systemPaint(family.hue, (family.min + (family.max - family.min) * systemBell(l)) * saturation, l)
    }
    func target(_ level: String, _ surfaceL: Double, _ t: Double) -> Double? {
        let reached = systemLevelTarget(level, appearance, surfaceL)
        if reached == nil && t == 0 { return nil }
        let distance = (reached ?? extreme) - surfaceL
        let floor = (systemLevelTarget(lighter ? "readable" : "subtle", appearance, surfaceL) ?? extreme) - surfaceL
        let compressed = abs(distance) > abs(floor) ? distance - (distance - floor) * min(t, 1) : distance
        return surfaceL + compressed * (1 - max(0, t - 1))
    }
    let extremeText = RgbColorValue(r: extreme * 255, g: extreme * 255, b: extreme * 255)
    func readable(_ color: RgbColorValue) -> Bool { wcagContrast(extremeText, color) >= 4.5 }
    func limitPanel(_ token: String, _ l: Double) -> RgbColorValue {
        let color = paint(token, l)
        if readable(color) { return color }
        var low = backgroundL, high = l
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if readable(paint(token, middle)) { low = middle } else { high = middle }
        }
        return paint(token, low)
    }
    func solve(_ t: Double) -> [String: RgbColorValue]? {
        var colors = ["background": background]
        for token in systemSolveOrder {
            var targets: [Double] = []
            for rule in systemRules where rule.token == token {
                for surface in rule.on {
                    guard let value = target(rule.level, systemLabLightness(colors[surface] ?? background), t), value >= 0, value <= 1 else { return nil }
                    targets.append(value)
                }
            }
            let l = lighter ? targets.max()! : targets.min()!
            colors[token] = systemPanels.contains(token) ? limitPanel(token, l) : paint(token, l)
        }
        return colors
    }
    var relaxation = 0.0, colors = solve(0)
    if colors == nil {
        var low = 0.0, high = 2.0
        colors = solve(high)
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if let attempt = solve(middle) { high = middle; colors = attempt } else { low = middle }
        }
        relaxation = high
    }
    let solved = colors ?? [:]
    func surfacesOf(_ token: String) -> [RgbColorValue] {
        systemRules.filter { $0.token == token }.flatMap { $0.on.map { solved[$0] ?? background } }
    }
    var result: [String: SystemThemeColor] = [:]
    for (token, _) in systemTokenFamilies { result[token] = .string(solved[token].map { colorToHex(.rgb($0)) } ?? "") }
    for token in systemForeground {
        let surfaces = surfacesOf(token)
        var text = solved[token]
        if let foreground = input.foreground {
            let targets = surfaces.map { target("emphasis", systemLabLightness($0), relaxation) }
            if targets.allSatisfy({ $0 != nil && $0! >= 0 && $0! <= 1 }) {
                let needed = lighter ? targets.map { $0! }.max()! : targets.map { $0! }.min()!
                let foregroundL = systemLabLightness(foreground)
                if lighter ? foregroundL >= needed : foregroundL <= needed { result[token] = .string(""); continue }
                text = systemAnchored(systemSource(foreground), systemFamilies["neutral"]!, oklabToOkhslLightness(needed), saturation)
            }
        }
        if let text { result[token] = .string(colorToHex(.rgb(systemTextContrast(text, surfaces, lighter)))) }
    }
    return .init(colors: result, dim: [], appearance: appearance)
}
