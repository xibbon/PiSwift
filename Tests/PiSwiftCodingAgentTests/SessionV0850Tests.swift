import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func sessionPortModel(_ id: String = "port", reasoning: Bool = true) -> Model {
    Model(id: id, name: id, api: .openAIResponses, provider: "openai", baseUrl: "https://example.invalid", reasoning: reasoning, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 200)
}
private func sessionPortStream(_ model: Model, _ content: [ContentBlock], reason: StopReason = .stop) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason)
    stream.push(.done(reason: reason, message: message))
    stream.end(message)
    return stream
}
private func portSession(model: Model = sessionPortModel(), settings: Settings = Settings(), api: HookAPI? = nil, tools: [AgentTool] = [], templates: [PromptTemplate] = [], stream: @escaping StreamFn) -> AgentSession {
    let manager = SessionManager.inMemory()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("openai", "test")
    let registry = ModelRegistry(auth)
    let runner = api.map { api in HookRunner([LoadedHook(path: "port", resolvedPath: "port", handlers: api.handlers, setSendMessageHandler: api.setSendMessageHandler)], manager.getCwd(), manager, registry) }
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: tools), convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, streamFn: stream, getApiKey: { _ in "test" }))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager, settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(), promptTemplates: templates, hookRunner: runner, modelRegistry: registry))
}

@Test func signalKilledChildrenReturnShellExitStatus() async throws {
    let exec = try await execCommand("/bin/sh", ["-c", "kill -9 $$"], "/tmp")
    #expect(exec.code == 137)
    let bash = try await executeBash("kill -9 $$")
    #expect(bash.exitCode == 137)
    #expect(!bash.cancelled)
}

@Test func modelMutationsAreSessionScopedUnlessPersisted() async throws {
    var settings = Settings()
    settings.defaultModel = "saved"
    settings.defaultProvider = "openai"
    settings.defaultThinkingLevel = "medium"
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    let session = portSession(settings: settings) { model, _, _ in sessionPortStream(model, []) }
    defer { session.dispose() }
    try await session.setModel(sessionPortModel("selected", reasoning: false))
    session.setThinkingLevel(.high)
    #expect(session.settingsManager.getDefaultModel() == "saved")
    #expect(session.settingsManager.getDefaultThinkingLevel() == "medium")
    #expect(session.agent.state.thinkingLevel == .off)
    session.setThinkingLevel(.high, options: ModelMutationOptions(persist: true))
    #expect(session.settingsManager.getDefaultThinkingLevel() == "high")
    #expect(session.agent.state.thinkingLevel == .off)
    session.setScopedModels([ScopedModel(model: sessionPortModel())])
    try await session.setModel(sessionPortModel("persisted"), options: ModelMutationOptions(persist: true))
    #expect(session.settingsManager.getDefaultModel() == "persisted")
    #expect(session.scopedModels.contains { $0.model.id == "persisted" })
    #expect(session.getAvailableThinkingLevels() == PiSwiftAI.getSupportedThinkingLevels(session.agent.state.model).compactMap { PiSwiftAgent.ThinkingLevel(rawValue: $0.rawValue) })
    #expect(THINKING_LEVEL_OPTIONS == [.off, .minimal, .low, .medium, .high, .xhigh, .max])
}

@Test func contextOnlyCustomMessagesFollowAllToolResults() async throws {
    let holder = LockedState<AgentSession?>(nil)
    let calls = LockedState(0)
    let tool = AgentTool(label: "test", name: "test", description: "test", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        let session = holder.withLock { $0 }!
        await session.sendHookMessage(HookMessageInput(customType: "note", content: .text("note"), display: false), options: HookSendMessageOptions(triggerTurn: false))
        try? await session.prompt("rejected while tool runs")
        #expect(!session.sessionManager.getEntries().contains { if case .customMessage = $0 { return true }; return false })
        return AgentToolResult(content: [.text(TextContent(text: "result"))])
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    let seen = LockedState<[String]>([])
    let session = portSession(settings: settings, tools: [tool]) { model, context, _ in
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return sessionPortStream(model, [.toolCall(ToolCall(id: "1", name: "test", arguments: [:]))], reason: .toolUse) }
        seen.withLock { $0 = context.messages.map(\.role) }
        return sessionPortStream(model, [.text(TextContent(text: "done"))])
    }
    holder.withLock { $0 = session }
    defer { holder.withLock { $0 = nil }; session.dispose() }
    try await session.prompt("go")
    await session.waitForIdle()
    let entries = session.sessionManager.getEntries()
    let toolIndex = try #require(entries.firstIndex { if case .message(let e) = $0 { return e.message.role == "toolResult" }; return false })
    let customIndex = try #require(entries.firstIndex { if case .customMessage = $0 { return true }; return false })
    #expect(toolIndex < customIndex)
    #expect(calls.withLock { $0 } == 2)
    #expect(seen.withLock { $0 }.contains("toolResult"))
}

@Test func zeroUsageToolOutputCompactsBeforeNextAssistant() async throws {
    let calls = LockedState(0)
    let preparedAfterCompaction = LockedState(false)
    let compacted = LockedState(false)
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        compacted.withLock { $0 = true }
        return SessionBeforeCompactResult(compaction: CompactionResult(summary: "summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore))
    }
    let tool = AgentTool(label: "large", name: "large", description: "large", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: String(repeating: "x", count: 6000)))])
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 10)
    let session = portSession(settings: settings, api: api, tools: [tool]) { model, _, _ in
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return sessionPortStream(model, [.toolCall(ToolCall(id: "1", name: "large", arguments: [:]))], reason: .toolUse) }
        preparedAfterCompaction.withLock { $0 = compacted.withLock { $0 } }
        return sessionPortStream(model, [.text(TextContent(text: "done"))])
    }
    defer { session.dispose() }
    _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text("old"))))
    _ = session.sessionManager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "old response"))], api: .openAIResponses, provider: "openai", model: "port", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
    session.agent.messages = session.sessionManager.buildSessionContext().messages
    try await session.prompt("go")
    await session.waitForIdle()
    #expect(preparedAfterCompaction.withLock { $0 })
}

private actor PortLatch {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { open = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
}

@Test func abortCancelsManualCompactionAndResolvesIdle() async throws {
    let started = PortLatch()
    let failures = LockedState<[SessionCompactFailedEvent]>([])
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        await started.signal()
        while event.signal?.isCancelled != true { try await Task.sleep(for: .milliseconds(2)) }
        return SessionBeforeCompactResult(cancel: true)
    }
    api.on("session_compact_failed") { (event: SessionCompactFailedEvent, _: HookContext) in failures.withLock { $0.append(event) }; return nil }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 100, keepRecentTokens: 1)
    let session = portSession(settings: settings, api: api) { model, _, _ in sessionPortStream(model, [.text(TextContent(text: "response"))]) }
    defer { session.dispose() }
    try await session.prompt("one")
    try await session.prompt("two")
    await session.waitForIdle()
    let task = Task { try await session.compact() }
    await started.wait()
    #expect(!session.isIdle)
    await session.abort()
    _ = try? await task.value
    #expect(session.isIdle)
    #expect(failures.withLock { $0.count } == 1)
    #expect(failures.withLock { $0.first?.reason } == .manual)
    #expect(failures.withLock { $0.first?.aborted } == true)
}

@Test func failedInlineExtensionDiscardsFlagsProvidersAndSubscriptions() async throws {
    enum Failure: Error { case rejected }
    let bus = createEventBus()
    let apiHolder = LockedState<HookAPI?>(nil)
    let notifications = LockedState(0)
    let result = ExtensionLoader.load(InlineExtension(name: "failed") { api in
        apiHolder.withLock { $0 = api }
        api.registerFlag("value", HookFlagOptions(type: .boolean, defaultValue: .bool(true)))
        api.events.on("port") { _ in notifications.withLock { $0 += 1 } }
        throw Failure.rejected
    }, cwd: "/tmp", eventBus: bus)
    #expect(result.hook == nil)
    #expect(result.error != nil)
    let api = try #require(apiHolder.withLock { $0 })
    #expect(api.flags.isEmpty)
    #expect(throws: HookAPIError.self) { try api.validateActive() }
    bus.emit("port", nil)
    await Task.yield()
    #expect(notifications.withLock { $0 } == 0)
    let invalid = ExtensionLoader.load(InlineExtension(name: "invalid") { api in
        api.registerFlag("value", HookFlagOptions(type: .boolean, defaultValue: .string("wrong")))
    }, cwd: "/tmp", eventBus: bus)
    #expect(invalid.error != nil)
}

@Test func truncatedCompactionDoesNotStoreSummary() async throws {
    let failures = LockedState<[SessionCompactFailedEvent]>([])
    let api = HookAPI()
    api.on("session_compact_failed") { (event: SessionCompactFailedEvent, _: HookContext) in failures.withLock { $0.append(event) }; return nil }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 100, keepRecentTokens: 1)
    let session = portSession(settings: settings, api: api) { model, context, _ in
        sessionPortStream(model, [.text(TextContent(text: "text"))], reason: context.systemPrompt == "test" ? .stop : .length)
    }
    defer { session.dispose() }
    try await session.prompt("one")
    try await session.prompt("two")
    await session.waitForIdle()
    do { _ = try await session.compact(); Issue.record("Expected incomplete summary failure") } catch {
        #expect(error.localizedDescription.contains("token cap"))
    }
    #expect(!session.sessionManager.getEntries().contains { if case .compaction = $0 { return true }; return false })
    #expect(failures.withLock { $0.count } == 1)
}

@Test func terminatingToolDoesNotTriggerNextTurnCompaction() async throws {
    let calls = LockedState(0)
    let tool = AgentTool(label: "large", name: "large", description: "large", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: String(repeating: "x", count: 6000)))], terminate: true)
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 1)
    let session = portSession(settings: settings, tools: [tool]) { model, _, _ in
        calls.withLock { $0 += 1 }
        let message = AssistantMessage(content: [.toolCall(ToolCall(id: "call", name: "large", arguments: [:]))], api: model.api, provider: model.provider, model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .toolUse)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .toolUse, message: message))
        stream.end(message)
        return stream
    }
    defer { session.dispose() }
    try await session.prompt("go")
    await session.waitForIdle()
    #expect(calls.withLock { $0 } == 1)
    #expect(!session.sessionManager.getEntries().contains { if case .compaction = $0 { return true }; return false })
}

@Test func importAvoidsCollisionsAndOpensStoredSourceInPlace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-import-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source/session.jsonl")
    let stored = root.appendingPathComponent("stored")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager.create(root.path, stored.path)
    let model = sessionPortModel()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("openai", "test")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model), streamFn: { model, _, _ in sessionPortStream(model, []) }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager, settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(auth)))
    defer { session.dispose() }
    let exported = SessionManager.inMemory(root.path)
    _ = exported.appendMessage(.user(UserMessage(content: .text("imported"))))
    _ = try exportSessionToJsonl(exported, outputPath: source.path)
    try Data("keep".utf8).write(to: stored.appendingPathComponent("session.jsonl"))
    let imported = try await session.importFromJsonl(source.path)
    #expect(!imported.cancelled)
    #expect(session.sessionFile?.hasSuffix("session-1.jsonl") == true)
    #expect(try String(contentsOf: stored.appendingPathComponent("session.jsonl"), encoding: .utf8) == "keep")
    let originalPath = try #require(session.sessionFile)
    _ = try await session.importFromJsonl(originalPath)
    #expect(session.sessionFile == originalPath)
    #expect(!FileManager.default.fileExists(atPath: stored.appendingPathComponent("session-1-1.jsonl").path))
}

private final class PortUIContext: HookUIContext {
    nonisolated init() {}
    var nested: (() async -> String?)?

    func select(_ title: String, _ options: [String]) async -> String? { await nested?() }
    func confirm(_ title: String, _ message: String) async -> Bool { false }
    func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    func notify(_ message: String, _ type: HookNotificationType?) {}
    func setStatus(_ key: String, _ text: String?) {}
    func setWorkingMessage(_ message: String?) {}
    func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    func setFooter(_ factory: HookFooterFactory?) {}
    func setTitle(_ title: String) {}
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    func pasteToEditor(_ text: String) {}
    func setEditorText(_ text: String) {}
    func getEditorText() -> String { "" }
    func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    func getAllThemes() -> [HookThemeInfo] { [] }
    func getTheme(_ name: String) -> Theme? { nil }
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult {
        HookThemeResult(success: false, error: "UI not available")
    }
    func getToolsExpanded() -> Bool { false }
    func setToolsExpanded(_ expanded: Bool) {}
    var theme: Theme { Theme.fallback() }
}

@Test @MainActor func uiPromptsEmitOnlyTheOuterLifecyclePair() async throws {
    let events = LockedState<[String]>([])
    let completed = PortLatch()
    let api = HookAPI()
    api.on("ui_prompt_start") { (event: UIPromptStartEvent, _: HookContext) in events.withLock { $0.append("start:\(event.kind.rawValue):\(event.title ?? "")") }; return nil }
    api.on("ui_prompt_end") { (event: UIPromptEndEvent, _: HookContext) in events.withLock { $0.append("end:\(event.kind.rawValue)") }; await completed.signal(); return nil }
    let manager = SessionManager.inMemory()
    let runner = HookRunner([LoadedHook(path: "ui", resolvedPath: "ui", handlers: api.handlers)], "/tmp", manager, ModelRegistry(AuthStorage(":memory:")))
    let base = PortUIContext()
    runner.initialize(getModel: { sessionPortModel() }, uiContext: base, hasUI: true)
    let wrapped = runner.getUIContext()
    base.nested = { await wrapped.input("nested", nil) }
    _ = await wrapped.select("outer", ["one"])
    await completed.wait()
    #expect(events.withLock { $0 } == ["start:select:outer", "end:select"])
}

@Test func extensionTurnEndCustomMessageJoinsTheSameFlush() async throws {
    let api = HookAPI()
    api.on("turn_end") { [weak api] (event: TurnEndEvent, _: HookContext) in
        if !event.toolResults.isEmpty {
            api?.sendMessage(HookMessageInput(customType: "turn-note", content: .text("turn note"), display: false), options: HookSendMessageOptions(triggerTurn: false))
        }
        return nil
    }
    let tool = AgentTool(label: "test", name: "test", description: "test", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in AgentToolResult(content: []) }
    let calls = LockedState(0)
    let sawNote = LockedState(false)
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    let session = portSession(settings: settings, api: api, tools: [tool]) { model, context, _ in
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return sessionPortStream(model, [.toolCall(ToolCall(id: "call", name: "test", arguments: [:]))], reason: .toolUse) }
        sawNote.withLock { $0 = context.messages.contains { message in
            if case .user(let user) = message, case .text(let text) = user.content { return text.contains("turn note") }
            if case .user(let user) = message, case .blocks(let blocks) = user.content { return blocks.contains { if case .text(let text) = $0 { return text.text.contains("turn note") }; return false } }
            return false
        } }
        return sessionPortStream(model, [])
    }
    defer { session.dispose() }
    try await session.prompt("go")
    await session.waitForIdle()
    #expect(sawNote.withLock { $0 })
}

@Test func inMemoryForkDoesNotReceiveTheAbortedToolTurn() async throws {
    let started = PortLatch()
    let calls = LockedState(0)
    let roles = LockedState<[String]>([])
    let tool = AgentTool(label: "block", name: "block", description: "block", parameters: ["type": AnyCodable("object")]) { _, _, signal, _ in
        await started.signal()
        while signal?.isCancelled != true { try await Task.sleep(for: .milliseconds(1)) }
        return AgentToolResult(content: [.text(TextContent(text: "tool aborted"))])
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    let session = portSession(settings: settings, tools: [tool]) { model, context, _ in
        let call = calls.withLock { $0 += 1; return $0 }
        if call == 2 { return sessionPortStream(model, [.toolCall(ToolCall(id: "block", name: "block", arguments: [:]))], reason: .toolUse) }
        roles.withLock { $0 = context.messages.map(\.role) }
        return sessionPortStream(model, [.text(TextContent(text: "done"))])
    }
    defer { session.dispose() }
    try await session.prompt("first")
    await session.waitForIdle()
    let first = try #require(session.sessionManager.getEntries().first { if case .message(let entry) = $0 { return entry.message.role == "user" }; return false })
    let task = Task { try await session.prompt("start tool") }
    await started.wait()
    let fork = try await session.fork(first.id)
    try await task.value
    #expect(!fork.cancelled)
    #expect(session.agent.state.messages.isEmpty)
    #expect(session.sessionManager.getEntries().filter { if case .message = $0 { return true }; return false }.isEmpty)
    try await session.prompt("next")
    await session.waitForIdle()
    #expect(roles.withLock { $0 } == ["user"])
}

@Test func manualCompactionStoresTheAbortedResponseBeforeItsSummary() async throws {
    let started = PortLatch()
    let calls = LockedState(0)
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        SessionBeforeCompactResult(compaction: CompactionResult(summary: "manual summary", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore))
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 1)
    let session = portSession(settings: settings, api: api) { model, _, options in
        let call = calls.withLock { $0 += 1; return $0 }
        if call == 1 { return sessionPortStream(model, [.text(TextContent(text: "first"))]) }
        await started.signal()
        while options.signal?.isCancelled != true { try await Task.sleep(for: .milliseconds(1)) }
        return sessionPortStream(model, [.text(TextContent(text: String(repeating: "x", count: 4000)))], reason: .aborted)
    }
    defer { session.dispose() }
    try await session.prompt("first")
    await session.waitForIdle()
    let response = Task { try await session.prompt("second") }
    await started.wait()
    _ = try await session.compact()
    try await response.value
    let entries = session.sessionManager.getEntries()
    let aborted = try #require(entries.firstIndex { if case .message(let entry) = $0, case .assistant(let message) = entry.message { return message.stopReason == .aborted }; return false })
    let summary = try #require(entries.firstIndex { if case .compaction = $0 { return true }; return false })
    #expect(aborted < summary)
    #expect(entries.filter { if case .compaction = $0 { return true }; return false }.count == 1)
}

@Test func userMessagesExpandTemplatesOnlyWhenRequested() async throws {
    let texts = LockedState<[String]>([])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    let template = PromptTemplate(name: "hello", description: "hello", content: "expanded $1", source: "user", filePath: "/tmp/hello.md")
    let session = portSession(settings: settings, templates: [template]) { model, context, _ in
        if case .user(let user) = context.messages.last, case .blocks(let blocks) = user.content {
            texts.withLock { $0.append(blocks.compactMap { if case .text(let text) = $0 { return text.text }; return nil }.joined()) }
        } else if case .user(let user) = context.messages.last, case .text(let text) = user.content {
            texts.withLock { $0.append(text) }
        }
        return sessionPortStream(model, [])
    }
    defer { session.dispose() }
    try await session.sendUserMessage("/hello one")
    await session.waitForIdle()
    try await session.sendUserMessage("/hello two", options: HookSendMessageOptions(expandPromptTemplates: true))
    await session.waitForIdle()
    try await session.prompt("/hello three", options: PromptOptions(expandPromptTemplates: false))
    await session.waitForIdle()
    #expect(texts.withLock { $0 } == ["/hello one", "expanded two", "/hello three"])
}

@Test func extensionBranchSummaryUsesTheSourceLeafAndPreservesUsage() async throws {
    let api = HookAPI()
    let usage = Usage(input: 10, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 12)
    api.on("session_before_tree") { (_: SessionBeforeTreeEvent, _: HookContext) in
        SessionBeforeTreeResult(summary: BranchSummaryResult(summary: "Extension summary", usage: usage))
    }
    let session = portSession(api: api) { model, _, _ in sessionPortStream(model, []) }
    defer { session.dispose() }
    let target = session.sessionManager.appendMessage(.user(UserMessage(content: .text("first branch"))))
    _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text("abandoned work"))))
    let source = session.sessionManager.appendMessage(.assistant(AssistantMessage(content: [], api: .openAIResponses, provider: "openai", model: "port", usage: usage, stopReason: .stop)))
    session.agent.messages = session.sessionManager.buildSessionContext().messages
    let result = await session.navigateTree(target, summarize: true)
    let summary = try #require(result.summaryEntry)
    #expect(summary.parentId == nil)
    #expect(summary.fromId == source)
    #expect(summary.fromHook == true)
    #expect(summary.summary == "Extension summary")
    #expect(summary.usage?.totalTokens == 12)
    await session.waitForIdle()
    #expect(session.isIdle)
}
