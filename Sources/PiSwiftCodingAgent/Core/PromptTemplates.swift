import Foundation

public struct PromptTemplate: Sendable {
    public var name: String
    public var description: String
    public var content: String
    public var filePath: String
    /// v0.67.6: optional argument hint shown before the description in the autocomplete dropdown.
    /// Convention: `<required>` for required args, `[optional]` for optional.
    public var argumentHint: String?
    /// v0.62.0: structured provenance for autocomplete / RPC / SDK introspection.
    public var sourceInfo: SourceInfo

    public init(
        name: String,
        description: String,
        content: String,
        source: String,
        filePath: String,
        argumentHint: String? = nil
    ) {
        self.name = name
        self.description = description
        self.content = content
        self.filePath = filePath
        self.argumentHint = argumentHint
        self.sourceInfo = SourceInfo(
            path: filePath,
            source: source,
            scope: promptScopeFromSource(source)
        )
    }

    public init(
        name: String,
        description: String,
        content: String,
        filePath: String,
        sourceInfo: SourceInfo,
        argumentHint: String? = nil
    ) {
        self.name = name
        self.description = description
        self.content = content
        self.filePath = filePath
        self.argumentHint = argumentHint
        self.sourceInfo = sourceInfo
    }
}

private func promptScopeFromSource(_ source: String) -> String {
    switch source {
    case "user", "claude-user", "codex-user", "pi-user":
        return "user"
    case "project", "claude-project", "pi-project":
        return "project"
    case "package":
        return "package"
    case "core", "":
        return "core"
    default:
        return source
    }
}

private func normalizePromptPath(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "~" { return getHomeDir() }
    if trimmed.hasPrefix("~/") {
        return URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst(2))).path
    }
    if trimmed.hasPrefix("~") {
        return URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst())).path
    }
    return trimmed
}

private func resolvePromptPath(_ path: String, cwd: String) -> String {
    let normalized = normalizePromptPath(path)
    if normalized.hasPrefix("/") {
        return normalized
    }
    return URL(fileURLWithPath: cwd).appendingPathComponent(normalized).path
}

/// The shared frontmatter parser is intentionally permissive for skills. Prompt
/// templates follow upstream YAML's rejection of an unquoted colon-space scalar.
private func promptFrontmatterSyntaxError(_ content: String) -> String? {
    let lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first == "---" else { return nil }
    for (index, line) in lines.dropFirst().enumerated() {
        if line == "---" { break }
        if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        if !value.hasPrefix("\""), !value.hasPrefix("'"), value.contains(": ") {
            return "Invalid YAML frontmatter at line \(index + 1), column \(parts[0].count + 3)"
        }
    }
    return nil
}

private func loadTemplateFromFile(_ filePath: String, source: String, sourceLabel: String) -> (PromptTemplate?, [ResourceDiagnostic]) {
    guard let rawContent = try? String(contentsOfFile: filePath, encoding: .utf8) else {
        return (nil, [ResourceDiagnostic(type: "warning", message: "Failed to read prompt template", path: filePath)])
    }
    let parsed = parseFrontmatter(rawContent)
    if let parseError = parsed.parseError ?? promptFrontmatterSyntaxError(rawContent) {
        return (nil, [ResourceDiagnostic(type: "warning", message: parseError, path: filePath)])
    }
    let baseName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent

    var description = parsed.frontmatter["description"] ?? ""
    if description.isEmpty {
        if let firstLine = parsed.body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let line = String(firstLine)
            description = line.count > 60 ? String(line.prefix(60)) + "..." : line
        }
    }

    description = description.isEmpty ? sourceLabel : "\(description) \(sourceLabel)"

    return (PromptTemplate(
        name: baseName,
        description: description,
        content: parsed.body,
        source: source,
        filePath: filePath
    ), [])
}

private func resolveEntryType(_ entry: URL) -> (isDirectory: Bool, isFile: Bool)? {
    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
    let isSymlink = values?.isSymbolicLink ?? false
    if isSymlink {
        let resolved = entry.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return nil
        }
        return (isDirectory.boolValue, !isDirectory.boolValue)
    }

    return (values?.isDirectory ?? false, values?.isRegularFile ?? false)
}

private func loadTemplatesFromDir(_ dir: String, source: String, subdir: String = "") -> LoadPromptTemplatesResult {
    var templates: [PromptTemplate] = []
    var diagnostics: [ResourceDiagnostic] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: []
    ) else {
        return LoadPromptTemplatesResult(templates: templates, diagnostics: diagnostics)
    }

    for entry in entries {
        let name = entry.lastPathComponent
        guard let type = resolveEntryType(entry) else { continue }
        let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
        let subdirName = subdir.isEmpty ? name : "\(subdir):\(name)"

        if type.isDirectory {
            let nested = loadTemplatesFromDir(entry.path, source: source, subdir: subdirName)
            templates.append(contentsOf: nested.templates)
            diagnostics.append(contentsOf: nested.diagnostics)
            continue
        }

        guard type.isFile, entry.pathExtension.lowercased() == "md" else {
            continue
        }

        if !isSymlink && !FileManager.default.isReadableFile(atPath: entry.path) {
            continue
        }

        let sourceStr: String = {
            if source == "user" {
                return subdir.isEmpty ? "(user)" : "(user:\(subdir))"
            }
            return subdir.isEmpty ? "(project)" : "(project:\(subdir))"
        }()
        let (template, warnings) = loadTemplateFromFile(entry.path, source: source, sourceLabel: sourceStr)
        diagnostics.append(contentsOf: warnings)
        if let template {
            templates.append(template)
        }
    }

    return LoadPromptTemplatesResult(templates: templates, diagnostics: diagnostics)
}

public struct LoadPromptTemplatesResult: Sendable {
    public var templates: [PromptTemplate]
    public var diagnostics: [ResourceDiagnostic]

    public init(templates: [PromptTemplate], diagnostics: [ResourceDiagnostic]) {
        self.templates = templates
        self.diagnostics = diagnostics
    }
}

public struct LoadPromptTemplatesOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var promptPaths: [String]?
    public var includeDefaults: Bool?

    public init(cwd: String? = nil, agentDir: String? = nil, promptPaths: [String]? = nil, includeDefaults: Bool? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.promptPaths = promptPaths
        self.includeDefaults = includeDefaults
    }
}

public func loadPromptTemplates(_ options: LoadPromptTemplatesOptions = LoadPromptTemplatesOptions()) -> [PromptTemplate] {
    loadPromptTemplatesWithDiagnostics(options).templates
}

public func loadPromptTemplatesWithDiagnostics(_ options: LoadPromptTemplatesOptions = LoadPromptTemplatesOptions()) -> LoadPromptTemplatesResult {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getPromptsDir()
    let includeDefaults = options.includeDefaults ?? true

    var templates: [PromptTemplate] = []
    var diagnostics: [ResourceDiagnostic] = []

    func add(_ result: LoadPromptTemplatesResult) {
        templates.append(contentsOf: result.templates)
        diagnostics.append(contentsOf: result.diagnostics)
    }

    if includeDefaults {
        let globalPromptsDir = options.agentDir != nil
            ? URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("prompts").path
            : resolvedAgentDir
        add(loadTemplatesFromDir(globalPromptsDir, source: "user"))

        let projectPromptsDir = URL(fileURLWithPath: resolvedCwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("prompts").path
        add(loadTemplatesFromDir(projectPromptsDir, source: "project"))
    }

    if let promptPaths = options.promptPaths {
        for entry in promptPaths {
            let resolved = resolvePromptPath(entry, cwd: resolvedCwd)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                add(loadTemplatesFromDir(resolved, source: "path"))
            } else if resolved.lowercased().hasSuffix(".md") {
                let (template, warnings) = loadTemplateFromFile(resolved, source: "path", sourceLabel: "(path)")
                diagnostics.append(contentsOf: warnings)
                if let template { templates.append(template) }
            }
        }
    }

    return LoadPromptTemplatesResult(templates: templates, diagnostics: diagnostics)
}

public func expandPromptTemplate(_ text: String, _ templates: [PromptTemplate]) -> String {
    guard text.hasPrefix("/") else { return text }
    let spaceIndex = text.firstIndex(of: " ")
    let templateName: String
    let argsString: String
    if let spaceIndex {
        templateName = String(text[text.index(after: text.startIndex)..<spaceIndex])
        argsString = String(text[text.index(after: spaceIndex)...])
    } else {
        templateName = String(text.dropFirst())
        argsString = ""
    }

    if let template = templates.first(where: { $0.name == templateName }) {
        let args = parseCommandArgs(argsString)
        return substituteArgs(template.content, args)
    }

    return text
}
