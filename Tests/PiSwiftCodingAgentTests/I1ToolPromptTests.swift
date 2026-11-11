import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// v1.5.2 C-SESS 705d047cb, core/tools/edit.ts:41-45 updates the edit guidelines.
// Upstream v1.1.0 core/tools: read:20, bash:45, write:16,
// grep:35, find:34, ls:16. Use literal text to detect changes to the constants.
@Test func i1ToolPromptContributionsMatchUpstream() {
    let expected: [(ToolSystemPromptContribution, String, [String])] = [
        (readToolSystemPromptContribution, "Read file contents", ["Use read to examine files instead of cat or sed."]),
        (bashToolSystemPromptContribution, "Execute bash commands (ls, grep, find, etc.)", ["You can inspect PI_* environment variables for current model and session details."]),
        (editToolSystemPromptContribution, "Make precise file edits with exact text replacement, including multiple disjoint edits in one call", [
            "Use edit for targeted changes. Batch changes to one file in a single call.",
            "Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and non-overlapping; merge nearby changes without including large unchanged regions.",
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
    // v1.5.2 C-SESS 705d047cb, system-prompt.ts:160 and tools/edit.ts:43-45.
    #expect(sections["tools"] == """
    <tools>
    - read: Read file contents
    - bash: Execute bash commands (ls, grep, find, etc.)
    - edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call
    - write: Create or overwrite files

    Additional tools may be available.
    </tools>
    """)
    #expect(sections["rules"] == """
    <rules>
    - Use bash for file operations like ls, rg, find
    - Use read to examine files instead of cat or sed.
    - You can inspect PI_* environment variables for current model and session details.
    - Use edit for targeted changes. Batch changes to one file in a single call.
    - Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and non-overlapping; merge nearby changes without including large unchanged regions.
    - Use write only for new files or complete rewrites.
    - Be concise in your responses
    - Show file paths clearly when working with files
    </rules>
    """)
    #expect(session.getAllTools().first { $0.name == "edit" }?.promptGuidelines == editToolSystemPromptContribution.guidelines)
}
