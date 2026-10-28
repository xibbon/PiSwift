import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c1v140RecoveryModel() -> Model {
    Model(id: "recovery-v140", name: "Recovery", api: .openAICompletions, provider: "openai",
          baseUrl: "https://example.invalid", reasoning: false, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 100_000, maxTokens: 1_000)
}

private func c1v140RecoverySession(_ manager: SessionManager, requests: LockedState<[[Message]]>,
                                    firstUserId: String) -> AgentSession {
    let model = c1v140RecoveryModel()
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, streamFn: { model, context, _ in
            requests.withLock { $0.append(context.messages) }
            let response = AssistantMessage(content: [.text(TextContent(text: "done"))],
                api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: response))
            stream.end(response)
            return stream
        }, getApiKey: { _ in "test-key" }))
    agent.messages = manager.buildSessionContext().messages
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let registry = ModelRegistry(auth)
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        // Retain all input after the first user so unrelated results stay observable.
        return SessionBeforeCompactResult(compaction: CompactionResult(summary: "summary",
            firstKeptEntryId: firstUserId, tokensBefore: event.preparation.tokensBefore))
    }
    let runner = HookRunner([LoadedHook(path: "recovery", resolvedPath: "recovery", handlers: api.handlers)],
                            manager.getCwd(), manager, registry)
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true)
    settings.retry = RetrySettings(enabled: false)
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(),
        hookRunner: runner, modelRegistry: registry))
}

private func c1v140Omissions(_ manager: SessionManager) -> [String] {
    manager.getBranch().compactMap { entry in
        if case .contextEdit(let edit) = entry, edit.replacement == nil { return edit.targetId }
        return nil
    }
}

// Upstream 02726086d, test/suite/regressions/11227-recovery-omits-tool-results.test.ts:15.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c1v140ResumedLengthRecoveryOmitsCallAndResult(replaceBeforePrompt: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-recovery-v140-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager.create(root.path, root.path)
    let model = c1v140RecoveryModel()
    let userId = manager.appendMessage(.user(UserMessage(content: .text("check status"), timestamp: 1_000)))
    let call = ContentBlock.toolCall(ToolCall(id: "call_truncated", name: "bash", arguments: ["command": AnyCodable("echo")]))
    let assistantId = manager.appendMessage(.assistant(AssistantMessage(content: [call],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 100, output: 16, cacheRead: 0, cacheWrite: 0, totalTokens: 116),
        stopReason: .length, timestamp: 1_500)))
    let resultId = manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "call_truncated", toolName: "bash",
        content: [.text(TextContent(text: "Not executed: output token limit reached."))], isError: true, timestamp: 1_600)))
    if replaceBeforePrompt {
        manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "call_unrelated", toolName: "bash",
            content: [.text(TextContent(text: "keep unrelated"))], isError: false, timestamp: 1_700)))
        try manager.appendContextEdit(assistantId, .blocks([.text(TextContent(text: "edited prefix")), call]))
    }
    let path = try #require(manager.getSessionFile())
    // Open a new manager before the prompt to cover the persisted resume path.
    let resumed = try SessionManager.openValidated(path)
    let requests = LockedState<[[Message]]>([])
    let session = c1v140RecoverySession(resumed, requests: requests, firstUserId: userId)
    try await session.prompt("continue")
    await session.waitForIdle()
    session.dispose()
    let request = try #require(requests.withLock { $0.first })
    #expect(!request.contains { if case .assistant(let value) = $0 { return value.stopReason == .length }; return false })
    let resultIds = request.compactMap { message -> String? in
        if case .toolResult(let value) = message { return value.toolCallId }; return nil
    }
    #expect(resultIds == (replaceBeforePrompt ? ["call_unrelated"] : []))
    #expect(c1v140Omissions(resumed) == [assistantId, resultId])
    let reopened = try SessionManager.openValidated(path)
    #expect(c1v140Omissions(reopened) == [assistantId, resultId])
    let projected = reopened.buildSessionProjection().messages
    #expect(!projected.contains { if case .assistant(let value) = $0 { return value.stopReason == .length }; return false })
    #expect(!projected.contains { if case .toolResult(let value) = $0 { return value.toolCallId == "call_truncated" }; return false })
    let secondRequests = LockedState<[[Message]]>([])
    let second = c1v140RecoverySession(reopened, requests: secondRequests, firstUserId: userId)
    defer { second.dispose() }
    try await second.prompt("continue again")
    await second.waitForIdle()
    #expect(c1v140Omissions(reopened) == [assistantId, resultId])
    let secondRequest = try #require(secondRequests.withLock { $0.first })
    #expect(!secondRequest.contains { if case .assistant(let value) = $0 { return value.stopReason == .length }; return false })
    #expect(!secondRequest.contains { if case .toolResult(let value) = $0 { return value.toolCallId == "call_truncated" }; return false })
}

@Test func c1v140RecoveryMissingSourceHasTypedDiagnostic() {
    #expect(AgentSessionError.recoveryEntryMissing.localizedDescription ==
        "Cannot persist recovery omission because a projected message has no source entry")
}
