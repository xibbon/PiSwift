import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// Upstream v1.1.0 core/tools: read:20, bash:45, edit:43, write:16,
// grep:35, find:34, ls:16. Use literal text to detect changes to the constants.
@Test func i1ToolPromptContributionsMatchUpstream() {
    let expected: [(ToolSystemPromptContribution, String, [String])] = [
        (readToolSystemPromptContribution, "Read file contents", ["Use read to examine files instead of cat or sed."]),
        (bashToolSystemPromptContribution, "Execute bash commands (ls, grep, find, etc.)", ["You can inspect PI_* environment variables for current model and session details."]),
        (editToolSystemPromptContribution, "Make precise file edits with exact text replacement, including multiple disjoint edits in one call", [
            "Use edit for precise changes (edits[].oldText must match exactly)",
            "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
            "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
            "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
        ]),
        (writeToolSystemPromptContribution, "Create or overwrite files", ["Use write only for new files or complete rewrites."]),
        (grepToolSystemPromptContribution, "Search file contents for patterns (respects .gitignore)", []),
        (findToolSystemPromptContribution, "Find files by glob pattern (respects .gitignore)", []),
        (lsToolSystemPromptContribution, "List directory contents", []),
    ]
    for (contribution, snippet, guidelines) in expected {
        #expect(contribution.snippet == snippet)
        #expect(contribution.guidelines == guidelines)
    }
}

@Test(.timeLimit(.minutes(1))) func i1AgentSessionKeepsBuiltInPromptText() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let tools = ["read", "bash", "edit", "write"].map { name in
        AgentTool(label: name, name: name, description: name, parameters: [:]) { _, _, _, _ in
            AgentToolResult(content: [.text(TextContent(text: "ok"))])
        }
    }
    let requests = LockedState<[TranscriptContext]>([])
    let agent = Agent(AgentOptions(initialState: AgentState(model: model, tools: tools),
        streamFn: { model, context, _ in
            requests.withLock { $0.append(context) }
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }, getApiKey: { _ in "test" }))
    let auth = AuthStorage.inMemory()
    auth.setRuntimeApiKey(model.provider, "test")
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(), resourceLoader: TestResourceLoader(),
        systemPromptOptions: BuildSystemPromptOptions(cwd: "/i1", contextFiles: [], skills: []),
        modelRegistry: ModelRegistry(auth),
        toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })))
    defer { session.dispose() }
    try await session.prompt("hello")
    let request = try #require(requests.withLock { $0.first })
    let sections = try #require(getCurrentSystemMessage(request.messages)?.sections)
    #expect(sections["tools"] == """
    <tools>
    - read: Read file contents
    - bash: Execute bash commands (ls, grep, find, etc.)
    - edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call
    - write: Create or overwrite files

    In addition to the tools above, you may have access to other custom tools depending on the project.
    </tools>
    """)
    #expect(sections["rules"] == """
    <rules>
    - Use bash for file operations like ls, rg, find
    - Use read to examine files instead of cat or sed.
    - You can inspect PI_* environment variables for current model and session details.
    - Use edit for precise changes (edits[].oldText must match exactly)
    - When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls
    - Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.
    - Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.
    - Use write only for new files or complete rewrites.
    - Be concise in your responses
    - Show file paths clearly when working with files
    </rules>
    """)
    #expect(session.getAllTools().first { $0.name == "edit" }?.promptGuidelines == editToolSystemPromptContribution.guidelines)
}
