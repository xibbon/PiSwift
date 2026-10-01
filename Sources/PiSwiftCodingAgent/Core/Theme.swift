import Foundation
import PiSwiftAI
import Dispatch
import Darwin

public enum ThemeColor: String, CaseIterable, Sendable {
    case accent
    case border
    case borderAccent
    case borderMuted
    case success
    case error
    case warning
    case muted
    case dim
    case text
    case thinkingText
    case userMessageText
    case customMessageText
    case customMessageLabel
    case toolTitle
    case toolOutput
    case mdHeading
    case mdLink
    case mdLinkUrl
    case mdCode
    case mdCodeBlock
    case mdCodeBlockBorder
    case mdQuote
    case mdQuoteBorder
    case mdHr
    case mdListBullet
    case toolDiffAdded
    case toolDiffRemoved
    case toolDiffContext
    case syntaxComment
    case syntaxKeyword
    case syntaxFunction
    case syntaxVariable
    case syntaxString
    case syntaxNumber
    case syntaxType
    case syntaxOperator
    case syntaxPunctuation
    case thinkingOff
    case thinkingMinimal
    case thinkingLow
    case thinkingMedium
    case thinkingHigh
    case thinkingXhigh
    case thinkingMax
    case bashMode
    case scrollbarTrack
    case searchMatchText
    case scrollbarThumb
}

public enum ThemeBg: String, CaseIterable, Sendable {
    case searchMatchBg
    case selectedBg
    case userMessageBg
    case customMessageBg
    case toolPendingBg
    case toolSuccessBg
    case toolErrorBg
}

private typealias ColorMode = TerminalColorMode

public enum ThemeAppearance: String, Codable, Sendable { case dark, light }

public struct TerminalColors: Sendable, Equatable {
    public var foreground: RgbColorValue?
    public var background: RgbColorValue?
    public var palette: [RgbColorValue]?
    public init(foreground: RgbColorValue? = nil, background: RgbColorValue? = nil, palette: [RgbColorValue]? = nil) {
        self.foreground = foreground; self.background = background; self.palette = palette
    }
}

public enum ThemeForeground: Sendable { case token(ThemeColor), color(Color) }
public enum ThemeBackground: Sendable { case token(ThemeBg), color(Color) }
public struct ThemeStyle: Sendable {
    public var fg: ThemeForeground?
    public var bg: ThemeBackground?
    public var attributes: TextAttributes
    public init(fg: ThemeForeground? = nil, bg: ThemeBackground? = nil, attributes: TextAttributes = TextAttributes()) {
        self.fg = fg; self.bg = bg; self.attributes = attributes
    }
}

private enum ThemeColorValue: Decodable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.typeMismatch(
            ThemeColorValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
        )
    }
}

private struct ThemeExportSection: Decodable, Sendable {
    var pageBg: ThemeColorValue?
    var cardBg: ThemeColorValue?
    var infoBg: ThemeColorValue?
}

private struct ThemeJson: Decodable, Sendable {
    var name: String
    var appearance: ThemeAppearance?
    var vars: [String: ThemeColorValue]?
    var colors: [String: ThemeColorValue]
    var export: ThemeExportSection?
}

private enum ThemeLoadError: Error, CustomStringConvertible {
    case missingTheme(String)
    case invalidTheme(String)

    var description: String {
        switch self {
        case .missingTheme(let name):
            return "Theme not found: \(name)"
        case .invalidTheme(let message):
            return message
        }
    }
}

public struct Theme: Sendable {
    public let name: String
    fileprivate var fgColors: [ThemeColor: String]
    fileprivate var bgColors: [ThemeBg: String]
    private var mode: ColorMode
    fileprivate var concreteColors: [String: Color] = [:]
    fileprivate var defaultForegroundTokens: [String] = []
    fileprivate var defaultBackgroundTokens: [String] = []
    fileprivate var dimTokens: Set<ThemeColor> = []
    fileprivate var ownAppearance: ThemeAppearance?
    private let cache = LockedState(ThemeResolvedCache())

    public var colorMode: TerminalColorMode { mode }
    public var appearance: ThemeAppearance { ownAppearance ?? getTerminalTheme() }
    public var colors: [String: Color] {
        let snapshot = withThemeState { ($0.terminalColors, $0.generation, $0.terminalColorScheme) }
        return cache.withLock { state in
            if state.generation == snapshot.1 { return state.colors }
            let light = (ownAppearance ?? detectTerminalTheme(colors: snapshot.0, reportedScheme: snapshot.2)) == .light
            let foreground = snapshot.0.foreground.map(Color.rgb) ?? (try! parseColor(light ? "#000000" : "#e5e5e7"))
            let background = snapshot.0.background.map(Color.rgb) ?? (try! parseColor(light ? "#ffffff" : "#000000"))
            var values = concreteColors
            for token in defaultForegroundTokens { values[token] = foreground }
            for token in defaultBackgroundTokens { values[token] = background }
            for token in dimTokens {
                if let color = values[token.rawValue] { values[token.rawValue] = try! mixColors(color, background, amount: 0.4) }
            }
            state.generation = snapshot.1; state.colors = values
            return values
        }
    }

    public func style(_ text: String, options: ThemeStyle) -> String {
        var attributes = options.attributes
        var foreground: String?
        var background: String?
        if let fg = options.fg {
            switch fg {
            case .token(let token): foreground = fgColors[token]; if dimTokens.contains(token) { attributes.dim = true }
            case .color(let color): foreground = foregroundAnsi(color, mode)
            }
        }
        if let bg = options.bg {
            switch bg {
            case .token(let token): background = bgColors[token]
            case .color(let color): background = backgroundAnsi(color, mode)
            }
        }
        return styleTextWithAnsi(text, fgAnsi: foreground, bgAnsi: background, options: attributes)
    }

    fileprivate init(fgColors: [ThemeColor: String], bgColors: [ThemeBg: String], mode: ColorMode, name: String = "dark") {
        self.name = name
        self.fgColors = fgColors
        self.bgColors = bgColors
        self.mode = mode
    }

    public static func fallback() -> Theme {
        let fg = Dictionary(uniqueKeysWithValues: ThemeColor.allCases.map { ($0, "\u{001B}[39m") })
        let bg = Dictionary(uniqueKeysWithValues: ThemeBg.allCases.map { ($0, "\u{001B}[49m") })
        return Theme(fgColors: fg, bgColors: bg, mode: .color256)
    }

    public func fg(_ color: ThemeColor, _ text: String) -> String {
        guard let ansi = fgColors[color] else { return text }
        if dimTokens.contains(color) { return "\(ansi)\u{001B}[2m\(text)\u{001B}[22;39m" }
        return "\(ansi)\(text)\u{001B}[39m"
    }

    public func fg(_ color: String, _ text: String) -> String {
        guard let parsed = ThemeColor(rawValue: color) else { return text }
        return fg(parsed, text)
    }

    public func bg(_ color: ThemeBg, _ text: String) -> String {
        guard let ansi = bgColors[color] else { return text }
        return "\(ansi)\(text)\u{001B}[49m"
    }

    public func bg(_ color: String, _ text: String) -> String {
        guard let parsed = ThemeBg(rawValue: color) else { return text }
        return bg(parsed, text)
    }

    public func bold(_ text: String) -> String {
        "\u{001B}[1m\(text)\u{001B}[22m"
    }

    public func italic(_ text: String) -> String {
        "\u{001B}[3m\(text)\u{001B}[23m"
    }

    public func underline(_ text: String) -> String {
        "\u{001B}[4m\(text)\u{001B}[24m"
    }

    public func strikethrough(_ text: String) -> String {
        "\u{001B}[9m\(text)\u{001B}[29m"
    }

    public func inverse(_ text: String) -> String {
        "\u{001B}[7m\(text)\u{001B}[27m"
    }

    public func getFgAnsi(_ color: ThemeColor) -> String {
        (fgColors[color] ?? "\u{001B}[39m") + (dimTokens.contains(color) ? "\u{001B}[2m" : "")
    }

    public func getBgAnsi(_ color: ThemeBg) -> String {
        bgColors[color] ?? "\u{001B}[49m"
    }

    public func getColorMode() -> String {
        mode.rawValue
    }

    public func getThinkingBorderColor(_ level: String) -> (String) -> String {
        switch level {
        case "off":
            return { self.fg(.thinkingOff, $0) }
        case "minimal":
            return { self.fg(.thinkingMinimal, $0) }
        case "low":
            return { self.fg(.thinkingLow, $0) }
        case "medium":
            return { self.fg(.thinkingMedium, $0) }
        case "high":
            return { self.fg(.thinkingHigh, $0) }
        case "xhigh":
            return { self.fg(.thinkingXhigh, $0) }
        case "max":
            return { self.fg(.thinkingMax, $0) }
        default:
            return { self.fg(.thinkingOff, $0) }
        }
    }

    public func getBashModeBorderColor() -> (String) -> String {
        { self.fg(.bashMode, $0) }
    }
}

private struct ResolvedColor: Sendable {
    var string: String?
    var number: Int?

    init(string: String) {
        self.string = string
        self.number = nil
    }

    init(number: Int) {
        self.string = nil
        self.number = number
    }
}

private struct ThemeResolvedCache: Sendable {
    var generation: UInt64? = nil
    var colors: [String: Color] = [:]
}

private func detectColorMode() -> ColorMode {
    if let mode = withThemeState({ $0.colorMode }) { return mode }
    let env = ProcessInfo.processInfo.environment
    return ["truecolor", "24bit"].contains(env["COLORTERM"] ?? "") || (env["TERM"] ?? "").hasSuffix("-direct") || env["WT_SESSION"] != nil ? .truecolor : .color256
}

private func parseResolved(_ value: ResolvedColor) throws -> Color? {
    if let number = value.number { return try parseColor(number) }
    let string = value.string ?? ""
    return string.isEmpty ? nil : try parseColor(string)
}

private func resolveVarRefs(
    _ value: ThemeColorValue,
    vars: [String: ThemeColorValue],
    visited: inout Set<String>
) throws -> ResolvedColor {
    switch value {
    case .number(let number):
        guard (0...255).contains(number) else {
            throw ThemeLoadError.invalidTheme("Invalid color index: \(number)")
        }
        return ResolvedColor(number: number)
    case .string(let stringValue):
        if stringValue.isEmpty || stringValue.hasPrefix("#") || stringValue.lowercased().hasPrefix("oklch(") || stringValue.lowercased().hasPrefix("okhsl(") {
            return ResolvedColor(string: stringValue)
        }
        let key = stringValue.hasPrefix("$") ? String(stringValue.dropFirst()) : stringValue
        if visited.contains(key) {
            throw ThemeLoadError.invalidTheme("Circular variable reference detected: \(key)")
        }
        guard let ref = vars[key] else {
            throw ThemeLoadError.invalidTheme("Variable reference not found: \(key)")
        }
        visited.insert(key)
        let resolved = try resolveVarRefs(ref, vars: vars, visited: &visited)
        visited.remove(key)
        return resolved
    }
}

private func resolveThemeColors(
    colors: [String: ThemeColorValue],
    vars: [String: ThemeColorValue]
) throws -> [String: ResolvedColor] {
    var resolved: [String: ResolvedColor] = [:]
    for (key, value) in colors {
        var visited: Set<String> = []
        resolved[key] = try resolveVarRefs(value, vars: vars, visited: &visited)
    }
    return resolved
}

private func getBuiltinThemeData() -> [String: ThemeJson] {
    if let cached = withThemeState({ $0.builtinThemes }) {
        return cached
    }

    let decoder = JSONDecoder()
    var builtins: [String: ThemeJson] = [:]
    let names = ["dark", "light"]

    for name in names {
        let bundledUrl = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "theme")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        if let url = bundledUrl,
           let data = try? Data(contentsOf: url),
           let json = try? decoder.decode(ThemeJson.self, from: data) {
            builtins[name] = json
            continue
        }
        let fallbackPath = (getThemesDir() as NSString).appendingPathComponent("\(name).json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
           let json = try? decoder.decode(ThemeJson.self, from: data) {
            builtins[name] = json
        }
    }

    withThemeState { $0.builtinThemes = builtins }
    return builtins
}

private func validateThemeJson(_ json: ThemeJson, name: String) throws {
    let required = Set(ThemeColor.allCases.map { $0.rawValue } + ThemeBg.allCases.map { $0.rawValue })
    let present = Set(json.colors.keys)
    let missing = required.subtracting(present).sorted()
    if !missing.isEmpty {
        var message = "Invalid theme \"\(name)\":\n\nMissing required color tokens:\n"
        message += missing.map { "  - \($0)" }.joined(separator: "\n")
        message += "\n\nPlease add these colors to your theme's \"colors\" object."
        message += "\nSee the built-in themes (dark.json, light.json) for reference values."
        throw ThemeLoadError.invalidTheme(message)
    }
    if json.name.contains("/") {
        throw ThemeLoadError.invalidTheme("Invalid theme name \"\(json.name)\": theme names cannot contain \"/\" because it is reserved for automatic light/dark theme settings.")
    }
}

/// Applies optional theme-token fallbacks before validation so themes written before a
/// new optional token was introduced remain valid.
private func withThemeColorFallbacks(_ json: ThemeJson) -> ThemeJson {
    var resolved = json
    if resolved.colors[ThemeColor.thinkingMax.rawValue] == nil,
       let xhigh = resolved.colors[ThemeColor.thinkingXhigh.rawValue] {
        resolved.colors[ThemeColor.thinkingMax.rawValue] = xhigh
    }
    for (key, fallback) in [("scrollbarTrack", "muted"), ("scrollbarThumb", "text"),
                            ("searchMatchBg", "selectedBg"), ("searchMatchText", "text")] {
        if resolved.colors[key] == nil { resolved.colors[key] = resolved.colors[fallback] }
    }
    return resolved
}

private func loadThemeJson(_ name: String) throws -> ThemeJson {
    if let registeredPath = withThemeState({ $0.registeredThemePaths[name] }) {
        guard FileManager.default.fileExists(atPath: registeredPath) else {
            throw ThemeLoadError.missingTheme(name)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: registeredPath))
        let json = withThemeColorFallbacks(try JSONDecoder().decode(ThemeJson.self, from: data))
        try validateThemeJson(json, name: name)
        return json
    }

    let builtins = getBuiltinThemeData()
    if let builtin = builtins[name] {
        return withThemeColorFallbacks(builtin)
    }

    let customDir = getCustomThemesDir()
    let path = (customDir as NSString).appendingPathComponent("\(name).json")
    guard FileManager.default.fileExists(atPath: path) else {
        throw ThemeLoadError.missingTheme(name)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let json = withThemeColorFallbacks(try JSONDecoder().decode(ThemeJson.self, from: data))
    try validateThemeJson(json, name: name)
    return json
}

private func averageLightness(_ colors: [Color]) -> Double? {
    let fixed = colors.filter { if case .indexed(let value) = $0 { return value.index >= 16 }; return true }
    return fixed.isEmpty ? nil : fixed.reduce(0) { $0 + colorToOklch($1).l } / Double(fixed.count)
}
private func createTheme(_ themeJson: ThemeJson, mode: ColorMode?, dim: [String] = []) throws -> Theme {
    let colorMode = mode ?? detectColorMode()
    let resolved = try resolveThemeColors(colors: themeJson.colors, vars: themeJson.vars ?? [:])
    var result = Theme(fgColors: [:], bgColors: [:], mode: colorMode, name: themeJson.name)
    var foregrounds: [Color] = [], backgrounds: [Color] = []
    for (key, value) in resolved {
        let color = try parseResolved(value)
        if let color { result.concreteColors[key] = color }
        if let token = ThemeBg(rawValue: key) {
            result.bgColors[token] = color.map { backgroundAnsi($0, colorMode) } ?? "\u{001B}[49m"
            if let color { backgrounds.append(color) } else { result.defaultBackgroundTokens.append(key) }
        } else if let token = ThemeColor(rawValue: key) {
            result.fgColors[token] = color.map { foregroundAnsi($0, colorMode) } ?? "\u{001B}[39m"
            if let color { foregrounds.append(color) } else { result.defaultForegroundTokens.append(key) }
        }
    }
    let fg = averageLightness(foregrounds), bg = averageLightness(backgrounds)
    var detected: ThemeAppearance?
    if let fg, let bg { detected = bg < fg ? .dark : .light }
    else if let bg { detected = bg < 0.5 ? .dark : .light }
    else if let fg { detected = fg > 0.5 ? .dark : .light }
    result.ownAppearance = themeJson.appearance ?? detected
    result.dimTokens = Set(dim.compactMap(ThemeColor.init(rawValue:)))
    return result
}

public func loadTheme(_ name: String, mode: TerminalColorMode? = nil) throws -> Theme {
    if name == "system" {
        let snapshot = withThemeState { ($0.terminalColors, $0.terminalColorsPending, $0.terminalColorScheme) }
        let generated = generateSystemThemeColors(SystemThemeInput(foreground: snapshot.0.foreground, background: snapshot.0.background, palette: snapshot.0.palette, saturation: snapshot.1 ? 0 : 1, appearanceHint: detectTerminalTheme(colors: snapshot.0, reportedScheme: snapshot.2)))
        let colors = generated.colors.mapValues { value -> ThemeColorValue in
            switch value { case .string(let value): return .string(value); case .number(let value): return .number(value) }
        }
        return try createTheme(ThemeJson(name: "system", appearance: generated.appearance, colors: colors), mode: mode, dim: generated.dim)
    }
    return try createTheme(loadThemeJson(name), mode: mode)
}

public func loadThemeFromPath(_ path: String, mode: TerminalColorMode? = nil) throws -> Theme {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let json = withThemeColorFallbacks(try JSONDecoder().decode(ThemeJson.self, from: data))
    try validateThemeJson(json, name: json.name)
    return try createTheme(json, mode: mode)
}

public func detectColorFgBgTheme(env: [String: String] = ProcessInfo.processInfo.environment) -> ThemeAppearance? {
    guard let field = env["COLORFGBG"]?.components(separatedBy: ";").last?.trimmingCharacters(in: .whitespaces),
          field.range(of: "^\\d{1,2}$", options: .regularExpression) != nil,
          let index = Int(field), index <= 15 else { return nil }
    return index <= 6 || index == 8 ? .dark : .light
}
public func detectTerminalTheme(colors: TerminalColors = TerminalColors(), reportedScheme: ThemeAppearance? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> ThemeAppearance {
    if let background = colors.background { return terminalAppearance(background, foreground: colors.foreground) }
    return reportedScheme ?? detectColorFgBgTheme(env: env) ?? .dark
}
public func getTerminalTheme() -> ThemeAppearance {
    let snapshot = withThemeState { ($0.terminalColors, $0.terminalColorScheme) }
    return detectTerminalTheme(colors: snapshot.0, reportedScheme: snapshot.1)
}
public func setTerminalColors(_ colors: TerminalColors) {
    withThemeState { $0.terminalColors = colors; $0.terminalColorsPending = false; $0.generation &+= 1 }
}
public func setTerminalColorScheme(_ scheme: ThemeAppearance?) {
    withThemeState { $0.terminalColorScheme = scheme; $0.generation &+= 1 }
}
public func markTerminalColorsPending() { withThemeState { $0.terminalColorsPending = true; $0.generation &+= 1 } }
public func setTerminalColorMode(_ mode: TerminalColorMode) { withThemeState { $0.colorMode = mode; $0.generation &+= 1 } }
private func getDefaultTheme() -> String { "system" }

private struct ThemeState: Sendable {
    var terminalColors = TerminalColors()
    var terminalColorsPending = false
    var terminalColorScheme: ThemeAppearance?
    var colorMode: TerminalColorMode?
    var generation: UInt64 = 0
    var theme: Theme = Theme.fallback()
    var builtinThemes: [String: ThemeJson]?
    var currentThemeName: String?
    var registeredThemePaths: [String: String] = [:]
    var themeWatcher: DispatchSourceFileSystemObject?
    var themeWatcherFd: Int32 = -1
    var onThemeChangeCallback: (@Sendable () -> Void)?
    var themeReloadTask: Task<Void, Never>?
}

private let themeState = LockedState(ThemeState())

private func withThemeState<T>(_ body: (inout sending ThemeState) throws -> sending T) rethrows -> sending T {
    try themeState.withLock(body)
}

public var theme: Theme {
    get { withThemeState { $0.theme } }
    set { withThemeState { $0.theme = newValue } }
}

public func initTheme(_ name: String? = nil, enableWatcher: Bool = false) {
    let themeName = name ?? getDefaultTheme()
    if themeName == "system" { stopThemeWatcher() }
    withThemeState { $0.currentThemeName = themeName }
    do {
        theme = try loadTheme(themeName)
        if enableWatcher {
            startThemeWatcher()
        }
    } catch {
        stopThemeWatcher()
        withThemeState { $0.currentThemeName = "system" }
        theme = (try? loadTheme("system")) ?? Theme.fallback()
    }
}

public func setTheme(_ name: String, enableWatcher: Bool = false) -> (success: Bool, error: String?) {
    if name == "system" { stopThemeWatcher() }
    withThemeState { $0.currentThemeName = name }
    do {
        theme = try loadTheme(name)
        if enableWatcher {
            startThemeWatcher()
        }
        withThemeState { $0.onThemeChangeCallback?() }
        return (true, nil)
    } catch {
        stopThemeWatcher()
        withThemeState { $0.currentThemeName = "system" }
        theme = (try? loadTheme("system")) ?? Theme.fallback()
        return (false, (error as? ThemeLoadError)?.description ?? error.localizedDescription)
    }
}

public func onThemeChange(_ callback: @escaping @Sendable () -> Void) {
    withThemeState { $0.onThemeChangeCallback = callback }
}

private func startThemeWatcher() {
    stopThemeWatcher()

    guard let themeName = withThemeState({ $0.currentThemeName }),
          themeName != "system",
          themeName != "dark",
          themeName != "light" else {
        return
    }

    let customDir = getCustomThemesDir()
    let path = (customDir as NSString).appendingPathComponent("\(themeName).json")
    guard FileManager.default.fileExists(atPath: path) else {
        return
    }

    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        return
    }
    withThemeState { $0.themeWatcherFd = fd }

    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .delete, .rename],
        queue: DispatchQueue.global()
    )

    source.setEventHandler {
        let flags = source.data
        if flags.contains(.delete) || flags.contains(.rename) {
            withThemeState { $0.currentThemeName = "system" }
            theme = (try? loadTheme("system")) ?? Theme.fallback()
            stopThemeWatcher()
            withThemeState { $0.onThemeChangeCallback?() }
            return
        }

        let previousTask = withThemeState { state in
            let task = state.themeReloadTask
            state.themeReloadTask = nil
            return task
        }
        previousTask?.cancel()
        let task = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            guard let current = withThemeState({ $0.currentThemeName }) else { return }
            if let loaded = try? loadTheme(current) {
                theme = loaded
                withThemeState { $0.onThemeChangeCallback?() }
            }
        }
        withThemeState { $0.themeReloadTask = task }
    }

    source.setCancelHandler {
        let closeFd = withThemeState { state -> Int32 in
            let fd = state.themeWatcherFd
            if fd >= 0 {
                state.themeWatcherFd = -1
            }
            return fd
        }
        if closeFd >= 0 {
            close(closeFd)
        }
    }

    withThemeState { $0.themeWatcher = source }
    source.resume()
}

public func stopThemeWatcher() {
    let (task, watcher) = withThemeState { state -> (Task<Void, Never>?, DispatchSourceFileSystemObject?) in
        let task = state.themeReloadTask
        let watcher = state.themeWatcher
        state.themeReloadTask = nil
        state.themeWatcher = nil
        return (task, watcher)
    }
    task?.cancel()
    watcher?.cancel()
}

public func setRegisteredThemes(_ themes: [HookThemeInfo]) {
    var updated: [String: String] = [:]
    for theme in themes {
        guard let path = theme.path, !theme.name.isEmpty else { continue }
        updated[theme.name] = path
    }
    withThemeState { $0.registeredThemePaths = updated }
}

public func getAvailableThemes() -> [String] {
    var themes = Set(getBuiltinThemeData().keys)
    themes.formUnion(withThemeState { $0.registeredThemePaths.keys })
    let customDir = getCustomThemesDir()
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: customDir) {
        for file in contents where file.hasSuffix(".json") {
            themes.insert(String(file.dropLast(5)))
        }
    }
    return ["system"] + themes.filter { $0 != "system" }.sorted()
}

public func getAvailableThemesWithPaths() -> [HookThemeInfo] {
    var results: [String: HookThemeInfo] = [:]
    let builtins = getBuiltinThemeData()
    let themesDir = getThemesDir()
    for name in builtins.keys {
        let fallbackPath = (themesDir as NSString).appendingPathComponent("\(name).json")
        let path = FileManager.default.fileExists(atPath: fallbackPath) ? fallbackPath : nil
        results[name] = HookThemeInfo(name: name, path: path)
    }

    let customDir = getCustomThemesDir()
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: customDir) {
        for entry in entries where entry.hasSuffix(".json") {
            let name = (entry as NSString).deletingPathExtension
            let path = (customDir as NSString).appendingPathComponent(entry)
            results[name] = HookThemeInfo(name: name, path: path)
        }
    }

    let registered = withThemeState { $0.registeredThemePaths }
    for (name, path) in registered {
        results[name] = HookThemeInfo(name: name, path: path)
    }

    return [HookThemeInfo(name: "system", path: nil)] + results.values.filter { $0.name != "system" }.sorted { $0.name < $1.name }
}

public func getThemeByName(_ name: String, mode: TerminalColorMode? = nil) -> Theme? {
    do {
        return try loadTheme(name, mode: mode)
    } catch {
        return nil
    }
}

public func setThemeInstance(_ newTheme: Theme) {
    theme = newTheme
    withThemeState { $0.currentThemeName = "<in-memory>" }
    stopThemeWatcher()
    withThemeState { $0.onThemeChangeCallback?() }
}

public func getResolvedThemeColors(_ themeName: String? = nil) -> [String: String] {
    guard let loaded = try? loadTheme(themeName ?? withThemeState { $0.currentThemeName } ?? getDefaultTheme(), mode: .truecolor) else { return [:] }
    return loaded.colors.mapValues(colorToHex)
}
public func isLightTheme(_ themeName: String? = nil) -> Bool {
    (try? loadTheme(themeName ?? withThemeState { $0.currentThemeName } ?? getDefaultTheme()).appearance) == .light
}
public func getThemeExportColors(_ themeName: String? = nil) -> (pageBg: String?, cardBg: String?, infoBg: String?) {
    let name = themeName ?? withThemeState { $0.currentThemeName } ?? getDefaultTheme()
    guard name != "system", let json = try? loadThemeJson(name) else { return (nil, nil, nil) }
    do {
        return (try resolveExportColor(json.export?.pageBg, vars: json.vars ?? [:]), try resolveExportColor(json.export?.cardBg, vars: json.vars ?? [:]), try resolveExportColor(json.export?.infoBg, vars: json.vars ?? [:]))
    } catch { return (nil, nil, nil) }
}
private func resolveExportColor(_ value: ThemeColorValue?, vars: [String: ThemeColorValue]) throws -> String? {
    guard let value else { return nil }
    var visited: Set<String> = []
    let resolved = try resolveVarRefs(value, vars: vars, visited: &visited)
    if let number = resolved.number { return try colorToHex(parseColor(number)) }
    guard let string = resolved.string, !string.isEmpty else { return nil }
    if string.lowercased().hasPrefix("okhsl(") { return try colorToHex(parseColor(string)) }
    return string
}

private func escapeAnsiForDebug(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        if scalar.value == 0x1B {
            result += "\\u{001B}"
        } else if scalar.value < 0x20 {
            result += String(format: "\\u{%02X}", scalar.value)
        } else {
            result.append(Character(scalar))
        }
    }
    return result
}

public func getThemeDiagnostics() -> String {
    let env = ProcessInfo.processInfo.environment
    let term = env["TERM"] ?? ""
    let colorterm = env["COLORTERM"] ?? ""
    let colorfgbg = env["COLORFGBG"] ?? ""
    let cwd = FileManager.default.currentDirectoryPath

    let accentAnsi = theme.getFgAnsi(.accent)
    let selectedBgAnsi = theme.getBgAnsi(.selectedBg)
    let accentDefault = accentAnsi == "\u{001B}[39m"
    let selectedBgDefault = selectedBgAnsi == "\u{001B}[49m"

    let bundlePath = Bundle.module.bundleURL.path
    let bundleDark = Bundle.module.url(forResource: "dark", withExtension: "json", subdirectory: "theme") != nil
        || Bundle.module.url(forResource: "dark", withExtension: "json") != nil
    let bundleLight = Bundle.module.url(forResource: "light", withExtension: "json", subdirectory: "theme") != nil
        || Bundle.module.url(forResource: "light", withExtension: "json") != nil
    let themesDir = getThemesDir()
    let themesDirDark = FileManager.default.fileExists(atPath: (themesDir as NSString).appendingPathComponent("dark.json"))
    let themesDirLight = FileManager.default.fileExists(atPath: (themesDir as NSString).appendingPathComponent("light.json"))
    let customThemesDir = getCustomThemesDir()

    let lines = [
        "Theme diagnostics:",
        "currentTheme=\(withThemeState { $0.currentThemeName } ?? "nil")",
        "colorMode=\(theme.getColorMode())",
        "fg.accent=\(escapeAnsiForDebug(accentAnsi)) default=\(accentDefault)",
        "bg.selectedBg=\(escapeAnsiForDebug(selectedBgAnsi)) default=\(selectedBgDefault)",
        "bundlePath=\(bundlePath)",
        "bundleHasDark=\(bundleDark) bundleHasLight=\(bundleLight)",
        "cwd=\(cwd)",
        "themesDir=\(themesDir) dark=\(themesDirDark) light=\(themesDirLight)",
        "customThemesDir=\(customThemesDir)",
        "env TERM=\(term) COLORTERM=\(colorterm) COLORFGBG=\(colorfgbg)",
    ]
    return lines.joined(separator: "\n")
}

public func getLanguageFromPath(_ filePath: String) -> String? {
    let ext = (filePath as NSString).pathExtension.lowercased()
    if ext.isEmpty { return nil }

    let extToLang: [String: String] = [
        "ts": "typescript",
        "tsx": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "go": "go",
        "java": "java",
        "kt": "kotlin",
        "swift": "swift",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
        "php": "php",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "fish",
        "ps1": "powershell",
        "sql": "sql",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "sass": "sass",
        "less": "less",
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "md": "markdown",
        "markdown": "markdown",
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "cmake": "cmake",
        "lua": "lua",
        "perl": "perl",
        "r": "r",
        "scala": "scala",
        "clj": "clojure",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "ml": "ocaml",
        "vim": "vim",
        "graphql": "graphql",
        "proto": "protobuf",
        "tf": "hcl",
        "hcl": "hcl",
    ]

    return extToLang[ext]
}

public func highlightCode(_ code: String, lang: String? = nil) -> [String] {
    return code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}
