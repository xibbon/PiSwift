import Foundation

public let MAX_SKILL_NAME_LENGTH = 64
public let MAX_SKILL_DESCRIPTION_LENGTH = 1024

private let allowedFrontmatterFields: Set<String> = [
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
    "disable-model-invocation",
]

public struct Skill: Sendable {
    public var name: String
    public var description: String
    public var filePath: String
    public var baseDir: String
    public var disableModelInvocation: Bool
    /// v0.62.0: structured provenance for autocomplete / RPC / SDK introspection.
    public var sourceInfo: SourceInfo

    public init(
        name: String,
        description: String,
        filePath: String,
        baseDir: String,
        source: String,
        disableModelInvocation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.filePath = filePath
        self.baseDir = baseDir
        self.disableModelInvocation = disableModelInvocation
        self.sourceInfo = SourceInfo(
            path: filePath,
            source: source,
            scope: skillScopeFromSource(source),
            baseDir: baseDir
        )
    }

    public init(
        name: String,
        description: String,
        filePath: String,
        baseDir: String,
        sourceInfo: SourceInfo,
        disableModelInvocation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.filePath = filePath
        self.baseDir = baseDir
        self.disableModelInvocation = disableModelInvocation
        self.sourceInfo = sourceInfo
    }
}

/// Map the legacy `source` string to the upstream `scope` taxonomy ("user" / "project" / "package" / "core").
private func skillScopeFromSource(_ source: String) -> String {
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

public struct SkillWarning: Sendable {
    public var skillPath: String
    public var message: String

    public init(skillPath: String, message: String) {
        self.skillPath = skillPath
        self.message = message
    }
}

public struct LoadSkillsResult: Sendable {
    public var skills: [Skill]
    public var warnings: [SkillWarning]
}

public struct LoadSkillsFromDirOptions: Sendable {
    public var dir: String
    public var source: String

    public init(dir: String, source: String) {
        self.dir = dir
        self.source = source
    }
}

public struct LoadSkillsOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var enableCodexUser: Bool?
    public var enableClaudeUser: Bool?
    public var enableClaudeProject: Bool?
    public var enablePiUser: Bool?
    public var enablePiProject: Bool?
    public var customDirectories: [String]?
    public var ignoredSkills: [String]?
    public var includeSkills: [String]?

    public init(
        cwd: String? = nil,
        agentDir: String? = nil,
        enableCodexUser: Bool? = nil,
        enableClaudeUser: Bool? = nil,
        enableClaudeProject: Bool? = nil,
        enablePiUser: Bool? = nil,
        enablePiProject: Bool? = nil,
        customDirectories: [String]? = nil,
        ignoredSkills: [String]? = nil,
        includeSkills: [String]? = nil
    ) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.enableCodexUser = enableCodexUser
        self.enableClaudeUser = enableClaudeUser
        self.enableClaudeProject = enableClaudeProject
        self.enablePiUser = enablePiUser
        self.enablePiProject = enablePiProject
        self.customDirectories = customDirectories
        self.ignoredSkills = ignoredSkills
        self.includeSkills = includeSkills
    }
}

private func validateName(_ name: String, parentDirName: String) -> [String] {
    var errors: [String] = []
    if name != parentDirName {
        errors.append("name \"\(name)\" does not match parent directory \"\(parentDirName)\"")
    }
    if name.count > MAX_SKILL_NAME_LENGTH {
        errors.append("name exceeds \(MAX_SKILL_NAME_LENGTH) characters (\(name.count))")
    }
    let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    if name.rangeOfCharacter(from: validChars.inverted) != nil {
        errors.append("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)")
    }
    if name.hasPrefix("-") || name.hasSuffix("-") {
        errors.append("name must not start or end with a hyphen")
    }
    if name.contains("--") {
        errors.append("name must not contain consecutive hyphens")
    }
    return errors
}

private func validateDescription(_ description: String?) -> [String] {
    guard let description else { return ["description is required"] }
    if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ["description is required"]
    }
    if description.count > MAX_SKILL_DESCRIPTION_LENGTH {
        return ["description exceeds \(MAX_SKILL_DESCRIPTION_LENGTH) characters (\(description.count))"]
    }
    return []
}

private func validateFrontmatterFields(_ keys: [String]) -> [String] {
    keys.compactMap { key in
        allowedFrontmatterFields.contains(key) ? nil : "unknown frontmatter field \"\(key)\""
    }
}

func loadSkillFromFile(_ filePath: String, source: String) -> (skill: Skill?, warnings: [SkillWarning]) {
    var warnings: [SkillWarning] = []
    let content: String
    do {
        content = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
        return (nil, [SkillWarning(skillPath: filePath, message: error.localizedDescription)])
    }

    let isDeclaredSkill = URL(fileURLWithPath: filePath).lastPathComponent == "SKILL.md"
    let parsed = parseFrontmatter(content)
    if let error = parsed.parseError {
        return (nil, isDeclaredSkill ? [SkillWarning(skillPath: filePath, message: error)] : [])
    }
    let skillDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
    let parentDirName = URL(fileURLWithPath: skillDir).lastPathComponent
    let declaredName = parsed.nonStringKeys.contains("name") ? nil : parsed.frontmatter["name"]
    let name = declaredName.flatMap { $0.isEmpty ? nil : $0 } ?? parentDirName
    let description = parsed.nonStringKeys.contains("description") ? nil : parsed.frontmatter["description"]
    if !isDeclaredSkill && (description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
        return (nil, [])
    }
    let disableModelInvocation = parsed.frontmatter["disable-model-invocation"]?.lowercased() == "true"

    for error in validateFrontmatterFields(parsed.keys) {
        warnings.append(SkillWarning(skillPath: filePath, message: error))
    }
    for error in validateDescription(description) {
        warnings.append(SkillWarning(skillPath: filePath, message: error))
    }
    for error in validateName(name, parentDirName: parentDirName) {
        warnings.append(SkillWarning(skillPath: filePath, message: error))
    }

    guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (nil, warnings)
    }

    let skill = Skill(
        name: name,
        description: description,
        filePath: filePath,
        baseDir: skillDir,
        source: source,
        disableModelInvocation: disableModelInvocation
    )
    return (skill, warnings)
}

public func loadSkillsFromDir(options: LoadSkillsFromDirOptions) -> LoadSkillsResult {
    loadSkillsFromDirInternal(dir: options.dir, source: options.source, includeRootFiles: true)
}

private func loadSkillsFromDirInternal(dir: String, source: String, includeRootFiles: Bool) -> LoadSkillsResult {
    guard FileManager.default.fileExists(atPath: dir) else {
        return LoadSkillsResult(skills: [], warnings: [])
    }

    var skills: [Skill] = []
    var warnings: [SkillWarning] = []

    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: []
    ) else {
        return LoadSkillsResult(skills: [], warnings: [])
    }

    // v0.63.1: if this directory contains a SKILL.md, treat the entire directory as one skill
    // and DO NOT recurse into subdirectories. This prevents nested SKILL.md from being picked
    // up as separate skills under a top-level skill.
    let hasSkillMdAtRoot = entries.contains { $0.lastPathComponent == "SKILL.md" }

    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") { continue }
        if name == "node_modules" { continue }

        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        let isSymlink = values?.isSymbolicLink ?? false
        var isDir = values?.isDirectory ?? false
        var isFile = values?.isRegularFile ?? false

        if isSymlink {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &dirFlag) {
                isDir = dirFlag.boolValue
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }

        if isDir {
            // v0.63.1: don't recurse if the parent directory already declared itself a skill.
            if hasSkillMdAtRoot { continue }
            let sub = loadSkillsFromDirInternal(dir: entry.path, source: source, includeRootFiles: false)
            skills.append(contentsOf: sub.skills)
            warnings.append(contentsOf: sub.warnings)
            continue
        }

        guard isFile else { continue }
        let isRootMd = includeRootFiles && name.hasSuffix(".md")
        let isSkillMd = !includeRootFiles && name == "SKILL.md"
        // v0.63.1: also pick up SKILL.md at the root when this directory itself is a skill.
        let isRootSkillMd = includeRootFiles && hasSkillMdAtRoot && name == "SKILL.md"
        guard isRootMd || isSkillMd || isRootSkillMd else { continue }

        let result = loadSkillFromFile(entry.path, source: source)
        if let skill = result.skill {
            skills.append(skill)
        }
        warnings.append(contentsOf: result.warnings)
    }

    return LoadSkillsResult(skills: skills, warnings: warnings)
}

public enum SkillFileReadTool: String, Sendable {
    case read
    case bash
}

public func formatSkillsForPrompt(_ skills: [Skill], fileReadTool: SkillFileReadTool = .read) -> String {
    let visible = skills.filter { !$0.disableModelInvocation }
    guard !visible.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("\n\nThe following skills provide specialized instructions for specific tasks.")
    lines.append(fileReadTool == .read
        ? "Use the read tool to load a skill's file when the task matches its description."
        : "Use bash to load a skill's file when the task matches its description.")
    lines.append("")
    lines.append("<available_skills>")
    for skill in visible {
        lines.append("  <skill>")
        lines.append("    <name>\(escapeXml(skill.name))</name>")
        lines.append("    <description>\(escapeXml(skill.description))</description>")
        lines.append("    <location>\(escapeXml(skill.filePath))</location>")
        lines.append("  </skill>")
    }
    lines.append("</available_skills>")
    return lines.joined(separator: "\n")
}

private func escapeXml(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

public func loadSkills(_ options: LoadSkillsOptions = LoadSkillsOptions()) -> LoadSkillsResult {
    let cwd = options.cwd ?? FileManager.default.currentDirectoryPath
    let agentDir = options.agentDir ?? getAgentDir()

    let enableCodexUser = options.enableCodexUser ?? true
    let enableClaudeUser = options.enableClaudeUser ?? true
    let enableClaudeProject = options.enableClaudeProject ?? true
    let enablePiUser = options.enablePiUser ?? true
    let enablePiProject = options.enablePiProject ?? true

    let ignored = options.ignoredSkills ?? []
    let include = options.includeSkills ?? []

    var skills: [Skill] = []
    var warnings: [SkillWarning] = []
    var seenNames: [String: Skill] = [:]

    func matchesPatterns(_ name: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        for pattern in patterns {
            if matchesGlob(name, pattern) {
                return true
            }
        }
        return false
    }

    func shouldIgnore(_ name: String) -> Bool {
        guard !ignored.isEmpty else { return false }
        for pattern in ignored {
            if matchesGlob(name, pattern) {
                return true
            }
        }
        return false
    }

    func addSkills(from result: LoadSkillsResult) {
        warnings.append(contentsOf: result.warnings)
        for skill in result.skills {
            if shouldIgnore(skill.name) {
                continue
            }
            if !include.isEmpty && !matchesPatterns(skill.name, patterns: include) {
                continue
            }
            if let existing = seenNames[skill.name] {
                warnings.append(SkillWarning(skillPath: skill.filePath, message: "name collision: \"\(skill.name)\" already loaded from \(existing.filePath), skipping this one"))
                continue
            }
            seenNames[skill.name] = skill
            skills.append(skill)
        }
    }

    if enableCodexUser {
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/skills").path
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "codex-user")))
    }
    if enableClaudeUser {
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills").path
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "claude-user")))
    }
    if enableClaudeProject {
        let path = URL(fileURLWithPath: cwd).appendingPathComponent(".claude/skills").path
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "claude-project")))
    }
    if enablePiUser {
        let path = URL(fileURLWithPath: agentDir).appendingPathComponent("skills").path
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "user")))
    }
    if enablePiProject {
        let path = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("skills").path
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "project")))
    }
    for custom in options.customDirectories ?? [] {
        let expanded = custom.hasPrefix("~") ? custom.replacingOccurrences(of: "~", with: NSHomeDirectory()) : custom
        addSkills(from: loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: expanded, source: "custom")))
    }

    return LoadSkillsResult(skills: skills, warnings: warnings)
}
