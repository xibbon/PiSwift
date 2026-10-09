import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Test func i1DocsSectionKeepsUpstreamTextAndAcceptedReference() throws {
    let sections = try buildSystemPromptSections(BuildSystemPromptOptions(cwd: "/i1", contextFiles: [], skills: []))
    // PORT_SYNC_NOTES.md:143 accepts the extra Codemode reference.
    #expect(sections["docs"] == """
    <docs>
    Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
    - Main documentation: \(getReadmePath())
    - Additional docs: \(getDocsPath())
    - Examples: \(getExamplesPath()) (extensions, custom tools, SDK)
    - When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
    - When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md), MCP servers (docs/mcp.md), codemode scripts and non-LLM models such as classifiers and image models (docs/codemode.md)
    - Codemode script reference: \(CODEMODE_DOCS_PATH)
    - When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
    - Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
    </docs>
    """)
}

@Test func i1SystemPromptSectionsKeepUpstreamOrderAndContent() throws {
    let skill = Skill(name: "sample", description: "Sample skill", filePath: "/skills/sample/SKILL.md",
        baseDir: "/skills/sample", source: "test")
    let sections = try buildSystemPromptSections(BuildSystemPromptOptions(selectedToolNames: ["read"],
        appendSystemPrompt: "Extra instructions", cwd: "C:\\project",
        contextFiles: [ContextFile(path: "/project/AGENTS.md", content: "Project instructions")], skills: [skill],
        toolSnippets: ["read": "Read file contents"],
        toolGuidelines: ["read": ["  First rule  ", "First rule", ""]],
        promptGuidelines: ["First rule", "Second rule"],
        sections: SystemPromptSections([("custom", "Custom instructions")])))
    #expect(sections.entries.map(\.name) == ["preamble", "tools", "rules", "docs", "addendum", "project_context", "skills", "cwd", "custom"])
    #expect(sections["preamble"] == "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.")
    #expect(sections["tools"] == "<tools>\n- read: Read file contents\n\nIn addition to the tools above, you may have access to other custom tools depending on the project.\n</tools>")
    #expect(sections["rules"] == "<rules>\n- First rule\n- Second rule\n- Be concise in your responses\n- Show file paths clearly when working with files\n</rules>")
    #expect(sections["addendum"] == "<addendum>\nExtra instructions\n</addendum>")
    #expect(sections["project_context"] == "<project_context>\nProject-specific instructions and guidelines:\n\n<project_instructions path=\"/project/AGENTS.md\">\nProject instructions\n</project_instructions>\n</project_context>")
    #expect(sections["skills"] == """
    <skills>
    The following skills provide specialized instructions for specific tasks.
    Use the read tool to load a skill's file when the task matches its description.
    When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.

    <available_skills>
      <skill>
        <name>sample</name>
        <description>Sample skill</description>
        <location>/skills/sample/SKILL.md</location>
      </skill>
    </available_skills>
    </skills>
    """)
    #expect(sections["cwd"] == "<cwd>\nC:/project\n</cwd>")
    #expect(sections["custom"] == "<custom>\nCustom instructions\n</custom>")
}

@Test func i1OmittedPromptResourcesDoNotLoadFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("i1-resources-\(UUID().uuidString)")
    let skillDirectory = directory.appendingPathComponent(".pi/skills/sample")
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "Project instructions".write(to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "---\nname: sample\ndescription: Sample skill\n---\nSkill instructions".write(
        to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let sections = try buildSystemPromptSections(BuildSystemPromptOptions(cwd: directory.path, agentDir: directory.path))
    #expect(sections["project_context"] == nil)
    #expect(sections["skills"] == nil)
    #expect(sections.entries.map(\.name) == ["preamble", "tools", "rules", "docs", "cwd"])
}

@Test func i1PromptFilePathsStayLiteral() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("i1-prompt-\(UUID().uuidString).txt")
    try "File contents".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let sections = try buildSystemPromptSections(BuildSystemPromptOptions(customPrompt: file.path,
        appendSystemPrompt: file.path, cwd: "/i1"))
    #expect(sections["preamble"] == file.path)
    #expect(sections["addendum"] == "<addendum>\n\(file.path)\n</addendum>")
    #expect(sections.entries.map(\.name) == ["preamble", "addendum", "cwd"])
    // File resolution remains available to resource loaders.
    #expect(resolvePromptInput(file.path, "system prompt") == "File contents")
}

@Test func i1RulesUseJavaScriptWhitespaceAndStringIdentity() throws {
    let sections = try buildSystemPromptSections(BuildSystemPromptOptions(selectedToolNames: [], cwd: "/i1",
        promptGuidelines: ["\u{FEFF}Trimmed\u{FEFF}", "Trimmed", "\u{0085}Retained\u{0085}",
            "caf\u{00E9}", "cafe\u{0301}", "caf\u{00E9}"]))
    let expected = "<rules>\n- Trimmed\n- \u{0085}Retained\u{0085}\n- caf\u{00E9}\n- cafe\u{0301}\n- Be concise in your responses\n- Show file paths clearly when working with files\n</rules>"
    let actual = try #require(sections["rules"])
    #expect(Array(actual.utf16) == Array(expected.utf16))
}
