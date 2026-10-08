import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func v110BashModel() -> Model {
    Model(id: "bash-exclude-test", name: "Bash exclude test", api: .openAICompletions,
          provider: "bash-exclude-test", baseUrl: "https://example.invalid", reasoning: false,
          input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 32_000, maxTokens: 1_024)
}

private func v110BashSession(streamFn: StreamFn? = nil) -> AgentSession {
    let model = v110BashModel()
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test-key")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, streamFn: streamFn,
        getApiKey: { _ in "test-key" }))
    var settings = Settings()
    settings.compaction = CompactionSettingsOverrides(enabled: false)
    settings.retry = RetrySettings(enabled: false)
    return AgentSession(config: AgentSessionConfig(agent: agent,
        sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(settings),
        resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(auth)))
}

private func v110BashEntries(_ manager: SessionManager) -> [AgentCustomMessage] {
    manager.getEntries().compactMap { entry in
        guard case .message(let message) = entry,
              case .custom(let custom) = message.message,
              custom.role == "bashExecution" else { return nil }
        return custom
    }
}

private struct V110BashOperations: BashOperations {
    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        BashResult(output: "private-output", exitCode: 0, cancelled: false, truncated: false)
    }
}

@Test func v110BashExcludedResultIsStored() async throws {
    // Decision U5: !! output stays in the session history.
    let session = v110BashSession()
    _ = try await session.executeBash("private-command", excludeFromContext: true,
                                      operations: V110BashOperations())
    let message = try #require(v110BashEntries(session.sessionManager).first)
    #expect((message.payload?.value as? [String: Any])?["excludeFromContext"] as? Bool == true)
}

private func v110BashResponse(_ model: Model) -> AssistantMessageEventStream {
    let response = AssistantMessage(content: [.text(TextContent(text: "answer"))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop)
    let stream = AssistantMessageEventStream()
    stream.push(.done(reason: .stop, message: response))
    stream.end(response)
    return stream
}

@Test(.timeLimit(.minutes(1))) func v110BashExcludedResultIsDeferredWhileStreaming() async throws {
    let holder = LockedState<AgentSession?>(nil)
    let didRecord = LockedState(false)
    let session = v110BashSession(streamFn: { model, _, _ in
        let session = try #require(holder.withLock { $0 })
        #expect(session.isStreaming)
        session.recordBashResult("private-command", BashResult(output: "private-output", exitCode: 0,
            cancelled: false, truncated: false), excludeFromContext: true)
        #expect(v110BashEntries(session.sessionManager).isEmpty)
        #expect(session.agent.state.messages.contains { $0.role == "bashExecution" } == false)
        didRecord.withLock { $0 = true }
        return v110BashResponse(model)
    })
    holder.withLock { $0 = session }
    // No shell is started; do not call dispose(), which stops other tests' shell processes.
    defer { holder.withLock { $0 = nil } }
    try await session.prompt("hello")
    await session.waitForIdle()
    #expect(didRecord.withLock { $0 })
    let message = try #require(v110BashEntries(session.sessionManager).first)
    guard case .bashExecution(let bash) = message.decode() else {
        Issue.record("Expected a stored shell result")
        return
    }
    #expect(bash.excludeFromContext == true)
    #expect(PiSwiftCodingAgent.convertToLlm(session.agent.state.messages).contains {
        if case .user(let user) = $0, case .text(let text) = user.content {
            return text.contains("private-output")
        }
        return false
    } == false)
}

@Test(.timeLimit(.minutes(1))) func v110BashModelContextIncludesNormalAndOmitsExcludedResults() async throws {
    let input = LockedState("")
    let session = v110BashSession(streamFn: { model, context, _ in
        input.withLock { $0 = serializeConversation(context.messages) }
        return v110BashResponse(model)
    })
    session.recordBashResult("private-command", BashResult(output: "private-output", exitCode: 0,
        cancelled: false, truncated: false), excludeFromContext: true)
    session.recordBashResult("normal-command", BashResult(output: "normal-output", exitCode: 0,
        cancelled: false, truncated: false), excludeFromContext: false)
    try await session.prompt("hello")
    await session.waitForIdle()
    #expect(v110BashEntries(session.sessionManager).count == 2)
    let context = input.withLock { $0 }
    #expect(context.contains("normal-command"))
    #expect(context.contains("normal-output"))
    #expect(context.contains("private-command") == false)
    #expect(context.contains("private-output") == false)
}

@Test func v110BashExcludeFlagSurvivesSessionAndRpcJson() throws {
    let session = v110BashSession()
    session.recordBashResult("private-command", BashResult(output: "private-output", exitCode: 0,
        cancelled: false, truncated: false), excludeFromContext: true)
    let entry = try #require(session.sessionManager.getEntries().first { entry in
        if case .message(let message) = entry { return message.message.role == "bashExecution" }
        return false
    })
    let header = try #require(session.sessionManager.getHeader())
    let text = encodeSessionHeader(header) + "\n" + encodeSessionEntry(entry)
    let decoded = try #require(parseSessionEntries(text).last)
    guard case .entry(.message(let message)) = decoded,
          case .custom(let custom) = message.message,
          case .bashExecution(let bash) = custom.decode() else {
        Issue.record("Expected a decoded shell result")
        return
    }
    #expect(bash.excludeFromContext == true)
    #expect(PiSwiftCodingAgent.convertToLlm([message.message]).isEmpty)
    let rpc = encodeSessionEvent(.agent(.messageEnd(message: message.message)))
    let rpcMessage = try #require(rpc["message"] as? [String: Any])
    #expect(rpcMessage["excludeFromContext"] as? Bool == true)
    #expect(encodeAgentMessageJSON(message.message).serialized().contains("\"excludeFromContext\":true"))
}

@Test(arguments: [Optional<Bool>.none, Optional(false)])
func v110BashNormalResultsOmitTheExcludeFlag(_ flag: Bool?) throws {
    let message = makeBashExecutionAgentMessage(BashExecutionMessage(command: "normal-command",
        output: "normal-output", exitCode: 0, cancelled: false, truncated: false,
        timestamp: 123, excludeFromContext: flag))
    #expect(encodeAgentMessageDict(message)["excludeFromContext"] == nil)
    #expect(encodeAgentMessageJSON(message).serialized().contains("excludeFromContext") == false)
    let context = PiSwiftCodingAgent.convertToLlm([message])
    #expect(serializeConversation(context).contains("normal-output"))
    guard case .custom(let custom) = message, case .bashExecution(let bash) = custom.decode() else {
        Issue.record("Expected a decoded shell result")
        return
    }
    #expect(bash.excludeFromContext == nil)
}

@Test func v110BashOldSessionDecodesWithoutExcludeFlag() throws {
    let text = """
    {"type":"session","version":3,"id":"old-session","timestamp":"2026-10-01T00:00:00Z","cwd":"/tmp"}
    {"type":"message","id":"old-bash","parentId":null,"timestamp":"2026-10-01T00:00:00Z","message":{"role":"bashExecution","command":"old-command","output":"old-output","exitCode":0,"cancelled":false,"truncated":false,"timestamp":123}}
    """
    let decoded = try #require(parseSessionEntries(text).last)
    guard case .entry(.message(let message)) = decoded,
          case .custom(let custom) = message.message,
          case .bashExecution(let bash) = custom.decode() else {
        Issue.record("Expected an old shell result")
        return
    }
    #expect(bash.excludeFromContext == nil)
    #expect(serializeConversation(PiSwiftCodingAgent.convertToLlm([message.message])).contains("old-output"))
}

@Test(.timeLimit(.minutes(1))) func v110BashCompactionAndBranchInputsOmitExcludedResults() async throws {
    let session = v110BashSession()
    session.recordBashResult("private-command", BashResult(output: "private-output", exitCode: 0,
        cancelled: false, truncated: false), excludeFromContext: true)
    session.recordBashResult("normal-command", BashResult(output: "normal-output", exitCode: 0,
        cancelled: false, truncated: false), excludeFromContext: false)
    let inputs = LockedState([String]())
    let streamFn: StreamFn = { model, context, _ in
        inputs.withLock { $0.append(serializeConversation(context.messages)) }
        return v110BashResponse(model)
    }
    _ = try await generateSummary(currentMessages: session.agent.state.messages,
        model: v110BashModel(), reserveTokens: 1_024, apiKey: "test-key", streamFn: streamFn)
    let branch = await generateBranchSummary(session.sessionManager.getBranch(),
        GenerateBranchSummaryOptions(model: v110BashModel(), apiKey: "test-key", signal: nil,
            customInstructions: nil, reserveTokens: 1_024, streamFn: streamFn))
    #expect(branch.error == nil)
    #expect(branch.summary == "answer")
    let prompts = inputs.withLock { $0 }
    #expect(prompts.count == 2)
    for prompt in prompts {
        #expect(prompt.contains("normal-command"))
        #expect(prompt.contains("normal-output"))
        #expect(prompt.contains("private-command") == false)
        #expect(prompt.contains("private-output") == false)
    }
}
