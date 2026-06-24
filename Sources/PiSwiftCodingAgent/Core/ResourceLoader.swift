import Foundation
import PiSwiftAI

public struct ExtensionsResult: Sendable {
    public var paths: [String]
    public var diagnostics: [ResourceDiagnostic]

    public init(paths: [String], diagnostics: [ResourceDiagnostic]) {
        self.paths = paths
        self.diagnostics = diagnostics
    }
}

public protocol ResourceLoader: Sendable {
    func getExtensions() -> ExtensionsResult
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic])
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic])
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic])
    func getAgentsFiles() -> [ContextFile]
    func getSystemPrompt() -> String?
    func getAppendSystemPrompt() -> [String]
    func getPathMetadata() -> [String: PathMetadata]
    func reload() async
}

public struct DefaultResourceLoaderOptions: Sendable {
    public var cwd: String?
    public var agentDir: String?
    public var settingsManager: SettingsManager?
    public var additionalExtensionPaths: [String]?
    public var additionalSkillPaths: [String]?
    public var additionalPromptTemplatePaths: [String]?
    public var additionalThemePaths: [String]?
    public var noExtensions: Bool?
    public var noSkills: Bool?
    public var noPromptTemplates: Bool?
    public var noThemes: Bool?
    /// v0.67.4: skip AGENTS.md / CLAUDE.md auto-discovery for clean runs.
    public var noContextFiles: Bool?
    public var projectTrusted: Bool?
    public var offline: Bool?
    public var systemPrompt: String?
    public var appendSystemPrompt: String?

    public init(
        cwd: String? = nil,
        agentDir: String? = nil,
        settingsManager: SettingsManager? = nil,
        additionalExtensionPaths: [String]? = nil,
        additionalSkillPaths: [String]? = nil,
        additionalPromptTemplatePaths: [String]? = nil,
        additionalThemePaths: [String]? = nil,
        noExtensions: Bool? = nil,
        noSkills: Bool? = nil,
        noPromptTemplates: Bool? = nil,
        noThemes: Bool? = nil,
        noContextFiles: Bool? = nil,
        projectTrusted: Bool? = nil,
        offline: Bool? = nil,
        systemPrompt: String? = nil,
        appendSystemPrompt: String? = nil
    ) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.settingsManager = settingsManager
        self.additionalExtensionPaths = additionalExtensionPaths
        self.additionalSkillPaths = additionalSkillPaths
        self.additionalPromptTemplatePaths = additionalPromptTemplatePaths
        self.additionalThemePaths = additionalThemePaths
        self.noExtensions = noExtensions
        self.noSkills = noSkills
        self.noPromptTemplates = noPromptTemplates
        self.noThemes = noThemes
        self.noContextFiles = noContextFiles
        self.projectTrusted = projectTrusted
        self.offline = offline
        self.systemPrompt = systemPrompt
        self.appendSystemPrompt = appendSystemPrompt
    }
}

public final class DefaultResourceLoader: ResourceLoader {
    private let cwd: String
    private let agentDir: String
    private let settingsManager: SettingsManager
    private let packageManager: DefaultPackageManager

    private let additionalExtensionPaths: [String]
    private let additionalSkillPaths: [String]
    private let additionalPromptTemplatePaths: [String]
    private let additionalThemePaths: [String]
    private let noExtensions: Bool
    private let noSkills: Bool
    private let noPromptTemplates: Bool
    private let noThemes: Bool
    private let noContextFiles: Bool
    private let projectTrusted: Bool
    private let offline: Bool
    private let systemPromptSource: String?
    private let appendSystemPromptSource: String?

    private struct State: Sendable {
        var extensionsResult = ExtensionsResult(paths: [], diagnostics: [])
        var skills: [Skill] = []
        var skillDiagnostics: [ResourceDiagnostic] = []
        var prompts: [PromptTemplate] = []
        var promptDiagnostics: [ResourceDiagnostic] = []
        var themes: [HookThemeInfo] = []
        var themeDiagnostics: [ResourceDiagnostic] = []
        var agentsFiles: [ContextFile] = []
        var systemPrompt: String?
        var appendSystemPrompt: [String] = []
        var pathMetadata: [String: PathMetadata] = [:]
    }

    private let state = LockedState(State())

    private var extensionsResult: ExtensionsResult {
        get { state.withLock { $0.extensionsResult } }
        set { state.withLock { $0.extensionsResult = newValue } }
    }

    private var skills: [Skill] {
        get { state.withLock { $0.skills } }
        set { state.withLock { $0.skills = newValue } }
    }

    private var skillDiagnostics: [ResourceDiagnostic] {
        get { state.withLock { $0.skillDiagnostics } }
        set { state.withLock { $0.skillDiagnostics = newValue } }
    }

    private var prompts: [PromptTemplate] {
        get { state.withLock { $0.prompts } }
        set { state.withLock { $0.prompts = newValue } }
    }

    private var promptDiagnostics: [ResourceDiagnostic] {
        get { state.withLock { $0.promptDiagnostics } }
        set { state.withLock { $0.promptDiagnostics = newValue } }
    }

    private var themes: [HookThemeInfo] {
        get { state.withLock { $0.themes } }
        set { state.withLock { $0.themes = newValue } }
    }

    private var themeDiagnostics: [ResourceDiagnostic] {
        get { state.withLock { $0.themeDiagnostics } }
        set { state.withLock { $0.themeDiagnostics = newValue } }
    }

    private var agentsFiles: [ContextFile] {
        get { state.withLock { $0.agentsFiles } }
        set { state.withLock { $0.agentsFiles = newValue } }
    }

    private var systemPrompt: String? {
        get { state.withLock { $0.systemPrompt } }
        set { state.withLock { $0.systemPrompt = newValue } }
    }

    private var appendSystemPrompt: [String] {
        get { state.withLock { $0.appendSystemPrompt } }
        set { state.withLock { $0.appendSystemPrompt = newValue } }
    }

    private var pathMetadata: [String: PathMetadata] {
        get { state.withLock { $0.pathMetadata } }
        set { state.withLock { $0.pathMetadata = newValue } }
    }

    public init(_ options: DefaultResourceLoaderOptions = DefaultResourceLoaderOptions()) {
        self.cwd = options.cwd ?? FileManager.default.currentDirectoryPath
        self.agentDir = options.agentDir ?? getAgentDir()
        self.projectTrusted = options.projectTrusted ?? true
        self.offline = options.offline ?? false
        self.settingsManager = options.settingsManager ?? SettingsManager.create(self.cwd, self.agentDir, projectTrusted: self.projectTrusted)
        self.packageManager = DefaultPackageManager(
            cwd: self.cwd,
            agentDir: self.agentDir,
            settingsManager: self.settingsManager,
            projectTrusted: self.projectTrusted,
            offline: self.offline
        )
        self.additionalExtensionPaths = options.additionalExtensionPaths ?? []
        self.additionalSkillPaths = options.additionalSkillPaths ?? []
        self.additionalPromptTemplatePaths = options.additionalPromptTemplatePaths ?? []
        self.additionalThemePaths = options.additionalThemePaths ?? []
        self.noExtensions = options.noExtensions ?? false
        self.noSkills = options.noSkills ?? false
        self.noPromptTemplates = options.noPromptTemplates ?? false
        self.noThemes = options.noThemes ?? false
        self.noContextFiles = options.noContextFiles ?? false
        self.systemPromptSource = options.systemPrompt
        self.appendSystemPromptSource = options.appendSystemPrompt
    }

    public func getExtensions() -> ExtensionsResult {
        extensionsResult
    }

    public func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
        (skills, skillDiagnostics)
    }

    public func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) {
        (prompts, promptDiagnostics)
    }

    public func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) {
        (themes, themeDiagnostics)
    }

    public func getAgentsFiles() -> [ContextFile] {
        agentsFiles
    }

    public func getSystemPrompt() -> String? {
        systemPrompt
    }

    public func getAppendSystemPrompt() -> [String] {
        appendSystemPrompt
    }

    public func getPathMetadata() -> [String: PathMetadata] {
        pathMetadata
    }

    public func reload() async {
        let resolvedPaths: ResolvedPaths
        do {
            resolvedPaths = try await packageManager.resolve(onMissing: nil)
        } catch {
            resolvedPaths = ResolvedPaths()
        }

        let cliExtensionPaths: ResolvedPaths
        do {
            cliExtensionPaths = try await packageManager.resolveExtensionSources(additionalExtensionPaths, options: PackageResolveOptions(temporary: true, offline: offline))
        } catch {
            cliExtensionPaths = ResolvedPaths()
        }

        func getEnabledResources(_ resources: [ResolvedResource]) -> [ResolvedResource] {
            resources.filter { $0.enabled }
        }

        func getEnabledPaths(_ resources: [ResolvedResource]) -> [String] {
            getEnabledResources(resources).map { $0.path }
        }

        pathMetadata = [:]
        let enabledExtensions = getEnabledPaths(resolvedPaths.extensions)
        let enabledSkillResources = getEnabledResources(resolvedPaths.skills)
        let enabledPrompts = getEnabledPaths(resolvedPaths.prompts)
        let enabledThemes = getEnabledPaths(resolvedPaths.themes)

        let mapSkillPath: (ResolvedResource) -> String = { resource in
            let path = resource.path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                let skillFile = URL(fileURLWithPath: path).appendingPathComponent("SKILL.md").path
                if FileManager.default.fileExists(atPath: skillFile) {
                    if self.pathMetadata[skillFile] == nil {
                        self.pathMetadata[skillFile] = resource.metadata
                    }
                    return skillFile
                }
            }
            return path
        }

        for resource in enabledSkillResources {
            if pathMetadata[resource.path] == nil {
                pathMetadata[resource.path] = resource.metadata
            }
        }

        let enabledSkills = enabledSkillResources.map(mapSkillPath)

        for resource in cliExtensionPaths.extensions {
            if pathMetadata[resource.path] == nil {
                pathMetadata[resource.path] = PathMetadata(source: "cli", scope: "temporary", origin: "top-level")
            }
        }
        for resource in cliExtensionPaths.skills {
            if pathMetadata[resource.path] == nil {
                pathMetadata[resource.path] = PathMetadata(source: "cli", scope: "temporary", origin: "top-level")
            }
        }

        let cliEnabledExtensions = getEnabledPaths(cliExtensionPaths.extensions)
        let cliEnabledSkills = getEnabledPaths(cliExtensionPaths.skills)
        let cliEnabledPrompts = getEnabledPaths(cliExtensionPaths.prompts)
        let cliEnabledThemes = getEnabledPaths(cliExtensionPaths.themes)

        let extensionPaths = noExtensions ? cliEnabledExtensions : mergePaths(enabledExtensions, additionalExtensionPaths, cliEnabledExtensions)
        extensionsResult = ExtensionsResult(paths: extensionPaths, diagnostics: [])

        let skillPaths = noSkills
            ? mergePaths(cliEnabledSkills, additionalSkillPaths)
            : mergePaths(enabledSkills + cliEnabledSkills, additionalSkillPaths)

        let skillsResult = loadSkillsFromPaths(skillPaths, includeDefaults: false)
        skills = skillsResult.skills
        skillDiagnostics = skillsResult.diagnostics
        for skill in skills {
            addDefaultMetadataForPath(skill.filePath)
        }

        let promptPaths = noPromptTemplates
            ? mergePaths(cliEnabledPrompts, additionalPromptTemplatePaths)
            : mergePaths(enabledPrompts + cliEnabledPrompts, additionalPromptTemplatePaths)

        let promptsResult = loadPromptsFromPaths(promptPaths, includeDefaults: false)
        prompts = promptsResult.prompts
        promptDiagnostics = promptsResult.diagnostics
        for prompt in prompts {
            addDefaultMetadataForPath(prompt.filePath)
        }

        let themePaths = noThemes
            ? mergePaths(cliEnabledThemes, additionalThemePaths)
            : mergePaths(enabledThemes + cliEnabledThemes, additionalThemePaths)

        let themesResult = loadThemesFromPaths(themePaths)
        themes = themesResult.themes
        themeDiagnostics = themesResult.diagnostics
        for theme in themes {
            if let path = theme.path {
                addDefaultMetadataForPath(path)
            }
        }

        for path in extensionsResult.paths {
            addDefaultMetadataForPath(path)
        }

        // v0.67.4: --no-context-files / noContextFiles option skips AGENTS.md / CLAUDE.md discovery.
        agentsFiles = noContextFiles
            ? []
            : (projectTrusted ? loadProjectContextFiles(LoadContextFilesOptions(cwd: cwd, agentDir: agentDir)) : [])

        let baseSystemPrompt = resolvePromptInput(systemPromptSource ?? discoverSystemPromptFile(), "system prompt")
        systemPrompt = baseSystemPrompt

        let appendSource = appendSystemPromptSource ?? discoverAppendSystemPromptFile()
        let resolvedAppend = resolvePromptInput(appendSource, "append system prompt")
        appendSystemPrompt = resolvedAppend.map { [$0] } ?? []
    }

    private func mergePaths(_ primary: [String], _ additional: [String], _ extra: [String] = []) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for path in primary + additional + extra {
            let resolved = resolveResourcePath(path)
            if seen.contains(resolved) { continue }
            seen.insert(resolved)
            merged.append(resolved)
        }
        return merged
    }

    private func resolveResourcePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return getHomeDir()
        }
        if trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst(2))).path
        }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst())).path
        }
        // If the path is already absolute, return it as-is (standardized)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardized.path
        }
        return URL(fileURLWithPath: cwd).appendingPathComponent(trimmed).standardized.path
    }

    private func loadSkillsFromPaths(_ paths: [String], includeDefaults: Bool) -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
        var skills: [Skill] = []
        var diagnostics: [ResourceDiagnostic] = []

        if !includeDefaults, paths.isEmpty {
            return ([], [])
        }

        for path in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let result = loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: path, source: "path"))
                skills.append(contentsOf: result.skills)
                diagnostics.append(contentsOf: result.warnings.map { ResourceDiagnostic(type: "warning", message: $0.message, path: $0.skillPath) })
            } else {
                let result = loadSkillFromFile(path, source: "path")
                if let skill = result.skill {
                    skills.append(skill)
                }
                diagnostics.append(contentsOf: result.warnings.map { ResourceDiagnostic(type: "warning", message: $0.message, path: $0.skillPath) })
            }
        }

        return (skills, diagnostics)
    }

    private func loadPromptsFromPaths(_ paths: [String], includeDefaults: Bool) -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) {
        if !includeDefaults, paths.isEmpty {
            return ([], [])
        }

        let templates = loadPromptTemplates(LoadPromptTemplatesOptions(
            cwd: cwd,
            agentDir: agentDir,
            promptPaths: paths,
            includeDefaults: includeDefaults
        ))

        let deduped = dedupePrompts(templates)
        return deduped
    }

    private func loadThemesFromPaths(_ paths: [String]) -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) {
        var themes: [HookThemeInfo] = []
        var diagnostics: [ResourceDiagnostic] = []

        for path in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                diagnostics.append(ResourceDiagnostic(type: "warning", message: "theme path does not exist", path: path))
                continue
            }
            if isDir.boolValue {
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for entry in entries where entry.hasSuffix(".json") {
                        let name = (entry as NSString).deletingPathExtension
                        let fullPath = URL(fileURLWithPath: path).appendingPathComponent(entry).path
                        themes.append(HookThemeInfo(name: name, path: fullPath))
                    }
                }
            } else if path.lowercased().hasSuffix(".json") {
                let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
                themes.append(HookThemeInfo(name: name, path: path))
            } else {
                diagnostics.append(ResourceDiagnostic(type: "warning", message: "theme path is not a json file", path: path))
            }
        }

        let deduped = dedupeThemes(themes)
        diagnostics.append(contentsOf: deduped.diagnostics)
        return (deduped.themes, diagnostics)
    }

    private func dedupePrompts(_ prompts: [PromptTemplate]) -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) {
        var seen: [String: PromptTemplate] = [:]
        var diagnostics: [ResourceDiagnostic] = []

        for prompt in prompts {
            if let existing = seen[prompt.name] {
                diagnostics.append(ResourceDiagnostic(
                    type: "collision",
                    message: "name \"/\(prompt.name)\" collision",
                    path: prompt.filePath,
                    collision: ResourceCollision(
                        resourceType: "prompt",
                        name: prompt.name,
                        winnerPath: existing.filePath,
                        loserPath: prompt.filePath
                    )
                ))
            } else {
                seen[prompt.name] = prompt
            }
        }

        return (Array(seen.values), diagnostics)
    }

    private func dedupeThemes(_ themes: [HookThemeInfo]) -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) {
        var seen: [String: HookThemeInfo] = [:]
        var diagnostics: [ResourceDiagnostic] = []

        for theme in themes {
            let name = theme.name
            if let existing = seen[name] {
                diagnostics.append(ResourceDiagnostic(
                    type: "collision",
                    message: "name \"\(name)\" collision",
                    path: theme.path,
                    collision: ResourceCollision(
                        resourceType: "theme",
                        name: name,
                        winnerPath: existing.path ?? "<builtin>",
                        loserPath: theme.path ?? "<builtin>"
                    )
                ))
            } else {
                seen[name] = theme
            }
        }

        return (Array(seen.values), diagnostics)
    }

    private func discoverSystemPromptFile() -> String? {
        if projectTrusted {
            let projectPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("SYSTEM.md").path
            if FileManager.default.fileExists(atPath: projectPath) {
                return projectPath
            }
        }
        let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("SYSTEM.md").path
        if FileManager.default.fileExists(atPath: globalPath) {
            return globalPath
        }
        return nil
    }

    private func discoverAppendSystemPromptFile() -> String? {
        if projectTrusted {
            let projectPath = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("APPEND_SYSTEM.md").path
            if FileManager.default.fileExists(atPath: projectPath) {
                return projectPath
            }
        }
        let globalPath = URL(fileURLWithPath: agentDir).appendingPathComponent("APPEND_SYSTEM.md").path
        if FileManager.default.fileExists(atPath: globalPath) {
            return globalPath
        }
        return nil
    }

    private func addDefaultMetadataForPath(_ filePath: String) {
        guard !filePath.isEmpty, !filePath.hasPrefix("<") else { return }
        let normalized = URL(fileURLWithPath: filePath).standardized.path
        if pathMetadata[normalized] != nil || pathMetadata[filePath] != nil { return }

        let agentRoots = [
            URL(fileURLWithPath: agentDir).appendingPathComponent("skills").path,
            URL(fileURLWithPath: agentDir).appendingPathComponent("prompts").path,
            URL(fileURLWithPath: agentDir).appendingPathComponent("themes").path,
            URL(fileURLWithPath: agentDir).appendingPathComponent("extensions").path,
        ]
        let projectRoots = [
            URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("skills").path,
            URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("prompts").path,
            URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("themes").path,
            URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("extensions").path,
        ]

        for root in agentRoots {
            if isUnderPath(target: normalized, root: root) {
                pathMetadata[normalized] = PathMetadata(source: "local", scope: "user", origin: "top-level")
                return
            }
        }

        for root in projectRoots {
            if isUnderPath(target: normalized, root: root) {
                pathMetadata[normalized] = PathMetadata(source: "local", scope: "project", origin: "top-level")
                return
            }
        }
    }

    private func isUnderPath(target: String, root: String) -> Bool {
        let normalizedRoot = URL(fileURLWithPath: root).standardized.path
        if target == normalizedRoot { return true }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return target.hasPrefix(prefix)
    }
}
