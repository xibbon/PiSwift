import Foundation

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

private func loadContextFileFromDir(_ dir: String) -> ContextFile? {
    let candidates = ["AGENTS.md", "CLAUDE.md"]
    for filename in candidates {
        let filePath = URL(fileURLWithPath: dir).appendingPathComponent(filename).path
        if FileManager.default.fileExists(atPath: filePath) {
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
    var currentDir = resolvedCwd
    let root = URL(fileURLWithPath: "/").path

    while true {
        if let context = loadContextFileFromDir(currentDir), !seenPaths.contains(context.path) {
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
    public var selectedTools: [ToolName]?
    public var appendSystemPrompt: String?
    public var skillsSettings: SkillsSettings?
    public var cwd: String?
    public var agentDir: String?
    public var contextFiles: [ContextFile]?
    public var skills: [Skill]?

    public init(
        customPrompt: String? = nil,
        selectedTools: [ToolName]? = nil,
        appendSystemPrompt: String? = nil,
        skillsSettings: SkillsSettings? = nil,
        cwd: String? = nil,
        agentDir: String? = nil,
        contextFiles: [ContextFile]? = nil,
        skills: [Skill]? = nil
    ) {
        self.customPrompt = customPrompt
        self.selectedTools = selectedTools
        self.appendSystemPrompt = appendSystemPrompt
        self.skillsSettings = skillsSettings
        self.cwd = cwd
        self.agentDir = agentDir
        self.contextFiles = contextFiles
        self.skills = skills
    }
}

public func buildSystemPrompt(_ options: BuildSystemPromptOptions = BuildSystemPromptOptions()) -> String {
    let resolvedCwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let resolvedCustomPrompt = resolvePromptInput(options.customPrompt, "system prompt")
    let resolvedAppendPrompt = resolvePromptInput(options.appendSystemPrompt, "append system prompt")

    let appendSection = resolvedAppendPrompt.map { "\n\n\($0)" } ?? ""

    let contextFiles = options.contextFiles ?? loadProjectContextFiles(LoadContextFilesOptions(cwd: resolvedCwd, agentDir: options.agentDir))

    let skills: [Skill]
    if let provided = options.skills {
        skills = provided
    } else if options.skillsSettings?.enabled == false {
        skills = []
    } else {
        let settings = options.skillsSettings
        skills = loadSkills(LoadSkillsOptions(
            cwd: resolvedCwd,
            agentDir: options.agentDir,
            enableCodexUser: settings?.enableCodexUser,
            enableClaudeUser: settings?.enableClaudeUser,
            enableClaudeProject: settings?.enableClaudeProject,
            enablePiUser: settings?.enablePiUser,
            enablePiProject: settings?.enablePiProject,
            customDirectories: settings?.customDirectories,
            ignoredSkills: settings?.ignoredSkills,
            includeSkills: settings?.includeSkills
        )).skills
    }

    if let resolvedCustomPrompt {
        var prompt = resolvedCustomPrompt
        if !appendSection.isEmpty {
            prompt += appendSection
        }

        if !contextFiles.isEmpty {
            prompt += "\n\n# Project Context\n\n"
            prompt += "The following project context files have been loaded:\n\n"
            for file in contextFiles {
                prompt += "## \(file.path)\n\n\(file.content)\n\n"
            }
        }

        let includesRead = options.selectedTools == nil || (options.selectedTools?.contains(.read) ?? false)
        if includesRead && !skills.isEmpty {
            prompt += formatSkillsForPrompt(skills)
        }

        prompt += "\nCurrent working directory: \(resolvedCwd)"
        return prompt
    }

    let readmePath = getReadmePath()
    let docsPath = getDocsPath()
    let examplesPath = getExamplesPath()

    let tools = options.selectedTools ?? [.read, .bash, .edit, .write]
    let toolsList = tools.isEmpty ? "(none)" : tools.map { "- \($0.rawValue): \(toolDescriptions[$0] ?? "")" }.joined(separator: "\n")

    var guidelinesList: [String] = []

    let hasBash = tools.contains(.bash)
    let hasEdit = tools.contains(.edit)
    let hasWrite = tools.contains(.write)
    let hasGrep = tools.contains(.grep)
    let hasFind = tools.contains(.find)
    let hasLs = tools.contains(.ls)
    let hasRead = tools.contains(.read)

    if !hasBash && !hasEdit && !hasWrite {
        guidelinesList.append("You are in READ-ONLY mode - you cannot modify files or execute arbitrary commands")
    }

    if hasBash && !hasEdit && !hasWrite {
        guidelinesList.append("Use bash ONLY for read-only operations (git log, gh issue view, curl, etc.) - do NOT modify any files")
    }

    if hasBash && !hasGrep && !hasFind && !hasLs {
        guidelinesList.append("Use bash for file operations like ls, grep, find")
    } else if hasBash && (hasGrep || hasFind || hasLs) {
        guidelinesList.append("Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)")
    }

    if hasRead && hasEdit {
        guidelinesList.append("Use read to examine files before editing. You must use this tool instead of cat or sed.")
    }

    if hasEdit {
        guidelinesList.append("Use edit for precise changes (old text must match exactly)")
    }

    if hasWrite {
        guidelinesList.append("Use write only for new files or complete rewrites")
    }

    if hasEdit || hasWrite {
        guidelinesList.append("When summarizing your actions, output plain text directly - do NOT use cat or bash to display what you did")
    }

    guidelinesList.append("Be concise in your responses")
    guidelinesList.append("Show file paths clearly when working with files")

    let guidelines = guidelinesList.map { "- \($0)" }.joined(separator: "\n")

    var prompt = """
    You are an expert coding assistant. You help users with coding tasks by reading files, executing commands, editing code, and writing new files.

    Available tools:
    \(toolsList)

    Guidelines:
    \(guidelines)

    Documentation:
    - Main documentation: \(readmePath)
    - Additional docs: \(docsPath)
    - Examples: \(examplesPath) (hooks, custom tools, SDK)
    - When asked to create: custom models/providers (README.md), hooks (docs/hooks.md, examples/hooks/), custom tools (docs/custom-tools.md, docs/tui.md, examples/custom-tools/), themes (docs/theme.md), skills (docs/skills.md)
    - Always read the doc, examples, AND follow .md cross-references before implementing
    """

    if !appendSection.isEmpty {
        prompt += appendSection
    }

    if !contextFiles.isEmpty {
        prompt += "\n\n# Project Context\n\n"
        prompt += "The following project context files have been loaded:\n\n"
        for file in contextFiles {
            prompt += "## \(file.path)\n\n\(file.content)\n\n"
        }
    }

    if hasRead && !skills.isEmpty {
        prompt += formatSkillsForPrompt(skills)
    }

    prompt += "\nCurrent working directory: \(resolvedCwd)"

    return prompt
}
