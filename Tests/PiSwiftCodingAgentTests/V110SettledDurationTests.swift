import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func v110Assistant(_ model: Model, content: [ContentBlock] = [], reason: StopReason = .stop,
                           error: String? = nil) -> AssistantMessage {
    AssistantMessage(content: content, api: model.api, provider: model.provider, model: model.id,
                     usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                     stopReason: reason, errorMessage: error)
}

private func v110EventSession(_ api: HookAPI = HookAPI(), retry: Bool = false,
                             response: (@Sendable (Int, Model) -> AssistantMessage)? = nil) -> AgentSession {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let calls = LockedState(0)
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { model, _, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            let stream = AssistantMessageEventStream()
            let message = response?(call, model) ?? v110Assistant(model)
            if message.stopReason == .error { stream.push(.error(reason: .error, error: message)) }
            else { stream.push(.done(reason: message.stopReason, message: message)) }
            stream.end(message)
            return stream
        }, getApiKey: { _ in "test-key" }))
    let manager = SessionManager.inMemory()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let registry = ModelRegistry(auth)
    let runner = HookRunner([LoadedHook(path: "v110-events", resolvedPath: "v110-events", handlers: api.handlers)],
                            manager.getCwd(), manager, registry)
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 10, keepRecentTokens: 1)
    settings.retry = RetrySettings(enabled: retry, maxRetries: 1, baseDelayMs: 1)
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(),
        hookRunner: runner, modelRegistry: registry))
}

@Test(.timeLimit(.minutes(1))) func v110RetrySettlesOnceWithAbortedFalse() async throws {
    // Upstream regressions/6363-agent-settled-event.test.ts:29-61.
    let hookOrder = LockedState<[String]>([])
    let hookValues = LockedState<[Bool]>([])
    let api = HookAPI()
    api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
        hookOrder.withLock { $0.append("agent_end") }
        return nil
    }
    api.on("agent_settled") { (event: AgentSettledEvent, context: HookContext) in
        hookOrder.withLock { $0.append("agent_settled:\(context.isIdle())") }
        hookValues.withLock { $0.append(event.aborted) }
        return nil
    }
    let session = v110EventSession(api, retry: true) { call, model in
        v110Assistant(model, reason: call == 1 ? .error : .stop, error: call == 1 ? "overloaded_error" : nil)
    }
    defer { session.dispose() }
    let values = LockedState<[Bool]>([])
    let unsubscribe = session.subscribe { event in
        if case .agentSettled(let aborted) = event { values.withLock { $0.append(aborted) } }
    }
    defer { unsubscribe() }
    try await session.prompt("start")
    await session.waitForIdle()
    #expect(values.withLock { $0 } == [false])
    #expect(hookValues.withLock { $0 } == [false])
    #expect(hookOrder.withLock { $0 } == ["agent_end", "agent_end", "agent_settled:true"])
}

private struct V110AbortObserverBashOperations: BashOperations {
    let ready: LockedState<Bool>
    let releaseBoundary: LockedState<Bool>

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        let remove = options?.signal?.onCancel { releaseBoundary.withLock { $0 = true } }
        defer { remove?() }
        ready.withLock { $0 = true }
        while options?.signal?.isCancelled != true { try await Task.sleep(for: .milliseconds(1)) }
        return BashResult(output: "", exitCode: nil, cancelled: true, truncated: false)
    }
}

@Test(.timeLimit(.minutes(1))) func v110AbortDuringBeforeSettleReportsAbortedAndNextRunClearsIt() async throws {
    // Upstream agent-session-boundaries.test.ts:705-737.
    let entered = LockedState(false)
    let release = LockedState(false)
    let boundaryCalls = LockedState(0)
    let api = HookAPI()
    api.on("agent_before_settle") { (_: AgentBeforeSettleEvent, _: HookContext) in
        guard boundaryCalls.withLock({ $0 += 1; return $0 }) == 1 else { return nil }
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
        // Swift boundary custom data must be a dictionary. Supply a runnable continuation.
        return BoundaryResult(entries: [
            .custom(customType: "after-abort", data: AnyCodable(["value": true])),
            .customMessage(customType: "continuation", content: .text("continue"), display: false, details: nil)
        ], shouldContinue: true)
    }
    let session = v110EventSession(api)
    defer { session.dispose() }
    let values = LockedState<[Bool]>([])
    let unsubscribe = session.subscribe { event in
        if case .agentSettled(let aborted) = event { values.withLock { $0.append(aborted) } }
    }
    defer { unsubscribe() }
    let prompt = Task { try await session.prompt("first") }
    while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
    // abortBash runs after the per-run abort request. Its cancellation releases the hook.
    let ready = LockedState(false)
    let bash = Task {
        try await session.executeBash("observe-abort", excludeFromContext: true,
            operations: V110AbortObserverBashOperations(ready: ready, releaseBoundary: release))
    }
    while !ready.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
    let abort = Task { await session.abort() }
    try await prompt.value
    await abort.value
    #expect(try await bash.value.cancelled)
    #expect(values.withLock { $0 } == [true])
    #expect(session.sessionManager.getEntries().contains { entry in
        if case .custom(let value) = entry { return value.customType == "after-abort" }
        return false
    })
    try await session.prompt("next")
    await session.waitForIdle()
    #expect(values.withLock { $0 } == [true, false])
}

@Test(.timeLimit(.minutes(1))) func v110ManualIdleCompactionSettlesWithAbortedFalse() async throws {
    // C1 retains Swift's idle manual-compaction settlement.
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        SessionBeforeCompactResult(compaction: CompactionResult(summary: "summary",
            firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore))
    }
    let session = v110EventSession(api)
    defer { session.dispose() }
    _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text(String(repeating: "x", count: 5000)))))
    _ = session.sessionManager.appendMessage(.assistant(v110Assistant(session.agent.state.model,
        content: [.text(TextContent(text: String(repeating: "y", count: 500)))])))
    session.refreshContext()
    let values = LockedState<[Bool]>([])
    let unsubscribe = session.subscribe { event in
        if case .agentSettled(let aborted) = event { values.withLock { $0.append(aborted) } }
    }
    defer { unsubscribe() }
    _ = try await session.compact()
    await session.waitForIdle()
    #expect(values.withLock { $0 } == [false])
}

@Test func v110SettlementJSONIncludesBothAbortValues() throws {
    for value in [false, true] {
        let event = AgentSessionEvent.agentSettled(aborted: value)
        #expect(encodeSessionEvent(event)["aborted"] as? Bool == value)
        let json = try #require(encodeSessionEventJSON(event).data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["type"] as? String == "agent_settled")
        #expect(object["aborted"] as? Bool == value)
    }
}

@Test func v110ToolDurationSessionAndJSONRoundTrip() throws {
    // #10549: old sessions have no duration; new sessions preserve Int milliseconds.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v110-duration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    manager.appendMessage(.user(UserMessage(content: .text("start"))))
    manager.appendMessage(.assistant(v110Assistant(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))))
    for duration in [Int?.none, 37] {
        let message = ToolResultMessage(toolCallId: "call", toolName: "test", content: [], isError: false, durationMs: duration)
        manager.appendMessage(.toolResult(message))
        let json = encodeAgentMessageJSON(.toolResult(message)).serialized()
        if let duration { #expect(json.hasSuffix("\"durationMs\":\(duration)}")) }
        else { #expect(!json.contains("durationMs")) }
        for event in [AgentEvent.messageEnd(message: .toolResult(message)),
                      .turnEnd(message: .assistant(v110Assistant(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))), toolResults: [message])] {
            let object = encodeSessionEvent(.agent(event))
            let result = (object["toolResults"] as? [[String: Any]])?.first ?? (object["message"] as? [String: Any])
            #expect(result?["durationMs"] as? Int == duration)
            let jsonObject = try #require(JSONSerialization.jsonObject(
                with: Data(encodeSessionEventJSON(.agent(event)).utf8)) as? [String: Any])
            let jsonResult = (jsonObject["toolResults"] as? [[String: Any]])?.first ??
                (jsonObject["message"] as? [String: Any])
            #expect(jsonResult?["durationMs"] as? Int == duration)
            if let duration {
                #expect(encodeSessionEventJSON(.agent(event)).contains("\"durationMs\":\(duration)}"))
            }
        }
    }
    let path = try #require(manager.getSessionFile())
    let results = loadEntriesFromFile(path).compactMap { entry -> ToolResultMessage? in
        guard case .entry(.message(let entry)) = entry, case .toolResult(let result) = entry.message else { return nil }
        return result
    }
    #expect(results.count == 2)
    #expect(results.map(\.durationMs) == [nil, 37])
}

@Test func v110ToolEndJSONIncludesOnlySetDuration() throws {
    for duration in [Int?.none, 19] {
        let result = AgentToolResult(content: [])
        let events: [AgentSessionEvent] = [
            .agent(.toolExecutionEnd(toolCallId: "call", toolName: "test", result: result, isError: false, durationMs: duration)),
            .nestedToolExecution(.end(toolCallId: "nested", toolName: "test", result: result, isError: false,
                                     parentToolCallId: "call", durationMs: duration))]
        for event in events {
            #expect(encodeSessionEvent(event)["durationMs"] as? Int == duration)
            let object = try #require(JSONSerialization.jsonObject(with: Data(encodeSessionEventJSON(event).utf8)) as? [String: Any])
            #expect(object["durationMs"] as? Int == duration)
        }
    }
}

@Test func v110NestedRunnerUsesOutcomeDuration() async {
    let events = LockedState<[NestedToolExecutionEvent]>([])
    let runner = NestedToolCallRunner(host: NestedToolCallHost(getTools: { [] }, isSequential: { false },
        runToolCall: { call, _, _, _ in AgentToolCallOutcome(toolCall: call, result: AgentToolResult(content: []), isError: false, durationMs: 43) },
        emit: { event in events.withLock { $0.append(event) } }))
    _ = await runner.execute(callerId: "root", name: "child", args: [:])
    let durations = events.withLock { $0.compactMap { event -> Int? in
        if case .end(_, _, _, _, _, let duration) = event { return duration }
        return nil
    } }
    #expect(durations == [43])
}

private enum V110CompactionError: Error, LocalizedError {
    case failed
    var errorDescription: String? { "test failure" }
}

@Test(.timeLimit(.minutes(1))) func v110AutoCompactionFailureCarriesErrorMessage() async throws {
    let session = v110EventSession()
    defer { session.dispose() }
    let events = LockedState<[AgentSessionEvent]>([])
    let unsubscribe = session.subscribe { event in events.withLock { $0.append(event) } }
    defer { unsubscribe() }
    for reason in [AutoCompactionReason.threshold, .overflow] {
        events.withLock { $0.removeAll() }
        await session.runAutoCompaction(reason: reason, willRetry: true, compactBlock: { throw V110CompactionError.failed })
        await session.waitForIdle()
        let event = try #require(events.withLock { $0.first { if case .autoCompactionEnd = $0 { return true }; return false } })
        guard case .autoCompactionEnd(let result, let aborted, let willRetry, let errorMessage) = event else { return }
        let expected = reason == .overflow ? "Context overflow recovery failed: test failure" : "Auto-compaction failed: test failure"
        #expect(result == nil)
        #expect(!aborted)
        #expect(!willRetry)
        #expect(errorMessage == expected)
        #expect(encodeSessionEvent(event)["errorMessage"] as? String == expected)
        #expect(encodeSessionEventJSON(event).contains(expected))
    }
    events.withLock { $0.removeAll() }
    await session.runAutoCompaction(reason: .threshold, willRetry: true, compactBlock: { throw CancellationError() })
    await session.waitForIdle()
    let cancelled = try #require(events.withLock { $0.first { if case .autoCompactionEnd = $0 { return true }; return false } })
    guard case .autoCompactionEnd(_, let aborted, let willRetry, let errorMessage) = cancelled else { return }
    #expect(aborted)
    #expect(!willRetry)
    #expect(errorMessage == nil)
    #expect(encodeSessionEvent(cancelled)["errorMessage"] == nil)
}

@Test func v110RenderOptionsKeepDefaultsAndAcceptHostValues() {
    #expect(RenderResultOptions(expanded: false, isPartial: true).durationMs == nil)
    #expect(RenderResultOptions(expanded: false, isPartial: true).outputPad == 1)
    let result = RenderResultOptions(expanded: true, isPartial: false, durationMs: 9, outputPad: 3)
    #expect(result.durationMs == 9)
    #expect(result.outputPad == 3)
    #expect(HookMessageRenderOptions(expanded: false).outputPad == 1)
    #expect(HookMessageRenderOptions(expanded: true, outputPad: 0).outputPad == 0)
}

@Test(.timeLimit(.minutes(1))) func v110AgentAndNestedHooksReceiveExecutionDurations() async throws {
    // #10549: pass durations from both execution paths to extension handlers.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v110-hook-duration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let observed = LockedState<[ToolExecutionEndEvent]>([])
    let auth = AuthStorage(":memory:")
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    auth.setRuntimeApiKey(model.provider, "test-key")
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: false)
    let result = try await createAgentSession(CreateAgentSessionOptions(cwd: directory.path, agentDir: directory.path,
        authStorage: auth, modelRegistry: ModelRegistry(auth), model: model, projectTrusted: false, noTools: .builtin,
        inlineExtensions: [InlineExtension(name: "v110-durations") { api in
            api.on("tool_execution_end") { (event: ToolExecutionEndEvent, _: HookContext) in
                observed.withLock { $0.append(event) }
                return nil
            }
            api.registerTool(CustomTool(name: "duration_leaf", label: "Leaf", description: "Test leaf", parameters: [:],
                execute: { _, _, _, _, _ in
                    try await Task.sleep(for: .milliseconds(2))
                    return AgentToolResult(content: [])
                }))
            api.registerTool(CustomTool(name: "duration_outer", label: "Outer", description: "Test outer", parameters: [:],
                execute: { _, _, _, context, _ in
                    let nested = await context.executeTool(name: "duration_leaf", args: [:])
                    #expect(nested.durationMs != nil)
                    return nested.result
                }))
        }], sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(settings)))
    let session = result.session
    defer { session.dispose() }
    let calls = LockedState(0)
    session.agent.streamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        let call = calls.withLock { $0 += 1; return $0 }
        let message = call == 1
            ? v110Assistant(model, content: [.toolCall(ToolCall(id: "outer", name: "duration_outer", arguments: [:]))], reason: .toolUse)
            : v110Assistant(model)
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
        return stream
    }
    try await session.prompt("run tools")
    await session.waitForIdle()
    let events = observed.withLock { $0 }
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.durationMs != nil && $0.durationMs! >= 0 })
    #expect(events.first { $0.toolName == "duration_leaf" }?.parentToolCallId == "outer")
    #expect(events.first { $0.toolName == "duration_outer" }?.parentToolCallId == nil)
}
