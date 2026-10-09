import Foundation

/// Load default skills and explicit files or directories. The first skill with a given name wins.
/// Upstream warning and collision diagnostics become `warnings`, with their path and message.
public func loadSkills(
    cwd: String,
    agentDir: String,
    skillPaths: [String],
    includeDefaults: Bool
) -> LoadSkillsResult {
    let result = loadSkillsWithDiagnostics(cwd: cwd, agentDir: agentDir, skillPaths: skillPaths, includeDefaults: includeDefaults)
    return LoadSkillsResult(skills: result.skills, warnings: result.diagnostics.map {
        SkillWarning(skillPath: $0.path ?? "", message: $0.message)
    })
}

// Keep structured collision data for ResourceLoader, which exposes ResourceDiagnostic.
func loadSkillsWithDiagnostics(
    cwd: String,
    agentDir: String,
    skillPaths: [String],
    includeDefaults: Bool
) -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) {
    let resolvedCwd = resolveSkillPath(cwd)
    let userDir = resolveSkillPath("skills", cwd: resolveSkillPath(agentDir))
    let projectDir = resolveSkillPath("\(CONFIG_DIR_NAME)/skills", cwd: resolvedCwd)
    var skills: [Skill] = []
    var diagnostics: [ResourceDiagnostic] = []
    var collisions: [ResourceDiagnostic] = []
    var seenNames: [String: Skill] = [:]
    var seenPaths = Set<String>()

    func add(_ result: LoadSkillsResult) {
        diagnostics.append(contentsOf: result.warnings.map { ResourceDiagnostic(type: "warning", message: $0.message, path: $0.skillPath) })
        for skill in result.skills {
            let realPath = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().standardized.path
            if seenPaths.contains(realPath) { continue }
            if let winner = seenNames[skill.name] {
                collisions.append(ResourceDiagnostic(
                    type: "collision", message: "name \"\(skill.name)\" collision", path: skill.filePath,
                    collision: ResourceCollision(resourceType: "skill", name: skill.name, winnerPath: winner.filePath, loserPath: skill.filePath)
                ))
            } else {
                seenNames[skill.name] = skill
                seenPaths.insert(realPath)
                skills.append(skill)
            }
        }
    }

    if includeDefaults {
        add(loadSkillDirectory(userDir, source: "user"))
        add(loadSkillDirectory(projectDir, source: "project"))
    }

    for rawPath in skillPaths {
        let path = resolveSkillPath(rawPath.trimmingCharacters(in: .whitespacesAndNewlines), cwd: resolvedCwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            diagnostics.append(ResourceDiagnostic(type: "warning", message: "skill path does not exist", path: path))
            continue
        }
        let source: String
        if !includeDefaults, path == userDir || path.hasPrefix(userDir + "/") { source = "user" }
        else if !includeDefaults, path == projectDir || path.hasPrefix(projectDir + "/") { source = "project" }
        else { source = "path" }

        if isDirectory.boolValue {
            add(loadSkillDirectory(path, source: source))
        } else if path.hasSuffix(".md"), (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let result = loadSkillFromFile(path, source: source, requireBooleanModelInvocation: true)
            add(LoadSkillsResult(skills: result.skill.map { [skillWithPathSource($0, source: source)] } ?? [], warnings: result.warnings))
        } else {
            diagnostics.append(ResourceDiagnostic(type: "warning", message: "skill path is not a markdown file", path: path))
        }
    }
    return (skills, diagnostics + collisions)
}

private func resolveSkillPath(_ input: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
    var path = input
    if path == "~" { path = getHomeDir() }
    else if path.hasPrefix("~/") { path = getHomeDir() + String(path.dropFirst()) }
    if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { path = url.path }
    // Resolve dot components without following symlinks. Only duplicate detection uses real paths.
    let absolute = path.hasPrefix("/") ? path : cwd + "/" + path
    var components: [Substring] = []
    for component in absolute.split(separator: "/") {
        if component == "." { continue }
        if component == ".." {
            if !components.isEmpty { components.removeLast() }
        } else { components.append(component) }
    }
    return "/" + components.joined(separator: "/")
}

private func skillWithPathSource(_ skill: Skill, source: String) -> Skill {
    var skill = skill
    // Explicit paths use the temporary scope; default paths use the user or project scope.
    skill.sourceInfo = SourceInfo(path: skill.filePath, source: "local", scope: source == "path" ? "temporary" : source, origin: "top-level", baseDir: skill.baseDir)
    return skill
}

private struct SkillIgnoreRule {
    let regex: NSRegularExpression
    let negated: Bool

    func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}

private func loadSkillDirectory(
    _ dir: String,
    source: String,
    includeRootFiles: Bool = true,
    rootDir: String? = nil,
    inheritedRules: [SkillIgnoreRule] = []
) -> LoadSkillsResult {
    let root = rootDir ?? dir
    var rules = inheritedRules
    let rootPrefix = root.hasSuffix("/") ? root : root + "/"
    let prefix = dir == root ? "" : String(dir.dropFirst(rootPrefix.count)) + "/"
    for name in [".gitignore", ".ignore", ".fdignore"] {
        guard let content = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
        for line in content.components(separatedBy: .newlines) {
            if let rule = skillIgnoreRule(line, prefix: prefix) { rules.append(rule) }
        }
    }
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else {
        return LoadSkillsResult(skills: [], warnings: [])
    }
    func ignored(_ path: String) -> Bool {
        var ignored = false
        for rule in rules where rule.matches(path) { ignored = !rule.negated }
        return ignored
    }
    func loadFile(_ path: String) -> LoadSkillsResult {
        let result = loadSkillFromFile(path, source: source, requireBooleanModelInvocation: true)
        return LoadSkillsResult(skills: result.skill.map { [skillWithPathSource($0, source: source)] } ?? [], warnings: result.warnings)
    }
    // A declared skill root stops discovery, including other Markdown files in that root.
    if let entry = entries.first(where: { $0.lastPathComponent == "SKILL.md" }),
       (try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
       !ignored(prefix + "SKILL.md") {
        return loadFile(resolveSkillPath(entry.lastPathComponent, cwd: dir))
    }
    var skills: [Skill] = []
    var warnings: [SkillWarning] = []
    for entry in entries {
        let name = entry.lastPathComponent
        let path = resolveSkillPath(name, cwd: dir)
        if name.hasPrefix(".") || name == "node_modules" { continue }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { continue }
        if ignored(prefix + name + (directory.boolValue ? "/" : "")) { continue }
        let result: LoadSkillsResult
        if directory.boolValue {
            result = loadSkillDirectory(path, source: source, includeRootFiles: false, rootDir: root, inheritedRules: rules)
        } else if includeRootFiles, name.hasSuffix(".md"), (try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result = loadFile(path)
        } else { continue }
        skills.append(contentsOf: result.skills)
        warnings.append(contentsOf: result.warnings)
    }
    return LoadSkillsResult(skills: skills, warnings: warnings)
}

private func skillIgnoreRule(_ line: String, prefix: String) -> SkillIgnoreRule? {
    var pattern = line.replacingOccurrences(of: #"(?<!\\)\s+$"#, with: "", options: .regularExpression)
    if pattern.isEmpty || pattern.hasPrefix("#") { return nil }
    // Upstream removes this escape before it sends a root rule to the ignore matcher.
    if prefix.isEmpty && pattern.hasPrefix("\\!") { pattern.removeFirst() }
    let negated = pattern.hasPrefix("!")
    if negated { pattern.removeFirst() }
    if pattern.hasPrefix("/") { pattern.removeFirst() }
    let directoryOnly = pattern.hasSuffix("/")
    if directoryOnly { pattern.removeLast() }
    if pattern.isEmpty { return nil }
    var regex = "^" + NSRegularExpression.escapedPattern(for: prefix)
    if prefix.isEmpty && !pattern.contains("/") { regex += "(?:.*/)?" }
    let chars = Array(pattern)
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if char == "\\", index + 1 < chars.count {
            index += 1
            regex += NSRegularExpression.escapedPattern(for: String(chars[index]))
        } else if char == "*" {
            if index + 1 < chars.count, chars[index + 1] == "*" {
                index += 1
                if index + 1 < chars.count, chars[index + 1] == "/" { regex += "(?:.*/)?"; index += 1 }
                else { regex += ".*" }
            } else { regex += "[^/]*" }
        } else if char == "?" { regex += "[^/]" }
        else if char == "[", let end = chars[(index + 1)...].firstIndex(of: "]") {
            var content = String(chars[(index + 1)..<end])
            if content.hasPrefix("!") { content = "^" + content.dropFirst() }
            regex += "[" + content + "]"
            index = end
        } else { regex += NSRegularExpression.escapedPattern(for: String(char)) }
        index += 1
    }
    regex += directoryOnly ? "/" : "(?:/|$)"
    guard let compiled = try? NSRegularExpression(pattern: regex) else { return nil }
    return SkillIgnoreRule(regex: compiled, negated: negated)
}
