import Foundation

public protocol SyntaxTheme: Sendable {
    func plain(_ text: String) -> String
    func keyword(_ text: String) -> String
    func builtIn(_ text: String) -> String
    func literal(_ text: String) -> String
    func number(_ text: String) -> String
    func string(_ text: String) -> String
    func comment(_ text: String) -> String
    func function(_ text: String) -> String
    func type(_ text: String) -> String
    func variable(_ text: String) -> String
    func operatorToken(_ text: String) -> String
    func punctuation(_ text: String) -> String
}

public struct PlainSyntaxTheme: SyntaxTheme {
    public init() {}

    public func plain(_ text: String) -> String { text }
    public func keyword(_ text: String) -> String { text }
    public func builtIn(_ text: String) -> String { text }
    public func literal(_ text: String) -> String { text }
    public func number(_ text: String) -> String { text }
    public func string(_ text: String) -> String { text }
    public func comment(_ text: String) -> String { text }
    public func function(_ text: String) -> String { text }
    public func type(_ text: String) -> String { text }
    public func variable(_ text: String) -> String { text }
    public func operatorToken(_ text: String) -> String { text }
    public func punctuation(_ text: String) -> String { text }
}

public struct SyntaxHighlighter: Sendable {
    public init() {}

    public static func supportsLanguage(_ lang: String) -> Bool {
        let normalized = normalizeLanguage(lang)
        return languageSpecs[normalized] != nil
    }

    public static func highlight(code: String, lang: String? = nil, theme: SyntaxTheme = PlainSyntaxTheme()) -> [String] {
        let spec = languageSpec(for: lang)
        var state = ScanState()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            highlightLine(String(line), spec: spec, theme: theme, state: &state)
        }
    }
}

private struct BlockComment: Sendable, Hashable {
    let start: String
    let end: String
}

private struct LanguageSpec: Sendable {
    let keywords: Set<String>
    let literals: Set<String>
    let lineComments: [String]
    let blockComments: [BlockComment]
    let stringDelimiters: [Character]
    let multilineStringDelimiters: [String]
    let caseSensitive: Bool
}

private struct ScanState: Sendable {
    var blockComment: BlockComment?
    var stringDelimiter: String?
}

private let defaultKeywords: Set<String> = [
    "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default",
    "class", "struct", "enum", "protocol", "extension", "import", "from", "as", "new",
    "let", "var", "const", "static", "public", "private", "protected", "internal",
    "try", "catch", "throw", "throws", "async", "await", "in", "of", "do", "func", "function"
]

private let defaultLiterals: Set<String> = ["true", "false", "null", "nil", "undefined"]

private let swiftKeywords: Set<String> = defaultKeywords.union([
    "guard", "defer", "mutating", "nonmutating", "init", "deinit", "associatedtype", "rethrows",
    "operator", "precedencegroup", "where", "inout", "some", "any", "isolated"
])

private let jsKeywords: Set<String> = defaultKeywords.union([
    "yield", "super", "this", "typeof", "instanceof", "export", "package", "implements", "interface"
])

private let pythonKeywords: Set<String> = [
    "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "pass",
    "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield"
]

private let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "case", "esac",
    "while", "until", "function", "select", "return", "export", "local"
]

private let languageSpecs: [String: LanguageSpec] = {
    var specs: [String: LanguageSpec] = [:]
    let cLike = LanguageSpec(
        keywords: defaultKeywords,
        literals: defaultLiterals,
        lineComments: ["//", "#"],
        blockComments: [BlockComment(start: "/*", end: "*/")],
        stringDelimiters: ["\"", "'", "`"],
        multilineStringDelimiters: ["`"],
        caseSensitive: true
    )

    let swift = LanguageSpec(
        keywords: swiftKeywords,
        literals: defaultLiterals.union(["true", "false", "nil"]),
        lineComments: ["//"],
        blockComments: [BlockComment(start: "/*", end: "*/")],
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["\"\"\""],
        caseSensitive: true
    )

    let js = LanguageSpec(
        keywords: jsKeywords,
        literals: defaultLiterals,
        lineComments: ["//"],
        blockComments: [BlockComment(start: "/*", end: "*/")],
        stringDelimiters: ["\"", "'", "`"],
        multilineStringDelimiters: ["`"],
        caseSensitive: true
    )

    let python = LanguageSpec(
        keywords: pythonKeywords,
        literals: ["True", "False", "None"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: ["\"\"\"", "'''"],
        caseSensitive: true
    )

    let shell = LanguageSpec(
        keywords: shellKeywords,
        literals: ["true", "false"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: [],
        caseSensitive: true
    )

    let json = LanguageSpec(
        keywords: [],
        literals: ["true", "false", "null"],
        lineComments: [],
        blockComments: [],
        stringDelimiters: ["\""],
        multilineStringDelimiters: [],
        caseSensitive: true
    )

    let sql = LanguageSpec(
        keywords: [
            "select", "from", "where", "insert", "update", "delete", "create", "drop", "alter",
            "join", "left", "right", "inner", "outer", "group", "by", "order", "limit", "having"
        ],
        literals: ["true", "false", "null"],
        lineComments: ["--"],
        blockComments: [BlockComment(start: "/*", end: "*/")],
        stringDelimiters: ["\"", "'"],
        multilineStringDelimiters: [],
        caseSensitive: false
    )

    for key in ["c", "cpp", "csharp", "java", "kotlin", "go", "rust", "typescript", "javascript"] {
        specs[key] = cLike
    }
    specs["swift"] = swift
    specs["python"] = python
    specs["bash"] = shell
    specs["sh"] = shell
    specs["zsh"] = shell
    specs["json"] = json
    specs["sql"] = sql
    return specs
}()

private func languageSpec(for lang: String?) -> LanguageSpec {
    let normalized = normalizeLanguage(lang)
    if let spec = languageSpecs[normalized] {
        return spec
    }
    return LanguageSpec(
        keywords: defaultKeywords,
        literals: defaultLiterals,
        lineComments: ["//", "#", "--"],
        blockComments: [BlockComment(start: "/*", end: "*/")],
        stringDelimiters: ["\"", "'", "`"],
        multilineStringDelimiters: ["`"],
        caseSensitive: true
    )
}

private func normalizeLanguage(_ lang: String?) -> String {
    guard let lang else { return "" }
    let lower = lang.lowercased()
    switch lower {
    case "js", "jsx":
        return "javascript"
    case "ts", "tsx":
        return "typescript"
    case "py":
        return "python"
    case "shell", "zsh", "bash", "sh":
        return "bash"
    case "c++":
        return "cpp"
    case "cs":
        return "csharp"
    default:
        return lower
    }
}

private func highlightLine(
    _ line: String,
    spec: LanguageSpec,
    theme: SyntaxTheme,
    state: inout ScanState
) -> String {
    var result = ""
    var index = line.startIndex

    func appendPlain(_ text: String) {
        result += theme.plain(text)
    }

    while index < line.endIndex {
        if let block = state.blockComment {
            if let range = line[index...].range(of: block.end) {
                let segment = String(line[index..<range.upperBound])
                result += theme.comment(segment)
                index = range.upperBound
                state.blockComment = nil
                continue
            } else {
                result += theme.comment(String(line[index...]))
                return result
            }
        }

        if let delimiter = state.stringDelimiter {
            let (next, closed) = consumeString(line, from: index, delimiter: delimiter)
            result += theme.string(String(line[index..<next]))
            index = next
            if closed {
                state.stringDelimiter = nil
            }
            continue
        }

        if firstPrefixMatch(line, spec.lineComments, at: index) != nil {
            let rest = String(line[index...])
            result += theme.comment(rest)
            return result
        }

        if let block = firstBlockMatch(line, spec.blockComments, at: index) {
            if let range = line[index...].range(of: block.end) {
                let segment = String(line[index..<range.upperBound])
                result += theme.comment(segment)
                index = range.upperBound
                continue
            } else {
                result += theme.comment(String(line[index...]))
                state.blockComment = block
                return result
            }
        }

        let ch = line[index]
        // Match multi-character delimiters before their single-quote forms.
        let delimiter = firstPrefixMatch(line, spec.multilineStringDelimiters, at: index)
            ?? (spec.stringDelimiters.contains(ch) ? String(ch) : nil)
        if let delimiter {
            let contentStart = line.index(index, offsetBy: delimiter.count)
            let (next, closed) = consumeString(line, from: contentStart, delimiter: delimiter)
            result += theme.string(String(line[index..<next]))
            index = next
            if !closed && spec.multilineStringDelimiters.contains(delimiter) {
                state.stringDelimiter = delimiter
            }
            continue
        }

        if isDigit(ch) {
            let (token, next) = consumeNumber(line, from: index)
            result += theme.number(token)
            index = next
            continue
        }

        if isIdentifierStart(ch) {
            let (token, next) = consumeIdentifier(line, from: index)
            let tokenKey = spec.caseSensitive ? token : token.lowercased()
            if spec.literals.contains(tokenKey) || spec.literals.contains(token) {
                result += theme.literal(token)
            } else if spec.keywords.contains(tokenKey) || spec.keywords.contains(token) {
                result += theme.keyword(token)
            } else if looksLikeFunctionCall(line, after: next) {
                result += theme.function(token)
            } else {
                appendPlain(token)
            }
            index = next
            continue
        }

        if isOperatorChar(ch) {
            let (token, next) = consumeWhile(line, from: index, predicate: isOperatorChar)
            result += theme.operatorToken(token)
            index = next
            continue
        }

        if isPunctuationChar(ch) {
            result += theme.punctuation(String(ch))
            index = line.index(after: index)
            continue
        }

        appendPlain(String(ch))
        index = line.index(after: index)
    }

    return result
}

private func consumeString(
    _ line: String,
    from index: String.Index,
    delimiter: String
) -> (String.Index, Bool) {
    var idx = index
    var escaped = false
    while idx < line.endIndex {
        let ch = line[idx]
        if escaped {
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if line[idx...].hasPrefix(delimiter) {
            return (line.index(idx, offsetBy: delimiter.count), true)
        }
        idx = line.index(after: idx)
    }
    return (idx, false)
}

private func firstPrefixMatch(_ line: String, _ prefixes: [String], at index: String.Index) -> String? {
    for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
        if line[index...].hasPrefix(prefix) {
            return prefix
        }
    }
    return nil
}

private func firstBlockMatch(_ line: String, _ blocks: [BlockComment], at index: String.Index) -> BlockComment? {
    for block in blocks.sorted(by: { $0.start.count > $1.start.count }) {
        if line[index...].hasPrefix(block.start) {
            return block
        }
    }
    return nil
}

private func isDigit(_ ch: Character) -> Bool {
    ch >= "0" && ch <= "9"
}

private func isIdentifierStart(_ ch: Character) -> Bool {
    if ch == "_" { return true }
    guard let scalar = ch.unicodeScalars.first else { return false }
    return CharacterSet.letters.contains(scalar)
}

private func isIdentifierPart(_ ch: Character) -> Bool {
    isIdentifierStart(ch) || isDigit(ch)
}

private func isOperatorChar(_ ch: Character) -> Bool {
    "+-*/=<>!&|^%?:".contains(ch)
}

private func isPunctuationChar(_ ch: Character) -> Bool {
    "(){}[];,.".contains(ch)
}

private func consumeIdentifier(_ line: String, from index: String.Index) -> (String, String.Index) {
    var idx = index
    while idx < line.endIndex && isIdentifierPart(line[idx]) {
        idx = line.index(after: idx)
    }
    return (String(line[index..<idx]), idx)
}

private func consumeNumber(_ line: String, from index: String.Index) -> (String, String.Index) {
    var idx = index
    var isHex = false
    if line[idx] == "0" {
        let next = line.index(after: idx)
        if next < line.endIndex {
            let nextChar = line[next]
            if nextChar == "x" || nextChar == "X" {
                isHex = true
                idx = line.index(after: next)
            }
        }
    }

    while idx < line.endIndex {
        let ch = line[idx]
        if ch == "_" || ch == "." {
            idx = line.index(after: idx)
            continue
        }
        if isHex {
            if (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F") {
                idx = line.index(after: idx)
                continue
            }
            break
        }
        if isDigit(ch) {
            idx = line.index(after: idx)
            continue
        }
        break
    }

    return (String(line[index..<idx]), idx)
}

private func consumeWhile(
    _ line: String,
    from index: String.Index,
    predicate: (Character) -> Bool
) -> (String, String.Index) {
    var idx = index
    while idx < line.endIndex && predicate(line[idx]) {
        idx = line.index(after: idx)
    }
    return (String(line[index..<idx]), idx)
}

private func looksLikeFunctionCall(_ line: String, after index: String.Index) -> Bool {
    var idx = index
    while idx < line.endIndex {
        let ch = line[idx]
        if ch == " " || ch == "\t" {
            idx = line.index(after: idx)
            continue
        }
        return ch == "("
    }
    return false
}
