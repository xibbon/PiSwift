import Foundation
import CoreFoundation
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

private func safeInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 0,
          number.doubleValue <= maxSafeInteger,
          number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
    return Int(number.doubleValue)
}

public func parseCodemodeSource(_ input: String) throws -> ParsedCodemodeSource {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CodemodeSourceError(#"Expected JavaScript source text (non-empty). Provide JS only, optionally with a first line `// @options: {"max_output_tokens": 1000}`."#)
    }
    let ns = input as NSString
    let newline = ns.range(of: "\n").location
    let first = (newline == NSNotFound ? input : ns.substring(to: newline))
        .replacingOccurrences(of: "\r$", with: "", options: .regularExpression)
    let trimmed = first.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(codemodeOptionsPrefix) else {
        return ParsedCodemodeSource(code: input, options: .init())
    }
    let code = newline == NSNotFound ? "" : ns.substring(from: newline)
    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CodemodeSourceError("The @options line must be followed by JavaScript source on subsequent lines")
    }
    let directive = String(trimmed.dropFirst(codemodeOptionsPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !directive.isEmpty else {
        throw CodemodeSourceError("@options must be a JSON object with supported fields \(supportedFieldsText)")
    }
    let raw: Any
    do {
        raw = try JSONSerialization.jsonObject(with: Data(directive.utf8), options: [.fragmentsAllowed])
    } catch {
        throw CodemodeSourceError("@options must be valid JSON with supported fields \(supportedFieldsText): \(error.localizedDescription)")
    }
    guard let fields = raw as? [String: Any] else {
        throw CodemodeSourceError("@options must be a JSON object with supported fields \(supportedFieldsText)")
    }
    for key in fields.keys.sorted() where key != "max_output_tokens" && key != "timeout_ms" {
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
