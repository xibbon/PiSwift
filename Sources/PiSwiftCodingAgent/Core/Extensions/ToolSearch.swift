import Foundation
import PiSwiftAI

public let TOOL_SEARCH_TOOL_NAME = "tool_search"
public let DEFAULT_TOOL_SEARCH_LIMIT = 8

public struct ToolSearchDocument: Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
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

/// The ASCII token rules used by the upstream BM25 search.
public func tokenize(_ text: String) -> [String] {
    let scalars = Array(text.unicodeScalars)
    var words: [String] = []
    var word = ""
    func finish() {
        if !word.isEmpty && !toolSearchStopWords.contains(word) { words.append(stemToolSearchTerm(word)) }
        word = ""
    }
    for index in scalars.indices {
        let scalar = scalars[index]
        let previous = index > 0 ? scalars[index - 1] : nil
        let next = index + 1 < scalars.count ? scalars[index + 1] : nil
        if asciiUpper(scalar), let previous,
           (asciiLower(previous) || asciiDigit(previous) ||
            (asciiUpper(previous) && next.map(asciiLower) == true)) {
            finish()
        }
        if asciiLower(scalar) || asciiDigit(scalar) {
            word.unicodeScalars.append(scalar)
        } else if asciiUpper(scalar) {
            word.unicodeScalars.append(Unicode.Scalar(scalar.value + 32)!)
        } else {
            finish()
        }
    }
    finish()
    return words
}

private func appendSchemaText(_ schema: Any?, to parts: inout [String]) {
    guard let schema = schema as? [String: Any] else { return }
    if let description = schema["description"] as? String { parts.append(description) }
    if let properties = schema["properties"] as? [String: Any] {
        for name in properties.keys.sorted() {
            parts.append(name)
            appendSchemaText(properties[name], to: &parts)
        }
    }
    appendSchemaText(schema["items"], to: &parts)
    for key in ["anyOf", "oneOf", "allOf"] {
        if let variants = schema[key] as? [Any] {
            for variant in variants { appendSchemaText(variant, to: &parts) }
        }
    }
}

public func createToolSearchDocument(_ tool: ToolInfo, namespace: ToolNamespace? = nil) -> ToolSearchDocument {
    var parts = [tool.name, tool.name.replacingOccurrences(of: "_", with: " "), tool.description]
    if let parameters = tool.parameters {
        appendSchemaText(parameters.mapValues(\.value), to: &parts)
    }
    if let namespace = namespace ?? tool.namespace { parts += [namespace.name, namespace.description ?? ""] }
    return ToolSearchDocument(name: tool.name, text: parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " "))
}

/// Okapi BM25. Equal scores retain document order.
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
        let counts = documents.map { document in
            tokenize(document.text).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        }
        let lengths = counts.map { $0.values.reduce(0, +) }
        let average = Double(lengths.reduce(0, +)) / Double(documents.count)
        let averageLength = average == 0 ? 1 : average
        let idf = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
            let frequency = counts.filter { $0[term] != nil }.count
            return (term, log(1 + (Double(documents.count - frequency) + 0.5) / (Double(frequency) + 0.5)))
        })
        var matches: [(index: Int, match: ToolSearchMatch)] = []
        for (index, document) in documents.enumerated() {
            var score = 0.0
            for term in queryTerms {
                guard let count = counts[index][term], count > 0 else { continue }
                let norm = k1 * (1 - b + b * Double(lengths[index]) / averageLength)
                score += (idf[term] ?? 0) * (Double(count) * (k1 + 1) / (Double(count) + norm))
            }
            if score > 0 { matches.append((index, ToolSearchMatch(name: document.name, score: score))) }
        }
        return matches.sorted { $0.match.score == $1.match.score ? $0.index < $1.index : $0.match.score > $1.match.score }
            .prefix(limit).map(\.match)
    }
}

/// The source path identifies this built-in tool; Swift schemas have value semantics.
public func isToolSearchTool(_ tool: ToolInfo) -> Bool {
    tool.name == TOOL_SEARCH_TOOL_NAME && tool.sourceInfo?.path == "builtin:tool-search"
}

public func createToolSearchDescription(_ sources: [ToolNamespace] = []) -> String {
    let listed = sources.isEmpty ? "None currently enabled." : sources.map { source in
        let firstLine = source.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        return firstLine.isEmpty ? "- \(source.name)" : "- \(source.name): \(firstLine)"
    }.joined(separator: "\n")
    return "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nYou have access to tools from the following sources:\n\(listed)\n\nSome of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`."
}

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
        description: createToolSearchDescription(),
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
        exposure: .modelOnly, defaultActive: false,
        prepareLoadout: { loadout in
            var sources: [ToolNamespace] = []
            var seen: Set<String> = []
            for tool in loadout.registered where searchable(loadout.getExposure(tool.name)) {
                if let namespace = loadout.getNamespace(tool.name), seen.insert(namespace.name).inserted {
                    sources.append(namespace)
                }
            }
            return ToolLoadoutChanges(descriptions: [TOOL_SEARCH_TOOL_NAME: createToolSearchDescription(sources)])
        })
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
