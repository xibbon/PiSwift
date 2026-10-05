import Foundation
import PiSwiftAgent

public let defaultCodemodeInlineBudget = 3_000.0

public struct CodemodeDescriptionOptions: Sendable {
    public var models: Bool
    public var namespaces: [String: ToolNamespace]
    public var deferred: Set<String>
    /// Nil includes every non-deferred tool, as in upstream's bare builder.
    public var inlineBudget: Double?
    /// Name shown for the script engine. C5b uses JavaScriptCore.
    public var sandboxName: String

    public init(models: Bool = false, namespaces: [String: ToolNamespace] = [:],
                deferred: Set<String> = [], inlineBudget: Double? = defaultCodemodeInlineBudget,
                sandboxName: String = "JavaScriptCore") {
        self.models = models
        self.namespaces = namespaces
        self.deferred = deferred
        self.inlineBudget = inlineBudget
        self.sandboxName = sandboxName
    }
}

/// The installed docs take precedence over the bundled mobile resource.
public var CODEMODE_DOCS_PATH: String {
    let installed = URL(fileURLWithPath: getDocsPath()).appendingPathComponent("codemode.md").path
    if FileManager.default.fileExists(atPath: installed) { return installed }
    return Bundle.module.url(forResource: "codemode", withExtension: "md")!.path
}

private func describeGlobals(models: Bool) -> String {
    var lines = [
        "Globals:",
        "- `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script. `image()` also saves the image to a temp file and the result names its path.",
        "- `store(key, value)` and `load(key)` keep JSON values across codemode calls.",
        "- `ALL_TOOLS`, `searchTools(query, { limit?, namespace? })`, `describeTool(name)`, `describeNamespace(name)`: find unlisted tools, such as MCP tools.",
    ]
    if models { lines.append("- `models`: classifiers and image generation. Read \(CODEMODE_DOCS_PATH) first.") }
    return lines.joined(separator: "\n")
}

private struct CatalogEntry {
    let name: String
    let section: String
    let cost: Int
    let order: Int
}

private struct CatalogGroup {
    let namespace: ToolNamespace?
    var entries: [CatalogEntry]
}

private func section(_ tool: CodemodeDeclaration) -> String {
    let id = toCodemodeIdentifier(tool.name)
    let heading = id == tool.name ? "### `\(id)`" : "### `\(id)` (`\(tool.name)`)"
    return heading + "\n" + renderToolSample(tool).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func selected(_ groups: [CatalogGroup], budget: Double?) -> Set<String> {
    let listable = groups.map(\.entries)
    guard let budget else { return Set(listable.flatMap { $0.map(\.name) }) }
    var queues = listable.map { $0.sorted { $0.cost == $1.cost ? $0.order < $1.order : $0.cost < $1.cost } }
    var active = queues.indices.filter { !queues[$0].isEmpty }
    var remaining = budget
    var shown = Set<String>()
    while !active.isEmpty {
        active = active.filter { index in
            let next = queues[index][0]
            if Double(next.cost) > remaining { return false }
            remaining -= Double(next.cost)
            shown.insert(next.name)
            queues[index].removeFirst()
            return !queues[index].isEmpty
        }
    }
    return shown
}

public func createCodemodeDescription(_ tools: [AgentTool], options: CodemodeDescriptionOptions = .init()) -> String {
    let declarations = tools.filter { $0.name != "codemode" && !options.deferred.contains($0.name) }.map(CodemodeDeclaration.init(tool:))
    var groups: [String: CatalogGroup] = ["": CatalogGroup(namespace: nil, entries: [])]
    for (order, declaration) in declarations.enumerated() {
        let namespace = options.namespaces[declaration.name]
        let key = namespace.map { "ns:\($0.name)" } ?? ""
        let rendered = section(declaration)
        if groups[key] == nil { groups[key] = CatalogGroup(namespace: namespace, entries: []) }
        groups[key]!.entries.append(CatalogEntry(name: declaration.name, section: rendered,
                                                  cost: (rendered.utf16.count + 3) / 4,
                                                  order: order))
    }
    let ordered = groups.values.sorted {
        switch ($0.namespace, $1.namespace) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let lhs?, let rhs?): return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }
    let shown = selected(ordered, budget: options.inlineBudget)
    let intro = codemodeDescriptionIntro.replacingOccurrences(of: "JavaScriptCore sandbox", with: "\(options.sandboxName) sandbox")
    var sections = [intro, describeGlobals(models: options.models)]
    if declarations.contains(where: { shown.contains($0.name) && mcpStructuredContentSchema($0.outputSchema) != nil }) {
        sections.append("Shared MCP Types:\n```ts\n\(mcpTypescriptPreamble)\n```")
    }
    if declarations.isEmpty { return sections.joined(separator: "\n\n") }
    var toolSections = ["Nested tools:"]
    for group in ordered {
        let visible = group.entries.filter { shown.contains($0.name) }
        if let namespace = group.namespace {
            let count = group.entries.count
            let suffix = visible.count == count ? "" : visible.isEmpty ? " (tools not listed)" : " (some tools not listed)"
            let description = namespace.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            toolSections.append("## \(namespace.name)\(suffix)" +
                                ((description?.isEmpty == false) ? "\n\(description!)" : ""))
        }
        toolSections += visible.map(\.section)
    }
    sections.append(toolSections.joined(separator: "\n\n"))
    return sections.joined(separator: "\n\n")
}
