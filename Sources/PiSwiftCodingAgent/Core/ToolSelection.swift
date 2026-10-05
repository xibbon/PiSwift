/// Matches complete tool names. Only `*` has a special meaning: it matches
/// any number of characters, including zero. All other characters are literal.
public struct ToolNameMatcher: Sendable, Equatable {
    private struct Pattern: Sendable, Equatable {
        let segments: [[UInt8]]

        init(_ entry: [UInt8]) {
            segments = entry.split(separator: 42, omittingEmptySubsequences: false).map(Array.init)
        }

        func matches(_ name: String) -> Bool {
            let bytes = Array(name.utf8)
            guard let first = segments.first, bytes.starts(with: first) else { return false }
            var cursor = first.count
            for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
                guard segment.count <= bytes.count - cursor else { return false }
                var start = cursor
                while start <= bytes.count - segment.count,
                      !bytes[start...].starts(with: segment) { start += 1 }
                guard start <= bytes.count - segment.count else { return false }
                cursor = start + segment.count
            }
            let last = segments.last ?? []
            return last.count <= bytes.count - cursor && bytes.suffix(last.count).elementsEqual(last)
        }
    }

    private let names: Set<String>
    private let patterns: [Pattern]

    public init(_ entries: [String]) {
        names = Set(entries.filter { !$0.utf8.contains(42) })
        patterns = Set(entries.map { Array($0.utf8) }.filter { $0.contains(42) })
            .sorted { $0.lexicographicallyPrecedes($1) }.map(Pattern.init)
    }

    public func matches(_ name: String) -> Bool {
        names.contains(name) || patterns.contains { $0.matches(name) }
    }
}

/// MCP resource tools that can access resources from all servers.
public let LIST_MCP_RESOURCES_TOOL = "list_mcp_resources"
public let LIST_MCP_RESOURCE_TEMPLATES_TOOL = "list_mcp_resource_templates"
public let READ_MCP_RESOURCE_TOOL = "read_mcp_resource"

/// Returns true for an MCP server tool or one of the three MCP resource tools.
public func isMcpToolName(_ name: String) -> Bool {
    name.hasPrefix("mcp__") || name == LIST_MCP_RESOURCES_TOOL ||
        name == LIST_MCP_RESOURCE_TEMPLATES_TOOL || name == READ_MCP_RESOURCE_TOOL
}

/// Tool metadata used to select the first registry and active tool set.
public struct InitialToolRegistration: Sendable, Equatable {
    public var name: String
    public var isBuiltin: Bool
    public var exposure: ToolExposure
    public var defaultActive: Bool

    public init(name: String, isBuiltin: Bool = false, exposure: ToolExposure = .direct,
                defaultActive: Bool = true) {
        self.name = name
        self.isBuiltin = isBuiltin
        self.exposure = exposure
        self.defaultActive = defaultActive
    }
}

public struct InitialToolSelection: Sendable, Equatable {
    public var registeredToolNames: [String]
    public var activeToolNames: [String]
}

/// Selects the first tool registry and active set for SDK and CLI hosts.
///
/// Supply all registered names, including every built-in name. Patterns in
/// `toolNames` and `excludeTools` expand against those names. An explicit
/// allowlist keeps unnamed MCP tools registered unless it is empty or an entry
/// starts with `mcp__`. Unnamed MCP tools start inactive. Exclusions apply last.
/// `defaultToolNames` supplies the resolved default setting, or the standard
/// built-in names. Extension and custom tools use their exposure and
/// `defaultActive` when no allowlist is set. An explicit match activates a
/// declarable tool even when `defaultActive` is false. Exact names can also
/// select non-hidden indirect tools. Exact names keep their input order; pattern
/// matches are added in registry order.
///
/// A host that builds its own `AgentSessionConfig` must filter its registry with
/// `registeredToolNames`, set the agent's first tools from `activeToolNames`,
/// and pass `allowedToolNames: toolNames.map(Set.init) ?? (noTools == .all ? [] : nil)`
/// and `excludedToolNames: Set(excludeTools)` to the session. Set
/// `usesDefaultTools` to `toolNames == nil && noTools == nil`. The session applies
/// the same rules to tools registered later and to restored tool loadouts.
public func selectInitialTools(
    registeredTools: [InitialToolRegistration],
    toolNames: [String]? = nil,
    excludeTools: [String] = [],
    noTools: NoToolsMode? = nil,
    defaultToolNames: [String]
) -> InitialToolSelection {
    let allowed = toolNames.map(ToolNameMatcher.init)
    let excluded = ToolNameMatcher(excludeTools)
    let filtersMcp = toolNames.map { $0.isEmpty || $0.contains { $0.hasPrefix("mcp__") } } ?? false
    var seen: Set<String> = []
    let registered = registeredTools.filter { tool in
        guard seen.insert(tool.name).inserted, !excluded.matches(tool.name) else { return false }
        if let allowed {
            return allowed.matches(tool.name) || (!filtersMcp && isMcpToolName(tool.name))
        }
        return noTools != .all
    }
    let defaults = Set(defaultToolNames)
    let exactSelections = Set(toolNames ?? [])
    let active = registered.filter { tool in
        guard tool.exposure != .hidden else { return false }
        if let allowed {
            return exactSelections.contains(tool.name) ||
                (allowed.matches(tool.name) && (tool.exposure == .direct || tool.exposure == .modelOnly))
        }
        if tool.isBuiltin { return noTools == nil && defaults.contains(tool.name) }
        if noTools == nil && defaults.contains(tool.name) { return true }
        return (tool.exposure == .direct || tool.exposure == .modelOnly) && tool.defaultActive
    }
    let activeNames = Set(active.map(\.name))
    let firstNames = toolNames ?? (noTools == nil ? defaultToolNames : [])
    var seenActive: Set<String> = []
    let orderedActive = (firstNames + active.map(\.name)).filter {
        activeNames.contains($0) && seenActive.insert($0).inserted
    }
    return InitialToolSelection(registeredToolNames: registered.map(\.name), activeToolNames: orderedActive)
}
