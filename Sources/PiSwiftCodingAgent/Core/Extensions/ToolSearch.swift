import Foundation
import PiSwiftAI

public let TOOL_SEARCH_TOOL_NAME = "tool_search"
public let DEFAULT_TOOL_SEARCH_LIMIT = 8

public struct ToolSearchDocument: Sendable {
    public var name: String
    public var text: String
    public var namespaceText: String

    public init(name: String, text: String, namespaceText: String = "") {
        self.name = name
        self.text = text
        self.namespaceText = namespaceText
    }
}

public struct ToolSearchMatch: Sendable {
    public var name: String
    public var score: Double

    public init(name: String, score: Double) {
        self.name = name
        self.score = score
    }
}

public struct ToolSearchInput: Sendable {
    public var query: String
    public var limit: Double?

    public init(query: String, limit: Double? = nil) {
        self.query = query
        self.limit = limit
    }
}

public struct ToolSearchResultTool: Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct ToolSearchToolDetails: Sendable {
    public var loaded: [String]

    public init(loaded: [String]) { self.loaded = loaded }
}

public protocol ToolSearchToolAccess: Sendable {
    func getActiveTools() -> [String]
    func getAllTools() -> [ToolInfo]
    func setActiveTools(_ toolNames: [String])
}

extension HookAPI: ToolSearchToolAccess {}

public struct ToolSearchToolOptions: Sendable {
    public var tools: (any ToolSearchToolAccess)?

    public init(tools: (any ToolSearchToolAccess)? = nil) { self.tools = tools }
}

public protocol ToolRanker: Sendable {
    func rank(_ query: String, documents: [ToolSearchDocument], limit: Int) -> [ToolSearchMatch]
}

private let toolSearchStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it",
    "of", "on", "or", "that", "the", "this", "to", "with"
]

private func asciiLower(_ scalar: Unicode.Scalar) -> Bool { (97...122).contains(scalar.value) }
private func asciiUpper(_ scalar: Unicode.Scalar) -> Bool { (65...90).contains(scalar.value) }
private func asciiDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }

private func stemToolSearchTerm(_ term: String) -> String {
    if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
    if term.count > 4 && ["ches", "shes", "sses", "xes", "zes"].contains(where: term.hasSuffix) {
        return String(term.dropLast(2))
    }
    if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return String(term.dropLast()) }
    return term
}

/// Segment Unicode words and split ASCII identifier boundaries.
public func tokenize(_ text: String) -> [String] {
    let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
    var separated = ""
    for index in scalars.indices {
        let scalar = scalars[index]
        let previous = index > 0 ? scalars[index - 1] : nil
        let next = index + 1 < scalars.count ? scalars[index + 1] : nil
        if asciiUpper(scalar), let previous,
           (asciiLower(previous) || asciiDigit(previous) ||
            (asciiUpper(previous) && next.map(asciiLower) == true)) {
            separated.append(" ")
        }
        separated.unicodeScalars.append(scalar)
    }
    let normalized = separated.lowercased()
    var filtered = ""
    for scalar in normalized.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            filtered.unicodeScalars.append(scalar)
        default:
            filtered.append(" ")
        }
    }
    let words: [String]
    if filtered.unicodeScalars.allSatisfy({ asciiLower($0) || asciiDigit($0) || $0 == " " }) {
        words = filtered.split(separator: " ").map(String.init)
    } else {
        var segments: [String] = []
        var previousEnd: String.Index?
        filtered.enumerateSubstrings(in: filtered.startIndex..<filtered.endIndex, options: .byWords) {
            substring, range, _, _ in
            guard let substring else { return }
            let ascii = substring.unicodeScalars.allSatisfy { asciiLower($0) || asciiDigit($0) }
            if ascii, previousEnd == range.lowerBound, let last = segments.last,
               last.unicodeScalars.allSatisfy({ asciiLower($0) || asciiDigit($0) }) {
                segments[segments.count - 1] += substring
            } else {
                segments.append(substring)
            }
            previousEnd = range.upperBound
        }
        words = segments
    }
    return words.filter { !toolSearchStopWords.contains($0) }.map { word in
        word.unicodeScalars.allSatisfy { asciiLower($0) || asciiDigit($0) } ? stemToolSearchTerm(word) : word
    }
}

private func resolveSearchSchemaRef(_ ref: String, root: Any) -> (path: String, value: Any)? {
    guard ref == "#" || ref.hasPrefix("#/") else { return nil }
    var current = root
    var path = "#"
    if ref == "#" { return (path, current) }
    for segment in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
        guard let decoded = String(segment).removingPercentEncoding else { return nil }
        let key = decoded.replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        guard let next = (current as? [String: Any])?[key] else { return nil }
        current = next
        path += "/" + key.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }
    return (path, current)
}

private struct SearchTextBudget {
    static let maxBytes = 1_000_000
    static let maxNodes = 4_096
    static let maxDepth = 64
    var bytes = 0
    var nodes = 0

    mutating func append(_ value: String, to parts: inout [String]) {
        let separatorBytes = parts.isEmpty ? 0 : 1
        let remaining = Self.maxBytes - bytes - separatorBytes
        guard remaining > 0 else { return }
        let clipped = value.utf8.prefix(remaining)
        let text = String(bytes: clipped, encoding: .utf8)
            ?? (1...3).lazy.compactMap { String(bytes: clipped.dropLast(min($0, clipped.count)), encoding: .utf8) }.first
            ?? ""
        guard !text.isEmpty else { return }
        parts.append(text)
        bytes += separatorBytes + text.utf8.count
    }
}

private func appendSchemaText(_ schema: Any?, root: Any, to parts: inout [String],
                              seen: inout Set<String>, budget: inout SearchTextBudget, depth: Int) {
    guard let schema = schema as? [String: Any] else { return }
    guard budget.nodes < SearchTextBudget.maxNodes, depth <= SearchTextBudget.maxDepth,
          budget.bytes < SearchTextBudget.maxBytes else { return }
    budget.nodes += 1
    if let ref = schema["$ref"] as? String,
       let resolved = resolveSearchSchemaRef(ref, root: root),
       resolved.value is [String: Any], seen.insert(resolved.path).inserted {
        appendSchemaText(resolved.value, root: root, to: &parts, seen: &seen,
                         budget: &budget, depth: depth + 1)
    }
    if let description = schema["description"] as? String { budget.append(description, to: &parts) }
    if let properties = schema["properties"] as? [String: Any] {
        for name in properties.keys.sorted() {
            guard budget.nodes < SearchTextBudget.maxNodes, budget.bytes < SearchTextBudget.maxBytes else { break }
            budget.append(name, to: &parts)
            appendSchemaText(properties[name], root: root, to: &parts, seen: &seen,
                             budget: &budget, depth: depth + 1)
        }
    }
    appendSchemaText(schema["items"], root: root, to: &parts, seen: &seen,
                     budget: &budget, depth: depth + 1)
    for key in ["anyOf", "oneOf", "allOf"] {
        if let variants = schema[key] as? [Any] {
            for variant in variants {
                appendSchemaText(variant, root: root, to: &parts, seen: &seen,
                                 budget: &budget, depth: depth + 1)
            }
        }
    }
}

/// Match a namespace by its name or script identifier.
/// Codemode discovery uses this rule for namespace filters and lookups.
public func matchesToolNamespace(name: String, namespace: String) -> Bool {
    matchesToolNamespace(name: name, namespace: ToolNamespace(name: namespace))
}

/// Match the namespace name and its explicit aliases, including their script identifiers.
public func matchesToolNamespace(name: String, namespace: ToolNamespace) -> Bool {
    let queryIdentifier = toCodemodeIdentifier(name)
    return ([namespace.name] + (namespace.aliases ?? [])).contains { candidate in
        candidate == name || toCodemodeIdentifier(candidate) == queryIdentifier
    }
}

public func createToolSearchDocument(_ tool: ToolInfo, namespace: ToolNamespace? = nil) -> ToolSearchDocument {
    var parts: [String] = []
    var budget = SearchTextBudget()
    budget.append(tool.description, to: &parts)
    if let parameters = tool.parameters {
        let root = parameters.mapValues(\.value)
        var seen: Set<String> = ["#"]
        appendSchemaText(root, root: root, to: &parts, seen: &seen, budget: &budget, depth: 0)
    }
    var namespaceParts: [String] = []
    if let namespace = namespace ?? tool.namespace {
        budget.append([namespace.name, namespace.description ?? "", namespace.instructions ?? ""].joined(separator: " "),
                      to: &namespaceParts)
    }
    let namespaceText = namespaceParts.joined(separator: " ")
    return ToolSearchDocument(name: tool.name,
        text: parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " "),
        namespaceText: namespaceText)
}

private func normalizeSearchName(_ name: String) -> String {
    String(String.UnicodeScalarView(name.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased().unicodeScalars.map { scalar in
            asciiLower(scalar) || asciiDigit(scalar) || scalar == "_" || scalar == "$" ? scalar : "_"
        }))
}

private struct IndexedSearchDocument {
    let name: String
    let nameTerms: Set<String>
    let localNameTerms: Set<String>
    let textCounts: [String: Int]
    let textLength: Int
    let namespaceTerms: Set<String>

    init(_ document: ToolSearchDocument) {
        name = document.name
        nameTerms = Set(tokenize(document.name))
        localNameTerms = Set(tokenize(String(document.name.components(separatedBy: "__").last ?? "")))
        textCounts = tokenize(document.text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        textLength = textCounts.values.reduce(0, +)
        namespaceTerms = Set(tokenize(document.namespaceText))
    }
}

/// Okapi BM25 over the description, with separate name and namespace weights.
public struct Bm25Ranker: ToolRanker {
    public let k1: Double
    public let b: Double

    public init(k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    public func rank(_ query: String, documents: [ToolSearchDocument], limit: Int) -> [ToolSearchMatch] {
        var seen: Set<String> = []
        let queryTerms = tokenize(query).filter { seen.insert($0).inserted }
        guard !queryTerms.isEmpty, !documents.isEmpty, limit > 0 else { return [] }
        let indexed = documents.map(IndexedSearchDocument.init)
        let average = Double(indexed.reduce(0) { $0 + $1.textLength }) / Double(indexed.count)
        let averageLength = average == 0 ? 1 : average
        let idf = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
            let frequency = indexed.filter {
                $0.nameTerms.contains(term) || $0.textCounts[term] != nil || $0.namespaceTerms.contains(term)
            }.count
            return (term, log(1 + (Double(documents.count - frequency) + 0.5) / (Double(frequency) + 0.5)))
        })
        let fullNameBonus = queryTerms.reduce(0.0) { $0 + (idf[$1] ?? 0) }
        let exactQuery = normalizeSearchName(query)
        var matches: [(index: Int, match: ToolSearchMatch, covered: Int, exact: Bool)] = []
        for (index, document) in indexed.enumerated() {
            var score = 0.0
            var covered = 0
            let norm = k1 * (1 - b + b * Double(document.textLength) / averageLength)
            for term in queryTerms {
                let count = Double(document.textCounts[term] ?? 0)
                let weight = (document.nameTerms.contains(term) ? 3.0 : 0.0)
                    + (document.namespaceTerms.contains(term) ? 0.5 : 0.0)
                    + count * (k1 + 1) / (count + norm)
                if weight > 0 { covered += 1 }
                score += (idf[term] ?? 0) * weight
            }
            guard score > 0 else { continue }
            if !document.localNameTerms.isEmpty && document.localNameTerms.isSubset(of: Set(queryTerms)) {
                score += fullNameBonus
            }
            let normalized = normalizeSearchName(document.name)
            let exact = normalized == exactQuery || normalized.hasSuffix("__" + exactQuery)
            matches.append((index, ToolSearchMatch(name: document.name, score: score), covered, exact))
        }
        return matches.sorted {
            if $0.exact != $1.exact { return $0.exact }
            if $0.covered != $1.covered { return $0.covered > $1.covered }
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            return $0.index < $1.index
        }
            .prefix(limit).map(\.match)
    }
}

/// The source path identifies this built-in tool; Swift schemas have value semantics.
public func isToolSearchTool(_ tool: ToolInfo) -> Bool {
    tool.name == TOOL_SEARCH_TOOL_NAME && tool.sourceInfo?.path == "builtin:tool-search"
}

/// This description stays the same when servers register tools.
public let TOOL_SEARCH_DESCRIPTION = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`."

public enum ToolSearchError: Error, LocalizedError, Sendable, Equatable {
    case emptyQuery
    case invalidLimit

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "query must not be empty"
        case .invalidLimit: "limit must be a positive integer"
        }
    }
}

private func searchable(_ exposure: ToolExposure) -> Bool { exposure == .codemode || exposure == .deferred }

/// Create the model-only discovery tool. The API is supplied by the extension factory.
public func createToolSearchToolDefinition(options: ToolSearchToolOptions = ToolSearchToolOptions()) -> CustomTool {
    CustomTool(name: TOOL_SEARCH_TOOL_NAME, label: TOOL_SEARCH_TOOL_NAME,
        description: TOOL_SEARCH_DESCRIPTION,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "query": ["type": "string", "description": "Search query for deferred tools."],
                "limit": ["type": "number", "description": "Maximum number of tools to return. Defaults to 8."]
            ]),
            "required": AnyCodable(["query"])
        ],
        execute: { _, parameters, _, _, _ in
            let query = parameters["query"]?.value as? String ?? ""
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolSearchError.emptyQuery }
            var max = DEFAULT_TOOL_SEARCH_LIMIT
            if let value = parameters["limit"]?.value {
                if !(value is Bool), let number = value as? NSNumber, number.doubleValue.isFinite,
                   number.doubleValue.rounded() == number.doubleValue,
                   number.doubleValue > 0 {
                    max = number.doubleValue >= Double(Int.max) ? Int.max : number.intValue
                } else { throw ToolSearchError.invalidLimit }
            }
            let active = options.tools?.getActiveTools() ?? []
            let candidates = (options.tools?.getAllTools() ?? []).filter { searchable($0.exposure) && !active.contains($0.name) }
            let documents = candidates.map { createToolSearchDocument($0) }
            let matches = Bm25Ranker().rank(query, documents: documents, limit: max)
            if !matches.isEmpty { options.tools?.setActiveTools(active + matches.map(\.name)) }
            let found = matches.map { match in
                (name: match.name, description: candidates.first { $0.name == match.name }?.description ?? "")
            }
            let text: String
            if found.isEmpty {
                text = "No matching tools found."
            } else {
                let lines = found.map { item in
                    "- \(item.name): \(item.description.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "")"
                }.joined(separator: "\n")
                text = "Loaded \(found.count) tool\(found.count == 1 ? "" : "s"). They are available from your next call:\n\(lines)"
            }
            return CustomToolResult(content: [.text(TextContent(text: text))],
                details: AnyCodable(["loaded": matches.map(\.name)]))
        },
        promptGuidelines: nil,
        promptSnippet: "Search for tools that are not loaded yet and load the matches",
        exposure: .modelOnly, defaultActive: false, reachesTools: { _ in .all })
}

/// SDK users can pass this factory to `inlineExtensions`.
public func createToolSearchExtension() -> InlineExtension {
    InlineExtension(name: "tool-search", builtin: true, replaceable: true) { api in
        _ = api.registerTool(createToolSearchToolDefinition(options: ToolSearchToolOptions(tools: api)))
    }
}

/// Built-ins available to a host application. SDK sessions opt in by passing this list.
// The MCP built-in follows tool-search in the upstream built-in load order.
public let builtInExtensions: [InlineExtension] = [createCodemodeExtension(), createToolSearchExtension(), createMcpExtension()]
