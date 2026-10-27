import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private enum A2CopilotRequestError: LocalizedError {
    case requestTooLarge

    var errorDescription: String? {
        "github-copilot API error (413): {\"message\":\"failed to parse request\",\"code\":\"\"}"
    }
}

@Suite(.timeLimit(.minutes(1)))
struct A2CopilotRequestSizeOverflowTests {
    // Upstream v1.4.0: coding-agent/test/suite/regressions/copilot-request-size-overflow.test.ts:67.
    @Test func compactsImageHeavyHistoryAndRetriesAfterReal413() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-a2-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = Model(id: "faux-copilot", name: "Copilot request-size test", api: .openAICompletions,
            provider: "github-copilot", baseUrl: "https://example.invalid", reasoning: false, input: [.text, .image],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1_000_000, maxTokens: 16_384)
        let calls = LockedState(0)
        let requestSizes = LockedState<[Int]>([])
        let streamFn: StreamFn = { model, context, _ in
            let call = calls.withLock { $0 += 1; return $0 }
            let body = try JSONSerialization.data(withJSONObject: ["messages": context.messages.map(messageToJSONObject)])
            requestSizes.withLock { $0.append(body.count) }
            if call == 1 {
                #expect(body.count > 32 * 1024 * 1024)
                // Throw as upstream does. The agent makes the zero-usage failed assistant message.
                throw A2CopilotRequestError.requestTooLarge
            }
            #expect(call == 2 || call == 3)
            #expect(!String(decoding: body, as: UTF8.self).contains("\"type\":\"image\""))
            let text = call == 2
                ? "The old images have been reviewed. Continue with the recent task."
                : "Continued after compaction"
            let message = AssistantMessage(content: [.text(TextContent(text: text))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: message))
            stream.end(message)
            return stream
        }

        let manager = SessionManager.inMemory(directory.path)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        func assistant(_ text: String) -> AgentMessage {
            .assistant(AssistantMessage(content: [.text(TextContent(text: text))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop, timestamp: timestamp))
        }
        manager.appendMessage(.user(UserMessage(content: .text("Review the old images"), timestamp: timestamp)))
        manager.appendMessage(.assistant(AssistantMessage(
            content: [.toolCall(ToolCall(id: "read-images", name: "read", arguments: ["path": AnyCodable("old-images")]))],
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .toolUse, timestamp: timestamp)))
        let image = ImageContent(data: String(repeating: "A", count: 384 * 1024), mimeType: "image/png")
        manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "read-images", toolName: "read",
            content: Array(repeating: .image(image), count: 89), isError: false, timestamp: timestamp)))
        manager.appendMessage(assistant("Finished reviewing the old images"))
        // The completed recent turn keeps the image history outside the default 20k-token tail.
        manager.appendMessage(.user(UserMessage(content: .text("Recent task notes: " + String(repeating: "x", count: 80_000)), timestamp: timestamp)))
        manager.appendMessage(assistant("Ready to continue"))

        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, thinkingLevel: .off),
            convertToLlm: { convertToLlm($0) }, streamFn: streamFn, getApiKey: { _ in "test-key" }))
        agent.messages = manager.buildSessionContext().messages
        let auth = AuthStorage(directory.appendingPathComponent("auth.json").path)
        auth.setRuntimeApiKey(model.provider, "test-key")
        let registry = ModelRegistry(auth, directory.path, modelsStore: InMemoryCodingAgentModelsStore(), networkEnabled: false)
        let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: SettingsManager.inMemory(), resourceLoader: TestResourceLoader(), modelRegistry: registry))
        defer { session.dispose() }
        let events = LockedState<[AgentSessionEvent]>([])
        _ = session.subscribe { event in events.withLock { $0.append(event) } }

        try await session.prompt("Continue the task using the recent notes.")
        await session.waitForIdle()

        #expect(calls.withLock { $0 } == 3)
        let starts = events.withLock { $0.compactMap { event -> String? in
            if case .autoCompactionStart(let reason) = event { return reason.rawValue }
            return nil
        } }
        let ends = events.withLock { $0.compactMap { event -> (CompactionResult?, Bool, Bool, String?)? in
            if case .autoCompactionEnd(let result, let aborted, let willRetry, let error) = event {
                return (result, aborted, willRetry, error)
            }
            return nil
        } }
        #expect(starts == ["overflow"])
        #expect(ends.count == 1)
        let end = try #require(ends.last)
        #expect(end.0?.summary.hasPrefix("The old images have been reviewed. Continue with the recent task.") == true)
        #expect(end.1 == false)
        #expect(end.2 == true)
        #expect(end.3 == nil)
        #expect(requestSizes.withLock { $0.last ?? Int.max } < 32 * 1024 * 1024)
        #expect(session.getLastAssistantText() == "Continued after compaction")
    }
}
