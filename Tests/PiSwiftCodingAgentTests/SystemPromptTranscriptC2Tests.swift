import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c2Response(_ model: Model) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api,
        provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

private func c2Session(_ manager: SessionManager, requests: LockedState<[TranscriptContext]>,
                       tools: [AgentTool] = [], hooks: [LoadedHook] = [],
                       model: Model = getModel(provider: .openai, modelId: "gpt-4o-mini"),
                       settings: Settings = Settings(),
                       loader: ResourceLoader = TestResourceLoader()) -> AgentSession {
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let runner = hooks.isEmpty ? nil : HookRunner(hooks, manager.getCwd(), manager, ModelRegistry(auth))
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "old", model: model, tools: tools),
        streamFn: { model, context, _ in
            requests.withLock { $0.append(context) }
            return c2Response(model)
        }, getApiKey: { _ in "test" }))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: loader,
        systemPromptOptions: BuildSystemPromptOptions(cwd: manager.getCwd(), contextFiles: [], skills: []), hookRunner: runner,
        modelRegistry: ModelRegistry(auth), toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })))
}

private func c2Tool() -> AgentTool {
    AgentTool(label: "read", name: "read", description: "Read", parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "read"))])
    }
}

@Test func c2FirstRequestPersistsStructuredHeadAndReloads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c2-head-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(id: "c2-head")))
    let requests = LockedState<[TranscriptContext]>([])
    let session = c2Session(manager, requests: requests, tools: [c2Tool()])
    defer { session.dispose() }
    try await session.prompt("hello")
    let entries = manager.getEntries()
    guard case .message(let first) = try #require(entries.first), case .system(let system) = first.message else {
        Issue.record("Missing leading persisted system message"); return
    }
    #expect(system.sections?.entries.map(\.name) == ["preamble", "tools", "rules", "docs", "cwd"])
    #expect(system.toolsAdded?.map(\.name) == ["read"])
    #expect(requests.withLock { $0.first?.messages.first?.role } == "system")
    let reopened = SessionManager.open(file)
    #expect(getCurrentSystemPrompt(reopened.buildSessionProjection().messages) == getSystemMessageText(system))
}

@Test func c2ProviderUsesCanonicalProjectionAfterDirectAgentMutation() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let session = c2Session(manager, requests: requests)
    defer { session.dispose() }
    try await session.prompt("original")
    let user = try #require(manager.getEntries().first { entry in
        if case .message(let value) = entry { return value.message.role == "user" }
        return false
    })
    _ = try manager.appendContextEdit(user.id, .text("canonical"))
    session.agent.messages = [.user(UserMessage(content: .text("corrupt")))]
    try await session.prompt("second")
    let recorded = requests.withLock { $0 }
    #expect(recorded.count == 2)
    let text = recorded[1].messages.compactMap { message -> String? in
        if case .user(let user) = message, case .text(let value) = user.content { return value }
        return nil
    }
    #expect(text.contains("canonical"))
    #expect(!text.contains("corrupt"))
}

@Test func c2SectionDiffPreservesPrefixAndRemovesCustomSection() throws {
    let base = BuildSystemPromptOptions(cwd: "/tmp", contextFiles: [], skills: [],
        sections: SystemPromptSections([("plan_mode", "Plan only")]))
    let first = try buildSystemPromptSections(base)
    var second = base
    second.sections = SystemPromptSections([("plan_mode", "Execute")])
    let changed = diffSystemPromptSections(first, try buildSystemPromptSections(second))
    #expect(changed?.entries.map(\.name) == ["plan_mode"])
    #expect(changed?["plan_mode"] == "<plan_mode>\nExecute\n</plan_mode>")
    let removed = diffSystemPromptSections(first, try buildSystemPromptSections(BuildSystemPromptOptions(cwd: "/tmp", contextFiles: [], skills: [])))
    #expect(removed?.entries.first?.name == "plan_mode")
    #expect(removed?.entries.first?.value == nil)
    let unchangedPrefix = try buildSystemPromptSections(second).entries.prefix(5).map(\.value)
    #expect(first.entries.prefix(5).map(\.value) == unchangedPrefix)
}

@Test func c2ForcedPromptIsOnlyAtProviderHead() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let count = LockedState(0)
    let handler: HookHandler = { _, _ in
        let turn = count.withLock { value -> Int in value += 1; return value }
        return turn == 2 ? BeforeAgentStartEventResult(systemPrompt: "Exact forced prompt") : nil
    }
    let hook = LoadedHook(path: "c2", resolvedPath: "c2", handlers: ["before_agent_start": [handler]])
    let session = c2Session(manager, requests: requests, hooks: [hook])
    defer { session.dispose() }
    try await session.prompt("one")
    try await session.prompt("two")
    try await session.prompt("three")
    let recorded = requests.withLock { $0 }
    #expect(recorded.count == 3)
    #expect(getCurrentSystemPrompt(recorded[1].messages) == "Exact forced prompt")
    #expect(getCurrentSystemPrompt(recorded[2].messages) != "Exact forced prompt")
    #expect(!manager.buildSessionProjection().messages.contains { message in
        if case .system(let system) = message { return getSystemMessageText(system).contains("Exact forced prompt") }
        return false
    })
}

@Test func c2ToolRemovalReplaysAcrossBranchAndKeepsRequestPrefix() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let model = getModel(provider: .anthropic, modelId: "claude-fable-5")
    #expect(model.compat?.supportsMidConvoSystemMessages == true)
    let session = c2Session(manager, requests: requests, tools: [c2Tool()], model: model)
    defer { session.dispose() }
    try await session.prompt("first")
    let firstAssistant = try #require(manager.getEntries().first { entry in
        if case .message(let value) = entry { return value.message.role == "assistant" }
        return false
    })
    session.setActiveToolsByName([])
    try await session.prompt("second")
    let systems = manager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
    #expect(systems.count == 2)
    #expect(systems[1].toolsRemoved?.map(\.name) == ["read"])
    #expect(systems[1].sections?.entries.map(\.name) == ["tools", "rules"])
    let contexts = requests.withLock { $0 }
    guard case .system(let initial)? = contexts[0].messages.first,
          case .system(let cached)? = contexts[1].messages.first else {
        Issue.record("Expected provider system heads"); return
    }
    #expect(encodeAgentMessageJSON(.system(initial)).serialized() == encodeAgentMessageJSON(.system(cached)).serialized())
    let result = await session.navigateTree(firstAssistant.id)
    #expect(!result.cancelled)
    #expect(session.getActiveToolNames() == ["read"])
    #expect(getCurrentTools(manager.buildSessionProjection().messages).map(\.name) == ["read"])
}

@Test func c2AddingSkillOnlyPatchesSkillsSection() throws {
    let skill = Skill(name: "new", description: "New skill", filePath: "/tmp/new/SKILL.md", baseDir: "/tmp/new", source: "test")
    let original = try buildSystemPromptSections(BuildSystemPromptOptions(cwd: "/tmp", contextFiles: [], skills: []))
    let added = try buildSystemPromptSections(BuildSystemPromptOptions(cwd: "/tmp", contextFiles: [], skills: [skill]))
    let patch = diffSystemPromptSections(original, added)
    #expect(patch?.entries.map(\.name) == ["skills"])
    #expect(patch?["skills"]?.contains("<name>new</name>") == true)
    #expect(isValidSystemPromptSectionName("plan_mode"))
    #expect(!isValidSystemPromptSectionName("preamble"))
    #expect(!isValidSystemPromptSectionName("Bad Name"))
}

@Test func c2StructuredPromptRendersExactSectionOrder() throws {
    let options = BuildSystemPromptOptions(customPrompt: "Exact preamble", selectedToolNames: ["custom"],
        appendSystemPrompt: "Extra", cwd: "C:\\work", contextFiles: [ContextFile(path: "/tmp/AGENTS.md", content: "Rules")],
        skills: [], toolSnippets: ["custom": "Do custom work"],
        sections: SystemPromptSections([("zeta", "Z"), ("alpha", "A")]))
    let sections = try buildSystemPromptSections(options)
    #expect(sections.entries.map(\.name) == ["preamble", "addendum", "project_context", "cwd", "zeta", "alpha"])
    #expect(sections["preamble"] == "Exact preamble")
    #expect(sections["cwd"] == "<cwd>\nC:/work\n</cwd>")
    #expect(try buildSystemPrompt(options) == sections.entries.compactMap(\.value).joined(separator: "\n\n"))
    #expect(try buildSystemPrompt(BuildSystemPromptOptions(cwd: "/tmp", forceSystemPrompt: "forced")) == "forced")
}

@Test func c2InvalidCustomSectionNameThrows() {
    for name in ["preamble", "Bad Name", "1first", "éclair"] {
        let options = BuildSystemPromptOptions(cwd: "/tmp", contextFiles: [], skills: [],
            sections: SystemPromptSections([(name, "invalid")]))
        do {
            _ = try buildSystemPromptSections(options)
            Issue.record("Expected an invalid section name error for \(name)")
        } catch let error as SystemPromptError {
            #expect(error == .invalidSectionName(name))
            #expect(error.localizedDescription == "Invalid system prompt section name: \(name)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func c2TreeNavigationWaitsForActiveCompaction() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let started = LockedState(false)
    let released = LockedState(false)
    let handler: HookHandler = { event, _ in
        guard let event = event as? SessionBeforeCompactEvent else { return nil }
        started.withLock { $0 = true }
        while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
        return SessionBeforeCompactResult(compaction: CompactionResult(summary: "short",
            firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore))
    }
    let hook = LoadedHook(path: "c2-compact", resolvedPath: "c2-compact", handlers: ["session_before_compact": [handler]])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 1)
    let session = c2Session(manager, requests: requests, hooks: [hook], settings: settings)
    defer { session.dispose() }
    try await session.prompt("first")
    try await session.prompt("second")
    let target = try #require(manager.getEntries().first { entry in
        if case .message(let value) = entry { return value.message.role == "assistant" }
        return false
    })
    let originalLeaf = manager.getLeafId()
    let task = Task { try await session.compact() }
    let deadline = Date().addingTimeInterval(5)
    while !started.withLock({ $0 }) && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(started.withLock { $0 })
    let navigation = await session.navigateTree(target.id)
    #expect(navigation.cancelled)
    #expect(manager.getLeafId() == originalLeaf)
    released.withLock { $0 = true }
    _ = try await task.value
}

@Test func c2LegacyBeforeStartAppendIsRemovedOnNextRun() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let count = LockedState(0)
    let handler: HookHandler = { _, _ in
        let turn = count.withLock { value -> Int in value += 1; return value }
        return turn == 1 ? BeforeAgentStartEventResult(systemPromptAppend: "Temporary rule") : nil
    }
    let hook = LoadedHook(path: "c2-append", resolvedPath: "c2-append", handlers: ["before_agent_start": [handler]])
    let session = c2Session(manager, requests: requests, hooks: [hook])
    defer { session.dispose() }
    try await session.prompt("first")
    try await session.prompt("second")
    let recorded = requests.withLock { $0 }
    #expect(getCurrentSystemPrompt(recorded[0].messages).contains("Temporary rule"))
    #expect(!getCurrentSystemPrompt(recorded[1].messages).contains("Temporary rule"))
    let systems = manager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
    #expect(systems.last?.sections?.entries.contains { $0.name == "addendum" && $0.value == nil } == true)
}

@Test func c2ResumedSessionReplaysHeadWithoutDuplicate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c2-resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(id: "c2-resume")))
    let firstRequests = LockedState<[TranscriptContext]>([])
    let first = c2Session(manager, requests: firstRequests, tools: [c2Tool()])
    try await first.prompt("first")
    first.dispose()
    let firstHead = try #require(manager.buildSessionProjection().messages.first?.transcriptSystemMessage)

    let reopened = SessionManager.open(file)
    let nextRequests = LockedState<[TranscriptContext]>([])
    let resumed = c2Session(reopened, requests: nextRequests, tools: [c2Tool()])
    defer { resumed.dispose() }
    #expect(resumed.getActiveToolNames() == ["read"])
    try await resumed.prompt("second")
    let systems = reopened.getEntries().filter { entry in
        if case .message(let value) = entry { return value.message.role == "system" }
        return false
    }
    #expect(systems.count == 1)
    guard case .system(let requestHead)? = nextRequests.withLock({ $0.first?.messages.first }) else {
        Issue.record("Expected resumed request head"); return
    }
    #expect(encodeAgentMessageJSON(.system(requestHead)).serialized() == encodeAgentMessageJSON(.system(firstHead)).serialized())
}

@Test func c2LegacySessionAddsPromptAtFirstNewRequest() async throws {
    let manager = SessionManager.inMemory()
    manager.appendMessage(.user(UserMessage(content: .text("legacy"))))
    let requests = LockedState<[TranscriptContext]>([])
    let session = c2Session(manager, requests: requests)
    defer { session.dispose() }
    #expect(manager.buildSessionProjection().messages.map(\.role) == ["user"])
    try await session.prompt("new")
    #expect(manager.buildSessionProjection().messages.map(\.role).prefix(3) == ["user", "system", "user"])
    #expect(requests.withLock { $0.first?.messages.contains { $0.role == "system" } } == true)
}

@Test func c2OversizedTrailingToolResultKeepsLatestValidCut() throws {
    let manager = SessionManager.inMemory()
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    func assistant(_ content: [ContentBlock], _ reason: StopReason = .stop) -> AgentMessage {
        .assistant(AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: reason))
    }
    manager.appendMessage(.user(UserMessage(content: .text("old history"))))
    manager.appendMessage(assistant([.text(TextContent(text: "old answer"))]))
    manager.appendMessage(.user(UserMessage(content: .text("read large file"))))
    let callID = manager.appendMessage(assistant([.toolCall(ToolCall(id: "call-1", name: "read", arguments: [:]))], .toolUse))
    manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "read",
        content: [.text(TextContent(text: String(repeating: "x", count: 8000)))], isError: false)))
    let path = manager.getBranch()
    let cut = findCutPoint(path, 0, path.count, 1000)
    #expect(cut.firstKeptEntryIndex == 3)
    #expect(cut.turnStartIndex == 2)
    #expect(cut.isSplitTurn)
    let preparation = try #require(prepareCompaction(path, CompactionSettings(enabled: true, reserveTokens: 0, keepRecentTokens: 1000)))
    #expect(preparation.firstKeptEntryId == callID)
}

private final class C2SkillLoader: ResourceLoader {
    private let skills = LockedState<[Skill]>([])
    func add(_ skill: Skill) { skills.withLock { $0.append(skill) } }
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { (skills.withLock { $0 }, []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

@Test func c2AddingSkillPersistsOnlySkillsPatch() async throws {
    let manager = SessionManager.inMemory()
    let requests = LockedState<[TranscriptContext]>([])
    let loader = C2SkillLoader()
    let session = c2Session(manager, requests: requests, tools: [c2Tool()], loader: loader)
    defer { session.dispose() }
    try await session.prompt("before")
    loader.add(Skill(name: "new", description: "New skill", filePath: "/tmp/new/SKILL.md", baseDir: "/tmp/new", source: "test"))
    await session.reload()
    try await session.prompt("after")
    let systems = manager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
    #expect(systems.count == 2)
    #expect(systems[1].sections?.entries.map(\.name) == ["skills"])
    #expect(systems[1].sections?["skills"]?.contains("<name>new</name>") == true)
}
