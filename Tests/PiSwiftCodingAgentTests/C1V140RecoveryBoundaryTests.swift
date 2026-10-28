import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Upstream 02726086d: Omit matching results only up to the next assistant.
@Suite("C1 v1.4.0 recovery boundaries")
struct C1V140RecoveryBoundaryTests {
    @Test(.timeLimit(.minutes(1))) func currentRunRecoveryUsesSourceIdsAndStopsAtNextAssistant() async throws {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let manager = SessionManager.inMemory()
        let sessionRef = LockedState<AgentSession?>(nil)
        let failedSources = LockedState<[String]>([])
        let retainedSources = LockedState<[String]>([])
        let requests = LockedState(0)
        let compactions = LockedState(0)
        let usage = Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2)
        let api = HookAPI()
        api.on("turn_end") { (event: TurnEndEvent, _: HookContext) in
            failedSources.withLock { $0 = [event.messageEntryId] + event.toolResultEntryIds }
            let unrelated = manager.appendMessage(.toolResult(ToolResultMessage(
                toolCallId: "unrelated", toolName: "read", content: [.text(TextContent(text: "keep unrelated"))], isError: false)))
            let next = manager.appendMessage(.assistant(AssistantMessage(
                content: [.text(TextContent(text: "later assistant"))], api: model.api,
                provider: model.provider, model: model.id, usage: usage, stopReason: .stop)))
            let afterBoundary = manager.appendMessage(.toolResult(ToolResultMessage(
                toolCallId: "truncated", toolName: "read", content: [.text(TextContent(text: "keep after boundary"))], isError: false)))
            retainedSources.withLock { $0 = [unrelated, next, afterBoundary] }
            // Change projected content but keep the persisted assistant as the source.
            _ = try manager.appendContextEdit(event.messageEntryId, .text("edited failed response"))
            sessionRef.withLock { $0 }?.refreshContext()
            return nil
        }
        api.on("session_before_compact") { (_: SessionBeforeCompactEvent, _: HookContext) in
            compactions.withLock { $0 += 1 }
            return SessionBeforeCompactResult(cancel: true)
        }
        let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: { _, _, _ in
            requests.withLock { $0 += 1 }
            let response = AssistantMessage(content: [.toolCall(ToolCall(id: "truncated", name: "read", arguments: [:]))],
                api: model.api, provider: model.provider, model: model.id, usage: usage, stopReason: .length)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .length, message: response))
            stream.end(response)
            return stream
        }, getApiKey: { _ in "test-key" }))
        // End this agent run after its truncated turn; session recovery runs after it.
        agent.finishTurn = { _, _ in .end }
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey(model.provider, "test-key")
        let registry = ModelRegistry(auth)
        let hook = LoadedHook(path: "v140-recovery", resolvedPath: "v140-recovery", handlers: api.handlers,
            currentHandlers: { api.handlers })
        let runner = HookRunner([hook], manager.getCwd(), manager, registry)
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 1, keepRecentTokens: 1)
        settings.retry = RetrySettings(enabled: false)
        let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(settings), resourceLoader: TestResourceLoader(), hookRunner: runner,
            modelRegistry: registry))
        sessionRef.withLock { $0 = session }
        defer {
            sessionRef.withLock { $0 = nil }
            session.dispose()
        }
        try await session.prompt("start")
        await session.waitForIdle()
        #expect(requests.withLock { $0 } == 1)
        #expect(compactions.withLock { $0 } == 1)
        let failed = failedSources.withLock { $0 }
        #expect(failed.count == 2)
        let retained = retainedSources.withLock { $0 }
        #expect(retained.count == 3)
        let omissions = manager.getBranch().compactMap { entry -> String? in
            guard case .contextEdit(let edit) = entry, edit.replacement == nil else { return nil }
            return edit.targetId
        }
        #expect(Set(omissions) == Set(failed))
        let projectedSources = Set(manager.buildSessionProjection().entries.filter { !$0.messages.isEmpty }.map { $0.sourceEntry.id })
        #expect(failed.allSatisfy { !projectedSources.contains($0) })
        #expect(retained.allSatisfy { projectedSources.contains($0) })
    }
}
