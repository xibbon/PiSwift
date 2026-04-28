import Foundation

private let unicodeSpaceScalars = CharacterSet(charactersIn: "\u{00A0}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}")
private let narrowNoBreakSpace = "\u{202F}"

private func normalizeUnicodeSpaces(_ str: String) -> String {
    var result = ""
    for scalar in str.unicodeScalars {
        if unicodeSpaceScalars.contains(scalar) {
            result.append(" ")
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

/// v0.67.3: also handle lowercase "am"/"pm" in macOS screenshot filenames. Some locales
/// (e.g. some Asian English variants) produce "Screenshot ... at 3.14.15 pm.png" instead of
/// "PM". The narrow-no-break-space substitution must apply to both casings.
private func tryMacOSScreenshotPath(_ path: String) -> String {
    path.replacingOccurrences(of: " AM.", with: "\(narrowNoBreakSpace)AM.")
        .replacingOccurrences(of: " PM.", with: "\(narrowNoBreakSpace)PM.")
        .replacingOccurrences(of: " am.", with: "\(narrowNoBreakSpace)am.")
        .replacingOccurrences(of: " pm.", with: "\(narrowNoBreakSpace)pm.")
}

private func tryNFDVariant(_ path: String) -> String {
    path.decomposedStringWithCanonicalMapping
}

private func tryCurlyQuoteVariant(_ path: String) -> String {
    path.replacingOccurrences(of: "'", with: "\u{2019}")
}

private func fileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

public func expandPath(_ filePath: String) -> String {
    let normalized = normalizeUnicodeSpaces(filePath)
    if normalized == "~" {
        return getHomeDir()
    }
    if normalized.hasPrefix("~/") {
        let home = getHomeDir()
        return home + String(normalized.dropFirst())
    }
    return normalized
}

public func resolveToCwd(_ filePath: String, cwd: String) -> String {
    let expanded = expandPath(filePath)
    if expanded.hasPrefix("/") {
        return expanded
    }
    return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
}

public func resolveReadPath(_ filePath: String, cwd: String) -> String {
    let resolved = resolveToCwd(filePath, cwd: cwd)
    if fileExists(resolved) {
        return resolved
    }
    let macOSVariant = tryMacOSScreenshotPath(resolved)
    if macOSVariant != resolved && fileExists(macOSVariant) {
        return macOSVariant
    }
    let nfdVariant = tryNFDVariant(resolved)
    if nfdVariant != resolved && fileExists(nfdVariant) {
        return nfdVariant
    }
    let curlyVariant = tryCurlyQuoteVariant(resolved)
    if curlyVariant != resolved && fileExists(curlyVariant) {
        return curlyVariant
    }
    let nfdCurlyVariant = tryCurlyQuoteVariant(nfdVariant)
    if nfdCurlyVariant != resolved && fileExists(nfdCurlyVariant) {
        return nfdCurlyVariant
    }
    return resolved
}
