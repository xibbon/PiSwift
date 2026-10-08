import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func c3Physical(_ id: String, provider: String = "physical", reasoning: Bool = false,
                        contextWindow: Int = 50_000, maxTokens: Int = 5_000) -> Model {
    Model(id: id, name: id, api: .openAIResponses, provider: provider,
          baseUrl: "https://example.invalid/v1", reasoning: reasoning, input: [.text],
          cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: contextWindow, maxTokens: maxTokens)
}

private func c3Response(_ model: Model, stopReason: StopReason = .stop,
                        thinkingLevel: ModelThinkingLevel? = nil,
                        errorMessage: String? = nil) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: "answer"))], api: model.api,
                     provider: model.provider, model: model.id,
                     usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                     stopReason: stopReason, errorMessage: errorMessage, thinkingLevel: thinkingLevel)
}

private func c3Virtual(_ route: @escaping @Sendable (ModelRouteRequest) async throws -> ModelRoute,
                       provider: String = "router", id: String = "auto") -> VirtualModelDefinition {
    VirtualModelDefinition(provider: provider, id: id, name: "Auto", thinkingLevels: [.low, .high],
                           contextWindow: 1_000, maxTokens: 100, route: route)
}

@Test func virtualModelCatalogDefaultsAndPhysicalRouting() async throws {
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("physical", "key")
    let registry = ModelRegistry(auth)
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "key", models: [
            HookProviderModel(id: "small", reasoning: false, contextWindow: 1_000, maxTokens: 100),
            HookProviderModel(id: "large", reasoning: true, contextWindow: 50_000, maxTokens: 5_000)
        ]), sourceId: "physical")
    let requests = LockedState<[ModelRouteRequest]>([])
    try registry.registerVirtualModel(c3Virtual({ request in
        requests.withLock { $0.append(request) }
        let id = request.thinkingLevel == .high ? "large" : "small"
        let physical = registry.find("physical", id)!
        return ModelRoute(model: physical, thinkingLevel: .high)
    }), sourceId: "route")

    let virtual = try #require(registry.find("router", "auto"))
    #expect(virtual.api == VIRTUAL_MODEL_API)
    #expect(virtual.contextWindow == 1_000)
    #expect(virtual.maxTokens == 100)
    #expect(virtual.input == [.text, .image])
    #expect(virtual.thinkingLevelMap?[.low] == "low")
    #expect(virtual.thinkingLevelMap?.keys.contains(.medium) == true)
    #expect(virtual.thinkingLevelMap?[.medium] != "medium")
    let large = try #require(registry.find("physical", "large"))
    var previous = c3Response(large, thinkingLevel: .medium)
    let messages: [Message] = [.user(UserMessage(content: .text("first"))),
                               .assistant(previous), .user(UserMessage(content: .text("second")))]

    let low = try await registry.resolveVirtualModel(virtual, messages: messages, reason: .user,
                                                      thinkingLevel: .low)
    #expect(low.model.id == "small")
    #expect(low.thinkingLevel == .off)
    #expect(requests.withLock { $0.first?.previous?.model.id } == "large")
    #expect(requests.withLock { $0.first?.previous?.thinkingLevel } == .medium)

    let high = try await registry.resolveVirtualModel(virtual, messages: messages, reason: .user,
                                                       thinkingLevel: .high)
    #expect(high.model.id == "large")
    #expect(high.thinkingLevel == .high)

    previous.stopReason = .error
    let retry = try await registry.resolveVirtualModel(
        virtual, messages: messages, reason: .retry, thinkingLevel: .high, failed: previous)
    #expect(retry.model.id == "large")
    #expect(requests.withLock { $0.last?.failed?.model.id } == "large")
    #expect(requests.withLock { $0.last?.previous?.model.id } == "large")
    let routingError = c3Response(virtual, stopReason: .error)
    _ = try await registry.resolveVirtualModel(virtual, messages: messages, reason: .retry,
                                               thinkingLevel: .high, failed: routingError)
    #expect(requests.withLock { $0.last?.failed } == nil)
}

@Test func virtualModelRegistrationAndBranchSelection() throws {
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("physical", "key")
    let registry = ModelRegistry(auth)
    let physical = c3Physical("base")
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: physical.baseUrl, apiKey: "key",
        models: [HookProviderModel(id: physical.id)]), sourceId: "physical")
    let route: @Sendable (ModelRouteRequest) async throws -> ModelRoute = { _ in
        ModelRoute(model: physical, thinkingLevel: .off)
    }
    try registry.registerVirtualModel(c3Virtual(route), sourceId: "route")
    try registry.registerVirtualModel(c3Virtual(route, provider: "physical", id: "auto"), sourceId: "route")
    try registry.registerVirtualModel(c3Virtual(route, provider: "physical", id: "fast"), sourceId: "route")
    #expect(registry.getAll().filter { $0.provider == "physical" }.map(\.id).suffix(2) == ["auto", "fast"])
    #expect(throws: Error.self) {
        try registry.registerVirtualModel(c3Virtual(route, provider: "physical", id: "base"), sourceId: "route")
    }

    let manager = SessionManager.inMemory()
    manager.appendModelChange("router", "auto")
    manager.appendMessage(.assistant(c3Response(physical)))
    var selection = getBranchSelection(manager.getBranch(), getModel: registry.find)
    #expect(selection?.provider == "router")
    #expect(selection?.modelId == "auto")
    manager.appendCustomEntry(VIRTUAL_MODEL_STATE_ENTRY,
                              ["provider": "router", "modelId": "auto", "state": ["phase": "planning"]])
    #expect((getVirtualModelState(manager.getBranch(), provider: "router", modelId: "auto")?.value
             as? [String: String])?["phase"] == "planning")
    #expect(getVirtualModelState(manager.getBranch(), provider: "physical", modelId: "auto") == nil)

    registry.unregisterVirtualModel(provider: "router", id: "auto", sourceId: "route")
    selection = getBranchSelection(manager.getBranch(), getModel: registry.find)
    #expect(selection?.provider == "physical")
    #expect(selection?.modelId == "base")
    registry.unregisterProvider("physical", sourceId: "physical")
    #expect(registry.find("physical", "auto") != nil)
}

@Test func virtualModelHidesPhysicalCollisionAddedAfterRegistration() throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let target = c3Physical("target", provider: "other")
    try registry.registerVirtualModel(c3Virtual({ _ in ModelRoute(model: target, thinkingLevel: .off) },
                                                provider: "late", id: "same"), sourceId: "route")
    registry.registerProvider(HookProviderConfig(
        provider: "late", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "key", models: [HookProviderModel(id: "same"), HookProviderModel(id: "other")]),
        sourceId: "provider")
    #expect(registry.find("late", "same")?.api == VIRTUAL_MODEL_API)
    #expect(registry.getAll().filter { $0.provider == "late" }.map(\.id) == ["other", "same"])
    #expect(registry.getPhysicalModel("late", "same") == nil)
    registry.unregisterVirtualModel(provider: "late", id: "same", sourceId: "route")
    #expect(registry.find("late", "same")?.api == .openAIResponses)
}

@Test func virtualModelRejectsNonPhysicalAndUnauthenticatedRoutes() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let physical = c3Physical("target")
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: physical.baseUrl,
        models: [HookProviderModel(id: physical.id)]), sourceId: "physical")
    try registry.registerVirtualModel(c3Virtual({ _ in ModelRoute(model: physical, thinkingLevel: .off) }),
                                      sourceId: "route")
    let virtual = try #require(registry.find("router", "auto"))
    await #expect(throws: Error.self) {
        _ = try await registry.resolveVirtualModel(virtual, messages: [], reason: .direct, thinkingLevel: .off)
    }
    try registry.registerVirtualModel(c3Virtual({ _ in ModelRoute(model: virtual, thinkingLevel: .off) }),
                                      sourceId: "route")
    await #expect(throws: Error.self) {
        _ = try await registry.resolveVirtualModel(virtual, messages: [], reason: .direct, thinkingLevel: .off)
    }
}

@Test(.timeLimit(.minutes(1))) func virtualModelDirectStreamClampsBudgetAndKeepsCredentialsWithProvider() async throws {
    let observed = LockedState<[(String, Int?, String?)]>([])
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "physical-key", streamSimple: { model, _, options in
            observed.withLock { $0.append((model.id, options?.maxTokens, options?.apiKey)) }
            let stream = AssistantMessageEventStream()
            let message = c3Response(model)
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }, models: [HookProviderModel(id: "small", maxTokens: 100)]), sourceId: "physical")
    try registry.registerVirtualModel(c3Virtual({ _ in
        ModelRoute(model: registry.find("physical", "small")!, thinkingLevel: .high)
    }), sourceId: "route")
    let virtual = try #require(registry.find("router", "auto"))
    let context = Context(messages: [.user(UserMessage(content: .text("hello")))])
    let stream = registry.streamSimple(model: virtual, context: context,
                                       options: SimpleStreamOptions(maxTokens: 20_000, apiKey: "caller-key"))
    #expect(observed.withLock { $0.isEmpty })
    let result = await stream.result()
    #expect(result.provider == "physical")
    #expect(result.model == "small")
    #expect(observed.withLock { $0.first?.1 } == 100)
    #expect(observed.withLock { $0.first?.2 } != "caller-key")
}

@Test(.timeLimit(.minutes(1))) func agentSessionRoutesUserRetryContinuationAndPersistsState() async throws {
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey("physical", "physical-key")
    let registry = ModelRegistry(auth)
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "physical-key", models: [
            HookProviderModel(id: "small", reasoning: false, contextWindow: 1_000, maxTokens: 100),
            HookProviderModel(id: "large", reasoning: true, contextWindow: 50_000, maxTokens: 5_000)
        ]), sourceId: "physical")
    let requests = LockedState<[ModelRouteRequest]>([])
    try registry.registerVirtualModel(c3Virtual({ request in
        requests.withLock { $0.append(request) }
        let id = request.thinkingLevel == .high ? "large" : "small"
        let nextState = request.state == nil ? AnyCodable(["turns": 1]) : nil
        return ModelRoute(model: registry.find("physical", id)!, thinkingLevel: .high,
                          state: nextState)
    }), sourceId: "route")
    let virtual = try #require(registry.find("router", "auto"))
    let dispatched = LockedState<[String]>([])
    let calls = LockedState(0)
    let tool = AgentTool(label: "Echo", name: "echo", description: "Echo", parameters: [:]) { _, _, _, _ in
        AgentToolResult(content: [.text(TextContent(text: "echoed"))])
    }
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: virtual, thinkingLevel: .high, tools: [tool]),
        streamFn: { model, _, _ in
            dispatched.withLock { $0.append(model.id) }
            let call = calls.withLock { value in value += 1; return value }
            let stream = AssistantMessageEventStream()
            Task {
                var message = c3Response(model, stopReason: call == 1 ? .error : call == 2 ? .toolUse : .stop,
                                         thinkingLevel: model.reasoning ? .high : .off,
                                         errorMessage: call == 1 ? "rate limit" : nil)
                if call == 2 {
                    message.content = [.toolCall(ToolCall(id: "echo-1", name: "echo", arguments: [:]))]
                }
                if call == 1 {
                    stream.push(.error(reason: .error, error: message))
                } else {
                    stream.push(.done(reason: message.stopReason, message: message))
                }
                stream.end(message)
            }
            return stream
        }, getApiKey: { _ in "physical-key" }
    ))
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: true, maxRetries: 1, baseDelayMs: 1)
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent, sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(settings), resourceLoader: TestResourceLoader(),
        modelRegistry: registry))
    defer { session.dispose() }

    try await session.prompt("first")
    await session.waitForIdle()
    #expect(session.agent.state.model.id == "auto")
    #expect(session.routedModel?.model.id == "large")
    #expect(session.getContextUsage()?.contextWindow == 50_000)
    #expect(requests.withLock { $0.map(\.reason) } == [.user, .retry, .continuation])
    #expect(requests.withLock { $0[1].failed?.model.id } == "large")
    #expect(requests.withLock { $0[2].previous?.model.id } == "large")
    session.setThinkingLevel(.low)
    try await session.prompt("second")
    await session.waitForIdle()
    #expect(dispatched.withLock { $0 } == ["large", "large", "large", "small"])
    #expect(requests.withLock { $0.map(\.reason) } == [.user, .retry, .continuation, .user])
    #expect(requests.withLock { $0.last?.previous?.model.id } == "large")
    #expect((requests.withLock { $0.last?.state?.value } as? [String: Int])?["turns"] == 1)
    let storedStates = session.sessionManager.getBranch().filter { entry in
        if case .custom(let custom) = entry { return custom.customType == VIRTUAL_MODEL_STATE_ENTRY }
        return false
    }
    #expect(storedStates.count == 1)
    #expect(session.agent.state.model.id == "auto")
    #expect(session.routedModel?.model.id == "small")
    #expect(session.getContextUsage()?.contextWindow == 1_000)
}

@Test func sdkRestoresVirtualSelectionAndFallsBackAfterUnregistration() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("c3-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "physical-key", models: [HookProviderModel(id: "large", reasoning: true)]),
        sourceId: "physical")
    let physical = try #require(registry.find("physical", "large"))
    try registry.registerVirtualModel(c3Virtual({ _ in ModelRoute(model: physical, thinkingLevel: .high) }),
                                      sourceId: "route")
    let manager = SessionManager.inMemory(tempDir.path)
    manager.appendModelChange("router", "auto")
    manager.appendMessage(.user(UserMessage(content: .text("hello"))))
    manager.appendMessage(.assistant(c3Response(physical, thinkingLevel: .high)))
    let options = CreateAgentSessionOptions(
        cwd: tempDir.path, agentDir: tempDir.path, modelRegistry: registry, offline: true,
        noTools: .all, resourceLoader: TestResourceLoader(), sessionManager: manager,
        settingsManager: SettingsManager.inMemory())
    // C1 U3: SDK tool-list validation now throws.
    let restored = try await createAgentSession(options)
    defer { restored.session.dispose() }
    #expect(restored.modelFallbackMessage == nil)
    #expect(restored.session.agent.state.model.provider == "router")
    #expect(restored.session.agent.state.model.id == "auto")
    #expect(restored.session.routedModel?.model.id == "large")

    registry.unregisterVirtualModel(provider: "router", id: "auto", sourceId: "route")
    // C1 U3: SDK tool-list validation now throws.
    let fallback = try await createAgentSession(options)
    defer { fallback.session.dispose() }
    #expect(fallback.modelFallbackMessage == nil)
    #expect(fallback.session.agent.state.model.provider == "physical")
    #expect(fallback.session.agent.state.model.id == "large")
    #expect(fallback.session.routedModel == nil)
}

@Test(.timeLimit(.minutes(1))) func agentSessionCompactsBeforeSendingToSmallerRoutedModel() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(
        provider: "physical", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "physical-key", models: [
            HookProviderModel(id: "small", contextWindow: 1_000, maxTokens: 100),
            HookProviderModel(id: "large", reasoning: true, contextWindow: 50_000, maxTokens: 4_000)
        ]), sourceId: "physical")
    try registry.registerVirtualModel(c3Virtual({ request in
        let id = request.thinkingLevel == .high ? "large" : "small"
        return ModelRoute(model: registry.find("physical", id)!, thinkingLevel: .off)
    }), sourceId: "route")
    let virtual = try #require(registry.find("router", "auto"))
    let manager = SessionManager.inMemory()
    let compactedBeforeSmall = LockedState(false)
    let calls = LockedState(0)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: virtual, thinkingLevel: .high),
        streamFn: { model, _, _ in
            let call = calls.withLock { value in value += 1; return value }
            if model.id == "small" {
                compactedBeforeSmall.withLock { $0 = manager.getBranch().contains { $0.type == "compaction" } }
            }
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(
                content: [.text(TextContent(text: call == 1 ? String(repeating: "x", count: 8_000) : "done"))],
                api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: call == 1 ? 2_000 : 1, output: 1, cacheRead: 0,
                             cacheWrite: 0, totalTokens: call == 1 ? 2_001 : 2),
                stopReason: .stop)
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }, getApiKey: { _ in "physical-key" }
    ))
    let api = HookAPI()
    api.on("session_before_compact") { (event: SessionBeforeCompactEvent, _: HookContext) in
        SessionBeforeCompactResult(compaction: CompactionResult(
            summary: "compacted", firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore))
    }
    let hook = LoadedHook(path: "c3-compaction", resolvedPath: "c3-compaction", handlers: api.handlers,
                          currentHandlers: { api.handlers })
    let runner = HookRunner([hook], manager.getCwd(), manager, registry)
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: true, reserveTokens: 0, keepRecentTokens: 1)
    settings.retry = RetrySettings(enabled: false)
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent, sessionManager: manager, settingsManager: SettingsManager.inMemory(settings),
        resourceLoader: TestResourceLoader(), hookRunner: runner, modelRegistry: registry))
    defer { session.dispose() }

    try await session.prompt("first")
    await session.waitForIdle()
    #expect(manager.getBranch().contains { $0.type == "compaction" } == false)
    #expect(session.getContextUsage()?.contextWindow == 50_000)
    session.setThinkingLevel(.low)
    try await session.prompt("next")
    await session.waitForIdle()
    #expect(compactedBeforeSmall.withLock { $0 })
    #expect(session.routedModel?.model.id == "small")
}
