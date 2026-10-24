// Source parsing copied from Sources/PiSwiftCodingAgent/Codemode/Source.swift.
import Foundation
import PiSwiftChord
import PiSwiftAI

public let codemodeOptionsPrefix = "// @options:"
public let codemodeSourceGrammar = #"""

start: options_source | plain_source
options_source: OPTIONS_LINE NEWLINE SOURCE
plain_source: SOURCE

OPTIONS_LINE: /[ \t]*\/\/ @options:[^\r\n]*/
NEWLINE: /\r?\n/
SOURCE: /[\s\S]+/
"""# + "\n"

public let codemodeConstrainedSampling: ConstrainedSampling = .grammar(variants: [.openAILark: codemodeSourceGrammar])

public struct CodemodeSourceOptions: Sendable, Equatable {
    public var maxOutputTokens: Int?
    public var timeoutMs: Int?

    public init(maxOutputTokens: Int? = nil, timeoutMs: Int? = nil) {
        self.maxOutputTokens = maxOutputTokens
        self.timeoutMs = timeoutMs
    }
}

public struct ParsedCodemodeSource: Sendable, Equatable {
    public var code: String
    public var options: CodemodeSourceOptions

    public init(code: String, options: CodemodeSourceOptions) {
        self.code = code
        self.options = options
    }
}

public struct CodemodeSourceError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

private let supportedFieldsText = "`max_output_tokens` and `timeout_ms`"
private let maxSafeInteger = 9_007_199_254_740_991.0
// ECMAScript whitespace for trimStart(), including the byte order mark.
private let directiveWhitespace = CharacterSet(charactersIn:
    "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
    "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}" +
    "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

private func safeInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.numberValue, number.isFinite, number >= 0,
          number <= maxSafeInteger, number.rounded(.towardZero) == number else { return nil }
    return Int(number)
}

public func parseCodemodeSource(_ input: String) throws -> ParsedCodemodeSource {
    guard !input.trimmingCharacters(in: directiveWhitespace).isEmpty else {
        throw CodemodeSourceError(#"Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {"max_output_tokens": 1000}`."#)
    }
    for (index, line) in input.components(separatedBy: "\n").enumerated().dropFirst()
        where line.trimmingCharacters(in: directiveWhitespace).hasPrefix(codemodeOptionsPrefix) {
        throw CodemodeSourceError("The // @options: line must be the first line of the input; found one on line \(index + 1)")
    }
    let ns = input as NSString
    let newline = ns.range(of: "\n").location
    let first = (newline == NSNotFound ? input : ns.substring(to: newline))
        .replacingOccurrences(of: "\r$", with: "", options: .regularExpression)
    let trimmed = first.trimmingCharacters(in: directiveWhitespace)
    guard trimmed.hasPrefix(codemodeOptionsPrefix) else {
        return ParsedCodemodeSource(code: input, options: .init())
    }
    let code = newline == NSNotFound ? "" : ns.substring(from: newline)
    guard !code.trimmingCharacters(in: directiveWhitespace).isEmpty else {
        throw CodemodeSourceError("The @options line must be followed by JavaScript source on subsequent lines")
    }
    let directive = String(trimmed.dropFirst(codemodeOptionsPrefix.count)).trimmingCharacters(in: directiveWhitespace)
    guard !directive.isEmpty else {
        throw CodemodeSourceError("@options must be a JSON object with supported fields \(supportedFieldsText)")
    }
    let raw: JSONValue
    do {
        raw = try JSONValue(jsonData: Data(directive.utf8))
    } catch {
        throw CodemodeSourceError("@options must be valid JSON with supported fields \(supportedFieldsText): \(error.localizedDescription)")
    }
    guard let fields = raw.objectValue else {
        throw CodemodeSourceError("@options must be a JSON object with supported fields \(supportedFieldsText)")
    }
    for key in fields.keys where key != "max_output_tokens" && key != "timeout_ms" {
        throw CodemodeSourceError("@options only supports \(supportedFieldsText); got `\(key)`")
    }
    var options = CodemodeSourceOptions()
    if fields["max_output_tokens"] != nil {
        guard let maxOutputTokens = safeInteger(fields["max_output_tokens"]) else {
            throw CodemodeSourceError("@options field `max_output_tokens` must be a non-negative safe integer")
        }
        options.maxOutputTokens = maxOutputTokens
    }
    if fields["timeout_ms"] != nil {
        guard let timeoutMs = safeInteger(fields["timeout_ms"]), timeoutMs > 0, timeoutMs <= 2_147_483_647 else {
            throw CodemodeSourceError("@options field `timeout_ms` must be a positive integer up to 2147483647")
        }
        options.timeoutMs = timeoutMs
    }
    return ParsedCodemodeSource(code: code, options: options)
}
