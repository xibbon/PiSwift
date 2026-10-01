import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func makeStubStreamFn() -> StreamFn {
    { model, context, options in
        let stream = AssistantMessageEventStream()
        let message = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        stream.push(.done(reason: .stop, message: message))
        return stream
    }
}

@Test(.timeLimit(.minutes(1))) func autoCompactionResumesWhenOnlyAgentQueueExists() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-auto-compaction-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: "Test",
            model: model,
            thinkingLevel: .off,
            tools: []
        ),
        streamFn: makeStubStreamFn(),
        getApiKey: { _ in "test-key" }
    ))

    let sessionManager = SessionManager.inMemory()
    let settingsManager = SettingsManager.create(tempDir, tempDir)
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
    defer {
        session.dispose()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    agent.appendMessage(.user(UserMessage(content: .text("hi"), timestamp: Int64(Date().timeIntervalSince1970 * 1000))))
    agent.appendMessage(.assistant(AssistantMessage(
        content: [.text(TextContent(text: "hello"))],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .stop,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000)
    )))

    agent.followUp(.custom(AgentCustomMessage(role: "test", payload: nil)))

    #expect(session.pendingMessageCount == 0)
    #expect(agent.hasQueuedMessages() == true)

    await session.runAutoCompaction(reason: .threshold, willRetry: false, compactBlock: {
        CompactionResult(summary: "compacted", firstKeptEntryId: "entry-1", tokensBefore: 100)
    })

    #expect(agent.hasQueuedMessages() == false)
}
