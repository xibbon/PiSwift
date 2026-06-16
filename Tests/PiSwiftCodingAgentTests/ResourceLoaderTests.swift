import Foundation
import Testing
@testable import PiSwiftCodingAgent

/// Tests for DefaultResourceLoader
///
/// Tests verify:
/// - Resource discovery (skills, prompts, themes, extensions)
/// - AGENTS.md and SYSTEM.md discovery
/// - noSkills option behavior
/// - Override patterns for auto-discovered resources

// MARK: - Test fixture

private final class ResourceLoaderTestFixture {
    let tempDir: String
    let agentDir: String
    let cwd: String

    init() throws {
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rl-test-\(uuid)")
            .path

        agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
        cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path

        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func writeFile(_ path: String, content: String) throws {
        let fullPath = URL(fileURLWithPath: tempDir).appendingPathComponent(path).path
        let dir = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }

    func writeAgentFile(_ relativePath: String, content: String) throws {
        let fullPath = URL(fileURLWithPath: agentDir).appendingPathComponent(relativePath).path
        let dir = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }

    func writeCwdFile(_ relativePath: String, content: String) throws {
        let fullPath = URL(fileURLWithPath: cwd).appendingPathComponent(relativePath).path
        let dir = (fullPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
    }

    func createLoader(
        settingsManager: SettingsManager? = nil,
        noSkills: Bool = false,
        additionalSkillPaths: [String]? = nil,
        projectTrusted: Bool = true
    ) -> DefaultResourceLoader {
        DefaultResourceLoader(DefaultResourceLoaderOptions(
            cwd: cwd,
            agentDir: agentDir,
            settingsManager: settingsManager,
            additionalSkillPaths: additionalSkillPaths,
            noSkills: noSkills,
            projectTrusted: projectTrusted
        ))
    }
}

// MARK: - reload tests

@Test func resourceLoaderInitializesWithEmptyResultsBeforeReload() async throws {
    let fixture = try ResourceLoaderTestFixture()
    let loader = fixture.createLoader()

    #expect(loader.getExtensions().paths.isEmpty)
    #expect(loader.getSkills().skills.isEmpty)
    #expect(loader.getPrompts().prompts.isEmpty)
    #expect(loader.getThemes().themes.isEmpty)
}

@Test func resourceLoaderDiscoversSkillsFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/test-skill/SKILL.md", content: """
        ---
        name: test-skill
        description: A test skill
        ---
        Skill content here.
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.contains { $0.name == "test-skill" })
}

@Test func resourceLoaderIgnoresExtraMarkdownFilesInAutoDiscoveredSkillDirs() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/pi-skills/browser-tools/SKILL.md", content: """
        ---
        name: browser-tools
        description: Browser tools
        ---
        Skill content here.
        """)
    try fixture.writeAgentFile("skills/pi-skills/browser-tools/EFFICIENCY.md", content: "No frontmatter here")

    let loader = fixture.createLoader()
    await loader.reload()

    let (skills, diagnostics) = loader.getSkills()
    #expect(skills.contains { $0.name == "browser-tools" })
    #expect(!diagnostics.contains { $0.path?.hasSuffix("EFFICIENCY.md") ?? false })
}

@Test func resourceLoaderDiscoversPromptsFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("prompts/test-prompt.md", content: """
        ---
        description: A test prompt
        ---
        Prompt content.
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (prompts, _) = loader.getPrompts()
    #expect(prompts.contains { $0.name == "test-prompt" })
}

@Test func resourceLoaderSkipsProjectResourcesWhenUntrusted() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("SYSTEM.md", content: "global system")
    try fixture.writeAgentFile("skills/user-skill/SKILL.md", content: """
        ---
        name: user-skill
        description: User skill
        ---
        User skill content.
        """)
    try fixture.writeCwdFile("AGENTS.md", content: "project context")
    try fixture.writeCwdFile(".pi/SYSTEM.md", content: "project system")
    try fixture.writeCwdFile(".pi/skills/project-skill/SKILL.md", content: """
        ---
        name: project-skill
        description: Project skill
        ---
        Project skill content.
        """)

    let settingsManager = SettingsManager.create(fixture.cwd, fixture.agentDir, projectTrusted: false)
    let loader = fixture.createLoader(settingsManager: settingsManager, projectTrusted: false)
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.contains { $0.name == "user-skill" })
    #expect(!skills.contains { $0.name == "project-skill" })
    #expect(loader.getAgentsFiles().isEmpty)
    #expect(loader.getSystemPrompt() == "global system")
}

@Test func resourceLoaderHonorsOverridesForAutoDiscoveredResources() async throws {
    let fixture = try ResourceLoaderTestFixture()
    let settingsManager = SettingsManager.inMemory()
    settingsManager.setExtensionPaths(["-extensions/disabled.ts"])
    settingsManager.setSkillPaths(["-skills/skip-skill"])
    settingsManager.setPromptTemplatePaths(["-prompts/skip.md"])
    settingsManager.setThemePaths(["-themes/skip.json"])

    try fixture.writeAgentFile("extensions/disabled.ts", content: "export default function() {}")

    try fixture.writeAgentFile("skills/skip-skill/SKILL.md", content: """
        ---
        name: skip-skill
        description: Skip me
        ---
        Content
        """)

    try fixture.writeAgentFile("prompts/skip.md", content: "Skip prompt")
    try fixture.writeAgentFile("themes/skip.json", content: "{}")

    let loader = fixture.createLoader(settingsManager: settingsManager)
    await loader.reload()

    let extensions = loader.getExtensions()
    let (skills, _) = loader.getSkills()
    let (prompts, _) = loader.getPrompts()
    let (themes, _) = loader.getThemes()

    #expect(!extensions.paths.contains { $0.hasSuffix("disabled.ts") })
    #expect(!skills.contains { $0.name == "skip-skill" })
    #expect(!prompts.contains { $0.name == "skip" })
    #expect(!themes.contains { $0.path?.hasSuffix("skip.json") ?? false })
}

@Test func resourceLoaderDiscoversAgentsMdContextFiles() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeCwdFile("AGENTS.md", content: "# Project Guidelines\n\nBe helpful.")

    let loader = fixture.createLoader()
    await loader.reload()

    let agentsFiles = loader.getAgentsFiles()
    #expect(agentsFiles.contains { $0.path.contains("AGENTS.md") })
}

@Test func resourceLoaderDiscoversSystemMdFromCwdPi() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeCwdFile(".pi/SYSTEM.md", content: "You are a helpful assistant.")

    let loader = fixture.createLoader()
    await loader.reload()

    #expect(loader.getSystemPrompt() == "You are a helpful assistant.")
}

@Test func resourceLoaderDiscoversAppendSystemMd() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeCwdFile(".pi/APPEND_SYSTEM.md", content: "Additional instructions.")

    let loader = fixture.createLoader()
    await loader.reload()

    let appendPrompt = loader.getAppendSystemPrompt()
    #expect(appendPrompt.contains { $0.contains("Additional instructions.") })
}

// MARK: - noSkills option tests

@Test func resourceLoaderSkipsSkillDiscoveryWhenNoSkillsIsTrue() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/test-skill/SKILL.md", content: """
        ---
        name: test-skill
        description: A test skill
        ---
        Content
        """)

    let loader = fixture.createLoader(noSkills: true)
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.isEmpty)
}

@Test func resourceLoaderStillLoadsAdditionalSkillPathsWhenNoSkillsIsTrue() async throws {
    let fixture = try ResourceLoaderTestFixture()
    let customSkillDir = URL(fileURLWithPath: fixture.tempDir).appendingPathComponent("custom-skills").appendingPathComponent("custom").path
    try FileManager.default.createDirectory(atPath: customSkillDir, withIntermediateDirectories: true)

    let customSkillPath = URL(fileURLWithPath: customSkillDir).appendingPathComponent("SKILL.md").path
    try """
        ---
        name: custom
        description: Custom skill
        ---
        Content
        """.write(toFile: customSkillPath, atomically: true, encoding: .utf8)

    let loader = fixture.createLoader(noSkills: true, additionalSkillPaths: [URL(fileURLWithPath: fixture.tempDir).appendingPathComponent("custom-skills").path])
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.contains { $0.name == "custom" })
}

// MARK: - Theme discovery tests

@Test func resourceLoaderDiscoversThemesFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("themes/dark.json", content: """
        {
            "name": "dark",
            "colors": {}
        }
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (themes, _) = loader.getThemes()
    #expect(themes.contains { $0.name == "dark" })
}

// MARK: - Extension discovery tests

@Test func resourceLoaderDiscoversExtensionsFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("extensions/my-ext.ts", content: "export default function() {}")

    let loader = fixture.createLoader()
    await loader.reload()

    let extensions = loader.getExtensions()
    #expect(extensions.paths.contains { $0.hasSuffix("my-ext.ts") })
}

// MARK: - Path metadata tests

@Test func resourceLoaderPopulatesPathMetadata() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/test-skill/SKILL.md", content: """
        ---
        name: test-skill
        description: Test
        ---
        Content
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let metadata = loader.getPathMetadata()
    #expect(!metadata.isEmpty)
}

// MARK: - Multiple resource discovery tests

@Test func resourceLoaderDiscoversMultipleSkillsFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/skill-a/SKILL.md", content: """
        ---
        name: skill-a
        description: Skill A
        ---
        Content A
        """)
    try fixture.writeAgentFile("skills/skill-b/SKILL.md", content: """
        ---
        name: skill-b
        description: Skill B
        ---
        Content B
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.contains { $0.name == "skill-a" })
    #expect(skills.contains { $0.name == "skill-b" })
}

@Test func resourceLoaderDiscoversMultiplePromptsFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("prompts/prompt-a.md", content: """
        ---
        description: Prompt A
        ---
        Content A
        """)
    try fixture.writeAgentFile("prompts/prompt-b.md", content: """
        ---
        description: Prompt B
        ---
        Content B
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (prompts, _) = loader.getPrompts()
    #expect(prompts.contains { $0.name == "prompt-a" })
    #expect(prompts.contains { $0.name == "prompt-b" })
}

// MARK: - SKILL.md in subdirectory tests

@Test func resourceLoaderDiscoversSkillMdInSubdirectories() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/complex-skill/SKILL.md", content: """
        ---
        name: complex-skill
        description: Complex skill
        ---
        Content
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (skills, _) = loader.getSkills()
    #expect(skills.contains { $0.name == "complex-skill" })
}

// MARK: - System prompt from agentDir tests

@Test func resourceLoaderDiscoversSystemMdFromAgentDir() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("SYSTEM.md", content: "Global system prompt.")

    let loader = fixture.createLoader()
    await loader.reload()

    #expect(loader.getSystemPrompt() == "Global system prompt.")
}

@Test func resourceLoaderPrefersProjectSystemMdOverGlobal() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("SYSTEM.md", content: "Global system prompt.")
    try fixture.writeCwdFile(".pi/SYSTEM.md", content: "Project system prompt.")

    let loader = fixture.createLoader()
    await loader.reload()

    #expect(loader.getSystemPrompt() == "Project system prompt.")
}

// MARK: - Diagnostics tests

@Test func resourceLoaderReturnsEmptyDiagnosticsForValidResources() async throws {
    let fixture = try ResourceLoaderTestFixture()
    try fixture.writeAgentFile("skills/valid-skill/SKILL.md", content: """
        ---
        name: valid-skill
        description: Valid
        ---
        Content
        """)

    let loader = fixture.createLoader()
    await loader.reload()

    let (_, diagnostics) = loader.getSkills()
    // No errors for valid skill
    #expect(diagnostics.filter { $0.type == "error" }.isEmpty)
}
