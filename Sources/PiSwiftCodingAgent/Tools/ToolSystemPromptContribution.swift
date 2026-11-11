/// Text that a tool adds to the system prompt.
public struct ToolSystemPromptContribution: Sendable, Equatable {
    public let snippet: String
    public let guidelines: [String]

    public init(snippet: String, guidelines: [String]) {
        self.snippet = snippet
        self.guidelines = guidelines
    }
}

// Keep this text equal to coding-agent/src/core/tools at upstream v1.5.2.
public let readToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Read file contents",
    guidelines: ["Use read to examine files instead of cat or sed."]
)

public let bashToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Execute bash commands (ls, grep, find, etc.)",
    guidelines: ["You can inspect PI_* environment variables for current model and session details."]
)

public let editToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
    guidelines: [
        "Use edit for targeted changes. Batch changes to one file in a single call.",
        "Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and non-overlapping; merge nearby changes without including large unchanged regions.",
    ]
)

public let writeToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Create or overwrite files",
    guidelines: ["Use write only for new files or complete rewrites."]
)

public let grepToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Search file contents for patterns (respects .gitignore)", guidelines: []
)

public let findToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "Find files by glob pattern (respects .gitignore)", guidelines: []
)

public let lsToolSystemPromptContribution = ToolSystemPromptContribution(
    snippet: "List directory contents", guidelines: []
)
