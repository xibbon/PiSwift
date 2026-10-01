import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private actor RetryStreamState {
    private var calls = 0

    func next() -> Int {
        calls += 1
        return calls
    }
}

private func waitForCondition(timeoutMs: Int, pollMs: Int = 5, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
    }
    return condition()
}

@Test(.timeLimit(.minutes(1))) func autoRetrySchedulesContinueOnRetryableError() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-retry-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let streamState = RetryStreamState()
    let streamFn: StreamFn = { model, _, _ in
        let stream = AssistantMessageEventStream()
        Task {
            let call = await streamState.next()
            let usage = Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2)
            if call == 1 {
                let message = AssistantMessage(
                    content: [.text(TextContent(text: ""))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: usage,
                    stopReason: .error,
                    errorMessage: "rate limit"
                )
                stream.push(.error(reason: .error, error: message))
                stream.end(message)
            } else {
                let message = AssistantMessage(
                    content: [.text(TextContent(text: "ok"))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: usage,
                    stopReason: .stop
                )
                stream.push(.done(reason: .stop, message: message))
                stream.end(message)
            }
        }
        return stream
    }

    var overrides = Settings()
    overrides.retry = RetrySettings(enabled: true, maxRetries: 1, baseDelayMs: 1)
    let settingsManager = SettingsManager.inMemory(overrides)

    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: "Test",
            model: model,
            thinkingLevel: .off
        ),
        convertToLlm: { messages in
            convertToLlm(messages)
        },
        streamFn: streamFn
    ))

    let sessionManager = SessionManager.inMemory()
    let authStorage = AuthStorage(URL(fileURLWithPath: tempDir).appendingPathComponent("auth.json").path)
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    let modelRegistry = ModelRegistry(authStorage, tempDir)

    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        modelRegistry: modelRegistry
    ))
    defer { session.dispose() }

    let events = LockedState<[AgentSessionEvent]>([])
    _ = session.subscribe { event in
        events.withLock { $0.append(event) }
    }

    try await session.prompt("hello")
    await session.agent.waitForIdle()

    _ = await waitForCondition(timeoutMs: 200) {
        let recorded = events.withLock { $0 }
        return recorded.contains { event in
            if case .autoRetryEnd = event { return true }
            return false
        }
    }
    await session.agent.waitForIdle()

    let starts = events.withLock { events in
        events.compactMap { event -> Int? in
            if case .autoRetryStart(let attempt, _, _, _) = event { return attempt }
            return nil
        }
    }
    let ends = events.withLock { events in
        events.compactMap { event -> Bool? in
            if case .autoRetryEnd(let success, _, _) = event { return success }
            return nil
        }
    }

    #expect(starts == [1])
    #expect(ends == [true])

    let hasError = session.messages.contains { message in
        if case .assistant(let assistant) = message {
            return assistant.stopReason == .error
        }
        return false
    }
    #expect(hasError == false)
}
