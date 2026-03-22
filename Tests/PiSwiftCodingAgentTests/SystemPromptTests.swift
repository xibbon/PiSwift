import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - Empty tools tests

@Test func buildSystemPromptEmptyToolsShowsNone() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Available tools:\n(none)"))
}

@Test func buildSystemPromptEmptyToolsShowsFilePathsGuideline() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Show file paths clearly"))
}

// MARK: - Default tools tests

@Test func buildSystemPromptDefaultToolsIncluded() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("- read:"))
    #expect(prompt.contains("- bash:"))
    #expect(prompt.contains("- edit:"))
    #expect(prompt.contains("- write:"))
}

// MARK: - Custom prompt tests

@Test func buildSystemPromptCustomPromptOverridesDefault() {
    let customPrompt = "You are a specialized assistant for testing."
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        customPrompt: customPrompt,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains(customPrompt))
    #expect(!prompt.contains("Available tools:"))
}

@Test func buildSystemPromptAppendSystemPrompt() {
    let appendText = "Additional instructions for the assistant."
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        appendSystemPrompt: appendText,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains(appendText))
}

// MARK: - Context files tests

@Test func buildSystemPromptIncludesContextFiles() {
    let contextFiles = [
        ContextFile(path: "/test/CLAUDE.md", content: "Test context content")
    ]
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: contextFiles,
        skills: []
    ))

    #expect(prompt.contains("# Project Context"))
    #expect(prompt.contains("/test/CLAUDE.md"))
    #expect(prompt.contains("Test context content"))
}

// MARK: - Skills tests

@Test func buildSystemPromptIncludesSkills() {
    let skills = [
        Skill(
            name: "test-skill",
            description: "A test skill for testing",
            filePath: "/test/skills/test-skill/SKILL.md",
            baseDir: "/test/skills/test-skill",
            source: "test"
        )
    ]
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: skills
    ))

    #expect(prompt.contains("test-skill"))
    #expect(prompt.contains("A test skill for testing"))
}

@Test func buildSystemPromptNoSkillsWhenReadNotIncluded() {
    let skills = [
        Skill(
            name: "test-skill",
            description: "A test skill for testing",
            filePath: "/test/skills/test-skill/SKILL.md",
            baseDir: "/test/skills/test-skill",
            source: "test"
        )
    ]
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.bash, .edit],  // No .read
        contextFiles: [],
        skills: skills
    ))

    // Skills should not be included when read tool is not available
    #expect(!prompt.contains("test-skill"))
}

// MARK: - Guidelines tests

@Test func buildSystemPromptReadOnlyModeGuideline() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .grep, .find],  // No bash, edit, or write
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("READ-ONLY mode"))
}

@Test func buildSystemPromptBashReadOnlyGuideline() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .bash],  // bash but no edit/write
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Use bash ONLY for read-only operations"))
}

@Test func buildSystemPromptEditGuideline() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .edit],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Use edit for precise changes"))
}

@Test func buildSystemPromptWriteGuideline() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        selectedTools: [.read, .write],
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Use write only for new files or complete rewrites"))
}

// MARK: - Environment info tests

@Test func buildSystemPromptIncludesDate() {
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        contextFiles: [],
        skills: []
    ))

    // v0.61.1: ISO date only, no time component
    #expect(prompt.contains("Current date:"))
}

@Test func buildSystemPromptIncludesCwd() {
    let cwd = "/test/working/directory"
    let prompt = buildSystemPrompt(BuildSystemPromptOptions(
        cwd: cwd,
        contextFiles: [],
        skills: []
    ))

    #expect(prompt.contains("Current working directory: \(cwd)"))
}
