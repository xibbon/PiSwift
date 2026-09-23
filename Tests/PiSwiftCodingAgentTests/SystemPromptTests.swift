import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - Empty tools tests

@Test func buildSystemPromptEmptyToolsShowsNone() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("<tools>\n(none)\n"))
}

@Test func buildSystemPromptEmptyToolsShowsFilePathsGuideline() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Show file paths clearly"))
}

// MARK: - Default tools tests

@Test func buildSystemPromptDefaultToolsIncluded() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: []
    ))

    #expect(!prompt.contains("- read:"))
    #expect(!prompt.contains("- bash:"))
    #expect(!prompt.contains("- edit:"))
    #expect(!prompt.contains("- write:"))
}

// MARK: - Custom prompt tests

@Test func buildSystemPromptCustomPromptOverridesDefault() throws {
    let customPrompt = "You are a specialized assistant for testing."
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        customPrompt: customPrompt,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains(customPrompt))
    #expect(!prompt.contains("Available tools:"))
}

@Test func buildSystemPromptAppendSystemPrompt() throws {
    let appendText = "Additional instructions for the assistant."
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        appendSystemPrompt: appendText,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains(appendText))
}

// MARK: - Context files tests

@Test func buildSystemPromptIncludesContextFiles() throws {
    let contextFiles = [
        ContextFile(path: "/test/CLAUDE.md", content: "Test context content")
    ]
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: contextFiles,
        skills: []
    ))

    #expect(prompt.contains("<project_context>\nProject-specific instructions and guidelines:"))
    #expect(prompt.contains("/test/CLAUDE.md"))
    #expect(prompt.contains("Test context content"))
}

// MARK: - Skills tests

@Test func buildSystemPromptIncludesSkills() throws {
    let skills = [
        Skill(
            name: "test-skill",
            description: "A test skill for testing",
            filePath: "/test/skills/test-skill/SKILL.md",
            baseDir: "/test/skills/test-skill",
            source: "test"
        )
    ]
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: skills
    ))

    #expect(prompt.contains("test-skill"))
    #expect(prompt.contains("A test skill for testing"))
}

@Test func buildSystemPromptIncludesSkillsWhenBashCanRead() throws {
    let skills = [
        Skill(
            name: "test-skill",
            description: "A test skill for testing",
            filePath: "/test/skills/test-skill/SKILL.md",
            baseDir: "/test/skills/test-skill",
            source: "test"
        )
    ]
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.bash, .edit],  // Bash can load skill files without read.
        contextFiles: [],
        skills: skills
    ))

    // v0.85.0 uses bash when the read tool is not available.
    #expect(prompt.contains("test-skill"))
    #expect(prompt.contains("Use bash to load a skill's file"))
}

// MARK: - Guidelines tests

@Test func buildSystemPromptReadOnlyModeGuideline() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .grep, .find],  // No bash, edit, or write
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("- Be concise in your responses"))
}

@Test func buildSystemPromptBashReadOnlyGuideline() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .bash],  // bash but no edit/write
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Use bash for file operations like ls, rg, find"))
}

@Test func buildSystemPromptEditGuideline() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .edit],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("- Show file paths clearly when working with files"))
}

@Test func buildSystemPromptWriteGuideline() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .write],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("- Show file paths clearly when working with files"))
}

// MARK: - Environment info tests

@Test func buildSystemPromptOmitsDate() throws {
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: []
    ))

    // v0.80.x: the current date is no longer injected into the system prompt
    // (a daily-changing date busted the system-prompt cache). Working directory stays.
    #expect(!prompt.contains("Current date:"))
    #expect(prompt.contains("<cwd>\n"))
}

@Test func buildSystemPromptIncludesCwd() throws {
    let cwd = "/test/working/directory"
    let prompt = try buildSystemPrompt(BuildSystemPromptOptions(
        cwd: cwd,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("<cwd>\n\(cwd)\n</cwd>"))
}
