import Foundation
import PiSwiftAgent

public let defaultCodemodeInlineBudget = 3_000.0

public struct CodemodeDescriptionOptions: Sendable {
    public var models: Bool
    public var namespaces: [String: ToolNamespace]
    public var deferred: Set<String>
    /// Nil includes every non-deferred tool, as in upstream's bare builder.
    public var inlineBudget: Double?
    /// C5b supplies this only where the runtime enforces the stated limit.
    public var memoryLimitSentence: String?
    /// Name shown for the script engine. C5b uses JavaScriptCore.
    public var sandboxName: String

    public init(models: Bool = false, namespaces: [String: ToolNamespace] = [:],
                deferred: Set<String> = [], inlineBudget: Double? = defaultCodemodeInlineBudget,
                memoryLimitSentence: String? = nil, sandboxName: String = "JavaScriptCore") {
        self.models = models
        self.namespaces = namespaces
        self.deferred = deferred
        self.inlineBudget = inlineBudget
        self.memoryLimitSentence = memoryLimitSentence
        self.sandboxName = sandboxName
    }
}

private let upstreamMemorySentence = "- Scripts have a 256 MB memory limit; exceeding it throws `InternalError: out of memory`. Filter or aggregate large data instead of accumulating it."

private let modelGlobals: [CodemodeDeclaration] = [
    .init(name: "models.getModelsOfType", description: "Every known model of a type, optionally for one provider.",
          signature: "(type: ModelType, provider?: string): Promise<ModelInfo[]>"),
    .init(name: "models.getAvailableOfType", description: "Models of a type whose provider has working credentials.",
          signature: "(type: ModelType, provider?: string): Promise<ModelInfo[]>"),
    .init(name: "models.getModelOfType", description: "One catalog entry, or undefined.",
          signature: "(type: ModelType, provider: string, id: string): Promise<ModelInfo | undefined>"),
    .init(name: "models.classify", description: "Run a classifier model on one state. Only `provider` and `id` of `model` are used. Provider errors do not throw: check `stopReason` and `errorMessage`.",
          signature: "(model: ModelInfo, context: ClassifierContext): Promise<ClassifierResult>")
]

private struct CatalogEntry {
    let name: String
    let section: String
    let cost: Int
    let deferred: Bool
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
    let listable = groups.map { $0.entries.filter { !$0.deferred } }
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
    let declarations = tools.filter { $0.name != "codemode" }.map(CodemodeDeclaration.init(tool:))
    var groups: [String: CatalogGroup] = ["": CatalogGroup(namespace: nil, entries: [])]
    for (order, declaration) in declarations.enumerated() {
        let namespace = options.namespaces[declaration.name]
        let key = namespace.map { "ns:\($0.name)" } ?? ""
        let rendered = section(declaration)
        if groups[key] == nil { groups[key] = CatalogGroup(namespace: namespace, entries: []) }
        groups[key]!.entries.append(CatalogEntry(name: declaration.name, section: rendered,
                                                  cost: (rendered.utf16.count + 3) / 4,
                                                  deferred: options.deferred.contains(declaration.name), order: order))
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
    let complete = shown.count == declarations.count
    var intro = codemodeDescriptionIntro
    intro = intro.replacingOccurrences(of: "fresh QuickJS sandbox", with: "fresh \(options.sandboxName) sandbox")
    intro = intro.replacingOccurrences(of: upstreamMemorySentence + "\n",
                                        with: options.memoryLimitSentence.map { "- " + $0 + "\n" } ?? "")
    var sections = [intro]
    if !complete { sections.append(codemodeDeferredGuidance) }
    if declarations.contains(where: { mcpStructuredContentSchema($0.outputSchema) != nil }) {
        sections.append("Shared MCP Types:\n```ts\n\(mcpTypescriptPreamble)\n```")
    }
    if options.models {
        sections.append("Model API:\n```ts\n\(codemodeModelTypes)\n\n\(renderDeclarations(globals: modelGlobals))\n```")
    }
    if declarations.isEmpty { return sections.joined(separator: "\n\n") }
    var toolSections = [complete
        ? "Nested tools: COMPLETE list (\(declarations.count) tool\(declarations.count == 1 ? "" : "s"))."
        : "Nested tools: PARTIAL - \(shown.count) of \(declarations.count) shown."]
    for group in ordered {
        let visible = group.entries.filter { shown.contains($0.name) }
        if let namespace = group.namespace {
            let count = group.entries.count
            let suffix = visible.count == count ? "" : visible.isEmpty ? ", none shown" : ", \(visible.count) shown"
            let description = namespace.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            toolSections.append("## \(namespace.name) (\(count) tool\(count == 1 ? "" : "s")\(suffix))" +
                                ((description?.isEmpty == false) ? "\n\(description!)" : ""))
        }
        toolSections += visible.map(\.section)
    }
    sections.append(toolSections.joined(separator: "\n\n"))
    return sections.joined(separator: "\n\n")
}
