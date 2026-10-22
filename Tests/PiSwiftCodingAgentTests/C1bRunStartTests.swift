import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Port of v1.3.0 agent-session-prompt.test.ts:567–722. The input and auth
// cases also check that a run is reserved before its first suspension.
private actor C1bRunGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class C1bRunResources: ResourceLoader {
    func getExtensions() -> ExtensionsResult { ExtensionsResult(paths: [], diagnostics: []) }
    func getSkills() -> (skills: [Skill], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getPrompts() -> (prompts: [PromptTemplate], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getThemes() -> (themes: [HookThemeInfo], diagnostics: [ResourceDiagnostic]) { ([], []) }
    func getAgentsFiles() -> [ContextFile] { [] }
    func getSystemPrompt() -> String? { nil }
    func getAppendSystemPrompt() -> [String] { [] }
    func getPathMetadata() -> [String: PathMetadata] { [:] }
    func extendResources(_ paths: ResourceExtensionPaths) {}
    func reload() async {}
}

private enum C1bRunStart: String, Sendable, CaseIterable {
    case user, custom
}

private func c1bRunModel(provider: String = "c1b-test") -> Model {
    Model(id: "c1b-model", name: "C1b", api: .openAIResponses, provider: provider,
          baseUrl: "https://example.invalid", reasoning: false, input: [.text, .image],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 100_000, maxTokens: 100)
}

private func c1bRunResponse(_ model: Model, call: Int, toolOnCall: Int?) -> AssistantMessageEventStream {
    let usesTool = call == toolOnCall
    let content: [ContentBlock] = usesTool
        ? [.toolCall(ToolCall(id: "c1b-call", name: "noop", arguments: [:]))]
        : [.text(TextContent(text: "done"))]
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider,
        model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: usesTool ? .toolUse : .stop)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

private func c1bRunSession(
    _ api: HookAPI,
    requests: LockedState<[TranscriptContext]>,
    tools: [AgentTool] = [],
    toolOnCall: Int? = nil,
    authenticated: Bool = true
) -> AgentSession {
    let model = c1bRunModel()
    let manager = SessionManager.inMemory()
    let auth = AuthStorage(":memory:")
    if authenticated { auth.setRuntimeApiKey(model.provider, "test") }
    let registry = ModelRegistry(auth)
    let hook = LoadedHook(path: "c1b-run", resolvedPath: "c1b-run", handlers: api.handlers,
        currentHandlers: { api.handlers }, setSendMessageHandler: api.setSendMessageHandler,
        setSendUserMessageHandler: api.setSendUserMessageHandler, isExtension: true)
    let runner = HookRunner([hook], manager.getCwd(), manager, registry)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "test", model: model, tools: tools),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) },
        streamFn: { model, context, _ in
            let call = requests.withLock { values in values.append(context); return values.count }
            return c1bRunResponse(model, call: call, toolOnCall: toolOnCall)
        }, getApiKey: { _ in "test" }))
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: false)
    settings.images = ImageSettings(autoResize: false, blockImages: false)
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: C1bRunResources(),
        systemPromptOptions: BuildSystemPromptOptions(cwd: manager.getCwd(), contextFiles: [], skills: []),
        hookRunner: runner, modelRegistry: registry,
        toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })))
}

private func c1bStartRun(_ session: AgentSession, kind: C1bRunStart, text: String = "starting message") async throws {
    switch kind {
    case .user: try await session.prompt(text)
    case .custom:
        await session.sendHookMessage(HookMessageInput(customType: "start", content: .text(text), display: true),
                                      options: HookSendMessageOptions(triggerTurn: true))
    }
}

private func c1bRunTexts(_ context: TranscriptContext) -> [String] {
    context.messages.flatMap { message -> [String] in
        guard case .user(let user) = message else { return [] }
        switch user.content {
        case .text(let text): return [text]
        case .blocks(let blocks):
            return blocks.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func c1bCustomRunKeepsPromptAcrossToolRequestsAndTypedPayloads() async throws {
    let api = HookAPI()
    let events = LockedState<[BeforeAgentStartEvent]>([])
    api.on("before_agent_start") { (event: BeforeAgentStartEvent, _: HookContext) in
        events.withLock { $0.append(event) }
        return BeforeAgentStartEventResult(sections: ["extension_rules": "Answer in one word."])
    }
    let tool = AgentTool(label: "Noop", name: "noop", description: "Does nothing", parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "ok"))])
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests, tools: [tool], toolOnCall: 2)
    defer { session.dispose() }
    let image = ImageContent(data: "c1b-image", mimeType: "image/png")
    try await session.prompt("hello", options: PromptOptions(images: [image]))
    await session.waitForIdle()
    await session.sendHookMessage(HookMessageInput(customType: "task-done", content: .text("background task finished"),
        display: true, details: AnyCodable(["task": "one"])), options: HookSendMessageOptions(triggerTurn: true))
    await session.waitForIdle()

    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 3)
    let prompts = contexts.map { getCurrentSystemPrompt($0.messages) }
    #expect(prompts.allSatisfy { $0.contains("Answer in one word.") })
    #expect(Set(prompts).count == 1)
    let observed = events.withLock { $0 }
    #expect(observed.map(\.messageType) == ["user", "custom"])
    guard observed.count == 2 else { return }
    switch observed[0].payload {
    case .user(let prompt, let images):
        #expect(prompt == "hello")
        #expect(images?.first?.data == image.data)
        #expect(images?.first?.mimeType == image.mimeType)
    case .custom: Issue.record("Expected a user payload")
    }
    switch observed[1].payload {
    case .custom(let message):
        #expect(message.customType == "task-done")
        #expect(message.display)
        #expect(message.details?.value as? [String: String] == ["task": "one"])
        if case .text(let text) = message.content { #expect(text == "background task finished") }
        else { Issue.record("Expected custom text") }
    case .user: Issue.record("Expected a custom payload")
    }
}

@Test(.timeLimit(.minutes(1))) func c1bCustomMessageDuringStartUsesOneRequest() async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let api = HookAPI()
    api.on("before_agent_start") { (event: BeforeAgentStartEvent, _: HookContext) in
        guard case .custom(let message) = event.payload, message.customType == "start" else { return nil }
        await entered.open()
        await release.wait()
        return nil
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    let first = Task { try await c1bStartRun(session, kind: .custom, text: "first task") }
    await entered.wait()
    #expect(session.isStreaming)
    #expect(!session.isIdle)
    await session.sendHookMessage(HookMessageInput(customType: "second", content: .text("second task"), display: true),
                                  options: HookSendMessageOptions(triggerTurn: true))
    await release.open()
    try await first.value
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 1)
    #expect(contexts.first.map(c1bRunTexts) == ["first task", "second task"])
}

@Test(.timeLimit(.minutes(1)), arguments: C1bRunStart.allCases)
private func c1bContextOnlyMessageFromStartHandlerPrecedesStartingMessage(kind: C1bRunStart) async throws {
    let api = HookAPI()
    api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
        api.sendMessage(HookMessageInput(customType: "note", content: .text("context from handler"), display: true),
                        options: HookSendMessageOptions(triggerTurn: false))
        return nil
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    try await c1bStartRun(session, kind: kind)
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 1)
    #expect(contexts.first.map(c1bRunTexts) == ["context from handler", "starting message"])
}

@Test(.timeLimit(.minutes(1)), arguments: C1bRunStart.allCases)
private func c1bAbortDuringStartStopsBeforeFirstRequest(kind: C1bRunStart) async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let api = HookAPI()
    api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
        await entered.open()
        await release.wait()
        return nil
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    let run = Task { try await c1bStartRun(session, kind: kind) }
    await entered.wait()
    let abort = Task { await session.abort() }
    while !session.isRunAbortRequested { await Task.yield() }
    await release.open()
    _ = try? await run.value
    await abort.value
    #expect(requests.withLock { $0.isEmpty })
    guard case .assistant(let last)? = session.messages.last else {
        Issue.record("Expected an aborted assistant message")
        return
    }
    #expect(last.stopReason == .aborted)
    #expect(session.isIdle)
}

@Test(.timeLimit(.minutes(1)), arguments: C1bRunStart.allCases)
private func c1bNextTurnMessagesFollowStartAndPrecedeHandlerMessages(kind: C1bRunStart) async throws {
    let api = HookAPI()
    api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
        BeforeAgentStartEventResult(message: HookMessageInput(customType: "handler", content: .text("handler message"), display: true))
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    await session.sendHookMessage(HookMessageInput(customType: "next", content: .text("pending next turn"), display: true),
                                  options: HookSendMessageOptions(deliverAs: .nextTurn))
    try await c1bStartRun(session, kind: kind)
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 1)
    #expect(contexts.first.map(c1bRunTexts) == ["starting message", "pending next turn", "handler message"])
}

@Test(.timeLimit(.minutes(1))) func c1bUserMessagesRequireDeliveryModeDuringStart() async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let api = HookAPI()
    api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
        await entered.open()
        await release.wait()
        return nil
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    let run = Task { try await session.prompt("starting message") }
    await entered.wait()
    do {
        try await session.sendUserMessage("must reject")
        Issue.record("Expected a delivery mode error")
    } catch let error as AgentSessionError {
        if case .alreadyProcessingQueue = error {} else { Issue.record("Unexpected error: \(error)") }
    } catch { Issue.record("Unexpected error: \(error)") }
    try await session.sendUserMessage("steering message", options: HookSendMessageOptions(deliverAs: .steer))
    try await session.sendUserMessage("follow-up message", options: HookSendMessageOptions(deliverAs: .followUp))
    #expect(session.pendingMessageCount == 2)
    await release.open()
    try await run.value
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    let allTexts = contexts.flatMap(c1bRunTexts)
    #expect(allTexts.contains("steering message"))
    #expect(allTexts.contains("follow-up message"))
    #expect(!allTexts.contains("must reject"))
    #expect(session.pendingMessageCount == 0)
}

@Test(.timeLimit(.minutes(1))) func c1bInputHandlerReservesRunBeforeItSuspends() async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let api = HookAPI()
    api.on("input") { (event: InputEvent, _: HookContext) in
        if event.text == "starting message" {
            await entered.open()
            await release.wait()
        }
        return InputEventResult.continue
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    let run = Task { try await session.prompt("starting message") }
    await entered.wait()
    #expect(session.isStreaming)
    #expect(!session.isIdle)
    do {
        try await session.prompt("second start")
        Issue.record("Expected the concurrent start to fail")
    } catch let error as AgentSessionError {
        if case .alreadyProcessingQueue = error {} else { Issue.record("Unexpected error: \(error)") }
    } catch { Issue.record("Unexpected error: \(error)") }
    try await session.prompt("queued input", options: PromptOptions(streamingBehavior: .steer))
    await release.open()
    try await run.value
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 1)
    #expect(contexts.first.map(c1bRunTexts) == ["starting message", "queued input"])
    #expect(session.isIdle)
}

@Test(.timeLimit(.minutes(1))) func c1bAuthFailureDuringPreparationResolvesIdleWaiters() async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let api = HookAPI()
    api.on("input") { (_: InputEvent, _: HookContext) in
        await entered.open()
        await release.wait()
        return InputEventResult.continue
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests, authenticated: false)
    defer { session.dispose() }
    let run = Task { try await session.prompt("missing auth") }
    await entered.wait()
    #expect(session.isStreaming)
    #expect(!session.isIdle)
    let idle = Task { await session.waitForIdle() }
    await release.open()
    do {
        try await run.value
        Issue.record("Expected missing authentication")
    } catch let error as AgentSessionError {
        if case .missingApiKeyForProvider(let provider, _) = error { #expect(provider == "c1b-test") }
        else { Issue.record("Unexpected error: \(error)") }
    } catch { Issue.record("Unexpected error: \(error)") }
    await idle.value
    #expect(requests.withLock { $0.isEmpty })
    #expect(!session.isStreaming)
    #expect(session.isIdle)
}

@Test(.timeLimit(.minutes(1))) func c1bPlanModeAddsContextOnlyForUserStartPayloads() async throws {
    let api = HookAPI()
    registerPlanModeHook(api)
    api.setFlagValue("plan", .bool(true))
    let context = HookContext(sessionManager: .inMemory(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
                              model: nil, hasUI: false)
    for handler in api.handlers["session_start"] ?? [] {
        _ = try await handler(SessionStartEvent(reason: .startup), context)
    }
    let handler = try #require(api.handlers["before_agent_start"]?.first)
    let custom = BeforeAgentStartEvent(payload: .custom(message: HookMessage(
        customType: "background", content: .text("task complete"), display: true)))
    let customResult = try await handler(custom, context)
    #expect(customResult == nil)
    let user = BeforeAgentStartEvent(payload: .user(prompt: "make a plan", images: nil))
    let userResult = try await handler(user, context) as? BeforeAgentStartEventResult
    #expect(userResult?.message?.customType == "plan-mode-context")
}

@Test(.timeLimit(.minutes(1)), arguments: C1bRunStart.allCases)
private func c1bMcpStartHandlerAcceptsUserAndCustomPayloads(kind: C1bRunStart) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c1b-mcp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let loaded = ExtensionLoader.load(createMcpExtension(options: McpExtensionOptions(agentDir: directory,
        loadConfig: { _ in LoadedMcpConfig(servers: []) })), cwd: directory.path, eventBus: createEventBus())
    let hook = try #require(loaded.hook)
    defer { hook.dispose() }
    let manager = SessionManager.inMemory()
    let runner = HookRunner([hook], directory.path, manager, ModelRegistry(AuthStorage(":memory:")))
    let payload: BeforeAgentStartEvent.Payload
    switch kind {
    case .user: payload = .user(prompt: "hello", images: nil)
    case .custom:
        payload = .custom(message: HookMessage(customType: "background", content: .text("task complete"), display: true))
    }
    let result = await runner.emitBeforeAgentStart(payload)
    #expect(result?.sections.keys.contains(MCP_SERVERS_SECTION) == true)
}

@Test(.timeLimit(.minutes(1))) func c1bBeforeSettleKeepsRunReservedAndQueuesCustomContinuation() async throws {
    let entered = C1bRunGate()
    let release = C1bRunGate()
    let starts = LockedState(0)
    let boundaries = LockedState(0)
    let api = HookAPI()
    api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
        starts.withLock { $0 += 1 }
        return nil
    }
    api.on("agent_before_settle") { (_: AgentBeforeSettleEvent, _: HookContext) in
        let first = boundaries.withLock { count in count += 1; return count == 1 }
        if first {
            await entered.open()
            await release.wait()
        }
        return nil
    }
    let requests = LockedState<[TranscriptContext]>([])
    let session = c1bRunSession(api, requests: requests)
    defer { session.dispose() }
    let run = Task { try await session.prompt("starting message") }
    await entered.wait()
    #expect(session.isStreaming)
    #expect(!session.isIdle)
    do {
        try await session.prompt("must reject during boundary")
        Issue.record("Expected the concurrent start to fail")
    } catch let error as AgentSessionError {
        if case .alreadyProcessingQueue = error {} else { Issue.record("Unexpected error: \(error)") }
    } catch { Issue.record("Unexpected error: \(error)") }
    await session.sendHookMessage(HookMessageInput(customType: "boundary-note",
        content: .text("custom from boundary"), display: true), options: HookSendMessageOptions(triggerTurn: true))
    #expect(starts.withLock { $0 } == 1)
    #expect(requests.withLock { $0.count } == 1)
    await release.open()
    try await run.value
    await session.waitForIdle()
    let contexts = requests.withLock { $0 }
    #expect(contexts.count == 2)
    #expect(contexts.last.map(c1bRunTexts) == ["starting message", "custom from boundary"])
    #expect(starts.withLock { $0 } == 1)
    #expect(session.isIdle)
}
