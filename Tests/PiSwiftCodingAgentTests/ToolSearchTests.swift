import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func searchTestTool(_ name: String, _ description: String,
                            properties: [String: Any] = [:], namespace: ToolNamespace? = nil,
                            exposure: ToolExposure = .deferred) -> ToolInfo {
    ToolInfo(name: name, description: description,
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(properties)],
        exposure: exposure, namespace: namespace)
}

@Test func toolSearchTokenizerPortsUpstreamRules() {
    #expect(tokenize("listIssues for the GitHub_repo") == ["list", "issue", "git", "hub", "repo"])
    #expect(tokenize("searches queries HTTPServer") == ["search", "query", "http", "server"])
    #expect(tokenize("a an and are as at be by for from in is it of on or that the this to with").isEmpty)
}

@Test func toolSearchBm25PortsUpstreamRanking() {
    let tools = [
        searchTestTool("mcp__github__list_issues", "List issues in a repository.",
            properties: ["state": ["type": "string", "description": "open or closed"]]),
        searchTestTool("mcp__github__create_pull_request", "Open a pull request."),
        searchTestTool("mcp__linear__search_issues", "Search Linear issues by text."),
        searchTestTool("mcp__docs__search", "Search the documentation.")
    ]
    let documents = tools.map { createToolSearchDocument($0) }
    let ranker = Bm25Ranker()
    #expect(ranker.k1 == 1.2 && ranker.b == 0.75)
    #expect(ranker.rank("issue", documents: documents, limit: 8).map(\.name) ==
        ["mcp__linear__search_issues", "mcp__github__list_issues"])
    #expect(ranker.rank("pull requests", documents: documents, limit: 8).first?.name == "mcp__github__create_pull_request")
    #expect(ranker.rank("search", documents: documents, limit: 1).count == 1)
    #expect(ranker.rank("closed", documents: documents, limit: 8).map(\.name) == ["mcp__github__list_issues"])
    #expect(ranker.rank("kubernetes", documents: documents, limit: 8).isEmpty)
    #expect(ranker.rank("the", documents: documents, limit: 8).isEmpty)
    #expect(ranker.rank("tickets", documents: documents, limit: 8).isEmpty)
    #expect(ranker.rank("issue", documents: documents, limit: 0).isEmpty)
    let namespaced = createToolSearchDocument(searchTestTool("mcp__x__run", "Run it.",
        namespace: ToolNamespace(name: "mcp__x", description: "Kubernetes cluster tools")))
    #expect(ranker.rank("kubernetes", documents: [namespaced], limit: 8).map(\.name) == ["mcp__x__run"])
    #expect(ranker.rank("same", documents: [ToolSearchDocument(name: "a", text: "same"),
                                            ToolSearchDocument(name: "b", text: "same")], limit: 8).map(\.name) == ["a", "b"])
}

// Upstream v1.0.0 removed the createToolSearchDescription test.

private func toolSearchSession(settings: Settings = Settings(), noExtensions: Bool = false,
                               additionalPaths: [String] = [],
                               toolNames: [String]? = nil,
                               customTools: [CustomToolDefinition] = []) async -> CreateAgentSessionResult {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    return await createAgentSession(CreateAgentSessionOptions(
        authStorage: auth, model: model, offline: true, toolNames: toolNames, noTools: .builtin,
        customTools: customTools, resourceLoader: TestResourceLoader(),
        additionalExtensionPaths: additionalPaths,
        inlineExtensions: builtInExtensions, noExtensions: noExtensions,
        sessionManager: .inMemory(), settingsManager: .inMemory(settings)))
}

@Test func toolSearchExplicitInitialLoadoutCanStillDiscoverDeferredTools() async throws {
    // The mcp__ name keeps this deferred tool registered under the tool_search allowlist.
    let created = await toolSearchSession(toolNames: [TOOL_SEARCH_TOOL_NAME], customTools: [
        deferredSearchTool("mcp__docs__search", "Search documentation.")
    ])
    let session = created.session
    defer { session.dispose() }
    #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME])
    let search = try #require(session.agent.tools.first { $0.name == TOOL_SEARCH_TOOL_NAME })
    _ = try await search.execute("id", ["query": AnyCodable("documentation")], nil, nil)
    #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
}

private func deferredSearchTool(_ name: String, _ description: String,
                                exposure: ToolExposure = .deferred,
                                namespace: ToolNamespace? = nil) -> CustomToolDefinition {
    CustomToolDefinition(tool: CustomTool(name: name, label: name, description: description,
        execute: { _, _, _, _, _ in AgentToolResult(content: []) },
        exposure: exposure, namespace: namespace))
}

@Test func toolSearchLoadsOnlyInactiveSearchableToolsAndDescribesSources() async throws {
    let tools = [
        deferredSearchTool("mcp__docs__search", "Search documentation.\nSecond line",
            namespace: ToolNamespace(name: "mcp__docs", description: "Docs server\nmore")),
        deferredSearchTool("mcp__linear__search_issues", "Search Linear issues.", exposure: .codemode,
            namespace: ToolNamespace(name: "mcp__linear")),
        deferredSearchTool("private_search", "Search secret files.", exposure: .hidden),
        deferredSearchTool("direct_search", "Search direct files.", exposure: .direct)
    ]
    let created = await toolSearchSession(customTools: tools)
    let session = created.session
    defer { session.dispose() }
    #expect(session.getAllTools().contains(where: isToolSearchTool))
    #expect(!session.getActiveToolNames().contains(TOOL_SEARCH_TOOL_NAME))
    #expect(session.getAllTools().first { $0.name == TOOL_SEARCH_TOOL_NAME }?.exposure == .modelOnly)
    session.setActiveToolsByName([TOOL_SEARCH_TOOL_NAME])
    let search = try #require(session.agent.tools.first { $0.name == TOOL_SEARCH_TOOL_NAME })
    // Upstream v1.0.0 agent-session-mcp.test.ts: the description is the constant, with no server list.
    #expect(search.description == TOOL_SEARCH_DESCRIPTION)
    let result = try await search.execute("search-1", ["query": AnyCodable("documentation")], nil, nil)
    #expect(result.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } ==
        ["Loaded 1 tool. They are available from your next call:\n- mcp__docs__search: Search documentation."])
    let details = try #require(result.details?.value as? [String: Any])
    #expect(details["loaded"] as? [String] == ["mcp__docs__search"])
    #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
    let repeated = try await search.execute("search-2", ["query": AnyCodable("documentation")], nil, nil)
    #expect(repeated.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } == ["No matching tools found."])
    let noMatch = try await search.execute("search-3", ["query": AnyCodable("secret direct")], nil, nil)
    #expect(noMatch.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } == ["No matching tools found."])
    #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
}

@Test func toolSearchRejectsInvalidInputsAndWorksWithoutSession() async throws {
    let tool = createToolSearchToolDefinition()
    let context = CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    for query in ["", "  \n"] {
        await #expect(throws: ToolSearchError.emptyQuery) {
            try await tool.execute("id", ["query": AnyCodable(query)], nil, context, nil)
        }
    }
    for value in [AnyCodable(0), AnyCodable(-1), AnyCodable(1.5), AnyCodable(true)] {
        await #expect(throws: ToolSearchError.invalidLimit) {
            try await tool.execute("id", ["query": AnyCodable("search"), "limit": value], nil, context, nil)
        }
    }
    let empty = try await tool.execute("id", ["query": AnyCodable("search")], nil, context, nil)
    #expect(empty.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } == ["No matching tools found."])
    let hugeLimit = try await tool.execute("id", ["query": AnyCodable("search"), "limit": AnyCodable(1e100)], nil, context, nil)
    #expect(hugeLimit.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } == ["No matching tools found."])
}

@Test func toolSearchBuiltinCanBeDisabledAndExplicitlyLoaded() async {
    let loaded = ExtensionLoader.load(createToolSearchExtension(), cwd: "/tmp", eventBus: createEventBus())
    #expect(loaded.hook?.path == "builtin:tool-search")
    #expect(loaded.hook?.replaceable == true && loaded.hook?.hidden == true)
    var settings = Settings()
    settings.extensions = ["-builtin:tool-search"]
    let disabled = await toolSearchSession(settings: settings)
    #expect(!disabled.session.getAllTools().contains { $0.name == TOOL_SEARCH_TOOL_NAME })
    disabled.session.dispose()

    let noExtensions = await toolSearchSession(noExtensions: true)
    #expect(!noExtensions.session.getAllTools().contains { $0.name == TOOL_SEARCH_TOOL_NAME })
    noExtensions.session.dispose()

    let explicit = await toolSearchSession(settings: settings, noExtensions: true,
        additionalPaths: ["builtin:tool-search"])
    #expect(explicit.session.getAllTools().contains(where: isToolSearchTool))
    explicit.session.dispose()
}

@Test func toolSearchBuiltinIsReplaceableByAnotherExtension() async {
    let replacement = InlineExtension(name: "replacement") { api in
        _ = api.registerTool(CustomTool(name: TOOL_SEARCH_TOOL_NAME, label: "replacement",
            description: "Replacement discovery tool", parameters: [:],
            execute: { _, _, _, _, _ in AgentToolResult(content: []) }))
    }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let created = await createAgentSession(CreateAgentSessionOptions(
        authStorage: auth, model: model, offline: true, noTools: .builtin,
        resourceLoader: TestResourceLoader(), inlineExtensions: builtInExtensions + [replacement],
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    defer { created.session.dispose() }
    #expect(created.diagnostics.contains { $0.path == "builtin:tool-search" && $0.type == "warning" })
    #expect(created.session.getAllTools().first { $0.name == TOOL_SEARCH_TOOL_NAME }?.description ==
        "Replacement discovery tool")
    #expect(!created.session.getAllTools().contains(where: isToolSearchTool))
}

@Test(.timeLimit(.minutes(1))) func toolSearchActivationIsRecordedForTheNextModelCallAndTranscript() async throws {
    let created = await toolSearchSession(customTools: [
        deferredSearchTool("mcp__docs__search", "Search documentation.",
            namespace: ToolNamespace(name: "mcp__docs", description: "Docs server"))
    ])
    let session = created.session
    defer { session.dispose() }
    session.setActiveToolsByName([TOOL_SEARCH_TOOL_NAME])
    let requests = LockedState<[[String]]>([])
    let turn = LockedState(0)
    session.agent.streamFn = { model, context, _ in
        requests.withLock { $0.append(getCurrentTools(context.messages).map(\.name)) }
        let number = turn.withLock { value -> Int in value += 1; return value }
        let content: [ContentBlock] = number == 1
            ? [.toolCall(ToolCall(id: "search-call", name: TOOL_SEARCH_TOOL_NAME,
                                  arguments: ["query": AnyCodable("documentation")]))]
            : [.text(TextContent(text: "done"))]
        let reason: StopReason = number == 1 ? .toolUse : .stop
        let message = AssistantMessage(content: content, api: model.api, provider: model.provider,
            model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0,
                                          cacheWrite: 0, totalTokens: 2), stopReason: reason)
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: reason, message: message))
        stream.end(message)
        return stream
    }
    try await session.prompt("find a documentation tool")
    #expect(requests.withLock { $0 } == [[TOOL_SEARCH_TOOL_NAME],
        [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"]])
    #expect(session.getActiveToolNames() == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
    let projection = session.sessionManager.buildSessionProjection().messages
    #expect(getCurrentTools(projection).map(\.name) == [TOOL_SEARCH_TOOL_NAME, "mcp__docs__search"])
    #expect(getCurrentSystemPrompt(projection).contains("Search for tools that are not loaded yet and load the matches"))
    let toolResult = projection.compactMap { message -> ToolResultMessage? in
        if case .toolResult(let result) = message { return result }
        return nil
    }.first
    #expect(toolResult?.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } ==
        ["Loaded 1 tool. They are available from your next call:\n- mcp__docs__search: Search documentation."])
}
