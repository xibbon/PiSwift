import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct BridgeFixture {
    let session: AgentSession
    let runner: HookRunner

    init(hooks: [LoadedHook] = [], attachRunner: Bool = true, settings: Settings = Settings(), streamFn: StreamFn? = nil) {
        let manager = SessionManager.inMemory("/tmp")
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey("openai", "test")
        let registry = ModelRegistry(auth)
        runner = HookRunner(hooks, "/tmp", manager, registry)
        let model = Model(id: "bridge", name: "Bridge", api: .openAIResponses,
                          provider: "openai", baseUrl: "https://example.invalid", reasoning: false,
                          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                          contextWindow: 1000, maxTokens: 100)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model), streamFn: streamFn))
        session = AgentSession(config: AgentSessionConfig(
            agent: agent, sessionManager: manager, settingsManager: SettingsManager.inMemory(settings),
            resourceLoader: TestResourceLoader(), hookRunner: attachRunner ? runner : nil,
            modelRegistry: registry
        ))
    }
}

private enum BridgeEmission: String, CaseIterable, Sendable {
    case generic, extensions, resources, headers, trust, tool, bash, context, beforeStart

    var eventType: String {
        switch self {
        case .generic, .extensions: "agent_start"
        case .resources: "resources_discover"
        case .headers: "before_provider_headers"
        case .trust: "project_trust"
        case .tool: "tool_call"
        case .bash: "user_bash"
        case .context: "context"
        case .beforeStart: "before_agent_start"
        }
    }

    func emit(on runner: HookRunner) async {
        switch self {
        case .generic: _ = await runner.emit(AgentStartEvent())
        case .extensions: await runner.emitToExtensions(AgentStartEvent())
        case .resources: _ = await runner.emitResourcesDiscover(cwd: "/tmp", reason: .startup)
        case .headers: _ = await runner.emitBeforeProviderHeaders(["test": "value"])
        case .trust: _ = await runner.emitProjectTrust(ProjectTrustEvent(cwd: "/tmp"))
        case .tool: _ = await runner.emitToolCall(ToolCallEvent(toolName: "read", toolCallId: "1", input: [:]))
        case .bash: _ = await runner.emitUserBash(UserBashEvent(command: "pwd", excludeFromContext: false, cwd: "/tmp"))
        case .context: _ = await runner.emitContext([])
        case .beforeStart: _ = await runner.emitBeforeAgentStart("test", nil)
        }
    }
}

@Suite struct HookEventBridgeTests {
    @Test(arguments: BridgeEmission.allCases, [0, 2])
    fileprivate func everyEntryPathNotifiesOnceBeforeHandlers(_ emission: BridgeEmission, _ handlerCount: Int) async {
        let calls = LockedState<[String]>([])
        let handler: HookHandler = { _, _ in
            calls.withLock { $0.append("handler") }
            return nil
        }
        let hook = LoadedHook(path: "bridge", resolvedPath: "bridge",
                              handlers: [emission.eventType: Array(repeating: handler, count: handlerCount)],
                              isExtension: true)
        let fixture = BridgeFixture(hooks: [hook])
        defer { fixture.session.dispose() }
        let unsubscribe = fixture.runner.addEventObserver { event in
            calls.withLock { $0.append(event.type) }
        }
        await emission.emit(on: fixture.runner)
        #expect(calls.withLock { $0 } == [emission.eventType] + Array(repeating: "handler", count: handlerCount))
        unsubscribe()
        calls.withLock { $0.removeAll() }
        await emission.emit(on: fixture.runner)
        #expect(calls.withLock { $0 } == Array(repeating: "handler", count: handlerCount))
    }

    @Test func sessionSubscriptionSurvivesAttachmentReplacementAndRemoval() async {
        let fixture = BridgeFixture(attachRunner: false)
        let session = fixture.session
        defer { session.dispose() }
        let calls = LockedState<[String]>([])
        let unsubscribe = session.subscribeToHookEvents { event in calls.withLock { $0.append(event.type) } }
        #expect(session.hookRunner == nil)
        session.hookRunner = fixture.runner
        _ = await fixture.runner.emit(AgentStartEvent())
        let replacement = HookRunner([], "/tmp", session.sessionManager, session.modelRegistry)
        session.hookRunner = replacement
        _ = await fixture.runner.emit(AgentEndEvent(messages: []))
        _ = await replacement.emit(AgentStartEvent())
        session.hookRunner = nil
        _ = await replacement.emit(AgentEndEvent(messages: []))
        session.hookRunner = replacement
        _ = await replacement.emit(AgentStartEvent())
        #expect(calls.withLock { $0 } == Array(repeating: "agent_start", count: 3))
        unsubscribe()
        unsubscribe()
        _ = await replacement.emit(AgentEndEvent(messages: []))
        session.hookRunner = fixture.runner
        _ = await fixture.runner.emit(AgentEndEvent(messages: []))
        #expect(calls.withLock { $0.count } == 3)
    }

    @Test func disposalDetachesTheSessionObserver() async {
        let fixture = BridgeFixture()
        let count = LockedState(0)
        let unsubscribe = fixture.session.subscribeToHookEvents { _ in count.withLock { $0 += 1 } }
        defer { unsubscribe() }
        _ = await fixture.runner.emit(AgentStartEvent())
        fixture.session.dispose()
        _ = await fixture.runner.emit(AgentStartEvent())
        #expect(count.withLock { $0 } == 1)
        #expect(fixture.session.hookRunner == nil)
    }

    @Test func manualCompactionFailureReachesHostWithItsFields() async throws {
        let handled = LockedState<[SessionCompactFailedEvent]>([])
        let api = HookAPI()
        api.on("session_compact_failed") { (event: SessionCompactFailedEvent, _: HookContext) in
            handled.withLock { $0.append(event) }
            return nil
        }
        var settings = Settings()
        settings.compaction = CompactionSettingsOverrides(enabled: false, reserveTokens: 100, keepRecentTokens: 1)
        // Use the truncated-summary fixture pattern from SessionV0850Tests.
        let fixture = BridgeFixture(
            hooks: [LoadedHook(path: "bridge", resolvedPath: "bridge", handlers: api.handlers)],
            settings: settings,
            streamFn: { model, _, _ in
                let message = AssistantMessage(content: [.text(TextContent(text: "incomplete"))],
                    api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                    stopReason: .length)
                let stream = AssistantMessageEventStream()
                stream.push(.done(reason: .length, message: message))
                stream.end(message)
                return stream
            }
        )
        defer { fixture.session.dispose() }
        let observed = LockedState<[SessionCompactFailedEvent]>([])
        let unsubscribe = fixture.session.subscribeToHookEvents { event in
            if let event = event as? SessionCompactFailedEvent { observed.withLock { $0.append(event) } }
        }
        defer { unsubscribe() }
        fixture.session.sessionManager.appendMessage(.user(UserMessage(content: .text("one"))))
        fixture.session.sessionManager.appendMessage(.user(UserMessage(content: .text("two"))))
        fixture.session.agent.messages = fixture.session.sessionManager.buildSessionContext().messages
        do {
            _ = try await fixture.session.compact()
            Issue.record("Compaction must reject an incomplete summary.")
        } catch {
            #expect(error.localizedDescription.contains("token cap"))
        }
        let events = observed.withLock { $0 }
        #expect(events.count == 1)
        let event = try #require(events.first)
        let handlerEvent = try #require(handled.withLock { $0.first })
        #expect(event.reason == .manual)
        #expect(!event.aborted)
        #expect(event.errorMessage != nil)
        #expect(!event.willRetry)
        #expect(!event.fromExtension)
        #expect(event.fromExtension == handlerEvent.fromExtension)
        #expect(event.errorMessage == handlerEvent.errorMessage)
    }

    @Test(arguments: [false, true])
    func extensionOriginPassesThrough(_ fromExtension: Bool) async throws {
        let fixture = BridgeFixture()
        defer { fixture.session.dispose() }
        let events = LockedState<[SessionCompactFailedEvent]>([])
        let unsubscribe = fixture.session.subscribeToHookEvents { event in
            if let event = event as? SessionCompactFailedEvent { events.withLock { $0.append(event) } }
        }
        defer { unsubscribe() }
        _ = await fixture.runner.emit(SessionCompactFailedEvent(reason: .manual, errorMessage: "failed",
                                                                 aborted: false, willRetry: false, fromExtension: fromExtension))
        #expect(try #require(events.withLock { $0.first }).fromExtension == fromExtension)
    }

    @Test func handlerSelectProducesPromptStartThenEnd() async throws {
        let api = HookAPI()
        api.on("agent_start") { (_: AgentStartEvent, context: HookContext) in
            _ = await context.ui.select("Choose", ["one", "two"])
            return nil
        }
        let fixture = BridgeFixture(hooks: [LoadedHook(path: "bridge", resolvedPath: "bridge", handlers: api.handlers)])
        defer { fixture.session.dispose() }
        let prompts = LockedState<[(String, UIPromptKind)]>([])
        let unsubscribe = fixture.session.subscribeToHookEvents { event in
            if let event = event as? UIPromptStartEvent { prompts.withLock { $0.append((event.type, event.kind)) } }
            if let event = event as? UIPromptEndEvent { prompts.withLock { $0.append((event.type, event.kind)) } }
        }
        defer { unsubscribe() }
        _ = await fixture.runner.emit(AgentStartEvent())
        let deadline = ContinuousClock.now + .seconds(2)
        while prompts.withLock({ $0.count }) < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let events = prompts.withLock { $0 }
        #expect(events.map(\.0) == ["ui_prompt_start", "ui_prompt_end"])
        #expect(events.map(\.1) == [.select, .select])
    }

    @Test func observerCanUnsubscribeInsideCallback() async {
        let fixture = BridgeFixture()
        defer { fixture.session.dispose() }
        let count = LockedState(0)
        let cancellation = LockedState<(@Sendable () -> Void)?>(nil)
        let unsubscribe = fixture.runner.addEventObserver { _ in
            count.withLock { $0 += 1 }
            cancellation.withLock { $0 }?()
        }
        cancellation.withLock { $0 = unsubscribe }
        _ = await fixture.runner.emit(AgentStartEvent())
        _ = await fixture.runner.emit(AgentStartEvent())
        #expect(count.withLock { $0 } == 1)
    }

    @Test func sessionObserverCanUnsubscribeAndReplaceRunner() async {
        let fixture = BridgeFixture()
        defer { fixture.session.dispose() }
        let session = fixture.session
        let replacement = HookRunner([], "/tmp", session.sessionManager, session.modelRegistry)
        let count = LockedState(0)
        let cancellation = LockedState<(@Sendable () -> Void)?>(nil)
        let unsubscribe = session.subscribeToHookEvents { _ in
            count.withLock { $0 += 1 }
            cancellation.withLock { $0 }?()
            session.hookRunner = replacement
        }
        cancellation.withLock { $0 = unsubscribe }
        _ = await fixture.runner.emit(AgentStartEvent())
        _ = await replacement.emit(AgentStartEvent())
        #expect(count.withLock { $0 } == 1)
        #expect(session.hookRunner === replacement)
    }

    @Test func observerSeesOriginalHeadersAndCannotReplaceHandlerInput() async {
        let observed = LockedState<[ProviderHeaders]>([])
        let handled = LockedState<[ProviderHeaders]>([])
        let api = HookAPI()
        api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
            handled.withLock { $0.append(event.headers) }
            return BeforeProviderHeadersEventResult(headers: ["test": "changed"])
        }
        api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
            handled.withLock { $0.append(event.headers) }
            return nil
        }
        let fixture = BridgeFixture(hooks: [LoadedHook(path: "bridge", resolvedPath: "bridge", handlers: api.handlers)])
        defer { fixture.session.dispose() }
        let unsubscribe = fixture.runner.addEventObserver { event in
            if var event = event as? BeforeProviderHeadersEvent {
                observed.withLock { $0.append(event.headers) }
                event.headers = ["test": "observer"]
            }
        }
        defer { unsubscribe() }
        let result = await fixture.runner.emitBeforeProviderHeaders(["test": "original"])
        #expect(observed.withLock { $0 } == [["test": "original"]])
        #expect(handled.withLock { $0 } == [["test": "original"], ["test": "changed"]])
        #expect(result == ["test": "changed"])
    }

    @Test(arguments: [false, true])
    func concurrentSubscriptionsAreNotLost(_ onSession: Bool) async {

        let fixture = BridgeFixture()
        defer { fixture.session.dispose() }
        let counts = LockedState<[Int: Int]>([:])
        let cancellations = LockedState<[@Sendable () -> Void]>([])
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let observer: @Sendable (any HookEvent) -> Void = { _ in
                        counts.withLock { $0[index, default: 0] += 1 }
                    }
                    let cancel = onSession
                        ? fixture.session.subscribeToHookEvents(observer)
                        : fixture.runner.addEventObserver(observer)
                    cancellations.withLock { $0.append(cancel) }
                }
            }
        }
        _ = await fixture.runner.emit(AgentStartEvent())
        #expect(counts.withLock { $0.count } == 50)
        #expect(counts.withLock { $0.values.allSatisfy { $0 == 1 } })
        await withTaskGroup(of: Void.self) { group in
            for cancel in cancellations.withLock({ $0 }) { group.addTask { cancel() } }
        }
        _ = await fixture.runner.emit(AgentStartEvent())
        #expect(counts.withLock { $0.values.allSatisfy { $0 == 1 } })
    }
}
