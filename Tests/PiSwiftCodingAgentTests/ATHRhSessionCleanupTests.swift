import Foundation
import Testing
@testable import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private let athrhThreadModel = Model(
    id: "claude-haiku-4-5", name: "Claude", api: .anthropicMessages,
    provider: "anthropic", baseUrl: "https://api.anthropic.com", reasoning: false,
    input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
    contextWindow: 200_000, maxTokens: 1024
)

private let athrhFirstBody = Data(#"{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
private let athrhNextBody = Data(#"{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"text","text":"done"}]},{"role":"user","content":"more"}],"stream":true}"#.utf8)

private func athrhMakeSession(_ manager: SessionManager) -> AgentSession {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "test", model: model),
        convertToLlm: { PiSwiftCodingAgent.convertToLlm($0) }, sessionId: manager.getSessionId()))
    return AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
        settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:"))))
}

private func athrhThreadType(_ request: AnthropicThreadRequest) throws -> String? {
    let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    return (body["thread"] as? [String: String])?["type"]
}

private func athrhPrimeThread(_ id: String) throws {
    let store = AnthropicMessageThreadStore.shared
    let request = try #require(try store.prepare(model: athrhThreadModel, sessionId: id,
        fullBody: athrhFirstBody, betas: nil))
    #expect(try athrhThreadType(request) == "create")
    try store.record(request, model: athrhThreadModel, fullBody: athrhFirstBody, betas: nil,
        reply: ["role": "assistant", "content": [["type": "text", "text": "done"]]], replyId: "reply-1")
}

private actor ATHRhHTTPClient: ProviderHTTPClient {
    var requests: [Data] = []
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request.httpBody ?? Data())
        let replyId = requests.count == 1 ? "reply-first" : requests.count == 2 ? "reply-warm" : "reply-next"
        let start = #"{"type":"message_start","message":{"id":"\#(replyId)","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":0}}}"#
        let wire = "event: message_start\ndata: \(start)\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"done\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        return ProviderHTTPResponse(statusCode: 200, body: Data(wire.utf8))
    }
}

@Test(.timeLimit(.minutes(1))) func athrhWarmReplayDoesNotConsumeMessageThread() async throws {
    // Upstream cache-warmer.test.ts:155-169 plus anthropic-message-threads.test.ts:575-584.
    let client = ATHRhHTTPClient()
    let id = UUID().uuidString
    defer { try? cleanupSessionResources(id) }
    let firstOptions = AnthropicOptions(apiKey: "test-key", httpClient: client,
        cacheRetention: .short, sessionId: id, maxRetries: 0)
    let firstContext = normalizeContext(Context(systemPrompt: "test",
        messages: [.user(UserMessage(content: .text("hi"), timestamp: 1))]))
    let first = await streamAnthropic(model: athrhThreadModel, context: firstContext,
        options: firstOptions).result()
    #expect(first.stopReason == .stop)
    let replay = CacheWarmingPolicy.getCacheWarmingRequestOptions(
        SimpleStreamOptions(cacheRetention: .short, sessionId: id), signal: CancellationToken())
    #expect(replay.maxTokens == 1)
    #expect(replay.maxRetries == 0)
    #expect(replay.disableContinuation == true)
    let warmOptions = AnthropicOptions(maxTokens: replay.maxTokens, signal: replay.signal,
        apiKey: "test-key", httpClient: client, cacheRetention: replay.cacheRetention,
        sessionId: replay.sessionId, disableContinuation: replay.disableContinuation,
        maxRetries: replay.maxRetries)
    _ = await streamAnthropic(model: athrhThreadModel, context: firstContext, options: warmOptions).result()
    let nextContext = normalizeContext(Context(systemPrompt: "test", messages: [
        .user(UserMessage(content: .text("hi"), timestamp: 1)), .assistant(first),
        .user(UserMessage(content: .text("more"), timestamp: 2))
    ]))
    _ = await streamAnthropic(model: athrhThreadModel, context: nextContext, options: firstOptions).result()
    let bodies = try await client.requests.map {
        try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
    }
    #expect(bodies.count == 3)
    #expect(bodies[1]["thread"] == nil)
    #expect((bodies[2]["thread"] as? [String: String])?["previous_message_id"] == "reply-first")
}

private enum ATHRhCleanupFailure: Error { case expected }

@Test func athrhCleanupErrorDoesNotInterruptDisposal() throws {
    let session = athrhMakeSession(.inMemory())
    let id = session.sessionId
    try athrhPrimeThread(id)
    let called = LockedState(false)
    let removeFailure = registerSessionResourceCleanup { sessionId in
        if sessionId == id { throw ATHRhCleanupFailure.expected }
    }
    let removeSuccess = registerSessionResourceCleanup { sessionId in
        if sessionId == id { called.withLock { $0 = true } }
    }
    defer { removeFailure(); removeSuccess(); try? cleanupSessionResources(id) }
    session.dispose()
    #expect(called.withLock { $0 })
    #expect(session.lastSessionResourceCleanupError is SessionResourceCleanupError)
    let next = try #require(try AnthropicMessageThreadStore.shared.prepare(
        model: athrhThreadModel, sessionId: id, fullBody: athrhNextBody, betas: nil))
    #expect(try athrhThreadType(next) == "create")
}

@Test(.timeLimit(.minutes(1)), arguments: [
    "new", "switch", "fork", "clone", "import", "dispose", "runtime-replace", "runtime-dispose"
]) func athrhSessionEndClearsOldThreadAndNewIdStartsFresh(path: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("athrh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = athrhMakeSession(.inMemory(directory.path))
    let oldId = session.sessionId
    try athrhPrimeThread(oldId)
    var newId: String?
    switch path {
    case "new":
        #expect(await session.newSession())
        newId = session.sessionId
    case "switch", "import":
        let target = SessionManager.create(directory.path, directory.path)
        _ = target.newSession()
        _ = target.appendMessage(.user(UserMessage(content: .text("target"))))
        let file = try #require(target.getSessionFile())
        if path == "switch" {
            #expect(await session.switchSession(file))
        } else {
            let result = try await session.importFromJsonl(file)
            #expect(!result.cancelled)
        }
        newId = session.sessionId
    case "fork":
        let entry = session.sessionManager.appendMessage(.user(UserMessage(content: .text("fork"))))
        #expect(!(try await session.fork(entry)).cancelled)
        newId = session.sessionId
    case "clone":
        _ = session.sessionManager.appendMessage(.user(UserMessage(content: .text("clone"))))
        #expect(try await session.cloneAtLeaf())
        newId = session.sessionId
    case "dispose":
        session.dispose()
        newId = athrhMakeSession(.inMemory(directory.path)).sessionId
    case "runtime-replace", "runtime-dispose":
        let runtime = AgentSessionRuntime(agentDir: directory.path,
            factory: { args in athrhMakeSession(args.sessionManager) }, initialSession: session)
        if path == "runtime-replace" {
            let next = try await runtime.replaceSession(args: AgentSessionRuntimeFactoryArgs(
                cwd: directory.path, agentDir: directory.path,
                sessionManager: .inMemory(directory.path),
                sessionStartEvent: AgentSessionStartEvent(reason: .new)))
            newId = next.sessionId
            runtime.dispose()
        } else {
            runtime.dispose()
            newId = athrhMakeSession(.inMemory(directory.path)).sessionId
        }
    default: Issue.record("Unknown path \(path)")
    }
    let freshId = try #require(newId)
    #expect(freshId != oldId)
    let store = AnthropicMessageThreadStore.shared
    let oldRequest = try #require(try store.prepare(model: athrhThreadModel, sessionId: oldId,
        fullBody: athrhNextBody, betas: nil))
    #expect(try athrhThreadType(oldRequest) == "create")
    let newRequest = try #require(try store.prepare(model: athrhThreadModel, sessionId: freshId,
        fullBody: athrhNextBody, betas: nil))
    #expect(try athrhThreadType(newRequest) == "create")
    try cleanupSessionResources(oldId)
    try cleanupSessionResources(freshId)
    session.dispose()
}
