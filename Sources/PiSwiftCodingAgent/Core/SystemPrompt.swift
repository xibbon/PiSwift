import Foundation
import PiSwiftAI

public struct ContextFile: Sendable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

public struct LoadContextFilesOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?

    public init(cwd: String? = nil, agentDir: String? = nil) {
        self.cwd = cwd
        self.agentDir = agentDir
    }
}

private let toolDescriptions: [ToolName: String] = [
    .read: "Read file contents",
    .bash: "Execute bash commands (ls, grep, find, etc.)",
    .edit: "Make surgical edits to files (find exact text and replace)",
    .write: "Create or overwrite files",
    .grep: "Search file contents for patterns (respects .gitignore)",
    .find: "Find files by glob pattern (respects .gitignore)",
    .ls: "List directory contents",
    .subagent: "Delegate tasks to specialized subagents with isolated context",
]

public func resolvePromptInput(_ input: String?, _ description: String) -> String? {
    guard let input, !input.isEmpty else { return nil }
    if FileManager.default.fileExists(atPath: input) {
        do {
            return try String(contentsOfFile: input, encoding: .utf8)
        } catch {
            print("Warning: Could not read \(description) file \(input): \(error)")
            return input
        }
    }
    return input
}

private func isRegularContextFile(_ path: String) -> Bool {
    let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true
}

private func loadContextFileFromDir(_ dir: String) -> ContextFile? {
    let candidates = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
    for filename in candidates {
        let filePath = URL(fileURLWithPath: dir).appendingPathComponent(filename).path
        if isRegularContextFile(filePath) {
            do {
                let content = try String(contentsOfFile: filePath, encoding: .utf8)
                return ContextFile(path: filePath, content: content)
            } catch {
                print("Warning: Could not read \(filePath): \(error)")
            }
        }
    }
    return nil
}

private struct ContextGitPaths {
    var repoDir: String
    var commonGitDir: String
}

private func canonicalContextPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
}

/// Finds the checkout root and common Git directory for regular repositories and linked worktrees.
private func findContextGitPaths(_ cwd: String) -> ContextGitPaths? {
    var dir = URL(fileURLWithPath: cwd).standardized.path

    while true {
        let gitURL = URL(fileURLWithPath: dir).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let head = gitURL.appendingPathComponent("HEAD").path
                guard FileManager.default.fileExists(atPath: head) else { return nil }
                return ContextGitPaths(repoDir: dir, commonGitDir: gitURL.path)
            }

            guard let content = try? String(contentsOf: gitURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                content.hasPrefix("gitdir: ") else {
                return nil
            }
            let gitDirText = String(content.dropFirst("gitdir: ".count))
            let gitDir = URL(fileURLWithPath: gitDirText, relativeTo: URL(fileURLWithPath: dir, isDirectory: true))
                .standardized.path
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD").path) else {
                return nil
            }
            let commonDirFile = URL(fileURLWithPath: gitDir).appendingPathComponent("commondir")
            let commonGitDir: String
            if let commonDirText = try? String(contentsOf: commonDirFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !commonDirText.isEmpty {
                commonGitDir = URL(fileURLWithPath: commonDirText, relativeTo: URL(fileURLWithPath: gitDir, isDirectory: true))
                    .standardized.path
            } else {
                commonGitDir = gitDir
            }
            return ContextGitPaths(repoDir: dir, commonGitDir: commonGitDir)
        }

        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        if parent == dir { return nil }
        dir = parent
    }
}

/// Returns the main checkout context file shadowed by a nested linked worktree.
private func findShadowedContextFile(_ cwd: String) -> String? {
    guard let gitPaths = findContextGitPaths(cwd) else { return nil }
    let commonGitDir = canonicalContextPath(gitPaths.commonGitDir)
    let worktreeRoot = canonicalContextPath(gitPaths.repoDir)
    let mainRepoRoot = URL(fileURLWithPath: commonGitDir).deletingLastPathComponent().path
    let mainPrefix = mainRepoRoot.hasSuffix("/") ? mainRepoRoot : mainRepoRoot + "/"

    guard worktreeRoot.hasPrefix(mainPrefix) else { return nil }
    guard canonicalContextPath(URL(fileURLWithPath: mainRepoRoot).appendingPathComponent(".git").path) == commonGitDir else {
        return nil
    }
    guard let worktreeContext = loadContextFileFromDir(worktreeRoot) else { return nil }
    return URL(fileURLWithPath: mainRepoRoot)
        .appendingPathComponent(URL(fileURLWithPath: worktreeContext.path).lastPathComponent)
        .path
}

public func loadProjectContextFiles(_ options: LoadContextFilesOptions = LoadContextFilesOptions()) -> [ContextFile] {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedAgentDir = options.agentDir ?? getAgentDir()

    var contextFiles: [ContextFile] = []
    var seenPaths: Set<String> = []

    if let globalContext = loadContextFileFromDir(resolvedAgentDir) {
        contextFiles.append(globalContext)
        seenPaths.insert(globalContext.path)
    }

    var ancestorFiles: [ContextFile] = []
    let shadowedContextPath = findShadowedContextFile(resolvedCwd).map(canonicalContextPath)
    var currentDir = resolvedCwd
    let root = URL(fileURLWithPath: "/").path

    while true {
        if let context = loadContextFileFromDir(currentDir),
           canonicalContextPath(context.path) != shadowedContextPath,
           !seenPaths.contains(context.path) {
            ancestorFiles.insert(context, at: 0)
            seenPaths.insert(context.path)
        }

        if currentDir == root { break }
        let parent = URL(fileURLWithPath: currentDir).deletingLastPathComponent().path
        if parent == currentDir { break }
        currentDir = parent
    }

    contextFiles.append(contentsOf: ancestorFiles)
    return contextFiles
}

public struct BuildSystemPromptOptions: Sendable {
    public var customPrompt: String?
    public var forceSystemPrompt: String?
    public var selectedTools: [ToolName]?
    public var selectedToolNames: [String]?
    public var toolSnippets: [String: String]?
    public var toolGuidelines: [String: [String]]?
    public var promptGuidelines: [String]?
    public var sections: SystemPromptSections?
    public var appendSystemPrompt: String?
    public var skillsSettings: SkillsSettings?
    public var cwd: String?
    public var agentDir: String?
    public var contextFiles: [ContextFile]?
    public var skills: [Skill]?
    /// Selected tools whose declarations, rules, and named skills hint are hidden.
    public var hiddenTools: [String]?

    public init(
        customPrompt: String? = nil,
        selectedTools: [ToolName]? = nil,
        selectedToolNames: [String]? = nil,
        appendSystemPrompt: String? = nil,
        skillsSettings: SkillsSettings? = nil,
        cwd: String? = nil,
        agentDir: String? = nil,
        contextFiles: [ContextFile]? = nil,
        skills: [Skill]? = nil,
        forceSystemPrompt: String? = nil,
        toolSnippets: [String: String]? = nil,
        toolGuidelines: [String: [String]]? = nil,
        promptGuidelines: [String]? = nil,
        sections: SystemPromptSections? = nil,
        hiddenTools: [String]? = nil
    ) {
        self.customPrompt = customPrompt
        self.forceSystemPrompt = forceSystemPrompt
        self.selectedTools = selectedTools
        self.selectedToolNames = selectedToolNames
        self.toolSnippets = toolSnippets
        self.toolGuidelines = toolGuidelines
        self.promptGuidelines = promptGuidelines
        self.sections = sections
        self.appendSystemPrompt = appendSystemPrompt
        self.skillsSettings = skillsSettings
        self.cwd = cwd
        self.agentDir = agentDir
        self.contextFiles = contextFiles
        self.skills = skills
        self.hiddenTools = hiddenTools?.sorted()
    }
}

public func isValidSystemPromptSectionName(_ name: String) -> Bool {
    guard name != "preamble", let first = name.first, first >= "a", first <= "z" else { return false }
    return name.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-" }
}

public enum SystemPromptError: Error, LocalizedError, Sendable, Equatable {
    case invalidSectionName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSectionName(let name): "Invalid system prompt section name: \(name)"
        }
    }
}

/// Use the whitespace set specified by ECMAScript String.prototype.trim.
private func trimSystemPromptText(_ text: String) -> String {
    func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
    let scalars = text.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    while start < end, isWhitespace(scalars[start]) { scalars.formIndex(after: &start) }
    while start < end {
        let previous = scalars.index(before: end)
        guard isWhitespace(scalars[previous]) else { break }
        end = previous
    }
    return String(scalars[start..<end])
}

private func systemPromptRules(_ names: [String], _ options: BuildSystemPromptOptions) -> String {
    var rules: [String] = []
    var seen: Set<[UInt16]> = []
    func add(_ rule: String) {
        let value = trimSystemPromptText(rule)
        if !value.isEmpty && seen.insert(Array(value.utf16)).inserted { rules.append(value) }
    }
    let hasBash = names.contains("bash")
    let hasPowerShell = names.contains("powershell")
    if (hasBash || hasPowerShell) && !names.contains("grep") && !names.contains("find") && !names.contains("ls") {
        add(hasBash && hasPowerShell ? "Use bash or PowerShell for file operations like listing, searching, and finding files" :
            hasPowerShell ? "Use PowerShell for file operations like listing, searching, and finding files" :
            "Use bash for file operations like ls, rg, find")
    }
    for name in names { for rule in options.toolGuidelines?[name] ?? [] { add(rule) } }
    for rule in options.promptGuidelines ?? [] { add(rule) }
    add("Be concise in your responses")
    add("Show file paths clearly when working with files")
    return rules.map { "- \($0)" }.joined(separator: "\n")
}

/// Ordered sections replayed by the transcript codec. The preamble has no XML wrapper.
public func buildSystemPromptSections(_ options: BuildSystemPromptOptions = BuildSystemPromptOptions()) throws -> SystemPromptSections {
    for entry in options.sections?.entries ?? [] {
        guard isValidSystemPromptSectionName(entry.name) else { throw SystemPromptError.invalidSectionName(entry.name) }
    }
    let cwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let tools = options.selectedToolNames ?? (options.selectedTools ?? [.read, .bash, .edit, .write]).map(\.rawValue)
    let hidden = Set(options.hiddenTools ?? [])
    let declared = tools.filter { !hidden.contains($0) }
    let snippets = options.toolSnippets ?? [:]
    let custom = options.customPrompt
    var entries: [(name: String, value: String?)] = []
    func add(_ name: String, _ value: String) { entries.append((name: name, value: name == "preamble" ? value : "<\(name)>\n\(value)\n</\(name)>")) }
    if let custom, !custom.isEmpty {
        add("preamble", custom)
    } else {
        add("preamble", "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.")
        let visible = declared.filter { !(snippets[$0] ?? "").isEmpty }
        let list = visible.isEmpty ? "(none)" : visible.map { "- \($0): \(snippets[$0]!)" }.joined(separator: "\n")
        add("tools", "\(list)\n\nIn addition to the tools above, you may have access to other custom tools depending on the project.")
        add("rules", systemPromptRules(declared, options))
        // Keep the Codemode reference accepted in PORT_SYNC_NOTES.md (v1.0.0).
        add("docs", """
        Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
        - Main documentation: \(getReadmePath())
        - Additional docs: \(getDocsPath())
        - Examples: \(getExamplesPath()) (extensions, custom tools, SDK)
        - When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
        - When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md), MCP servers (docs/mcp.md), codemode scripts and non-LLM models such as classifiers and image models (docs/codemode.md)
        - Codemode script reference: \(CODEMODE_DOCS_PATH)
        - When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
        - Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
        """)
    }
    if let append = options.appendSystemPrompt, !append.isEmpty { add("addendum", append) }
    let contextFiles = options.contextFiles ?? []
    if !contextFiles.isEmpty {
        let files = contextFiles.map { "<project_instructions path=\"\($0.path)\">\n\($0.content)\n</project_instructions>" }
        add("project_context", (["Project-specific instructions and guidelines:"] + files).joined(separator: "\n\n"))
    }
    let skills = options.skills ?? []
    let reader: SkillFileReadTool? = declared.contains("read") ? .read :
        (declared.contains("bash") ? .bash : (tools.contains("read") || tools.contains("bash") ? .indirect : nil))
    if let reader, !skills.isEmpty {
        let value = trimSystemPromptText(formatSkillsForPrompt(skills, fileReadTool: reader))
        if !value.isEmpty { add("skills", value) }
    }
    add("cwd", cwd.replacingOccurrences(of: "\\", with: "/"))
    for entry in options.sections?.entries ?? [] {
        if let value = entry.value, !value.isEmpty { add(entry.name, value) }
    }
    return SystemPromptSections(entries)
}

public func buildSystemPromptState(_ options: BuildSystemPromptOptions = BuildSystemPromptOptions()) throws -> SystemMessage {
    if let forced = options.forceSystemPrompt { return SystemMessage(content: .text(forced), timestamp: 0) }
    return SystemMessage(content: .text(""), sections: try buildSystemPromptSections(options), timestamp: 0)
}

public func buildSystemPrompt(_ options: BuildSystemPromptOptions = BuildSystemPromptOptions()) throws -> String {
    getSystemMessageText(try buildSystemPromptState(options))
}

public func diffSystemPromptSections(_ previous: SystemPromptSections?, _ current: SystemPromptSections) -> SystemPromptSections? {
    var changes: [(name: String, value: String?)] = []
    for entry in current.entries where previous?[entry.name] != entry.value { changes.append((entry.name, entry.value)) }
    for entry in previous?.entries ?? [] where current.entries.allSatisfy({ $0.name != entry.name }) { changes.append((entry.name, nil)) }
    return changes.isEmpty ? nil : SystemPromptSections(changes)
}
