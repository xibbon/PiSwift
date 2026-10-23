import Foundation
import PiSwiftAI
import PiSwiftChord

/// The model tool that loads deferred tools.
public let TOOL_SEARCH_TOOL_NAME = "tool_search"
/// The maximum number of matches when a search has no limit.
public let DEFAULT_TOOL_SEARCH_LIMIT = 8

private let toolSearchDescription = "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`."

/// A search argument does not meet the tool requirements.
public enum ToolSearchError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The query contains only whitespace.
    case emptyQuery
    /// The limit is not a positive integer.
    case invalidLimit
    /// The error text supplied to the model.
    public var description: String {
        switch self {
        case .emptyQuery: return "query must not be empty"
        case .invalidLimit: return "limit must be a positive integer"
        }
    }
}

/// The names loaded by a search.
public struct ToolSearchToolDetails: Sendable, Equatable, Codable {
    /// Tool names in search rank order.
    public var loaded: [String]
    /// Creates search details.
    public init(loaded: [String]) { self.loaded = loaded }
}

private struct ToolSearchArguments: Sendable, Decodable {
    var query: String
    var limit: Double?
}

/// Creates the replay-safe, model-only deferred tool search.
public func createToolSearchTool() throws -> ToolRegistration {
    try defineTool(name: TOOL_SEARCH_TOOL_NAME, description: toolSearchDescription, parameters: [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Search query for deferred tools."],
            "limit": ["type": "number", "description": "Maximum number of tools to return. Defaults to 8."]
        ],
        "required": ["query"]
    ], args: ToolSearchArguments.self, replay: .safe, callers: [.model]) { arguments, api, context in
        guard !trimSearchText(arguments.query).isEmpty else { throw ToolSearchError.emptyQuery }
        let maximum = arguments.limit ?? Double(DEFAULT_TOOL_SEARCH_LIMIT)
        guard maximum.isFinite, maximum.rounded(.towardZero) == maximum, maximum > 0 else {
            throw ToolSearchError.invalidLimit
        }
        let candidates = try await api.agent(context).deferred
        let documents = try candidates.map { SearchDocument(name: $0.name, text: try searchText($0)) }
        let limit = maximum >= Double(Int.max) ? Int.max : Int(maximum)
        let loaded = rankDocuments(arguments.query, documents: documents, limit: limit)
        let text: String
        if loaded.isEmpty {
            text = "No matching tools found."
        } else {
            let lines = loaded.map { name in
                let description = candidates.first { harnessNamesEqual($0.name, name) }?.description ?? ""
                var first = trimSearchText(description).components(separatedBy: "\n")[0]
                if first.hasSuffix("\r") { first.removeLast() }
                return "- \(name): \(first)"
            }
            text = "Loaded \(loaded.count) tool\(loaded.count == 1 ? "" : "s"). They are available from your next call:\n" + lines.joined(separator: "\n")
        }
        return ToolExecutionResult(output: [.text(TextContent(text: text))],
            details: try JSONValue(encoding: ToolSearchToolDetails(loaded: loaded)),
            control: loaded.isEmpty ? nil : ToolControl(addTools: loaded))
    }
}

/// Creates an extension for hosts that select deferred tool discovery.
public func createToolSearchExtension() throws -> Extension {
    Extension(name: "tool-search", tools: [try createToolSearchTool()])
}

private func searchText(_ tool: ToolRegistration) throws -> String {
    var parts = [tool.name, tool.name.replacingOccurrences(of: "_", with: " "), tool.description]
    appendSchemaText(try tool.currentOrderedDeclaration()["parameters"], to: &parts)
    return parts.filter { !trimSearchText($0).isEmpty }.joined(separator: " ")
}

private func appendSchemaText(_ schema: JSONValue?, to parts: inout [String]) {
    guard let object = schema?.objectValue else { return }
    if let description = object["description"]?.stringValue { parts.append(description) }
    if let properties = object["properties"]?.objectValue {
        for (name, property) in properties {
            parts.append(name)
            appendSchemaText(property, to: &parts)
        }
    }
    appendSchemaText(object["items"], to: &parts)
    for key in ["anyOf", "oneOf", "allOf"] {
        for variant in object[key]?.arrayValue ?? [] { appendSchemaText(variant, to: &parts) }
    }
}

// ECMAScript String.trim includes BOM and excludes NEXT LINE (U+0085).
private func trimSearchText(_ text: String) -> String {
    func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }
    var scalars = text.unicodeScalars[...]
    while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    return String(scalars)
}
