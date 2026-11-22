import Foundation

// Use the shared PiSwift color math for the standard palette and color cube.
private let htmlAnsiColors = (0..<16).map { colorToHex(.indexed(IndexedColor(index: $0))) }

private func htmlIndexedColor(_ index: Double) -> String {
    if index <= 255 { return colorToHex(.indexed(IndexedColor(index: Int(index)))) }
    // Use floating-point arithmetic as JavaScript does. Do not clamp invalid indices.
    var gray = 8 + (index - 232) * 10
    var hex = ""
    if gray.isFinite {
        let digits = Array("0123456789abcdef")
        repeat {
            hex.insert(digits[Int(gray.truncatingRemainder(dividingBy: 16))], at: hex.startIndex)
            gray = floor(gray / 16)
        } while gray > 0
        if hex.count < 2 { hex = "0" + hex }
    } else { hex = "Infinity" }
    return "#" + hex + hex + hex
}

// SGR parameters are non-negative integers. Match JavaScript's decimal/exponent spelling.
private func htmlSgrNumber(_ number: Double) -> String {
    if !number.isFinite { return "Infinity" }
    let parts = String(number).lowercased().components(separatedBy: "e")
    var mantissa = parts[0]
    if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
    guard parts.count == 2, let exponent = Int(parts[1]) else { return mantissa }
    if number >= 1e21 { return mantissa + "e+" + String(exponent) }
    let fractionalCount = mantissa.split(separator: ".").dropFirst().first?.count ?? 0
    let digits = mantissa.replacingOccurrences(of: ".", with: "")
    return digits + String(repeating: "0", count: max(0, exponent - fractionalCount))
}

private func escapeAnsiHtml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#039;")
}

private struct HtmlAnsiStyle {
    var fg: String?
    var bg: String?
    var bold = false
    var dim = false
    var italic = false
    var underline = false

    var css: String {
        var parts: [String] = []
        if let fg { parts.append("color:\(fg)") }
        if let bg { parts.append("background-color:\(bg)") }
        if bold { parts.append("font-weight:bold") }
        if dim { parts.append("opacity:0.6") }
        if italic { parts.append("font-style:italic") }
        if underline { parts.append("text-decoration:underline") }
        return parts.joined(separator: ";")
    }

    mutating func apply(_ params: [Double]) {
        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0: self = HtmlAnsiStyle()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 30...37: fg = htmlAnsiColors[Int(code) - 30]
            case 40...47: bg = htmlAnsiColors[Int(code) - 40]
            case 90...97: fg = htmlAnsiColors[Int(code) - 90 + 8]
            case 100...107: bg = htmlAnsiColors[Int(code) - 100 + 8]
            case 39: fg = nil
            case 49: bg = nil
            case 38, 48:
                var color: String?
                if params.count > i + 2, params[i + 1] == 5 {
                    color = htmlIndexedColor(params[i + 2])
                    i += 2
                } else if params.count > i + 4, params[i + 1] == 2 {
                    // Keep the upstream rgb() spelling and channel values.
                    color = "rgb(\(htmlSgrNumber(params[i + 2])),\(htmlSgrNumber(params[i + 3])),\(htmlSgrNumber(params[i + 4])))"
                    i += 4
                }
                if let color {
                    if code == 38 { fg = color } else { bg = color }
                }
            default: break
            }
            i += 1
        }
    }
}

private let htmlEscapeRegex = try! NSRegularExpression(
    pattern: "\u{1b}\\[([0-9;]*)m|\u{1b}\\[[0-?]*[ -/]*[@-~]|\u{1b}\\]([^\u{07}\u{1b}]*)(?:\u{07}|\u{1b}\\\\)|\u{1b}_[^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)"
)

/// Remove terminal controls recognized by the HTML converter.
public func stripAnsiEscapes(_ text: String) -> String {
    let range = NSRange(location: 0, length: (text as NSString).length)
    return htmlEscapeRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        .replacingOccurrences(of: "\u{1b}", with: "")
}

/// Convert SGR and safe OSC 8 hyperlinks to HTML.
public func ansiToHtml(_ text: String) -> String {
    let source = text as NSString
    var style = HtmlAnsiStyle()
    var result = ""
    var lastIndex = 0
    var inSpan = false
    var inLink = false
    func cleaned(_ raw: String) -> String {
        escapeAnsiHtml(raw.replacingOccurrences(of: "\u{1b}", with: ""))
    }
    func safeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(trimmed.unicodeScalars.filter { $0.value > 31 && $0.value != 127 })
        let lower = cleaned.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("mailto:") ? cleaned : nil
    }
    func openSpan() {
        let css = style.css
        if !css.isEmpty {
            result += "<span style=\"\(css)\">"
            inSpan = true
        }
    }
    func closeSpan() {
        if inSpan {
            result += "</span>"
            inSpan = false
        }
    }
    for match in htmlEscapeRegex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += cleaned(source.substring(with: NSRange(location: lastIndex, length: match.range.location - lastIndex)))
        if match.range(at: 1).location != NSNotFound {
            let parameters = source.substring(with: match.range(at: 1))
            let params: [Double] = parameters.isEmpty ? [0] : parameters.components(separatedBy: ";").map { Double($0) ?? 0 }
            closeSpan()
            style.apply(params)
            openSpan()
        } else if match.range(at: 2).location != NSNotFound {
            let payload = source.substring(with: match.range(at: 2))
            if payload.hasPrefix("8;"), let separator = payload.dropFirst(2).firstIndex(of: ";") {
                let url = String(payload[payload.index(after: separator)...])
                closeSpan()
                if inLink { result += "</a>"; inLink = false }
                if let safe = safeURL(url) {
                    result += "<a href=\"\(escapeAnsiHtml(safe))\">"
                    inLink = true
                }
                openSpan()
            }
        }
        lastIndex = NSMaxRange(match.range)
    }
    result += cleaned(source.substring(from: lastIndex))
    closeSpan()
    if inLink { result += "</a>" }
    return result
}

/// Wrap each converted line in a div. Use a non-breaking space for an empty line.
public func ansiLinesToHtml(_ lines: [String]) -> String {
    lines.map { line in
        let html = ansiToHtml(line)
        return "<div class=\"ansi-line\">\(html.isEmpty ? "&nbsp;" : html)</div>"
    }.joined()
}
