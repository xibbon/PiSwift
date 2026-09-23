import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private final class C3BlockingAuthBackend: AuthStorageBackend {
    let started = LockedState(false)

    func withLock<Result: Sendable>(
        _ body: @Sendable (String?) throws -> AuthStorageLockResult<Result>
    ) throws -> Result {
        let transaction = try body(nil)
        transaction.onCommit()
        return transaction.result
    }

    func withLockAsync<Result: Sendable>(
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        let transaction = try await body(nil)
        transaction.onCommit()
        return transaction.result
    }

    func withLockAsync<Result: Sendable>(
        signal: CancellationToken?,
        _ body: @escaping @Sendable (String?) async throws -> AuthStorageLockResult<Result>
    ) async throws -> Result {
        started.withLock { $0 = true }
        while signal?.isCancelled != true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CancellationError()
    }
}

private func c3Session(
    _ api: HookAPI,
    order: LockedState<[String]>,
    settings overrideSettings: Settings? = nil,
    authStorage: AuthStorage? = nil,
    response: (@Sendable (Int, Model) -> AssistantMessage)? = nil
) -> AgentSession {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let calls = LockedState(0)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { model, _, _ in
            let stream = AssistantMessageEventStream()
            let call = calls.withLock { value in value += 1; return value }
            order.withLock { $0.append("request-\(call)") }
            Task {
                let message = response?(call, model) ?? AssistantMessage(content: [.text(TextContent(text: "answer \(call)"))],
                                               api: model.api, provider: model.provider, model: model.id,
                                               usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                                               stopReason: .stop)
                if message.stopReason == .error {
                    stream.push(.error(reason: .error, error: message))
                } else {
                    stream.push(.done(reason: .stop, message: message))
                }
                stream.end(message)
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))
    let manager = SessionManager.inMemory()
    let auth = authStorage ?? AuthStorage(":memory:")
    if authStorage == nil { auth.setRuntimeApiKey(model.provider, "test-key") }
    let registry = ModelRegistry(auth)
    let hook = LoadedHook(path: "c3", resolvedPath: "c3", handlers: api.handlers,
                          currentHandlers: { api.handlers })
    let runner = HookRunner([hook], manager.getCwd(), manager, registry)
    var settings = overrideSettings ?? Settings()
    if overrideSettings == nil {
        settings.compaction = CompactionSettingsOverrides(enabled: false)
        settings.retry = RetrySettings(enabled: false)
    }
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(),
        hookRunner: runner, modelRegistry: registry))
}

@Test func turnEndBoundaryCommitsBeforeNotificationAndContinuesOnce() async throws {
    let order = LockedState<[String]>([])
    let calls = LockedState(0)
    let api = HookAPI()
    api.on("turn_end") { (event: TurnEndEvent, _: HookContext) in
        let call = calls.withLock { value in value += 1; return value }
        if call == 1 {
            order.withLock { $0.append("preview") }
            #expect(event.messageEntryId.isEmpty == false)
            return BoundaryResult(entries: [.customMessage(customType: "note", content: .text("continue"),
                                                            display: false, details: nil)], shouldContinue: true)
        }
        return nil
    }
    let session = c3Session(api, order: order)
    defer { session.dispose() }
    let unsubscribe = session.subscribe { event in
        switch event {
        case .entryAppended: order.withLock { $0.append("commit") }
        case .agent(.turnEnd): order.withLock { $0.append("turn-end") }
        default: break
        }
    }
    defer { unsubscribe() }

    try await session.prompt("hello")
    await session.waitForIdle()
    let events = order.withLock { $0 }
    #expect(events.contains("request-1"))
    #expect(events.contains("request-2"))
    #expect(events.filter { $0.hasPrefix("request-") }.count == 2)
    #expect(events.firstIndex(of: "preview")! < events.firstIndex(of: "commit")!)
    #expect(events.firstIndex(of: "commit")! < events.firstIndex(of: "turn-end")!)
    #expect(events.firstIndex(of: "turn-end")! < events.firstIndex(of: "request-2")!)
}

@Test func retainNoneBoundaryCompactionCommitsAndContinuesOnce() async throws {
    let order = LockedState<[String]>([])
    let calls = LockedState(0)
    let api = HookAPI()
    api.on("turn_end") { (_: TurnEndEvent, _: HookContext) in
        guard calls.withLock({ value in value += 1; return value }) == 1 else { return nil }
        return BoundaryResult(entries: [
            .compaction(summary: "exact handoff", firstKeptEntryId: nil, details: nil, usage: nil),
            .customMessage(customType: "handoff", content: .text("continue from handoff"), display: false, details: nil),
        ], shouldContinue: true)
    }
    let session = c3Session(api, order: order)
    defer { session.dispose() }
    try await session.prompt("hello")
    await session.waitForIdle()

    let compaction = session.sessionManager.getBranch().compactMap { entry -> CompactionEntry? in
        if case .compaction(let value) = entry { return value }
        return nil
    }.first
    #expect(compaction?.summary == "exact handoff")
    #expect(compaction?.firstKeptEntryId == compaction?.id)
    #expect(order.withLock { $0.filter { $0.hasPrefix("request-") }.count } == 2)
}

@Test func beforeSettleCustomMessageContinuesBeforeFinalSettlement() async throws {
    let order = LockedState<[String]>([])
    let calls = LockedState(0)
    let api = HookAPI()
    api.on("agent_before_settle") { (_: AgentBeforeSettleEvent, _: HookContext) in
        let call = calls.withLock { value in value += 1; return value }
        guard call == 1 else { return nil }
        order.withLock { $0.append("before-settle") }
        return BoundaryResult(entries: [.customMessage(customType: "note", content: .text("one more"),
                                                        display: false, details: nil)], shouldContinue: true)
    }
    let session = c3Session(api, order: order)
    defer { session.dispose() }
    _ = session.subscribe { event in
        if case .agentSettled = event { order.withLock { $0.append("settled") } }
    }
    try await session.prompt("hello")
    await session.waitForIdle()
    let events = order.withLock { $0 }
    #expect(events.filter { $0.hasPrefix("request-") }.count == 2)
    #expect(events.firstIndex(of: "before-settle")! < events.firstIndex(of: "request-2")!)
    #expect(events.firstIndex(of: "request-2")! < events.firstIndex(of: "settled")!)
}

@Test func invalidTurnBoundaryDraftDoesNotCommitOrContinue() async throws {
    let order = LockedState<[String]>([])
    let api = HookAPI()
    api.on("turn_end") { (_: TurnEndEvent, _: HookContext) in
        BoundaryResult(entries: [.contextEdit(targetId: "missing", replacement: nil)], shouldContinue: true)
    }
    let session = c3Session(api, order: order)
    defer { session.dispose() }
    try await session.prompt("hello")
    await session.waitForIdle()
    #expect(order.withLock { $0.filter { $0.hasPrefix("request-") }.count } == 1)
    #expect(!session.sessionManager.getBranch().contains { $0.type == "context_edit" })
}

@Test func settledHandlersDeferNewRunUntilAllHaveFinished() async throws {
    let order = LockedState<[String]>([])
    let calls = LockedState(0)
    let sessionBox = LockedState<AgentSession?>(nil)
    let api = HookAPI()
    api.on("agent_settled") { (_: AgentSettledEvent, context: HookContext) in
        let call = calls.withLock { value in value += 1; return value }
        if call == 1 {
            #expect(context.isIdle())
            order.withLock { $0.append("settled-1") }
            try? await sessionBox.withLock { $0 }?.prompt("second")
        }
        return nil
    }
    api.on("agent_settled") { (_: AgentSettledEvent, _: HookContext) in
        order.withLock { $0.append("settled-2") }
        return nil
    }
    let session = c3Session(api, order: order)
    sessionBox.withLock { $0 = session }
    defer { session.dispose() }
    _ = session.subscribe { event in
        if case .agent(.agentStart) = event { order.withLock { $0.append("agent-start") } }
    }
    try await session.prompt("first")
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && order.withLock({ $0.filter { $0 == "agent-start" }.count }) < 2 {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    await session.waitForIdle()
    let events = order.withLock { $0 }
    #expect(events.filter { $0 == "agent-start" }.count == 2)
    #expect(events.firstIndex(of: "settled-2")! < events.lastIndex(of: "agent-start")!)
}

@Test func retryKeepsRawErrorButOmitsItFromProviderContext() async throws {
    let order = LockedState<[String]>([])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: true, maxRetries: 1, baseDelayMs: 1)
    let session = c3Session(HookAPI(), order: order, settings: settings) { call, model in
        AssistantMessage(content: [.text(TextContent(text: call == 1 ? "" : "ok"))],
                         api: model.api, provider: model.provider, model: model.id,
                         usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                         stopReason: call == 1 ? .error : .stop,
                         errorMessage: call == 1 ? "rate limit" : nil)
    }
    defer { session.dispose() }
    try await session.prompt("hello")
    await session.waitForIdle()

    let branch = session.sessionManager.getBranch()
    let rawError = branch.contains { entry in
        if case .message(let value) = entry, case .assistant(let assistant) = value.message {
            return assistant.stopReason == .error
        }
        return false
    }
    let omission = branch.contains { entry in
        if case .contextEdit(let edit) = entry { return edit.replacement == nil }
        return false
    }
    let projectedError = session.sessionManager.buildSessionProjection().messages.contains { message in
        if case .assistant(let assistant) = message { return assistant.stopReason == .error }
        return false
    }
    #expect(rawError)
    #expect(omission)
    #expect(!projectedError)
    #expect(order.withLock { $0.filter { $0.hasPrefix("request-") }.count } == 2)
}

@Test func nonretryableSecondErrorFinalizesRetryState() async throws {
    let order = LockedState<[String]>([])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: true, maxRetries: 2, baseDelayMs: 1)
    let session = c3Session(HookAPI(), order: order, settings: settings) { call, model in
        AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
                         usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                         stopReason: .error,
                         errorMessage: call == 1 ? "rate limit" : "invalid request")
    }
    defer { session.dispose() }
    let ends = LockedState<[Bool]>([])
    _ = session.subscribe { event in
        if case .autoRetryEnd(let success, _, _) = event { ends.withLock { $0.append(success) } }
    }
    try await session.prompt("hello")
    await session.waitForIdle()
    #expect(order.withLock { $0.filter { $0.hasPrefix("request-") }.count } == 2)
    #expect(ends.withLock { $0 } == [false])
}

@Test func failedLengthRecoveryKeepsRawAttemptAndDurableOmission() async throws {
    let order = LockedState<[String]>([])
    let api = HookAPI()
    api.on("session_before_compact") { (_: SessionBeforeCompactEvent, _: HookContext) in
        SessionBeforeCompactResult(cancel: true)
    }
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 10, keepRecentTokens: 1)
    settings.retry = RetrySettings(enabled: false)
    let session = c3Session(api, order: order, settings: settings) { _, model in
        AssistantMessage(content: [.text(TextContent(text: "truncated"))],
                         api: model.api, provider: model.provider, model: model.id,
                         usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                         stopReason: .length)
    }
    defer { session.dispose() }
    try await session.prompt("hello")
    await session.waitForIdle()

    let branch = session.sessionManager.getBranch()
    #expect(branch.contains { entry in
        if case .message(let value) = entry, case .assistant(let assistant) = value.message {
            return assistant.stopReason == .length
        }
        return false
    })
    #expect(branch.contains { entry in
        if case .contextEdit(let edit) = entry { return edit.replacement == nil }
        return false
    })
    #expect(!session.sessionManager.buildSessionProjection().messages.contains { message in
        if case .assistant(let assistant) = message { return assistant.stopReason == .length }
        return false
    })
    #expect(order.withLock { $0.filter { $0.hasPrefix("request-") }.count } == 1)
}

@Test func compactionStartCancellationStopsBeforeAuthOrProvider() async throws {
    let order = LockedState<[String]>([])
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 10, keepRecentTokens: 1)
    settings.retry = RetrySettings(enabled: false)
    let session = c3Session(HookAPI(), order: order, settings: settings)
    defer { session.dispose() }
    let model = session.agent.state.model
    _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text(String(repeating: "x", count: 5_000)))))
    _ = session.sessionManager.appendMessage(.assistant(AssistantMessage(
        content: [.text(TextContent(text: String(repeating: "y", count: 500)))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 100, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 100),
        stopReason: .stop)))
    session.refreshContext()
    let events = LockedState<[AgentSessionEvent]>([])
    _ = session.subscribe { event in
        events.withLock { $0.append(event) }
        if case .autoCompactionStart = event { session.abortCompaction() }
    }
    await session.runAutoCompaction(reason: .threshold, willRetry: false)
    let endedAborted = events.withLock { stored in stored.contains { event in
        if case .autoCompactionEnd(_, let aborted, _) = event { return aborted }
        return false
    } }
    #expect(endedAborted)
    #expect(order.withLock { $0.isEmpty })
}

@Test func cancellationInterruptsSummarizationAuthWait() async throws {
    let order = LockedState<[String]>([])
    let backend = C3BlockingAuthBackend()
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 10, keepRecentTokens: 1)
    settings.retry = RetrySettings(enabled: false)
    let auth = AuthStorage.fromStorage(backend)
    auth.set("anthropic", credential: .oauth(OAuthCredential(access: "expired", refresh: "refresh", expires: 0)))
    let session = c3Session(HookAPI(), order: order, settings: settings,
                            authStorage: auth)
    defer { session.dispose() }
    let model = session.agent.state.model
    _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text(String(repeating: "x", count: 5_000)))))
    _ = session.sessionManager.appendMessage(.assistant(AssistantMessage(
        content: [.text(TextContent(text: String(repeating: "y", count: 500)))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 100, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 100),
        stopReason: .stop)))
    session.refreshContext()
    let events = LockedState<[AgentSessionEvent]>([])
    _ = session.subscribe { event in events.withLock { $0.append(event) } }
    let compaction = Task { await session.runAutoCompaction(reason: .threshold, willRetry: false) }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && !backend.started.withLock({ $0 }) {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(backend.started.withLock { $0 })
    await session.abort()
    await compaction.value
    let aborted = events.withLock { stored in stored.contains { event in
        if case .autoCompactionEnd(_, let cancelled, _) = event { return cancelled }
        return false
    } }
    #expect(aborted)
    #expect(order.withLock { $0.isEmpty })
}
