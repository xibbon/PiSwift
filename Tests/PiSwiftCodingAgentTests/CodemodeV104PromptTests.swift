import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let v104ReadGuideline = "Use read to examine files instead of cat or sed."

private func v104HiddenPrompt(_ hidden: [String]) throws -> String {
    try buildSystemPrompt(.init(selectedToolNames: ["read", "bash", "run"], contextFiles: [],
        skills: [Skill(name: "sample", description: "Sample skill", filePath: "/skills/sample/SKILL.md",
                       baseDir: "/skills/sample", source: "test")],
        toolSnippets: ["read": "Read files", "bash": "Run commands", "run": "Run a task"],
        toolGuidelines: ["read": ["Use read for files."], "run": ["Prefer run."]], hiddenTools: hidden))
}

// v1.0.4 #10343: system-prompt.test.ts, hidden tools.
@Test func codemodeV104HiddenToolsLeaveListAndRules() throws {
    let prompt = try v104HiddenPrompt(["read", "bash"])
    #expect(prompt.contains("<tools>\n- run: Run a task\n"))
    #expect(!prompt.contains("- read: "))
    #expect(!prompt.contains("Use read for files."))
    #expect(!prompt.contains("Use bash for file operations"))
    #expect(prompt.contains("- Prefer run."))
}

// v1.0.4 #10343: system-prompt.test.ts, hidden reader skills hint.
@Test func codemodeV104SkillsNameOnlyDeclaredReaders() throws {
    #expect(try v104HiddenPrompt(["read", "bash"]).contains("\nLoad a skill's file when the task matches its description."))
    #expect(try v104HiddenPrompt(["read"]).contains("Use bash to load a skill's file"))
    #expect(try v104HiddenPrompt([]).contains("Use the read tool to load a skill's file"))
    let noReader = try buildSystemPrompt(.init(selectedToolNames: ["run"], contextFiles: [],
        skills: [Skill(name: "sample", description: "Sample skill", filePath: "/skills/sample/SKILL.md",
                       baseDir: "/skills/sample", source: "test")]))
    #expect(!noReader.contains("<available_skills>"))
    #expect(BuildSystemPromptOptions(hiddenTools: ["read", "bash"]).hiddenTools == ["bash", "read"])
}

private func v104PromptTool(_ name: String, description: String = "Tool description") -> AgentTool {
    AgentTool(label: name, name: name, description: description, parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [])
    }
}

// v1.0.4 #10343: toCodemodeDeclaration trims and drops blanks, but keeps duplicates.
@Test func codemodeV104DeclarationsCarryGuidelines() {
    let tool = v104PromptTool("sample", description: "  Tool description \n")
    let guidelines = ["  Use sample. \n", "  ", "Use sample.", "\n Keep output short.\t"]
    let declaration = CodemodeDeclaration(tool: tool, guidelines: guidelines)
    #expect(declaration.description == "Tool description\n\n- Use sample.\n- Use sample.\n- Keep output short.")
    #expect(CodemodeDeclaration(tool: tool).description == tool.description)
    #expect(CodemodeDeclaration(tool: tool, guidelines: ["\n", " "]).description == tool.description)
    let description = createCodemodeDescription([tool], options: .init(inlineBudget: nil,
        guidelines: ["sample": guidelines]))
    #expect(description.contains("- Use sample.\n- Use sample.\n- Keep output short."))
    #expect(createCodemodeDescription([tool], options: .init(inlineBudget: nil, guidelines: ["sample": [" "]])) ==
            createCodemodeDescription([tool], options: .init(inlineBudget: nil)))
    #expect(!createCodemodeDescription([tool], options: .init(inlineBudget: 0, guidelines: ["sample": guidelines])).contains("### `sample`"))
}

// v1.0.4 #10343: prepareCodemodeLoadout asks only for listed tools' guidelines.
@Test func codemodeV104LoadoutReadsListedGuidelinesOnly() {
    let direct = v104PromptTool("direct")
    let code = v104PromptTool("code")
    let deferred = v104PromptTool("deferred")
    let codemode = v104PromptTool("codemode")
    let requested = LockedState<[String]>([])
    let loadout = ToolLoadout(declared: [direct, codemode], callable: [direct, code, deferred, codemode],
        registered: [direct, code, deferred, codemode],
        getExposure: { $0 == "code" ? .codemode : $0 == "deferred" ? .deferred : .direct },
        getNamespace: { _ in nil }, getPromptGuidelines: { name in
            requested.withLock { $0.append(name) }
            return ["Use \(name)."]
        })
    let changes = prepareCodemodeLoadout(loadout)
    #expect(requested.withLock { $0 } == ["code", "deferred"])
    #expect(changes.descriptions?["codemode"]?.contains("- Use code.") == true)
    #expect(changes.descriptions?["codemode"]?.contains("- Use deferred.") == false)
    #expect(changes.descriptions?["direct"]?.contains("- Use direct.") == false)
    #expect(ToolLoadout(declared: [], callable: [], registered: [], getExposure: { _ in .direct },
                       getNamespace: { _ in nil }).getPromptGuidelines("missing").isEmpty)
}

private func v104PromptResponse(_ model: Model, script: String?) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let content: [ContentBlock] = script.map {
        [.toolCall(ToolCall(id: "guidelines", name: "codemode", arguments: ["code": AnyCodable($0)]))]
    } ?? [.text(TextContent(text: "done"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: script == nil ? .stop : .toolUse)
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

// v1.0.4 #10343: agent-session-codemode.test.ts, describeTool with zero inline budget.
@Test(.timeLimit(.minutes(1))) func codemodeV104SessionDescribesUnlistedBuiltInGuidelines() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let settings = SettingsManager.inMemory()
    settings.setCodemodeMode(.only)
    settings.setCodemodeInlineBudget(0)
    // C1 U3: SDK tool-list validation now throws.
    let created = try await createAgentSession(CreateAgentSessionOptions(authStorage: auth, model: model,
        offline: true, toolNames: ["read", "codemode"], resourceLoader: TestResourceLoader(),
        inlineExtensions: [createCodemodeExtension()], sessionManager: .inMemory(), settingsManager: settings))
    let session = created.session
    defer { session.dispose() }
    #expect(session.agent.tools.first { $0.name == "codemode" }?.description.contains("### `read`") == false)
    #expect(session.getAllTools().first { $0.name == "read" }?.promptGuidelines == [v104ReadGuideline])
    #expect(session.getCurrentSystemPromptOptions().hiddenTools == ["read"])
    let requests = LockedState<[TranscriptContext]>([])
    let count = LockedState(0)
    session.agent.streamFn = { model, context, _ in
        requests.withLock { $0.append(context) }
        let current = count.withLock { $0 += 1; return $0 }
        return v104PromptResponse(model, script: current == 1 ? "text(await describeTool('read')); text(await searchTools('read')); text(ALL_TOOLS);" : nil)
    }
    try await session.prompt("go")
    let result = try #require(session.messages.compactMap { message -> ToolResultMessage? in
        if case .toolResult(let result) = message, result.toolName == "codemode" { return result }
        return nil
    }.last)
    #expect(!result.isError)
    let text = result.content.compactMap { if case .text(let block) = $0 { return block.text }; return nil }
    // Upstream v1.1.0: adjacent text() output joins in one content block.
    #expect(text.joined(separator: "\n").components(separatedBy: "- " + v104ReadGuideline).count - 1 == 3)
    let request = try #require(requests.withLock { $0.first })
    #expect(!getCurrentSystemPrompt(request.messages).contains("Use read to examine files"))
}

// v1.0.4 #10343: getAllTools reports rules for every registered built-in tool.
// C1 U3: propagate the SDK error; authorized follow-up test edit.
@Test func codemodeV104AllToolsReportBuiltInGuidelines() async throws {
    let auth = AuthStorage(":memory:")
    // C1 U3: SDK tool-list validation now throws.
    let created = try await createAgentSession(CreateAgentSessionOptions(authStorage: auth,
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"), offline: true,
        toolNames: ["read", "bash", "edit", "write"], resourceLoader: TestResourceLoader(),
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    let session = created.session
    defer { session.dispose() }
    #expect(session.getAllTools().first { $0.name == "read" }?.promptGuidelines == [v104ReadGuideline])
    #expect(session.getAllTools().first { $0.name == "bash" }?.promptGuidelines ==
            ["You can inspect PI_* environment variables for current model and session details."])
    #expect(session.getAllTools().first { $0.name == "write" }?.promptGuidelines ==
            ["Use write only for new files or complete rewrites."])
    #expect(session.getAllTools().first { $0.name == "edit" }?.promptGuidelines?.count == 4)
}

// v1.0.4 #10343: ToolLoadout guidelines use the normalized session snapshot.
@Test func codemodeV104SessionNormalizesGuidelineSnapshot() {
    let observed = LockedState<[String: [String]]>([:])
    let tool = v104PromptTool("sample")
    let definition = CustomTool(name: "sample", label: "sample", description: "Sample",
        execute: { _, _, _, _, _ in AgentToolResult(content: []) },
        promptGuidelines: ["  First. ", " ", "First.", "\nSecond.\n"],
        prepareLoadout: { loadout in
            observed.withLock { $0 = ["sample": loadout.getPromptGuidelines("sample"),
                                       "read": loadout.getPromptGuidelines("read"),
                                       "missing": loadout.getPromptGuidelines("missing")] }
            return nil
        })
    let agent = Agent(AgentOptions(initialState: AgentState(tools: [tool])))
    let read = v104PromptTool("read")
    let session = AgentSession(config: .init(agent: agent, sessionManager: .inMemory(), settingsManager: .inMemory(),
        resourceLoader: TestResourceLoader(),
        systemPromptOptions: .init(toolGuidelines: ["read": [" Override read. ", "Override read."]]),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")),
        toolRegistry: ["sample": tool, "read": read], toolDefinitions: ["sample": definition]))
    defer { session.dispose() }
    session.setActiveToolsByName(["sample", "read"])
    #expect(observed.withLock { $0["sample"] } == ["First.", "Second."])
    #expect(observed.withLock { $0["read"] } == ["Override read."])
    #expect(observed.withLock { $0["missing"] } == [])
}
