import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private func promptDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func promptInput(cwd: String? = nil, names: [String] = [], env: (any ExecutionEnv)? = nil) throws -> PromptInput {
    let tools = try names.map { name in
        var tool = try createReadTool()
        tool.name = name
        return tool
    }
    return PromptInput(conversationId: try ConversationID(1), agent: Agent(tools: tools, cwd: cwd), env: env)
}

@Test func piPromptUsesSevenSectionsWithoutExtraTags() async throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    try "Prompt parity instructions".write(to: cwd.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let skill = cwd.appendingPathComponent(".pi/skills/parity-skill/SKILL.md")
    try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "---\nname: parity-skill\ndescription: Prompt parity skill.\n---\nSkill body\n"
        .write(to: skill, atomically: true, encoding: .utf8)
    let prompt = createPiPrompt(settingsManager: .inMemory(), fallbackCwd: cwd.path)
    #expect(prompt.name == "pi-prompt")
    #expect(prompt.tools.isEmpty && prompt.hooks.isEmpty && prompt.wraps.isEmpty && prompt.tasks.isEmpty)
    #expect(prompt.sections.map(\.key) == ["preamble", "tools", "rules", "docs", "project_context", "skills", "cwd"])
    #expect(prompt.sections.allSatisfy { $0.tag == false })
    let input = try promptInput(names: ["write", "edit", "read", "bash", "custom"])
    let snippets = ["read": readToolSystemPromptContribution, "bash": bashToolSystemPromptContribution,
                    "edit": editToolSystemPromptContribution, "write": writeToolSystemPromptContribution]
    let expected = try buildSystemPromptSections(.init(
        selectedToolNames: input.agent.tools.map(\.name), cwd: cwd.path,
        contextFiles: loadProjectContextFiles(.init(cwd: cwd.path, agentDir: getAgentDir())),
        skills: loadSkills(cwd: cwd.path, agentDir: getAgentDir(), skillPaths: [], includeDefaults: true).skills,
        toolSnippets: snippets.mapValues(\.snippet), toolGuidelines: snippets.mapValues(\.guidelines)
    ))
    for section in prompt.sections {
        let rendered = try await section.render(input, .background)
        #expect(rendered == expected[section.key])
    }
    #expect(expected["tools"]?.contains("- custom:") == false)
    #expect(expected["tools"]?.contains(editToolSystemPromptContribution.snippet) == true)
    #expect(expected["project_context"]?.contains("Prompt parity instructions") == true)
    #expect(expected["skills"]?.contains("<name>parity-skill</name>") == true)
}

@Test func piPromptSelectsEnvironmentThenAgentThenFallbackDirectory() async throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let prompt = createPiPrompt(settingsManager: .inMemory(), fallbackCwd: cwd.path)
    let section = try #require(prompt.sections.first { $0.key == "cwd" })
    #expect(try await section.render(promptInput(), .background) == "<cwd>\n\(cwd.path)\n</cwd>")
    #expect(try await section.render(promptInput(cwd: "/agent"), .background) == "<cwd>\n/agent\n</cwd>")
    #expect(try await section.render(promptInput(cwd: "/agent", env: FakeExecutionEnv(cwd: "/env")), .background)
            == "<cwd>\n/env\n</cwd>")
}

@Test func piPromptOmitsEmptyResourcesAndOnlyUsesSelectedContributions() throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let cache = PiPromptCache(settings: .inMemory(), fallbackCwd: cwd.path, agentDirectory: { cwd.path })
    let empty = try cache.build(promptInput())
    #expect(empty["tools"]?.contains("(none)") == true)
    #expect(empty["project_context"] == nil)
    #expect(empty["skills"] == nil)
    let read = try cache.build(promptInput(names: ["read", "custom"]))
    #expect(read["tools"]?.contains("- read: Read file contents") == true)
    #expect(read["tools"]?.contains("- bash:") == false)
    #expect(read["rules"]?.contains(readToolSystemPromptContribution.guidelines[0]) == true)
    #expect(read["rules"]?.contains(bashToolSystemPromptContribution.guidelines[0]) == false)
}

@Test func piPromptLoadsContextAndDefaultAndExplicitSkillsOncePerDirectory() throws {
    let root = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let agent = root.appendingPathComponent("agent")
    let explicit = root.appendingPathComponent("explicit.md")
    let projectSkill = project.appendingPathComponent(".pi/skills/project-skill/SKILL.md")
    let agentSkill = agent.appendingPathComponent("skills/user-skill/SKILL.md")
    for file in [projectSkill, agentSkill] {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let context = project.appendingPathComponent("AGENTS.md")
    try "first context".write(to: context, atomically: true, encoding: .utf8)
    for (file, name) in [(projectSkill, "project-skill"), (agentSkill, "user-skill"), (explicit, "explicit-skill")] {
        try "---\nname: \(name)\ndescription: The \(name) description.\n---\nBody\n".write(to: file, atomically: true, encoding: .utf8)
    }
    let settings = SettingsManager.inMemory()
    settings.setSkillPaths([explicit.path])
    let cache = PiPromptCache(settings: settings, fallbackCwd: project.path, agentDirectory: { agent.path })
    let first = try cache.build(promptInput(names: ["read"]))
    #expect(first["project_context"]?.contains("first context") == true)
    for name in ["project-skill", "user-skill", "explicit-skill"] {
        #expect(first["skills"]?.contains("<name>\(name)</name>") == true)
    }
    try "changed context".write(to: context, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: explicit)
    settings.setSkillPaths([])
    let next = try cache.build(promptInput(names: ["bash"]))
    #expect(next["project_context"] == first["project_context"])
    #expect(next["skills"]?.contains("<name>explicit-skill</name>") == true)
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try "other context".write(to: other.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let otherSections = try cache.build(promptInput(cwd: other.path, names: ["read"]))
    #expect(otherSections["project_context"]?.contains("other context") == true)
    #expect(otherSections["skills"]?.contains("<name>explicit-skill</name>") == false)
}

@Test func piPromptBuildsOnceForConcurrentRequestsAndToolOrderIsPartOfKey() async throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let count = Mutex(0)
    let cache = PiPromptCache(settings: .inMemory(), fallbackCwd: cwd.path, agentDirectory: { cwd.path }, buildSections: {
        count.withLock { $0 += 1 }
        return try buildSystemPromptSections($0)
    })
    let input = try promptInput(names: ["read", "write"])
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<50 { group.addTask { _ = try cache.build(input) } }
        try await group.waitForAll()
    }
    #expect(count.withLock { $0 } == 1)
    _ = try cache.build(promptInput(names: ["write", "read"]))
    #expect(count.withLock { $0 } == 2)
    var copied = input
    copied.conversationId = try ConversationID(2)
    copied.shown = ["tools": "old text"]
    _ = try cache.build(copied)
    #expect(count.withLock { $0 } == 2)
}

@Test func piPromptEvictsBuildsAtTheLimitAndKeepsDirectoryResources() throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let context = cwd.appendingPathComponent("AGENTS.md")
    try "original context".write(to: context, atomically: true, encoding: .utf8)
    let count = Mutex(0)
    let cache = PiPromptCache(settings: .inMemory(), fallbackCwd: cwd.path, agentDirectory: { cwd.path }, buildSections: {
        count.withLock { $0 += 1 }
        return try buildSystemPromptSections($0)
    })
    for index in 0..<PiPromptCache.buildLimit {
        _ = try cache.build(promptInput(names: ["custom-\(index)"]))
    }
    _ = try cache.build(promptInput(names: ["custom-0"]))
    #expect(count.withLock { $0 } == PiPromptCache.buildLimit)
    _ = try cache.build(promptInput(names: ["one-more"]))
    try "new context".write(to: context, atomically: true, encoding: .utf8)
    let rebuilt = try cache.build(promptInput(names: ["custom-0"]))
    #expect(count.withLock { $0 } == PiPromptCache.buildLimit + 2)
    #expect(rebuilt["project_context"]?.contains("original context") == true)
    #expect(rebuilt["project_context"]?.contains("new context") == false)
}

@Test func piPromptCacheKeepsLiteralUTF16DirectoryAndToolNamesDistinct() throws {
    let cwd = try promptDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let count = Mutex(0)
    let cache = PiPromptCache(settings: .inMemory(), fallbackCwd: cwd.path, agentDirectory: { cwd.path }, buildSections: {
        count.withLock { $0 += 1 }
        return try buildSystemPromptSections($0)
    })
    let composed = "/virtual-caf\u{00E9}"
    let decomposed = "/virtual-cafe\u{0301}"
    let first = try cache.build(promptInput(cwd: composed, names: ["read"]))
    let second = try cache.build(promptInput(cwd: decomposed, names: ["read"]))
    let firstCwd = try #require(first["cwd"])
    let secondCwd = try #require(second["cwd"])
    #expect(Array(firstCwd.utf16) == Array("<cwd>\n\(composed)\n</cwd>".utf16))
    #expect(Array(secondCwd.utf16) == Array("<cwd>\n\(decomposed)\n</cwd>".utf16))
    #expect(count.withLock { $0 } == 2)
    _ = try cache.build(promptInput(cwd: composed, names: ["caf\u{00E9}"]))
    _ = try cache.build(promptInput(cwd: composed, names: ["cafe\u{0301}"]))
    #expect(count.withLock { $0 } == 4)
}
