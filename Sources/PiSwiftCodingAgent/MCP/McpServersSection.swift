import Foundation

public let MCP_SERVERS_SECTION = "mcp_servers"
public let MAX_SERVERS_SECTION_CHARS = 4096
private let maxServerDescriptionChars = 250

/// Data for the MCP server section, including instructions from initialization.
public struct McpServerListing: Sendable {
    public var entry: McpServerEntry
    public var instructions: String?

    public init(entry: McpServerEntry, instructions: String? = nil) {
        self.entry = entry
        self.instructions = instructions
    }
}

func configuredMcpExposures(_ entry: McpServerEntry) -> Set<McpExposure> {
    Set([entry.config.effectiveExposure] + Array((entry.config.toolExposure ?? [:]).values))
}

/// Render the section with the limits and text from upstream v1.0.0.
public func renderServersSection(_ servers: [McpServerListing]) -> String? {
    let listed = servers.filter {
        let exposures = configuredMcpExposures($0.entry)
        return $0.entry.config.isEnabled && (exposures.contains(.codemode) || exposures.contains(.deferred))
    }.sorted { $0.entry.name.localizedCompare($1.entry.name) == .orderedAscending }
    guard !listed.isEmpty else { return nil }
    let reaches = listed.map { configuredMcpExposures($0.entry).contains(.codemode) ? "codemode" : "tool_search" }
    var intro = "MCP servers whose tools are not declared to you."
    if reaches.contains("codemode") { intro += " Call the tools of `codemode` servers from codemode scripts." }
    if reaches.contains("tool_search") { intro += " Load the tools of `tool_search` servers with `tool_search`." }
    let heads = zip(listed, reaches).map { "- \(mcpNamespace($0.0.entry.name)) (\($0.1))" }
    func omitted(_ count: Int) -> [String] {
        count > 0 ? ["- … \(count) more server\(count == 1 ? "" : "s"); find their tools with searchTools()"] : []
    }
    func size(_ kept: Int) -> Int {
        ([intro] + Array(heads.prefix(kept)) + omitted(listed.count - kept)).joined(separator: "\n").utf16.count
    }
    var kept = listed.count
    while kept > 0 && size(kept) > MAX_SERVERS_SECTION_CHARS { kept -= 1 }
    let perServer = kept == 0 ? 0 : min(maxServerDescriptionChars, (MAX_SERVERS_SECTION_CHARS - size(kept)) / kept - 2)
    let lines = listed.prefix(kept).enumerated().map { index, server in
        let description = server.entry.config.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = description.isEmpty ? server.instructions ?? "" : description
        let summary = source.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text: String
        if perServer <= 0 { text = "" }
        else if summary.utf16.count <= perServer { text = summary }
        else if perServer <= 1 { text = "" }
        else {
            text = String(decoding: summary.utf16.prefix(perServer - 1), as: UTF16.self)
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "…"
        }
        return text.isEmpty ? heads[index] : "\(heads[index]): \(text)"
    }
    return ([intro] + lines + omitted(listed.count - kept)).joined(separator: "\n")
}

func mcpScriptNeedsServer(_ code: String, server: String) -> Bool {
    code.range(of: "\\b(searchTools|describeNamespace|describeTool|ALL_TOOLS)\\b", options: .regularExpression) != nil
        || code.contains(mcpNamespace(server))
}
