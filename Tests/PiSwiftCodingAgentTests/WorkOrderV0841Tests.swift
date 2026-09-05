import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct V0841HTTPClient: ProviderHTTPClient {
    let handler: @Sendable (URLRequest) async throws -> ProviderHTTPResponse

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        try await handler(request)
    }
}

private func v0841CodingModel(
    headers: ProviderHeaders? = nil,
    compat: OpenAICompat? = nil
) -> Model {
    Model(
        id: "work-order-model",
        name: "Work order model",
        api: .openAICompletions,
        provider: "work-order-provider",
        baseUrl: "https://provider.example/v1",
        reasoning: true,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_000,
        maxTokens: 4_096,
        headers: headers,
        compat: compat
    )
}

private func v0841Assistant(_ model: Model, text: String = "ok") -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop
    )
}

private func v0841Stream(_ message: AssistantMessage) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: message.stopReason, message: message))
    stream.end(message)
    return stream
}

@Test func nullableHeadersSuppressDefaultsAtTheRequestBoundary() async throws {
    let capturedRequest = LockedState<URLRequest?>(nil)
    let client = V0841HTTPClient { request in
        capturedRequest.withLock { $0 = request }
        let body = """
        data: {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return ProviderHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            body: Data(body.utf8)
        )
    }
    let model = v0841CodingModel(headers: [
        "Authorization": "provider-default",
        "X-Normal": "provider-value",
    ])

    _ = await streamOpenAICompletions(
        model: model,
        context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
        options: OpenAICompletionsOptions(
            apiKey: "placeholder-key",
            httpClient: client,
            headers: [
                "authorization": nil,
                "X-Normal": "extension-value",
            ]
        )
    ).result()

    let request = try #require(capturedRequest.withLock { $0 })
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") != "")
    #expect(request.value(forHTTPHeaderField: "X-Normal") == "extension-value")
}

@Test func modelRegistryPreservesNullAndEmptyHeadersAndHookCanDelete() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-null-headers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let json = """
    {
      "providers": {
        "local": {
          "baseUrl": "https://provider.example/v1",
          "api": "openai-completions",
          "headers": {
            "Authorization": "provider-default",
            "X-Provider": "provider-value"
          },
          "models": [{
            "id": "nullable-model",
            "headers": {
              "authorization": null,
              "X-Empty": "",
              "X-Normal": "model-value"
            }
          }]
        }
      }
    }
    """
    try json.write(to: tempDir.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let model = try #require(registry.find("local", "nullable-model"))
    let headers = try #require(model.headers)
    #expect(providerHeadersContain(headers, name: "Authorization"))
    #expect(providerHeaderValue(headers, name: "Authorization") == nil)
    #expect(providerHeaderValue(headers, name: "X-Empty") == "")
    #expect(providerHeaderValue(headers, name: "X-Provider") == "provider-value")
    #expect(providerHeaderValue(headers, name: "X-Normal") == "model-value")

    let handler: HookHandler = { event, _ in
        guard event is BeforeProviderHeadersEvent else { return nil }
        return BeforeProviderHeadersEventResult(headers: [
            "x-provider": nil,
            "X-Hook": "hook-value",
        ])
    }
    let hook = LoadedHook(
        path: "<test:null-headers>",
        resolvedPath: "<test:null-headers>",
        handlers: ["before_provider_headers": [handler]]
    )
    let runner = HookRunner([hook], tempDir.path, SessionManager.inMemory(), registry)
    runner.initialize(getModel: { model }, hasUI: false)
    let transformed = await runner.emitBeforeProviderHeaders(headers)

    #expect(providerHeadersContain(transformed, name: "X-Provider"))
    #expect(providerHeaderValue(transformed, name: "X-Provider") == nil)
    #expect(providerHeaderValue(transformed, name: "X-Hook") == "hook-value")
}

@Test func modelConfigurationFieldsRoundTripFromModelsOverridesAndExtensions() throws {
    let baselineRegistry = ModelRegistry(AuthStorage(":memory:"))
    let baseline = try #require(baselineRegistry.getAll().first { $0.thinkingLevelMap != nil })
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-model-fields-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configuration: [String: Any] = [
        "providers": [
            "local": [
                "baseUrl": "https://provider.example/v1",
                "api": "openai-completions",
                "models": [[
                    "id": "configured-model",
                    "samplingParams": [
                        "top_p": 0.95,
                        "thinking_token_budget": 2_048,
                    ],
                    "compat": ["supportsThinkingTokenBudget": true],
                    "thinkingLevelMap": ["off": NSNull(), "max": "ultra"],
                ]],
            ],
            baseline.provider: [
                "modelOverrides": [
                    baseline.id: [
                        "name": "Overridden without losing the thinking map",
                        "samplingParams": [
                            "top_k": 40,
                            "thinking_token_budget": 1_024,
                        ],
                        "compat": ["supportsThinkingTokenBudget": true],
                    ],
                ],
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted])
    try data.write(to: tempDir.appendingPathComponent("models.json"))

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir.path)
    let configured = try #require(registry.find("local", "configured-model"))
    #expect(configured.samplingParams?["top_p"] == AnyCodable(0.95))
    #expect(configured.samplingParams?["thinking_token_budget"] == AnyCodable(2_048))
    #expect(configured.compat?.supportsThinkingTokenBudget == true)
    #expect(configured.thinkingLevelMap?[.max] == "ultra")
    #expect(configured.thinkingLevelMap?.keys.contains(.off) == true)

    let overridden = try #require(registry.find(baseline.provider, baseline.id))
    #expect(overridden.samplingParams?["top_k"] == AnyCodable(40))
    #expect(overridden.samplingParams?["thinking_token_budget"] == AnyCodable(1_024))
    #expect(overridden.compat?.supportsThinkingTokenBudget == true)
    #expect(overridden.thinkingLevelMap == baseline.thinkingLevelMap)

    registry.registerProvider(HookProviderConfig(
        provider: "extension-fields",
        api: .openAICompletions,
        baseUrl: "https://extension.example/v1",
        models: [HookProviderModel(
            id: "extension-model",
            reasoning: true,
            samplingParams: [
                "top_p": AnyCodable(0.8),
                "thinking_token_budget": AnyCodable(512),
            ],
            compat: OpenAICompat(supportsThinkingTokenBudget: true),
            thinkingLevelMap: [.max: "extension-max"]
        )]
    ), sourceId: "<test:extension-fields>")

    let extensionModel = try #require(registry.find("extension-fields", "extension-model"))
    #expect(extensionModel.samplingParams?["top_p"] == AnyCodable(0.8))
    #expect(extensionModel.samplingParams?["thinking_token_budget"] == AnyCodable(512))
    #expect(extensionModel.compat?.supportsThinkingTokenBudget == true)
    #expect(extensionModel.thinkingLevelMap?[.max] == "extension-max")
}

@Test func scopedModelsAreVisibleAndMarkdownTransformersAreDisplayOnlyAndOrdered() async throws {
    let model = v0841CodingModel()
    let observedModelIds = LockedState<[String]>([])
    let api = HookAPI(hookPath: "<test:display-surfaces>")
    api.on("session_start") { (_: SessionStartEvent, context: HookContext) in
        observedModelIds.withLock { $0 = context.scopedModels.map(\.model.id) }
        return nil
    }
    api.registerMarkdownTransformer { markdown, context in
        "[\(context.messageType.rawValue):\(markdown)]"
    }
    api.registerMarkdownTransformer { markdown, _ in
        markdown + "!"
    }
    let hook = LoadedHook(
        path: "<test:display-surfaces>",
        resolvedPath: "<test:display-surfaces>",
        handlers: api.handlers,
        markdownTransformers: api.markdownTransformers
    )
    let manager = SessionManager.inMemory()
    let original = "persisted markdown"
    manager.appendMessage(.user(UserMessage(content: .text(original))))
    let runner = HookRunner(
        [hook],
        FileManager.default.currentDirectoryPath,
        manager,
        ModelRegistry(AuthStorage(":memory:"))
    )
    runner.initialize(
        getModel: { model },
        getScopedModels: { [ScopedModel(model: model, thinkingLevel: .high)] },
        hasUI: false
    )

    _ = await runner.emit(SessionStartEvent())
    let displayed = runner.transformMarkdown(
        original,
        context: MarkdownTransformContext(messageType: .user, isStreaming: false, availableWidth: 80)
    )

    #expect(observedModelIds.withLock { $0 } == [model.id])
    #expect(displayed == "[user:persisted markdown]!")
    let persisted = manager.buildSessionContext().messages.first
    if case .user(let user) = persisted, case .text(let text) = user.content {
        #expect(text == original)
    } else {
        Issue.record("Expected the original persisted user Markdown")
    }
}

@Test func reloadedExtensionsDisposeEventBusListeners() async throws {
    let bus = createEventBus()
    let oldCount = LockedState(0)
    let newCount = LockedState(0)
    let oldResult = ExtensionLoader.load(
        InlineExtension(name: "old-listener") { api in
            api.events.on("reload-test") { _ in
                oldCount.withLock { $0 += 1 }
            }
        },
        cwd: FileManager.default.currentDirectoryPath,
        eventBus: bus
    )
    let oldHook = try #require(oldResult.hook)
    let runner = HookRunner(
        [oldHook],
        FileManager.default.currentDirectoryPath,
        SessionManager.inMemory(),
        ModelRegistry(AuthStorage(":memory:"))
    )

    bus.emit("reload-test", nil)
    try await Task.sleep(for: .milliseconds(30))
    #expect(oldCount.withLock { $0 } == 1)

    let newResult = ExtensionLoader.load(
        InlineExtension(name: "new-listener") { api in
            api.events.on("reload-test") { _ in
                newCount.withLock { $0 += 1 }
            }
        },
        cwd: FileManager.default.currentDirectoryPath,
        eventBus: bus
    )
    let newHook = try #require(newResult.hook)
    runner.replaceExtensionHooks([newHook])
    bus.emit("reload-test", nil)
    try await Task.sleep(for: .milliseconds(30))

    #expect(oldCount.withLock { $0 } == 1)
    #expect(newCount.withLock { $0 } == 1)
    runner.dispose()
}

@Test func blockedHookToolCallTerminateEndsTheBatch() async throws {
    let model = v0841CodingModel()
    let handler: HookHandler = { event, _ in
        guard event is ToolCallEvent else { return nil }
        return ToolCallEventResult(block: true, reason: "blocked by extension", terminate: true)
    }
    let runner = HookRunner(
        [LoadedHook(
            path: "<test:terminate>",
            resolvedPath: "<test:terminate>",
            handlers: ["tool_call": [handler]]
        )],
        FileManager.default.currentDirectoryPath,
        SessionManager.inMemory(),
        ModelRegistry(AuthStorage(":memory:"))
    )
    runner.initialize(getModel: { model }, hasUI: false)
    let tool = AgentTool(
        label: "Blocked",
        name: "blocked",
        description: "Must not run",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        Issue.record("The blocked tool executed")
        return AgentToolResult(content: [.text(TextContent(text: "unexpected"))])
    }
    let callCount = LockedState(0)
    let streamFn: StreamFn = { model, _, _ in
        let call = callCount.withLock { value -> Int in
            value += 1
            return value
        }
        if call == 1 {
            return v0841Stream(AssistantMessage(
                content: [.toolCall(ToolCall(id: "blocked-1", name: "blocked", arguments: [:]))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .toolUse
            ))
        }
        return v0841Stream(v0841Assistant(model, text: "unexpected follow-up"))
    }
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("start")))],
        context: AgentContext(systemPrompt: "", messages: [], tools: [tool]),
        config: AgentLoopConfig(
            model: model,
            toolExecution: .sequential,
            beforeToolCall: makeHookRunnerBeforeToolCallHook(runner),
            convertToLlm: { $0.compactMap(\.asMessage) }
        ),
        streamFn: streamFn
    )
    var blockedResult: ToolResultMessage?
    for await event in stream {
        if case .messageEnd(let message) = event, case .toolResult(let result) = message {
            blockedResult = result
        }
    }

    #expect(callCount.withLock { $0 } == 1)
    #expect(blockedResult?.isError == true)
}

@Test func extensionModelAuthPreservesCredentialResolvedEndpoint() async throws {
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(
        OAuthProvider.githubCopilot.rawValue,
        "tid=test;proxy-ep=proxy.business.githubcopilot.com;sku=business"
    )
    let registry = ModelRegistry(auth)
    let model = try #require(registry.find(OAuthProvider.githubCopilot.rawValue, "gpt-5.4"))
    let capturedBaseUrl = LockedState<String?>(nil)
    let result = await createAgentSession(CreateAgentSessionOptions(
        cwd: FileManager.default.currentDirectoryPath,
        agentDir: FileManager.default.currentDirectoryPath,
        authStorage: auth,
        modelRegistry: registry,
        model: model,
        projectTrusted: false,
        noTools: .all,
        hooks: [],
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory()
    ))
    defer { result.session.dispose() }
    result.session.agent.streamFn = { model, _, _ in
        capturedBaseUrl.withLock { $0 = model.baseUrl }
        return v0841Stream(v0841Assistant(model))
    }

    try await result.session.prompt("use the resolved Copilot endpoint")
    #expect(capturedBaseUrl.withLock { $0 } == "https://api.business.githubcopilot.com")
}

private actor V0841CompactionGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct V0841CompactionSession {
    let session: AgentSession
    let streamCalls: LockedState<Int>
}

private func makeV0841CompactionSession(
    beforeCompact: HookHandler? = nil
) -> V0841CompactionSession {
    let model = v0841CodingModel()
    let streamCalls = LockedState(0)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "test", model: model, tools: []),
        streamFn: { model, _, _ in
            streamCalls.withLock { $0 += 1 }
            return v0841Stream(v0841Assistant(model))
        },
        getApiKey: { _ in "test-key" }
    ))
    let manager = SessionManager.inMemory()
    manager.appendMessage(.user(UserMessage(content: .text("first"))))
    manager.appendMessage(.assistant(v0841Assistant(model, text: "first answer")))
    manager.appendMessage(.user(UserMessage(content: .text("second"))))
    manager.appendMessage(.assistant(v0841Assistant(model, text: "second answer")))
    agent.messages = manager.buildSessionContext().messages
    let settings = SettingsManager.inMemory()
    var overrides = Settings()
    overrides.compaction = CompactionSettingsOverrides(keepRecentTokens: 1)
    settings.applyOverrides(overrides)
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let registry = ModelRegistry(auth)
    let runner: HookRunner? = beforeCompact.map { handler in
        let runner = HookRunner(
            [LoadedHook(
                path: "<test:compaction>",
                resolvedPath: "<test:compaction>",
                handlers: ["session_before_compact": [handler]]
            )],
            FileManager.default.currentDirectoryPath,
            manager,
            registry
        )
        runner.initialize(getModel: { model }, hasUI: false)
        return runner
    }
    return V0841CompactionSession(
        session: AgentSession(config: AgentSessionConfig(
            agent: agent,
            sessionManager: manager,
            settingsManager: settings,
            resourceLoader: TestResourceLoader(),
            hookRunner: runner,
            modelRegistry: registry
        )),
        streamCalls: streamCalls
    )
}

@Test func manualCompactionAbortsAutoCompactionBeforeTakingItsState() async throws {
    let gate = V0841CompactionGate()
    let calls = LockedState(0)
    let handler: HookHandler = { event, _ in
        guard let event = event as? SessionBeforeCompactEvent else { return nil }
        let call = calls.withLock { $0 += 1; return $0 }
        if call == 1 {
            Task { await gate.block() }
            while event.signal?.isCancelled != true { try await Task.sleep(for: .milliseconds(1)) }
        }
        return SessionBeforeCompactResult(compaction: CompactionResult(summary: "manual", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: 1))
    }
    let context = makeV0841CompactionSession(beforeCompact: handler)
    defer { context.session.dispose() }
    let autoTask = Task { await context.session.runAutoCompaction(reason: .threshold, willRetry: false) }
    await gate.waitUntilStarted()
    #expect(context.session.isCompacting)
    let result = try await context.session.compact()
    await gate.release()
    await autoTask.value
    #expect(result.summary == "manual")
    #expect(calls.withLock { $0 } == 2)
    #expect(!context.session.isCompacting)
    #expect(context.session.sessionManager.getEntries().filter { if case .compaction = $0 { return true }; return false }.count == 1)
}

@Test func promptQueuedDuringManualCompactionRunsAfterCompletion() async throws {
    let gate = V0841CompactionGate()
    let handler: HookHandler = { event, _ in
        guard let event = event as? SessionBeforeCompactEvent else { return nil }
        await gate.block()
        return SessionBeforeCompactResult(compaction: CompactionResult(
            summary: "manual",
            firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore
        ))
    }
    let context = makeV0841CompactionSession(beforeCompact: handler)
    defer { context.session.dispose() }
    let compactTask = Task { try await context.session.compact() }
    await gate.waitUntilStarted()

    let promptTask = try await context.session.submitPrompt("queued during compaction")
    #expect(context.streamCalls.withLock { $0 } == 0)
    await gate.release()
    _ = try await compactTask.value
    try await promptTask.value

    #expect(context.streamCalls.withLock { $0 } == 1)
}

private func v0841TempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-v0841-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func v0841Write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func v0841RunGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
        throw V0841TestError.commandFailed("git \(arguments.joined(separator: " ")): \(errorText)")
    }
}

private enum V0841TestError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}

@Test func agentsOverrideReplacesSameDirectoryContextAndPreservesOtherDirectories() throws {
    let root = try v0841TempDirectory("context-override")
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDir = root.appendingPathComponent("global", isDirectory: true)
    let parent = root.appendingPathComponent("project", isDirectory: true)
    let child = parent.appendingPathComponent("child", isDirectory: true)
    let leaf = child.appendingPathComponent("leaf", isDirectory: true)
    try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

    try v0841Write("parent context", to: parent.appendingPathComponent("AGENTS.md"))
    try v0841Write("discarded agents", to: child.appendingPathComponent("AGENTS.md"))
    try v0841Write("discarded claude", to: child.appendingPathComponent("CLAUDE.md"))
    try v0841Write("override context", to: child.appendingPathComponent("AGENTS.override.md"))
    try v0841Write("leaf context", to: leaf.appendingPathComponent("CLAUDE.md"))

    let contexts = loadProjectContextFiles(LoadContextFilesOptions(cwd: leaf.path, agentDir: agentDir.path))
    #expect(contexts.map(\.content) == ["parent context", "override context", "leaf context"])
}

@Test func nestedLinkedWorktreeLoadsTrackedContextOnce() throws {
    let root = try v0841TempDirectory("nested-worktree")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("main", isDirectory: true)
    let agentDir = root.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    try v0841RunGit(["init"], in: repository)
    try v0841Write("tracked context", to: repository.appendingPathComponent("AGENTS.md"))
    try v0841RunGit(["add", "AGENTS.md"], in: repository)
    try v0841RunGit([
        "-c", "user.name=Pi Test",
        "-c", "user.email=pi@example.invalid",
        "commit", "-m", "context",
    ], in: repository)

    let worktree = repository.appendingPathComponent("nested-worktree", isDirectory: true)
    try v0841RunGit(["worktree", "add", "-b", "nested-test", worktree.path], in: repository)
    let child = worktree.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    let contexts = loadProjectContextFiles(LoadContextFilesOptions(cwd: child.path, agentDir: agentDir.path))
    #expect(contexts.filter { $0.content == "tracked context" }.count == 1)
    #expect(contexts.first?.path == worktree.appendingPathComponent("AGENTS.md").path)
}

@Test func directoryNamedLikeContextFileIsSkipped() throws {
    let root = try v0841TempDirectory("context-directory")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let agentDir = root.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("AGENTS.md", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

    let contexts = loadProjectContextFiles(LoadContextFilesOptions(cwd: project.path, agentDir: agentDir.path))
    #expect(contexts.isEmpty)
}

@Test func resourceLoaderListsFileBackedSystemPrompts() async throws {
    let root = try v0841TempDirectory("prompt-sources")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let agentDir = root.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    let system = project.appendingPathComponent(".pi/SYSTEM.md")
    let append = project.appendingPathComponent(".pi/APPEND_SYSTEM.md")
    try v0841Write("system", to: system)
    try v0841Write("append", to: append)

    let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(
        cwd: project.path,
        agentDir: agentDir.path,
        noExtensions: true,
        noSkills: true,
        noPromptTemplates: true,
        noThemes: true,
        projectTrusted: true,
        offline: true
    ))
    await loader.reload()

    #expect(loader.getSystemPromptSource()?.path == system.path)
    #expect(loader.getAppendSystemPromptSources().map(\.path) == [append.path])
}

@Test func messageUpdateEmitsUsableTextDeltasWithoutCumulativeMessage() throws {
    let model = v0841CodingModel()
    let startMessage = AssistantMessage(
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop
    )
    let firstPartial = v0841Assistant(model, text: "Hello")
    let finalMessage = v0841Assistant(model, text: "Hello world")
    let events: [AgentSessionEvent] = [
        .agent(.messageStart(message: .assistant(startMessage))),
        .agent(.messageUpdate(
            message: .assistant(firstPartial),
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: "Hello", partial: firstPartial)
        )),
        .agent(.messageUpdate(
            message: .assistant(finalMessage),
            assistantMessageEvent: .textDelta(contentIndex: 0, delta: " world", partial: finalMessage)
        )),
        .agent(.messageEnd(message: .assistant(finalMessage))),
    ]
    let encoded = events.map(encodeSessionEvent)
    var assembled = ""
    for update in encoded where update["type"] as? String == "message_update" {
        #expect(update["message"] == nil)
        let deltaEvent = try #require(update["assistantMessageEvent"] as? [String: Any])
        #expect(deltaEvent["type"] as? String == "text_delta")
        #expect(deltaEvent["contentIndex"] as? Int == 0)
        assembled += try #require(deltaEvent["delta"] as? String)
    }
    let end = try #require(encoded.last?["message"] as? [String: Any])
    let content = try #require(end["content"] as? [[String: Any]])
    #expect(assembled == content.first?["text"] as? String)
}

@Test func messageUpdateCarriesToolCallIdentityAndArgumentDelta() throws {
    let model = v0841CodingModel()
    let call = ToolCall(id: "call-1", name: "read", arguments: ["path": AnyCodable("a")])
    let partial = AssistantMessage(
        content: [.toolCall(call)],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
    let encoded = encodeSessionEvent(.agent(.messageUpdate(
        message: .assistant(partial),
        assistantMessageEvent: .toolCallDelta(contentIndex: 0, delta: "{\"path\":", partial: partial)
    )))
    let delta = try #require(encoded["assistantMessageEvent"] as? [String: Any])
    #expect(delta["type"] as? String == "tool_call_delta")
    #expect(delta["toolCallId"] as? String == "call-1")
    #expect(delta["toolName"] as? String == "read")
    #expect(delta["delta"] as? String == "{\"path\":")
}

private func v0841SharedModel(provider: String) -> Model {
    Model(
        id: "authenticated-shared-model",
        name: "Shared",
        api: .openAICompletions,
        provider: provider,
        baseUrl: "https://\(provider).example/v1",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 8_000,
        maxTokens: 1_000
    )
}

private func v0841RegistryWithSharedModels(_ authenticatedProviders: [String]) -> ModelRegistry {
    let auth = AuthStorage(":memory:")
    for provider in authenticatedProviders {
        auth.setRuntimeApiKey(provider, "key")
    }
    let registry = ModelRegistry(auth)
    for provider in ["shared-a", "shared-b"] {
        registry.registerProvider(HookProviderConfig(
            provider: provider,
            api: .openAICompletions,
            baseUrl: "https://\(provider).example/v1",
            models: [HookProviderModel(id: "authenticated-shared-model")]
        ), sourceId: "<test:\(provider)>")
    }
    return registry
}

@Test func ambiguousBareModelResolvesToOnlyAuthenticatedProvider() {
    let registry = v0841RegistryWithSharedModels(["shared-b"])
    let result = resolveCliModel(cliModel: "authenticated-shared-model", modelRegistry: registry)
    #expect(result.error == nil)
    #expect(result.model?.provider == "shared-b")
}

@Test func ambiguousBareModelReportsMultipleAuthenticatedProviders() {
    let registry = v0841RegistryWithSharedModels(["shared-a", "shared-b"])
    let result = resolveCliModel(cliModel: "authenticated-shared-model", modelRegistry: registry)
    #expect(result.model == nil)
    #expect(result.error?.contains("ambiguous") == true)
    #expect(result.error?.contains("More than one matching provider is authenticated") == true)
}

@Test func nestedProjectProviderRetrySettingsPreserveGlobalValues() throws {
    let root = try v0841TempDirectory("retry-settings")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let agentDir = root.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    try v0841Write(
        #"{"retry":{"provider":{"timeoutMs":12000,"maxRetries":4,"maxRetryDelayMs":90000}}}"#,
        to: agentDir.appendingPathComponent("settings.json")
    )
    try v0841Write(
        #"{"retry":{"provider":{"maxRetries":1}}}"#,
        to: project.appendingPathComponent(".pi/settings.json")
    )

    let retry = SettingsManager.create(project.path, agentDir.path).getProviderRetrySettings()
    #expect(retry.timeoutMs == 12_000)
    #expect(retry.maxRetries == 1)
    #expect(retry.maxRetryDelayMs == 90_000)
}

@Test func sessionDiscoveryTraversesSymlinkedProjectDirectories() async throws {
    let root = try v0841TempDirectory("session-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let agentDir = root.appendingPathComponent("agent", isDirectory: true)
    let sessions = agentDir.appendingPathComponent("sessions", isDirectory: true)
    let actual = root.appendingPathComponent("actual-project-sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    let sessionFile = actual.appendingPathComponent("session.jsonl")
    try v0841Write(
        #"{"type":"session","version":3,"id":"symlink-session","timestamp":"2026-08-12T00:00:00Z","cwd":"/tmp/project"}"# + "\n",
        to: sessionFile
    )
    try FileManager.default.createSymbolicLink(
        at: sessions.appendingPathComponent("--tmp-project--"),
        withDestinationURL: actual
    )

    let discovered = await SessionManager.listAll(inAgentDir: agentDir.path)
    #expect(discovered.map(\.id) == ["symlink-session"])
    #expect(discovered.first?.path.hasSuffix("/agent/sessions/--tmp-project--/session.jsonl") == true)
}

private struct V0841CapturingBashOperations: BashOperations {
    let capturedEnvironment: LockedState<[String: String]?>

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        _ = command
        capturedEnvironment.withLock { $0 = options?.environment }
        options?.onChunk?("ok")
        return BashResult(output: "ok", exitCode: 0, cancelled: false, truncated: false)
    }
}

@Test func bashToolReceivesAllSessionEnvironmentVariables() async throws {
    let captured = LockedState<[String: String]?>(nil)
    let expected = makePiSessionEnvironment(
        sessionId: "session-123",
        sessionFile: "/tmp/session.jsonl",
        provider: "provider-1",
        model: "model-1",
        reasoningLevel: "high"
    )
    let tool = createBashTool(
        cwd: FileManager.default.currentDirectoryPath,
        options: BashToolOptions(
            operations: V0841CapturingBashOperations(capturedEnvironment: captured),
            sessionEnvironment: { expected }
        )
    )
    _ = try await tool.execute("call-1", ["command": AnyCodable("true")], nil, nil)

    let environment = try #require(captured.withLock { $0 })
    #expect(Set(environment.keys) == Set(piSessionEnvironmentVariableNames))
    #expect(environment == expected)
}

@Test func truncatedBelowOutputLimitCompactsAndRetriesExactlyOnce() async throws {
    let compactionCalls = LockedState(0)
    let handler: HookHandler = { event, _ in
        guard let event = event as? SessionBeforeCompactEvent else { return nil }
        compactionCalls.withLock { $0 += 1 }
        return SessionBeforeCompactResult(compaction: CompactionResult(
            summary: "recovered truncated response",
            firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore
        ))
    }
    let context = makeV0841CompactionSession(beforeCompact: handler)
    defer { context.session.dispose() }
    let model = context.session.agent.state.model
    context.session.agent.streamFn = { model, _, _ in
        let call = context.streamCalls.withLock { value -> Int in
            value += 1
            return value
        }
        if call == 1 {
            return v0841Stream(AssistantMessage(
                content: [.text(TextContent(text: "truncated"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 100, output: 10, cacheRead: 0, cacheWrite: 0, totalTokens: 110),
                stopReason: .length
            ))
        }
        return v0841Stream(v0841Assistant(model, text: "complete"))
    }

    try await context.session.prompt("trigger recovery")
    await context.session.waitForIdle()

    #expect(model.maxTokens > 10)
    #expect(compactionCalls.withLock { $0 } == 1)
    #expect(context.streamCalls.withLock { $0 } == 2)
    #expect(context.session.getLastAssistantText() == "complete")
}

@Test func longRunningAuthStorageReloadsExternalCredentialUpdates() async throws {
    let root = try v0841TempDirectory("auth-reload")
    defer { try? FileManager.default.removeItem(at: root) }
    let authPath = root.appendingPathComponent("auth.json")
    try v0841Write(
        #"{"external-provider":{"type":"api_key","key":"first-key"}}"#,
        to: authPath
    )
    let storage = AuthStorage(authPath.path)
    #expect(await storage.getApiKey("external-provider") == "first-key")

    try v0841Write(
        #"{"external-provider":{"type":"api_key","key":"second-key"}}"#,
        to: authPath
    )
    async let firstRead = storage.getApiKey("external-provider")
    async let secondRead = storage.getApiKey("external-provider")
    let values = await [firstRead, secondRead]

    #expect(values == ["second-key", "second-key"])
}

private struct V0841CancellableBashOperations: BashOperations {
    let started: LockedState<Int>

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        _ = command
        started.withLock { $0 += 1 }
        while options?.signal?.isCancelled != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        return BashResult(output: "cancelled", exitCode: nil, cancelled: true, truncated: false)
    }
}

@Test func abortBashCancelsEveryConcurrentUserCommand() async throws {
    let context = makeV0841CompactionSession()
    defer { context.session.dispose() }
    let started = LockedState(0)
    let operations = V0841CancellableBashOperations(started: started)
    let first = Task {
        try await context.session.executeBash("first", excludeFromContext: true, operations: operations)
    }
    let second = Task {
        try await context.session.executeBash("second", excludeFromContext: true, operations: operations)
    }
    while started.withLock({ $0 }) < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }

    context.session.abortBash()
    let results = try await [first.value, second.value]

    #expect(results.allSatisfy { $0.cancelled })
    #expect(context.session.isBashRunning == false)
}
