import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum ExportHtmlError: LocalizedError, Sendable {
    case inMemorySession
    case nothingToExport
    case fileNotFound(String)
    case missingTemplate(String, String)

    public var errorDescription: String? {
        switch self {
        case .inMemorySession:
            return "Cannot export in-memory session to HTML"
        case .nothingToExport:
            return "Nothing to export yet - start a conversation first"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .missingTemplate(let name, let ext):
            return "Missing export template file: \(name).\(ext)"
        }
    }
}

public struct ExportOptions: Sendable {
    public var outputPath: String?
    public var themeName: String?

    public init(outputPath: String? = nil, themeName: String? = nil) {
        self.outputPath = outputPath
        self.themeName = themeName
    }
}

public func exportSessionToHtml(
    _ sessionManager: SessionManager,
    _ state: AgentState? = nil,
    _ options: ExportOptions? = nil
) throws -> String {
    guard let sessionFile = sessionManager.getSessionFile() else {
        throw ExportHtmlError.inMemorySession
    }
    guard FileManager.default.fileExists(atPath: sessionFile) else {
        throw ExportHtmlError.nothingToExport
    }

    let opts = options ?? ExportOptions()
    let sessionData = buildSessionData(
        header: sessionManager.getHeader(),
        entries: sessionManager.getEntries(),
        leafId: sessionManager.getLeafId(),
        systemPrompt: state?.systemPrompt,
        tools: state?.tools
    )

    let html = try generateHtml(sessionData, themeName: opts.themeName)
    let outputPath = opts.outputPath ?? defaultExportPath(for: sessionFile)
    try html.write(toFile: outputPath, atomically: true, encoding: .utf8)
    return outputPath
}

public func exportFromFile(_ inputPath: String, _ options: ExportOptions? = nil) throws -> String {
    guard FileManager.default.fileExists(atPath: inputPath) else {
        throw ExportHtmlError.fileNotFound(inputPath)
    }

    let opts = options ?? ExportOptions()
    let sessionManager = SessionManager.open(inputPath)
    let sessionData = buildSessionData(
        header: sessionManager.getHeader(),
        entries: sessionManager.getEntries(),
        leafId: sessionManager.getLeafId(),
        systemPrompt: nil,
        tools: nil
    )

    let html = try generateHtml(sessionData, themeName: opts.themeName)
    let outputPath = opts.outputPath ?? defaultExportPath(for: inputPath)
    try html.write(toFile: outputPath, atomically: true, encoding: .utf8)
    return outputPath
}

public func exportFromFile(_ inputPath: String, _ outputPath: String? = nil) throws -> String {
    try exportFromFile(inputPath, ExportOptions(outputPath: outputPath, themeName: nil))
}

private struct ExportColors {
    var pageBg: String
    var cardBg: String
    var infoBg: String
}

private func defaultExportPath(for path: String) -> String {
    let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return "\(APP_NAME)-session-\(base).html"
}

private func buildSessionData(
    header: SessionHeader?,
    entries: [SessionEntry],
    leafId: String?,
    systemPrompt: String?,
    tools: [AgentTool]?
) -> OrderedJSON {
    let headerValue: Any = header.map { sessionHeaderToDict($0) } ?? NSNull()
    let entryValues = entries.map { sessionEntryToDict($0) }

    var data: [String: Any] = [
        "header": headerValue,
        "entries": entryValues,
        "leafId": leafId ?? NSNull(),
        "systemPrompt": systemPrompt ?? NSNull(),
    ]

    if let tools {
        data["tools"] = tools.map { ["name": $0.name, "description": $0.description] }
    } else {
        data["tools"] = NSNull()
    }

    let orderedEntries = entries.map { (try? OrderedJSON.parse(encodeSessionEntry($0))) ?? .null }
    return replacingJSONMembers(OrderedJSON.fromFoundation(data), with: ["entries": .array(orderedEntries)])
}

private func generateHtml(_ sessionData: OrderedJSON, themeName: String?) throws -> String {
    let template = try loadTemplateFile(named: "template", ext: "html", subdir: "export-html")
    let templateCss = try loadTemplateFile(named: "template", ext: "css", subdir: "export-html")
    let templateJs = try loadTemplateFile(named: "template", ext: "js", subdir: "export-html")
    let markedJs = try loadTemplateFile(named: "marked.min", ext: "js", subdir: "export-html/vendor")
    let highlightJs = try loadTemplateFile(named: "highlight.min", ext: "js", subdir: "export-html/vendor")

    let themeVars = generateThemeVars(themeName)
    let colors = getResolvedThemeColors(themeName)
    let exportColors = deriveExportColors(colors["userMessageBg"] ?? "#343541")
    let themeExport = getThemeExportColors(themeName)

    let sessionJson = Data(sessionData.serialized().utf8)
    let sessionBase64 = sessionJson.base64EncodedString()

    let css = templateCss
        .replacingOccurrences(of: "{{THEME_VARS}}", with: themeVars)
        .replacingOccurrences(of: "{{BODY_BG}}", with: themeExport.pageBg ?? exportColors.pageBg)
        .replacingOccurrences(of: "{{CONTAINER_BG}}", with: themeExport.cardBg ?? exportColors.cardBg)
        .replacingOccurrences(of: "{{INFO_BG}}", with: themeExport.infoBg ?? exportColors.infoBg)

    return template
        .replacingOccurrences(of: "{{CSS}}", with: css)
        .replacingOccurrences(of: "{{JS}}", with: templateJs)
        .replacingOccurrences(of: "{{SESSION_DATA}}", with: sessionBase64)
        .replacingOccurrences(of: "{{MARKED_JS}}", with: markedJs)
        .replacingOccurrences(of: "{{HIGHLIGHT_JS}}", with: highlightJs)
}

private func generateThemeVars(_ themeName: String?) -> String {
    let colors = getResolvedThemeColors(themeName)
    var lines: [String] = []
    for key in colors.keys.sorted() {
        if let value = colors[key] {
            lines.append("--\(key): \(value);")
        }
    }

    let themeExport = getThemeExportColors(themeName)
    let base = colors["userMessageBg"] ?? "#343541"
    let derived = deriveExportColors(base)
    lines.append("--exportPageBg: \(themeExport.pageBg ?? derived.pageBg);")
    lines.append("--exportCardBg: \(themeExport.cardBg ?? derived.cardBg);")
    lines.append("--exportInfoBg: \(themeExport.infoBg ?? derived.infoBg);")

    return lines.joined(separator: "\n      ")
}

private func parseExportCssColor(_ color: String) -> (r: Double, g: Double, b: Double)? {
    if let match = color.range(of: #"^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$"#, options: .regularExpression) {
        let hex = String(color[match])
        let r = Double(Int(hex.dropFirst().prefix(2), radix: 16) ?? 0)
        let g = Double(Int(hex.dropFirst(3).prefix(2), radix: 16) ?? 0)
        let b = Double(Int(hex.dropFirst(5).prefix(2), radix: 16) ?? 0)
        return (r, g, b)
    }

    if let match = color.range(of: #"^rgb\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$"#, options: .regularExpression) {
        let parts = color[match].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        if parts.count == 3,
           let r = Double(parts[0]),
           let g = Double(parts[1]),
           let b = Double(parts[2]) {
            return (r, g, b)
        }
    }
    return nil
}

private func getLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func toLinear(_ c: Double) -> Double {
        let s = c / 255.0
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * toLinear(r) + 0.7152 * toLinear(g) + 0.0722 * toLinear(b)
}

private func adjustBrightness(_ color: String, _ factor: Double) -> String {
    guard let parsed = parseExportCssColor(color) else { return color }
    func adjust(_ c: Double) -> Int {
        Int(min(255, max(0, (c * factor).rounded())))
    }
    return "rgb(\(adjust(parsed.r)), \(adjust(parsed.g)), \(adjust(parsed.b)))"
}

private func deriveExportColors(_ baseColor: String) -> ExportColors {
    guard let parsed = parseExportCssColor(baseColor) else {
        return ExportColors(
            pageBg: "rgb(24, 24, 30)",
            cardBg: "rgb(30, 30, 36)",
            infoBg: "rgb(60, 55, 40)"
        )
    }

    let luminance = getLuminance(parsed.r, parsed.g, parsed.b)
    let isLight = luminance > 0.5
    if isLight {
        return ExportColors(
            pageBg: adjustBrightness(baseColor, 0.96),
            cardBg: baseColor,
            infoBg: "rgb(\(min(255, parsed.r + 10)), \(min(255, parsed.g + 5)), \(max(0, parsed.b - 20)))"
        )
    }
    return ExportColors(
        pageBg: adjustBrightness(baseColor, 0.7),
        cardBg: adjustBrightness(baseColor, 0.85),
        infoBg: "rgb(\(min(255, parsed.r + 20)), \(min(255, parsed.g + 15)), \(parsed.b))"
    )
}

private func loadTemplateFile(named name: String, ext: String, subdir: String) throws -> String {
    if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdir)
        ?? Bundle.module.url(forResource: name, withExtension: ext) {
        return try String(contentsOf: url, encoding: .utf8)
    }

    let baseDir = getExportTemplateDir()
    var relative = subdir
    if relative.hasPrefix("export-html") {
        relative = String(relative.dropFirst("export-html".count))
    }
    if relative.hasPrefix("/") {
        relative = String(relative.dropFirst())
    }
    let path = relative.isEmpty ? baseDir : (baseDir as NSString).appendingPathComponent(relative)
    let filePath = (path as NSString).appendingPathComponent("\(name).\(ext)")
    guard FileManager.default.fileExists(atPath: filePath) else {
        throw ExportHtmlError.missingTemplate(name, ext)
    }
    return try String(contentsOfFile: filePath, encoding: .utf8)
}

private func sessionHeaderToDict(_ header: SessionHeader) -> [String: Any] {
    var dict: [String: Any] = [
        "type": "session",
        "id": header.id,
        "timestamp": header.timestamp,
        "cwd": header.cwd,
    ]
    if let version = header.version { dict["version"] = version }
    if let parentSession = header.parentSession { dict["parentSession"] = parentSession }
    return dict
}

private func sessionEntryToDict(_ entry: SessionEntry) -> [String: Any] {
    codingAgentSessionEntryJSONObject(entry)
}
