import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c2aPrepareLoadout(_ loadout: ToolLoadout) -> ToolLoadoutChanges? {
    #expect(loadout.declared.map(\.name).contains("direct"))
    #expect(loadout.callable.map(\.name).contains("code"))
    return ToolLoadoutChanges(descriptions: ["direct": "prepared direct"],
                              hiddenDeclarations: ["model"])
}

private func c2aExposureSession() -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let names = ["direct", "model", "code", "deferred", "hidden"]
    let exposures: [ToolExposure] = [.direct, .modelOnly, .codemode, .deferred, .hidden]
    let tools = names.map { name in
        AgentTool(label: name, name: name, description: "original \(name)", parameters: [:]) {
            _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: name))])
        }
    }
    let definitions = Dictionary(uniqueKeysWithValues: zip(names, exposures).map { name, exposure in
        (name, CustomTool(name: name, label: name, description: "original \(name)",
            execute: { _, _, _, _, _ in AgentToolResult(content: []) },
            promptGuidelines: ["Use \(name)"], exposure: exposure,
            namespace: ToolNamespace(name: "sample"),
            annotations: ToolAnnotations(readOnlyHint: true),
            prepareLoadout: name == "direct" ? c2aPrepareLoadout : nil))
    })
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model, tools: tools)))
    return AgentSession(config: AgentSessionConfig(agent: agent,
        sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(AuthStorage(":memory:")),
        toolRegistry: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }),
        toolDefinitions: definitions))
}

// C1 U3: propagate the SDK error; authorized follow-up test edit.
@Test func c2aRegistrationActivatesOnlyDefaultDeclarableTools() async throws {
    let definitions: [(String, ToolExposure, Bool?)] = [
        ("direct", .direct, nil), ("model", .modelOnly, nil),
        ("off", .direct, false), ("code", .codemode, nil),
        ("deferred", .deferred, nil), ("hidden", .hidden, nil),
    ]
    let custom = definitions.map { name, exposure, active in
        CustomToolDefinition(tool: CustomTool(name: name, label: name, description: name,
            parameters: [:], execute: { _, _, _, _, _ in AgentToolResult(content: []) },
            exposure: exposure, defaultActive: active))
    }
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    // C1 U3: SDK tool-list validation now throws.
    let created = try await createAgentSession(CreateAgentSessionOptions(
        authStorage: auth, model: model, offline: true, noTools: .builtin,
        customTools: custom, resourceLoader: TestResourceLoader(),
        sessionManager: .inMemory(), settingsManager: .inMemory()))
    defer { created.session.dispose() }
    #expect(Set(created.session.getActiveToolNames()) == Set(["direct", "model"]))
    #expect(Set(created.session.getCallableTools().map(\.name)) == Set(["direct", "code", "deferred"]))

    created.session.setActiveToolsByName(["off", "hidden"])
    #expect(created.session.getActiveToolNames() == ["off"])
}

@Test func c2aExposureAndLoadoutKeepDeclaredSetInTranscript() async throws {
    let session = c2aExposureSession()
    defer { session.dispose() }
    session.setActiveToolsByName(["direct", "model", "code", "deferred", "hidden", "direct"])

    #expect(session.getActiveToolNames() == ["direct", "model", "code", "deferred"])
    #expect(Set(session.getCallableTools().map(\.name)) == Set(["direct", "code", "deferred"]))
    #expect(session.agent.tools.first?.description == "prepared direct")
    let model = try #require(session.getAllTools().first { $0.name == "model" })
    #expect(model.exposure == .modelOnly)
    #expect(model.namespace?.name == "sample")
    #expect(model.annotations?.readOnlyHint == true)
    #expect(model.promptGuidelines == ["Use model"])

    let declared = session.agent.tools.map(\.aiTool)
    let system = SystemMessage(content: .text("test"), toolsAdded: declared,
                               toolsRemoved: [ToolReference(name: "model"), ToolReference(name: "direct")])
    let projected = try await session.agent.transformContext?([.system(system)], nil)
    guard case .system(let transformed)? = projected?.first else {
        Issue.record("Expected a system message"); return
    }
    #expect(transformed.toolsAdded?.map(\.name) == ["direct", "code", "deferred"])
    #expect(transformed.toolsRemoved?.map(\.name) == ["direct"])
    #expect(system.toolsAdded?.map(\.name).contains("model") == true)
}

@Test(.timeLimit(.minutes(1))) func c2aNestedCallPersistsRecordUsageAndParentEvents() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let count = LockedState(0)
    let sessionBox = LockedState<AgentSession?>(nil)
    let parentIDs = LockedState<[String]>([])
    let turnEndHasNested = LockedState(false)
    let inner = AgentTool(label: "inner", name: "inner", description: "inner", parameters: [:]) {
        _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "child"))],
                        usage: Usage(input: 2, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 5))
    }
    let outer = AgentTool(label: "outer", name: "outer", description: "outer", parameters: [:]) {
        id, _, _, _ in
        guard let session = sessionBox.withLock({ $0 }) else {
            return AgentToolResult(content: [.text(TextContent(text: "missing session"))], isError: true)
        }
        let child = await session.executeNestedTool(callerId: id, name: "inner", args: [:])
        return AgentToolResult(content: child.result.content,
                               usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2))
    }
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model,
                                                          tools: [outer, inner]),
        streamFn: { model, _, _ in
            let current = count.withLock { value -> Int in value += 1; return value }
            let content: [ContentBlock] = current == 1
                ? [.toolCall(ToolCall(id: "outer-call", name: "outer", arguments: [:]))]
                : [.text(TextContent(text: "done"))]
            let message = AssistantMessage(content: content, api: model.api, provider: model.provider,
                model: model.id, usage: Usage(input: 1, output: 1, cacheRead: 0,
                                               cacheWrite: 0, totalTokens: 2),
                stopReason: current == 1 ? .toolUse : .stop)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: message.stopReason, message: message))
            stream.end(message)
            return stream
        }, getApiKey: { _ in "test" }))
    let manager = SessionManager.inMemory()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: SettingsManager.inMemory(), resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(auth), toolRegistry: ["outer": outer, "inner": inner]))
    sessionBox.withLock { $0 = session }
    defer { sessionBox.withLock { $0 = nil }; session.dispose() }
    let unsubscribe = session.subscribe { event in
        if case .nestedToolExecution = event {
            if let parent = encodeSessionEvent(event)["parentToolCallId"] as? String {
                parentIDs.withLock { $0.append(parent) }
            }
        } else if case .agent(.turnEnd(_, let results)) = event, !results.isEmpty {
            let coded = encodeSessionEvent(event)
            let encodedNested = (coded["toolResults"] as? [[String: Any]])?.first?["nestedCalls"] != nil
            turnEndHasNested.withLock { $0 = results.first?.nestedCalls != nil && encodedNested }
        }
    }
    defer { unsubscribe() }

    try await session.prompt("run")
    let tool = try #require(manager.getEntries().compactMap { entry -> ToolResultMessage? in
        guard case .message(let item) = entry, case .toolResult(let result) = item.message else { return nil }
        return result
    }.first)
    #expect(tool.nestedCalls?.calls.map(\.id) == ["outer-call/1"])
    #expect(tool.nestedCalls?.complete == true)
    #expect(tool.usage?.input == 3)
    #expect(tool.usage?.output == 4)
    #expect(parentIDs.withLock { $0 } == ["outer-call", "outer-call"])
    #expect(turnEndHasNested.withLock { $0 })
}
