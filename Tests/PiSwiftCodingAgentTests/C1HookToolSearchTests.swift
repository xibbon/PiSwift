import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Test(.timeLimit(.minutes(1))) func c1BeforeAgentStartMergesSectionsInHandlerOrder() async throws {
    let first: HookHandler = { _, _ in
        BeforeAgentStartEventResult(sections: ["mcp_servers": "first", "removed": "old", "kept": "unchanged"])
    }
    let second: HookHandler = { _, _ in
        BeforeAgentStartEventResult(sections: ["mcp_servers": "second", "removed": nil])
    }
    let runner = HookRunner([
        LoadedHook(path: "first", resolvedPath: "first", handlers: ["before_agent_start": [first]]),
        LoadedHook(path: "second", resolvedPath: "second", handlers: ["before_agent_start": [second]])
    ], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    let result = try #require(await runner.emitBeforeAgentStart("test", nil))
    #expect(result.sections["mcp_servers"] == "second")
    #expect(result.sections["kept"] == "unchanged")
    #expect(result.sections.keys.contains("removed"))
    #expect(result.sections["removed"]! == nil)
}

@Test(.timeLimit(.minutes(1))) func c1HookSectionsAppendChangesAndRemovalToTranscript() async throws {
    let turns = LockedState(0)
    let handler: HookHandler = { _, _ in
        let turn = turns.withLock { value in value += 1; return value }
        switch turn {
        case 1, 2: return BeforeAgentStartEventResult(sections: ["mcp_servers": "Docs server"])
        case 3: return BeforeAgentStartEventResult(sections: ["mcp_servers": "Changed server"])
        default: return BeforeAgentStartEventResult(sections: ["mcp_servers": nil])
        }
    }
    let manager = SessionManager.inMemory()
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let registry = ModelRegistry(auth)
    let runner = HookRunner([LoadedHook(path: "sections", resolvedPath: "sections",
        handlers: ["before_agent_start": [handler]])], manager.getCwd(), manager, registry)
    let agent = Agent(AgentOptions(initialState: AgentState(model: model), streamFn: { model, _, _ in
        let message = AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: .stop, message: message))
        stream.end(message)
        return stream
    }, getApiKey: { _ in "test" }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        systemPromptOptions: BuildSystemPromptOptions(cwd: manager.getCwd(), contextFiles: [], skills: []),
        hookRunner: runner, modelRegistry: registry))
    defer { session.dispose() }
    try await session.prompt("first")
    try await session.prompt("same")
    try await session.prompt("changed")
    try await session.prompt("removed")
    let systems = manager.buildSessionProjection().messages.compactMap(\.transcriptSystemMessage)
    #expect(systems.count == 3)
    #expect(systems[0].sections?["mcp_servers"] == "<mcp_servers>\nDocs server\n</mcp_servers>")
    #expect(systems[1].sections?.entries.map(\.name) == ["mcp_servers"])
    #expect(systems[1].sections?["mcp_servers"] == "<mcp_servers>\nChanged server\n</mcp_servers>")
    #expect(systems[2].sections?.entries.map(\.name) == ["mcp_servers"])
    #expect(systems[2].sections?.entries.first?.value == nil)
    #expect(!getCurrentSystemPrompt(manager.buildSessionProjection().messages).contains("mcp_servers"))
}

@Test func c1McpRegistrationRejectsNormalizedNamesDuringLoad() throws {
    // Upstream loader rejects server names that share a namespace after normalization.
    let bus = createEventBus()
    let first = ExtensionLoader.load(InlineExtension(name: "first") { api in
        try api.registerMcpServer("dev-radius", config: .init(url: "https://example.invalid/first"))
    }, cwd: "/tmp", eventBus: bus)
    #expect(first.hook != nil)
    let second = ExtensionLoader.load(InlineExtension(name: "second") { api in
        try api.registerMcpServer("dev_radius", config: .init(url: "https://example.invalid/second"))
    }, cwd: "/tmp", eventBus: bus)
    #expect(second.hook == nil)
    #expect(second.error?.localizedDescription == "Invalid extension '<inline:second>': MCP server \"dev_radius\" conflicts with registered server \"dev-radius\"")
}

@Test func c1McpRegistrationRejectsNormalizedNamesAtRuntime() throws {
    let saved = LockedState<HookAPI?>(nil)
    let hook = try #require(ExtensionLoader.load(InlineExtension(name: "registrar") { api in
        saved.withLock { $0 = api }
        try api.registerMcpServer("dev-radius", config: .init(url: "https://example.invalid/first"))
    }, cwd: "/tmp", eventBus: createEventBus()).hook)
    let runner = HookRunner([hook], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    let api = try #require(saved.withLock { $0 })
    #expect(throws: HookAPIError.self) {
        try api.registerMcpServer("dev_radius", config: .init(url: "https://example.invalid/second"))
    }
    try api.registerMcpServer("dev-radius", config: .init(url: "https://example.invalid/replaced"))
    #expect(api.getMcpServers().count == 1)
    #expect(api.getMcpServers().first?.config.url == "https://example.invalid/replaced")
}

@Test func c1EmptyCommandNameFailsExtensionLoad() {
    let loaded = ExtensionLoader.load(InlineExtension(name: "empty-command") { api in
        api.registerCommand("") { _, _ in }
    }, cwd: "/tmp", eventBus: createEventBus())
    #expect(loaded.hook == nil)
    #expect(loaded.error?.localizedDescription == "Invalid extension '<inline:empty-command>': Command registered by extension \"<inline:empty-command>\" must have a non-empty string name. Use pi.registerCommand(\"name\", { description, handler }).")
}

@Test func c1ToolSearchIndexesNamespaceInstructions() throws {
    let namespace = ToolNamespace(name: "mcp__docs", description: "Docs server",
        instructions: "Use this server for Kubernetes cluster questions.")
    let tool = ToolInfo(name: "mcp__docs__read", description: "Read a page.", parameters: [:],
        exposure: .deferred, namespace: namespace)
    let document = createToolSearchDocument(tool)
    #expect(Bm25Ranker().rank("kubernetes", documents: [document], limit: 8).map(\.name) == [tool.name])
    let decoded = try JSONDecoder().decode(ToolNamespace.self, from: JSONEncoder().encode(namespace))
    #expect(decoded.instructions == namespace.instructions)
}

@Test func c1ToolSearchUsesConstantDescription() {
    let tool = createToolSearchToolDefinition()
    #expect(tool.description == TOOL_SEARCH_DESCRIPTION)
    #expect(tool.description == "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools, such as tools of MCP servers, may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search`.")
    #expect(tool.prepareLoadout == nil)
}

@Test func c1NamespaceNamesAcceptOriginalIdentifierAndSuffixForms() {
    for namespace in ["mcp__dev-radius", "mcp__dev_radius"] {
        for query in ["mcp__dev-radius", "mcp__dev_radius", "dev-radius", "dev_radius"] {
            #expect(matchesToolNamespace(name: query, namespace: namespace))
        }
        #expect(!matchesToolNamespace(name: "radius", namespace: namespace))
        #expect(!matchesToolNamespace(name: "mcp__other", namespace: namespace))
    }
    #expect(matchesToolNamespace(name: "plain", namespace: "plain"))
    #expect(matchesToolNamespace(name: "last", namespace: "outer__inner__last"))
    #expect(!matchesToolNamespace(name: "inner__last", namespace: "outer__inner__last"))
}

@Test(.timeLimit(.minutes(1))) func c1BeforeToolCallAdapterPassesPerCallCancellation() async throws {
    let token = CancellationToken()
    let started = LockedState(false)
    let received = LockedState(false)
    let handler: HookHandler = { _, context in
        started.withLock { $0 = true }
        guard let signal = context.signal else { return ToolCallEventResult(block: true, reason: "no signal") }
        received.withLock { $0 = signal === token }
        while !signal.isCancelled { try await Task.sleep(for: .milliseconds(1)) }
        return ToolCallEventResult(block: true, reason: "cancelled")
    }
    let runner = HookRunner([LoadedHook(path: "cancellation", resolvedPath: "cancellation",
        handlers: ["tool_call": [handler]])], "/tmp", .inMemory(), ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil })
    defer { runner.dispose() }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let assistant = AssistantMessage(content: [], api: model.api, provider: model.provider,
        model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let context = BeforeToolCallContext(assistantMessage: assistant,
        toolCall: AgentToolCall(id: "call", name: "tool_search", arguments: [:]), args: [:],
        context: AgentContext(messages: [], tools: []))
    let adapter = makeHookRunnerBeforeToolCallHook(runner)
    async let result = adapter(context, token)
    while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
    token.cancel()
    let completed = await result
    #expect(received.withLock { $0 })
    #expect(completed?.block == true)
    #expect(completed?.reason == "cancelled")
    let nextCall = await runner.emitToolCall(ToolCallEvent(toolName: "tool_search", toolCallId: "next", input: [:]))
    #expect(nextCall?.reason == "no signal")
}

@Test(.timeLimit(.minutes(1))) func c1ConcurrentMcpRegistrationKeepsOneNormalizedNamespace() async {
    // Swift hosts can register on separate tasks; upstream executes these checks in one JS turn.
    for _ in 0..<32 {
        let bus = createEventBus()
        let first = HookAPI(events: bus, hookPath: "first")
        let second = HookAPI(events: bus, hookPath: "second")
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (api, name) in [(first, "dev-radius"), (second, "dev_radius")] {
                group.addTask {
                    do {
                        try api.registerMcpServer(name, config: .init(url: "https://example.invalid/mcp"))
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await success in group { if success { successes += 1 } }
            return successes
        }
        #expect(successes == 1)
        #expect(first.getMcpServers().count == 1)
        #expect(second.getMcpServers().count == 1)
    }
}
