import Foundation
import Testing
import PiSwiftCodingAgent

private struct I1SkillFixture {
    let root: URL
    var cwd: String { root.appendingPathComponent("project").path }
    var agentDir: String { root.appendingPathComponent("agent").path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    }

    func write(_ relative: String, name: String, description: String = "Test skill") throws -> String {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\nInstructions".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    func load(_ paths: [String] = [], defaults: Bool = false) -> LoadSkillsResult {
        loadSkills(cwd: cwd, agentDir: agentDir, skillPaths: paths, includeDefaults: defaults)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func i1SkillPathsLoadDefaultsOnlyWhenEnabled() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("agent/skills/user/SKILL.md", name: "user-skill")
    _ = try fixture.write("project/.pi/skills/project/SKILL.md", name: "project-skill")
    #expect(fixture.load().skills.isEmpty)
    let result = fixture.load(defaults: true)
    #expect(result.skills.map(\.name) == ["user-skill", "project-skill"])
    #expect(result.skills.map(\.sourceInfo.scope) == ["user", "project"])
    #expect(result.skills.allSatisfy { $0.sourceInfo.source == "local" })
    #expect(result.warnings.isEmpty)
}

@Test func i1SkillPathsLoadFilesAndDirectoriesRelativeToCwd() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("project/one.md", name: "one")
    _ = try fixture.write("project/collection/two/SKILL.md", name: "two")
    let result = fixture.load([" one.md ", "collection"])
    #expect(result.skills.map(\.name) == ["one", "two"])
    #expect(result.warnings.isEmpty)
}

@Test func i1SkillPathsDeduplicateSymlinkFilesAndDirectories() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    let file = try fixture.write("project/skill/SKILL.md", name: "sample")
    try FileManager.default.createSymbolicLink(atPath: fixture.cwd + "/alias.md", withDestinationPath: file)
    try FileManager.default.createSymbolicLink(atPath: fixture.cwd + "/alias-dir", withDestinationPath: fixture.cwd + "/skill")
    let result = fixture.load([file, "alias.md", "alias-dir"])
    #expect(result.skills.map(\.filePath) == [file])
    #expect(result.warnings.isEmpty)
}

@Test func i1SkillPathsKeepFirstNameAndReportCollisionAfterWarnings() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    let winner = try fixture.write("agent/skills/winner/SKILL.md", name: "sample")
    let loser = try fixture.write("project/loser.md", name: "sample", description: String(repeating: "x", count: 1025))
    let result = fixture.load([loser], defaults: true)
    #expect(result.skills.map(\.filePath) == [winner])
    #expect(result.warnings.map(\.skillPath) == [loser, loser])
    #expect(result.warnings.map(\.message) == ["description exceeds 1024 characters (1025)", "name \"sample\" collision"])
}

@Test func i1SkillPathsReportMissingAndNonMarkdownFiles() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("project/other.txt", name: "other")
    let result = fixture.load(["missing", "other.txt"])
    #expect(result.skills.isEmpty)
    #expect(result.warnings.map(\.message) == ["skill path does not exist", "skill path is not a markdown file"])
}

@Test func i1SkillPathsClassifyExplicitDefaultPathsWhenDefaultsAreOff() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    let user = try fixture.write("agent/skills/user/SKILL.md", name: "user")
    let project = try fixture.write("project/.pi/skills/project/SKILL.md", name: "project")
    #expect(fixture.load([user, project]).skills.map(\.sourceInfo.scope) == ["user", "project"])
    #expect(fixture.load([user], defaults: true).warnings.isEmpty)
}

@Test func i1SkillPathsStopAtDeclaredRoot() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    _ = try fixture.write("project/skill/SKILL.md", name: "root")
    _ = try fixture.write("project/skill/other.md", name: "other")
    _ = try fixture.write("project/skill/nested/SKILL.md", name: "nested")
    #expect(fixture.load(["skill"]).skills.map(\.name) == ["root"])
}

@Test func i1SkillPathsApplyIgnoreFilesAndNestedRules() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    for name in ["keep", "skip", "hidden"] {
        _ = try fixture.write("project/collection/\(name).md", name: name)
    }
    _ = try fixture.write("project/collection/nested/child/SKILL.md", name: "child")
    _ = try fixture.write("project/collection/nested/ignored/SKILL.md", name: "ignored")
    try "*.md\n!keep.md\n!SKILL.md\n\\!skip.md\n".write(toFile: fixture.cwd + "/collection/.gitignore", atomically: true, encoding: .utf8)
    try "ignored/\n".write(toFile: fixture.cwd + "/collection/nested/.ignore", atomically: true, encoding: .utf8)
    #expect(Set(fixture.load(["collection"]).skills.map(\.name)) == ["keep", "skip", "child"])
}

@Test func i1SkillPathsAcceptFileURLs() throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    let path = try fixture.write("project/a skill.md", name: "sample")
    #expect(fixture.load([URL(fileURLWithPath: path).absoluteString]).skills.map(\.name) == ["sample"])
}

@Test(arguments: [("true", true), ("\"true\"", false), ("false", false)])
func i1SkillPathsRequireBooleanForModelInvocation(value: String, disabled: Bool) throws {
    let fixture = try I1SkillFixture()
    defer { fixture.remove() }
    let file = fixture.cwd + "/SKILL.md"
    try "---\nname: sample\ndescription: Test\ndisable-model-invocation: \(value)\n---".write(toFile: file, atomically: true, encoding: .utf8)
    #expect(fixture.load([file]).skills.first?.disableModelInvocation == disabled)
    // The old loader retains its string-based flag for existing callers.
    #expect(loadSkillsFromDir(options: .init(dir: fixture.cwd, source: "test")).skills.first?.disableModelInvocation == (value != "false"))
}
