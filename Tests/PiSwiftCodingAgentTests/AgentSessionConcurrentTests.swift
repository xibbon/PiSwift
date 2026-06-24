import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private func createAssistantMessage(_ text: String, stopReason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "mock",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason,
        errorMessage: stopReason == .error ? "error" : nil,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000)
    )
}

private func waitForStreaming(_ session: AgentSession, timeoutNanoseconds: UInt64 = 500_000_000) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if session.isStreaming {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return session.isStreaming
}

@Test func promptThrowsWhileStreaming() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-concurrent-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")

    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                while true {
                    if options.signal?.isCancelled == true {
                        stream.push(.error(reason: .aborted, error: createAssistantMessage("Aborted", stopReason: .aborted)))
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let sessionManager = SessionManager.inMemory()
    let settingsManager = SettingsManager.create(tempDir, tempDir)
    let authStorage = AuthStorage(URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path)
    let modelRegistry = ModelRegistry(authStorage, tempDir)
    authStorage.setRuntimeApiKey("anthropic", "test-key")

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        modelRegistry: modelRegistry
    ))
    defer { session.dispose() }

    let firstPrompt = Task {
        try await session.prompt("First message")
    }

    _ = await waitForStreaming(session)

    do {
        try await session.prompt("Second message")
        #expect(Bool(false), "Expected prompt to throw while streaming")
    } catch {
        #expect(error.localizedDescription.contains("Agent is already processing"))
    }

    await session.abort()
    _ = try? await firstPrompt.value
}

@Test func submitPromptThrowsWhileStreamingBeforeStartingBackgroundTurn() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-submit-concurrent-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                stream.push(.error(reason: .aborted, error: createAssistantMessage("Aborted", stopReason: .aborted)))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey("anthropic", "test-key")
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.create(tempDir, tempDir),
        resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(authStorage, tempDir)
    ))
    defer { session.dispose() }

    let firstPrompt = try await session.submitPrompt("First message")
    #expect(await waitForStreaming(session) == true)

    do {
        _ = try await session.submitPrompt("Second message")
        #expect(Bool(false), "Expected submitPrompt to throw while streaming")
    } catch {
        #expect(error.localizedDescription.contains("Agent is already processing"))
    }

    await session.abort()
    _ = try? await firstPrompt.value
}

@Test func promptAllowsHeaderOnlyCustomModelAuth() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-header-auth-prompt-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let modelsJSON = """
    {
      "providers": {
        "header-provider": {
          "api": "openai-completions",
          "baseUrl": "https://example.invalid/v1",
          "headers": {
            "Authorization": "Bearer header-token"
          },
          "models": [
            { "id": "header-model" }
          ]
        }
      }
    }
    """
    try modelsJSON.write(
        to: URL(fileURLWithPath: tempDir).appendingPathComponent("models.json"),
        atomically: true,
        encoding: .utf8
    )

    let registry = ModelRegistry(AuthStorage(":memory:"), tempDir)
    let model = try #require(registry.find("header-provider", "header-model"))
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, _options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                stream.push(.done(reason: .stop, message: createAssistantMessage("Done")))
            }
            return stream
        },
        getModelAuth: { model in
            let auth = await registry.getApiKeyAndHeaders(model)
            return AgentModelAuth(apiKey: auth.apiKey, headers: auth.headers, baseUrl: auth.baseUrl)
        }
    ))

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.create(tempDir, tempDir),
        resourceLoader: TestResourceLoader(),
        modelRegistry: registry
    ))
    defer { session.dispose() }

    try await session.prompt("Use the header-auth model")
    #expect(session.messages.contains { message in
        if case .assistant = message { return true }
        return false
    })
}

@Test func steerWhileStreaming() async throws {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                stream.push(.error(reason: .aborted, error: createAssistantMessage("Aborted", stopReason: .aborted)))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:"))
    ))
    defer { session.dispose() }

    let firstPrompt = Task { try await session.prompt("First message") }
    try? await Task.sleep(nanoseconds: 10_000_000)

    session.steer("Steering message")
    #expect(session.pendingMessageCount == 1)

    await session.abort()
    _ = try? await firstPrompt.value
}

@Test func followUpWhileStreaming() async throws {
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                stream.push(.error(reason: .aborted, error: createAssistantMessage("Aborted", stopReason: .aborted)))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:"))
    ))
    defer { session.dispose() }

    let firstPrompt = Task { try await session.prompt("First message") }
    try? await Task.sleep(nanoseconds: 10_000_000)

    session.followUp("Follow-up message")
    #expect(session.pendingMessageCount == 1)

    await session.abort()
    _ = try? await firstPrompt.value
}

@Test func promptAfterCompletion() async throws {
    guard let apiKey = API_KEY else { return }
    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { _model, _context, _options in
            let stream = AssistantMessageEventStream()
            Task {
                stream.push(.start(partial: createAssistantMessage("")))
                stream.push(.done(reason: .stop, message: createAssistantMessage("Done")))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(),
        modelRegistry: {
            let authStorage = AuthStorage(":memory:")
            authStorage.setRuntimeApiKey("anthropic", apiKey)
            return ModelRegistry(authStorage)
        }()
    ))
    defer { session.dispose() }

    try await session.prompt("First message")
    try await session.prompt("Second message")
}
