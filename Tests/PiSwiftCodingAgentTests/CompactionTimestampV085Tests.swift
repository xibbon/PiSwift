import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func timestampModel() -> Model {
    Model(id: "timestamp-test", name: "Timestamp", api: .openAICompletions, provider: "openai",
          baseUrl: "https://example.invalid", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 100)
}

private func timestampAssistant(_ timestamp: Int64, tokens: Int = 950) -> AssistantMessage {
    let model = timestampModel()
    return AssistantMessage(content: [.text(TextContent(text: "old"))], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: tokens), stopReason: .stop, timestamp: timestamp)
}

private func timestampSession(_ boundary: String, calls: LockedState<Int>) throws -> AgentSession {
    let seconds = try #require(sessionTimestampMilliseconds("2026-09-04T12:00:00Z"))
    let model = timestampModel()
    let entries: [FileEntry] = [
        .session(SessionHeader(version: 3, id: "timestamp-session", timestamp: boundary, cwd: "/tmp")),
        .entry(.message(SessionMessageEntry(id: "user", timestamp: boundary, message: .user(UserMessage(content: .text("hello"), timestamp: seconds))))),
        .entry(.message(SessionMessageEntry(id: "assistant", parentId: "user", timestamp: boundary, message: .assistant(timestampAssistant(seconds + 700))))),
        .entry(.compaction(CompactionEntry(id: "compaction", parentId: "assistant", timestamp: boundary, summary: "summary", firstKeptEntryId: "user", tokensBefore: 950)))
    ]
    let manager = SessionManager.inMemory("/tmp", entries: entries)
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("openai", "test")
    let registry = ModelRegistry(auth)
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        calls.withLock { $0 += 1 }
        return SessionBeforeCompactResult(compaction: CompactionResult(summary: "unexpected", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore))
    }
    let runner = HookRunner([LoadedHook(path: "timestamp", resolvedPath: "timestamp", handlers: api.handlers, setSendMessageHandler: api.setSendMessageHandler)], "/tmp", manager, registry)
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 100, keepRecentTokens: 1)
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model), convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, streamFn: { _, _, _ in
        let response = timestampAssistant(seconds + 1000, tokens: 10)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: response)); stream.end(response)
        return stream
    }, getApiKey: { _ in "test" }))
    agent.messages = manager.buildSessionContext().messages
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(), hookRunner: runner, modelRegistry: registry))
    _ = session.subscribe { event in
        if case .autoCompactionStart = event { calls.withLock { $0 += 1 } }
    }
    return session
}

@Suite struct CompactionTimestampV085Tests {
    @Test func acceptsBothTimestampFormatsWithoutLosingMilliseconds() throws {
        let plain = try #require(sessionTimestampMilliseconds("2026-09-04T12:00:00Z"))
        #expect(sessionTimestampMilliseconds("2026-09-04T12:00:00.900Z") == plain + 900)
        #expect(sessionTimestampMilliseconds("invalid") == nil)
        let manager = SessionManager.inMemory()
        #expect(manager.getHeader()?.timestamp.contains(".") == true)
        let id = manager.appendCompaction("summary", "kept", 50)
        #expect(manager.getEntry(id)?.timestamp.contains(".") == true)
    }

    @Test(arguments: ["2026-09-04T12:00:00Z", "2026-09-04T12:00:00.900Z"])
    func retainedUsageIsUnknownAndDoesNotTriggerAnotherCompaction(boundary: String) async throws {
        let calls = LockedState(0)
        let session = try timestampSession(boundary, calls: calls)
        defer { session.dispose() }
        #expect(session.getContextUsage()?.tokens == nil)
        #expect(session.getContextUsage()?.percent == nil)
        let message = try #require(session.agent.state.messages.compactMap { if case .assistant(let assistant) = $0 { return assistant }; return nil }.last)
        let context = AgentContext(systemPrompt: "test", messages: session.agent.state.messages, tools: [])
        _ = try await session.agent.prepareNextTurnWithContext?(PrepareNextTurnContext(message: message, toolResults: [], context: context, newMessages: []), nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func validPostCompactionUsageRestoresContextCount() throws {
        let session = try timestampSession("2026-09-04T12:00:00.900Z", calls: LockedState(0))
        defer { session.dispose() }
        let freshTimestamp = try #require(sessionTimestampMilliseconds("2026-09-04T12:00:01.000Z"))
        session.sessionManager.appendMessage(.assistant(timestampAssistant(freshTimestamp, tokens: 200)))
        session.sessionManager.appendMessage(.user(UserMessage(content: .text("12345678"), timestamp: freshTimestamp + 1)))
        session.agent.messages = session.sessionManager.buildSessionContext().messages
        #expect(session.getContextUsage()?.tokens == 202)
        #expect(abs((try #require(session.getContextUsage()?.percent)) - 20.2) < 0.000001)
    }

    @Test func importedFractionalCompactionMessageRetainsTimestamp() throws {
        let session = try timestampSession("2026-09-04T12:00:00.900Z", calls: LockedState(0))
        defer { session.dispose() }
        guard case .custom(let summary) = session.agent.state.messages.first else { Issue.record("Missing compaction message"); return }
        #expect(summary.timestamp == sessionTimestampMilliseconds("2026-09-04T12:00:00.900Z"))
    }
}
