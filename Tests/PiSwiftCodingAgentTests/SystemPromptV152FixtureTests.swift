import Foundation
import Testing
@testable import PiSwiftCodingAgent

private struct TaggedPromptFixture: Decodable {
    struct Case: Decodable {
        struct Options: Decodable {
            struct SkillInput: Decodable {
                var name: String
                var description: String
                var filePath: String
            }
            var cwd: String
            var selectedTools: [String]?
            var customPrompt: String?
            var appendSystemPrompt: String?
            var toolSnippets: [String: String]?
            var toolGuidelines: [String: [String]]?
            var contextFiles: [ContextFileInput]?
            var skills: [SkillInput]?
        }
        struct ContextFileInput: Decodable {
            var path: String
            var content: String
        }
        var name: String
        var options: Options
        var expected: String
    }
    var tag: String
    var cases: [Case]
}

@Test func systemPromptV152MatchesTaggedBuildSystemPromptForSevenConfigurations() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("fixtures/system-prompt-v152.json")
    let fixture = try JSONDecoder().decode(TaggedPromptFixture.self, from: Data(contentsOf: root))
    #expect(fixture.tag == "v1.5.2")
    #expect(fixture.cases.map(\.name) == [
        "default tools", "no tools", "custom prompt", "appended prompt", "skills",
        "project context files", "codemode active",
    ])
    for item in fixture.cases {
        let input = item.options
        let skills = input.skills?.map { skill in
            Skill(name: skill.name, description: skill.description, filePath: skill.filePath,
                baseDir: URL(fileURLWithPath: skill.filePath).deletingLastPathComponent().path, source: "test")
        }
        let options = BuildSystemPromptOptions(customPrompt: input.customPrompt,
            selectedToolNames: input.selectedTools, appendSystemPrompt: input.appendSystemPrompt,
            cwd: input.cwd, contextFiles: input.contextFiles?.map { ContextFile(path: $0.path, content: $0.content) },
            skills: skills, toolSnippets: input.toolSnippets, toolGuidelines: input.toolGuidelines)
        let expected = item.expected.replacingOccurrences(of: "{{PACKAGE_DIR}}", with: getPackageDir())
        #expect(try buildSystemPrompt(options) == expected, "Tagged prompt mismatch: \(item.name)")
    }
}
