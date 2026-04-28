import PiSwiftAgent

public enum Mode: String, Sendable {
    case text
    case json
    case rpc
}

public enum ListModelsOption: Equatable, Sendable {
    case all
    case search(String)
}

public struct Args: Sendable {
    public var provider: String?
    public var model: String?
    public var apiKey: String?
    public var systemPrompt: String?
    /// v0.67.2: now an array. Multiple `--append-system-prompt` values are joined by `\n\n`.
    public var appendSystemPrompts: [String]?
    public var thinking: ThinkingLevel?
    public var `continue`: Bool?
    public var resume: Bool?
    public var help: Bool?
    public var version: Bool?
    public var mode: Mode?
    public var noSession: Bool?
    public var session: String?
    public var sessionDir: String?
    public var models: [String]?
    public var tools: [ToolName]?
    public var hooks: [String]?
    public var customTools: [String]?
    public var noTools: Bool?
    /// v0.68.0 / v0.70.0: disable only built-in default tools while keeping extension/custom tools
    /// active. Distinct from `noTools` (which disables everything).
    public var noBuiltinTools: Bool?
    public var noExtensions: Bool?
    public var print: Bool?
    public var export: String?
    public var noSkills: Bool?
    public var noPromptTemplates: Bool?
    /// v0.67.4: `--no-context-files` (`-nc`) disables AGENTS.md / CLAUDE.md auto-discovery.
    public var noContextFiles: Bool?
    public var skills: [String]?
    /// v0.65.0: explicit theme file paths or directories. Repeatable on the CLI as
    /// `--theme path1.json --theme path2.json`. Plumbed to `DefaultResourceLoader` as
    /// `additionalThemePaths` so they merge with discovered themes.
    public var themes: [String]?
    public var listModels: ListModelsOption?
    public var verbose: Bool?
    public var fork: String?
    public var offline: Bool?
    public var messages: [String]
    public var fileArgs: [String]

    public init() {
        self.messages = []
        self.fileArgs = []
    }

    /// v0.67.2: convenience accessor that joins multiple `--append-system-prompt` values
    /// with double newlines, matching upstream behavior.
    public var appendSystemPrompt: String? {
        guard let prompts = appendSystemPrompts, !prompts.isEmpty else { return nil }
        return prompts.joined(separator: "\n\n")
    }
}

private let validThinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh"]

public func isValidThinkingLevel(_ level: String) -> Bool {
    validThinkingLevels.contains(level)
}
