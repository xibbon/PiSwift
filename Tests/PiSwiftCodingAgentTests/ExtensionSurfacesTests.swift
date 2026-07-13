import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private actor ExtensionSurfaceRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private func extensionSurfaceAssistant(_ model: Model) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: "done"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop
    )
}

private func extensionSurfaceSession(
    hookRunner: HookRunner? = nil,
    streamFn: StreamFn? = nil
) -> AgentSession {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: streamFn ?? { model, _, _ in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: extensionSurfaceAssistant(model)))
                stream.push(.done(reason: .stop, message: extensionSurfaceAssistant(model)))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))
    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    return AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(),
        hookRunner: hookRunner,
        modelRegistry: ModelRegistry(authStorage)
    ))
}

@Test func agentSettledDispatchesBeforeIdleWaitReturns() async throws {
    let recorder = ExtensionSurfaceRecorder()
    let api = HookAPI(hookPath: "<test:settled>")
    api.on("agent_settled") { (_: AgentSettledEvent, _: HookContext) in
        await recorder.append("settled")
        return nil
    }
    let sessionManager = SessionManager.inMemory()
    let runner = HookRunner(
        [LoadedHook(path: "<test:settled>", resolvedPath: "<test:settled>", handlers: api.handlers)],
        FileManager.default.currentDirectoryPath,
        sessionManager,
        ModelRegistry(AuthStorage(":memory:"))
    )
    let session = extensionSurfaceSession(hookRunner: runner)
    defer { session.dispose() }

    let promptTask = try await session.submitPrompt("hello")
    await session.waitForIdle()
    try await promptTask.value

    #expect(await recorder.snapshot() == ["settled"])
    #expect(session.isStreaming == false)
}

@Test func beforeProviderHeadersMergesHandlerResultIntoOutgoingOptions() async throws {
    let capturedHeaders = LockedState<[String: String]?>(nil)
    let baseModel = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let model = Model(
        id: baseModel.id,
        name: baseModel.name,
        api: baseModel.api,
        provider: baseModel.provider,
        baseUrl: baseModel.baseUrl,
        reasoning: baseModel.reasoning,
        input: baseModel.input,
        cost: baseModel.cost,
        contextWindow: baseModel.contextWindow,
        maxTokens: baseModel.maxTokens,
        headers: ["X-Model": "model"],
        compat: baseModel.compat,
        thinkingLevelMap: baseModel.thinkingLevelMap
    )
    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    let registry = ModelRegistry(authStorage)
    let result = await createAgentSession(CreateAgentSessionOptions(
        cwd: FileManager.default.currentDirectoryPath,
        agentDir: FileManager.default.currentDirectoryPath,
        authStorage: authStorage,
        modelRegistry: registry,
        model: model,
        projectTrusted: false,
        noTools: .all,
        hooks: [HookDefinition(path: "<test:headers>") { api in
            api.on("before_provider_headers") { (event: BeforeProviderHeadersEvent, _: HookContext) in
                #expect(event.headers["X-Model"] == "model")
                return BeforeProviderHeadersEventResult(headers: ["X-Extension": "hook"])
            }
        }],
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory()
    ))
    let session = result.session
    defer { session.dispose() }
    session.agent.streamFn = { model, _, options in
        capturedHeaders.withLock { $0 = options.headers }
        let stream = AssistantMessageEventStream()
        Task {
            stream.push(.start(partial: extensionSurfaceAssistant(model)))
            stream.push(.done(reason: .stop, message: extensionSurfaceAssistant(model)))
        }
        return stream
    }

    try await session.prompt("hello")
    #expect(capturedHeaders.withLock { $0 }?["X-Extension"] == "hook")
}

@Test func entryRendererLookupPersistsDisplayOnlyEntryOutsideModelContext() {
    let api = HookAPI(hookPath: "<test:entry-renderer>")
    api.registerEntryRenderer("test-entry") { entry, options, _ in
        "\(entry.customType):\(options.expanded)"
    }
    let runner = HookRunner(
        [LoadedHook(
            path: "<test:entry-renderer>",
            resolvedPath: "<test:entry-renderer>",
            handlers: api.handlers,
            entryRenderers: api.entryRenderers
        )],
        FileManager.default.currentDirectoryPath,
        SessionManager.inMemory(),
        ModelRegistry(AuthStorage(":memory:"))
    )
    let sessionManager = SessionManager.inMemory()
    _ = sessionManager.appendCustomEntry("test-entry", ["value": "persisted"])

    guard let renderer = runner.getEntryRenderer("test-entry"),
          case .custom(let entry) = sessionManager.getEntries().first else {
        Issue.record("Expected persisted custom entry and renderer")
        return
    }
    #expect(renderer(entry, EntryRenderOptions(expanded: true), Theme.fallback()) as? String == "test-entry:true")
    #expect(sessionManager.buildSessionContext().messages.isEmpty)
}

@Test func inlineExtensionLoadsNamedFactoryHandlersAndTools() async throws {
    let inline = InlineExtension(name: "sample") { api in
        api.on("agent_settled") { (_: AgentSettledEvent, _: HookContext) in nil }
        api.registerTool(CustomTool(
            name: "inline-tool",
            label: "Inline tool",
            description: "Tool registered by an inline extension",
            parameters: [:],
            execute: { _, _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "ok"))]) }
        ))
    }
    let result = ExtensionLoader.load(
        inline,
        cwd: FileManager.default.currentDirectoryPath,
        eventBus: createEventBus()
    )

    #expect(result.error == nil)
    #expect(result.hook?.path == "<inline:sample>")
    #expect(result.hook?.handlers["agent_settled"]?.count == 1)
    #expect(result.hook?.tools["inline-tool"] != nil)
}
