import PiSwiftCodingAgent
import PiSwiftDurable
import PiSwiftAI
import Synchronization

private let piPromptKeys = ["preamble", "tools", "rules", "docs", "project_context", "skills", "cwd"]
private let piPromptContributions = [
    "read": readToolSystemPromptContribution,
    "bash": bashToolSystemPromptContribution,
    "edit": editToolSystemPromptContribution,
    "write": writeToolSystemPromptContribution,
]

/// Creates pi's prompt sections for the selected tools and working directory.
/// Context files and skills load once per directory. The build cache holds 128 entries.
public func createPiPrompt(settingsManager: SettingsManager, fallbackCwd: String) -> PiSwiftDurable.Extension {
    let cache = PiPromptCache(settings: settingsManager, fallbackCwd: fallbackCwd)
    return defineExtension(PiSwiftDurable.Extension(name: "pi-prompt", sections: piPromptKeys.map { key in
        section(key, tag: false) { input, _ in try cache.build(input)[key] }
    }))
}

/// A bounded cache replaces the upstream cache based on request object identity.
internal final class PiPromptCache: Sendable {
    internal static let buildLimit = 128

    private struct Key: Hashable, Sendable {
        let cwd: String
        let selectedNames: [String]

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.cwd.utf16.elementsEqual(rhs.cwd.utf16)
                && lhs.selectedNames.count == rhs.selectedNames.count
                && zip(lhs.selectedNames, rhs.selectedNames).allSatisfy { pair in
                    pair.0.utf16.elementsEqual(pair.1.utf16)
                }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(Array(cwd.utf16))
            hasher.combine(selectedNames.map { Array($0.utf16) })
        }
    }
    private struct Resources: Sendable {
        let contextFiles: [ContextFile]
        let skills: [Skill]
    }
    private struct State: Sendable {
        var resources: [[UInt16]: Resources] = [:]
        var builds: [Key: SystemPromptSections] = [:]
        var order: [Key] = []
    }

    private let settings: SettingsManager
    private let fallbackCwd: String
    private let agentDirectory: @Sendable () -> String
    private let buildSections: @Sendable (BuildSystemPromptOptions) throws -> SystemPromptSections
    private let state = Mutex(State())

    internal init(settings: SettingsManager, fallbackCwd: String,
                  agentDirectory: @escaping @Sendable () -> String = { getAgentDir() },
                  buildSections: @escaping @Sendable (BuildSystemPromptOptions) throws -> SystemPromptSections = {
                      try buildSystemPromptSections($0)
                  }) {
        self.settings = settings
        self.fallbackCwd = fallbackCwd
        self.agentDirectory = agentDirectory
        self.buildSections = buildSections
    }

    internal func build(_ input: PromptInput) throws -> SystemPromptSections {
        let key = Key(cwd: input.env?.cwd ?? input.agent.cwd ?? fallbackCwd,
                      selectedNames: input.agent.tools.map(\.name))
        return try state.withLock { state in
            if let found = state.builds[key] { return found }
            let directoryKey = Array(key.cwd.utf16)
            let resources: Resources
            if let found = state.resources[directoryKey] {
                resources = found
            } else {
                let agentDir = agentDirectory()
                resources = Resources(
                    contextFiles: loadProjectContextFiles(.init(cwd: key.cwd, agentDir: agentDir)),
                    skills: loadSkills(cwd: key.cwd, agentDir: agentDir,
                                       skillPaths: settings.getSkillPaths(), includeDefaults: true).skills
                )
                state.resources[directoryKey] = resources
            }
            var snippets: [String: String] = [:]
            var guidelines: [String: [String]] = [:]
            for name in key.selectedNames {
                guard let contribution = piPromptContributions[name] else { continue }
                snippets[name] = contribution.snippet
                guidelines[name] = contribution.guidelines
            }
            let sections = try buildSections(BuildSystemPromptOptions(
                selectedToolNames: key.selectedNames, cwd: key.cwd,
                contextFiles: resources.contextFiles, skills: resources.skills,
                toolSnippets: snippets, toolGuidelines: guidelines
            ))
            if state.order.count == Self.buildLimit {
                state.builds.removeValue(forKey: state.order.removeFirst())
            }
            state.order.append(key)
            state.builds[key] = sections
            return sections
        }
    }
}
