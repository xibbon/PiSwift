import Foundation
import Testing
@testable import PiSwiftAI

private actor ThreadHTTPClient: ProviderHTTPClient {
    private var scripted: [ProviderHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ scripted: [ProviderHTTPResponse]) { self.scripted = scripted }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return scripted.isEmpty ? threadSuccess("msg_extra") : scripted.removeFirst()
    }
    func bodies() -> [Data] { requests.map { $0.httpBody ?? Data() } }
    func headers() -> [String?] { requests.map { $0.value(forHTTPHeaderField: "anthropic-beta") } }
}

private actor GatedThreadHTTPClient: ProviderHTTPClient {
    private var held: CheckedContinuation<Void, Never>?
    private var count = 0
    private(set) var requests: [Data] = []

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        count += 1
        requests.append(request.httpBody ?? Data())
        let current = count
        if current == 1 {
            await withCheckedContinuation { held = $0 }
        }
        return threadSuccess(current == 1 ? "msg_late" : "msg_next")
    }

    func requestCount() -> Int { count }
    func release() { held?.resume(); held = nil }
}

private func threadBodies(_ client: ThreadHTTPClient) async throws -> [[String: Any]] {
    try await client.bodies().map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
}

private func threadWire(_ id: String, text: String = "Done") -> String {
    let start = "{\"type\":\"message_start\",\"message\":{\"id\":\"\(id)\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}"
    let block = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\(text)\"}}"
    let delta = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}"
    let wire = "event: message_start\ndata: \(start)\n\nevent: content_block_start\ndata: \(block)\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: \(delta)\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    return wire
}

private func threadSuccess(_ id: String, text: String = "Done") -> ProviderHTTPResponse {
    ProviderHTTPResponse(statusCode: 200, body: Data(threadWire(id, text: text).utf8))
}

private func threadToolSuccess(_ id: String, name: String = "lookup") -> ProviderHTTPResponse {
    let start = #"{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":0}}}"#
    let text = #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"answer"}}"#
    let tool = #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":{}}}"#
    let input = #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"value\":\"x\"}"}}"#
    let delta = #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#
    let events = [("message_start", start), ("content_block_start", text),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", tool), ("content_block_delta", input),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", delta), ("message_stop", #"{"type":"message_stop"}"#)]
    let wire = events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    return ProviderHTTPResponse(statusCode: 200, body: Data(wire.utf8))
}

private func threadServerToolSuccess(_ id: String) -> ProviderHTTPResponse {
    let start = #"{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":0}}}"#
    let use = #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"swift"}}}"#
    let result = #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://example.com","title":"Result","encrypted_content":"opaque"}]}}"#
    let delta = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#
    let events = [("message_start", start), ("content_block_start", use),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", result), ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", delta), ("message_stop", #"{"type":"message_stop"}"#)]
    let wire = events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    return ProviderHTTPResponse(statusCode: 200, body: Data(wire.utf8))
}

private func threadToolResult(_ name: String = "lookup") -> Message {
    .toolResult(ToolResultMessage(toolCallId: "toolu_1", toolName: name,
        content: [.text(TextContent(text: "result"))], isError: false, timestamp: 2))
}

private func threadIncomplete(_ kind: String) -> ProviderHTTPResponse {
    if kind == "stream error" {
        return ProviderHTTPResponse(statusCode: 200, body: Data(
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"stream failed\"}}\n\n".utf8))
    }
    var wire = threadWire("msg_bad")
    if kind == "early end" {
        let marker = "event: message_stop"
        if let range = wire.range(of: marker) { wire = String(wire[..<range.lowerBound]) }
    } else if kind == "refusal" {
        wire = wire.replacingOccurrences(of: #""stop_reason":"end_turn""#,
            with: #""stop_reason":"refusal""#)
    } else if kind == "fallback model" {
        wire = wire.replacingOccurrences(of: #""model":"claude-haiku-4-5""#,
            with: #""model":"claude-fallback""#)
    }
    return ProviderHTTPResponse(statusCode: 200, body: Data(wire.utf8))
}

private func threadError(_ code: String?, status: Int = 400, message: String = "thread rejected") -> ProviderHTTPResponse {
    var error: [String: Any] = ["type": "invalid_request_error", "message": message]
    if let code { error["details"] = ["error_code": code] }
    let body = (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": error])) ?? Data()
    return ProviderHTTPResponse(statusCode: status, body: body)
}

private func threadModel(compat: OpenAICompat? = nil, baseUrl: String = "https://api.anthropic.com",
    provider: String = "anthropic", id: String = "claude-haiku-4-5", reasoning: Bool = false) -> Model {
    Model(id: id, name: "Test Claude", api: .anthropicMessages,
        provider: provider, baseUrl: baseUrl, reasoning: reasoning, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 100, compat: compat)
}

private func threadContext(_ messages: [Message], system: String = "You are helpful", tools: [AITool]? = nil) -> TranscriptContext {
    normalizeContext(Context(systemPrompt: system, messages: messages, tools: tools))
}

private func threadTool(_ name: String) -> AITool {
    AITool(name: name, description: "Look up", parameters: ["type": AnyCodable("object")])
}

private func threadUser(_ text: String, _ timestamp: Int64 = 1) -> Message {
    .user(UserMessage(content: .text(text), timestamp: timestamp))
}

private func threadOptions(_ client: ThreadHTTPClient, session: String = UUID().uuidString,
    retention: CacheRetention = .short, disable: Bool? = nil) -> AnthropicOptions {
    AnthropicOptions(apiKey: "test-key", httpClient: client, cacheRetention: retention,
        sessionId: session, disableContinuation: disable, maxRetries: 0)
}

private func checkThreadRefusal(_ code: String, status: Int) async throws {
    let client = ThreadHTTPClient([threadSuccess("msg_a"), threadError(code, status: status), threadSuccess("msg_b")])
    var options = threadOptions(client)
    defer { try? cleanupSessionResources(options.sessionId) }
    let payloadCalls = LockedState(0)
    options.onPayload = { _ in payloadCalls.withLock { $0 += 1 }; return nil }
    let model = threadModel()
    let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
    let second = await streamAnthropic(model: model,
        context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)]), options: options).result()
    let bodies = try await threadBodies(client)
    #expect(second.stopReason == .stop)
    #expect(bodies.count == 3)
    #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
    #expect((bodies[2]["thread"] as? [String: String])?["type"] == "create")
    #expect((bodies[2]["messages"] as? [[String: Any]])?.count == 3)
    #expect(second.diagnostics?.first?.type == "anthropic_thread_fallback")
    #expect(second.diagnostics?.first?.details["reason"]?.value as? String == code)
    #expect(payloadCalls.withLock { $0 } == 2)
}

private func checkUnsupportedThread(_ code: String?, message: String) async throws {
    let client = ThreadHTTPClient([threadSuccess("msg_a"), threadError(code, message: message),
        threadSuccess("msg_b"), threadSuccess("msg_c")])
    let options = threadOptions(client)
    defer { try? cleanupSessionResources(options.sessionId) }
    let model = threadModel()
    let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
    let next = threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)])
    let second = await streamAnthropic(model: model, context: next, options: options).result()
    #expect(second.stopReason == .stop)
    _ = await streamAnthropic(model: model, context: next, options: options).result()
    let bodies = try await threadBodies(client)
    #expect(bodies.count == 4)
    #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
    #expect(bodies[2]["thread"] == nil)
    #expect(bodies[3]["thread"] == nil)
    #expect(second.diagnostics?.first?.type == "anthropic_thread_fallback")
    #expect(second.diagnostics?.first?.details["reason"]?.value as? String == (code ?? "400"))
    let headers = await client.headers()
    #expect(headers[3] == headers[0])
}

private func checkUnrelatedThreadError(_ status: Int, _ message: String) async throws {
    let client = ThreadHTTPClient([threadSuccess("msg_a"), threadError(nil, status: status, message: message),
        threadSuccess("msg_b")])
    let options = threadOptions(client)
    defer { try? cleanupSessionResources(options.sessionId) }
    let model = threadModel()
    let first = await streamAnthropic(model: model, context: threadContext([threadUser("first")]), options: options).result()
    let next = threadContext([threadUser("first"), .assistant(first), threadUser("second", 2)])
    let failed = await streamAnthropic(model: model, context: next, options: options).result()
    #expect(failed.stopReason == .error)
    #expect(failed.errorMessage?.contains(message) == true)
    #expect(failed.diagnostics == nil)
    #expect(await client.bodies().count == 2)
    _ = await streamAnthropic(model: model, context: next, options: options).result()
    let bodies = try await threadBodies(client)
    #expect((bodies[2]["thread"] as? [String: String])?["type"] == "create")
}

private func checkExplicitBetaOverride(_ header: String?) async throws {
    let client = ThreadHTTPClient([threadError(nil, message: "thread: Extra inputs are not permitted"),
        threadSuccess("msg_a"), threadSuccess("msg_b")])
    var options = threadOptions(client)
    options.headers = ["anthropic-beta": header]
    defer { try? cleanupSessionResources(options.sessionId) }
    let model = threadModel()
    let first = await streamAnthropic(model: model, context: threadContext([threadUser("first")]), options: options).result()
    #expect(first.stopReason == .stop)
    _ = await streamAnthropic(model: model, context: threadContext([threadUser("second")]), options: options).result()
    let bodies = try await threadBodies(client)
    #expect(bodies.count == 3)
    #expect((bodies[0]["thread"] as? [String: String])?["type"] == "create")
    #expect(bodies[1]["thread"] == nil)
    #expect(bodies[2]["thread"] == nil)
    #expect(await client.headers().allSatisfy { $0?.contains("message-threads-2026-08-12") != true })
}

@Suite("Anthropic message threads v1.5.2")
struct AnthropicMessageThreadsTests {
    @Test("enables threads for an alias provider on the Anthropic endpoint with a server tool reply")
    func aliasProviderContinuesAfterServerToolReply() async throws {
        let client = ThreadHTTPClient([threadServerToolSuccess("msg_alias"),
            threadSuccess("msg_next"), threadSuccess("msg_replay")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel(provider: "anthropic-alias")
        let first = await streamAnthropic(model: model,
            context: threadContext([threadUser("search")]), options: options).result()
        #expect(first.stopReason == .stop)
        #expect(first.providerContent != nil)
        let second = await streamAnthropic(model: model,
            context: threadContext([threadUser("search"), .assistant(first), threadUser("more", 2)]),
            options: options).result()
        #expect(second.stopReason == .stop)
        let third = await streamAnthropic(model: model,
            context: threadContext([threadUser("search"), .assistant(first), threadUser("more", 2),
                .assistant(second), threadUser("again", 3)], system: "Changed prompt"), options: options).result()
        #expect(third.stopReason == .stop)
        let bodies = try await threadBodies(client)
        #expect((bodies[0]["thread"] as? [String: String]) == ["type": "create"])
        #expect((bodies[1]["thread"] as? [String: String]) ==
            ["type": "continue", "previous_message_id": "msg_alias"])
        let messages = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect((bodies[2]["thread"] as? [String: String]) == ["type": "create"])
        let replay = try #require(bodies[2]["messages"] as? [[String: Any]])
        let replayBlocks = try #require(replay[1]["content"] as? [[String: Any]])
        #expect(replayBlocks.map { $0["type"] as? String ?? "" } ==
            ["server_tool_use", "web_search_tool_result"])
        #expect(await client.headers().allSatisfy { $0?.contains("message-threads-2026-08-12") == true })

        let gateway = ThreadHTTPClient([threadSuccess("msg_gateway")])
        let gatewayOptions = threadOptions(gateway)
        defer { try? cleanupSessionResources(gatewayOptions.sessionId) }
        _ = await streamAnthropic(model: threadModel(baseUrl: "https://gateway.example.com"),
            context: threadContext([threadUser("first")]), options: gatewayOptions).result()
        let gatewayBody = try await threadBodies(gateway)[0]
        #expect(gatewayBody["thread"] == nil)
        #expect(await gateway.headers().allSatisfy { $0?.contains("message-threads-2026-08-12") != true })
    }

    @Test("creates a thread, then continues it with only the new messages")
    func createsAndContinues() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_first"), threadSuccess("msg_second")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        #expect(first.stopReason == .stop)
        let second = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("Again", 2)]), options: options).result()
        #expect(second.stopReason == .stop)
        let bodies = try await threadBodies(client)
        #expect((bodies[0]["thread"] as? [String: String])?["type"] == "create")
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
        #expect((bodies[1]["thread"] as? [String: String])?["previous_message_id"] == "msg_first")
        #expect((bodies[1]["messages"] as? [[String: Any]])?.count == 1)
        #expect(bodies[1]["system"] == nil)
        #expect(await client.headers().allSatisfy { $0?.contains("message-threads-2026-08-12") == true })
    }

    @Test("continues after a reply that ends in tool calls, without placeholder results in the prefix")
    func toolCallTailContinues() async throws {
        let client = ThreadHTTPClient([threadToolSuccess("msg_tool"), threadSuccess("msg_next")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let tools = [threadTool("lookup")]
        let first = await streamAnthropic(model: model,
            context: threadContext([threadUser("look it up")], tools: tools), options: options).result()
        #expect(first.stopReason == .toolUse)
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("look it up"), .assistant(first), threadToolResult()], tools: tools),
            options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
        #expect((bodies[1]["thread"] as? [String: String])?["previous_message_id"] == "msg_tool")
        let messages = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "tool_result")
        #expect(content.first?["tool_use_id"] as? String == "toolu_1")
    }

    @Test("matches Claude Code tool names across turns with OAuth")
    func oauthToolNamesContinue() async throws {
        let client = ThreadHTTPClient([threadToolSuccess("msg_oauth", name: "Read"), threadSuccess("msg_next")])
        var options = threadOptions(client)
        options.apiKey = "sk-ant-oat-test"
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let tools = [threadTool("read")]
        let first = await streamAnthropic(model: model,
            context: threadContext([threadUser("read it")], tools: tools), options: options).result()
        let call = first.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }.first
        #expect(call?.name == "read")
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("read it"), .assistant(first), threadToolResult("read")], tools: tools),
            options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
        #expect((bodies[1]["thread"] as? [String: String])?["previous_message_id"] == "msg_oauth")
    }

    @Test("continues when the effort level changes between turns")
    func changedPerMessageEffortContinues() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        var options = threadOptions(client)
        options.thinkingEnabled = true
        options.effort = .high
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel(compat: OpenAICompat(forceAdaptiveThinking: true,
            supportsMidConvoEffort: true), reasoning: true)
        let first = await streamAnthropic(model: model,
            context: threadContext([threadUser("first")]), options: options).result()
        var nextOptions = options
        nextOptions.effort = .low
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("first"), .assistant(first), threadUser("second", 2)]),
            options: nextOptions).result()
        let bodies = try await threadBodies(client)
        let initial = try #require(bodies[0]["messages"] as? [[String: Any]])
        let next = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(initial.map { ($0["output_config"] as? [String: String])?["effort"] ?? ($0["role"] as? String ?? "") } == ["user", "high"])
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
        #expect(next.map { ($0["output_config"] as? [String: String])?["effort"] ?? ($0["role"] as? String ?? "") } == ["user", "low"])
    }

    @Test("continues when a system message with a native tool change follows the reply")
    func inlineToolChangeContinues() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel(compat: OpenAICompat(supportsMidConvoSystemMessages: true,
            supportsMidConvoToolChanges: true))
        let first = await streamAnthropic(model: model,
            context: threadContext([threadUser("first")], tools: [threadTool("lookup")]), options: options).result()
        let update = Message.system(SystemMessage(content: .text("Update"),
            toolsAdded: [threadTool("other")], timestamp: 2))
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("first"), .assistant(first), update, threadUser("second", 3)],
                tools: [threadTool("lookup")]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "continue")
        let messages = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String ?? "" } == ["user", "system"])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
        #expect(text.contains("tool_addition"))
    }

    @Test("creates a new thread when the system prompt changes")
    func systemChangeCreatesNewThread() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)], system: "Different"),
            options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "create")
        #expect((bodies[1]["messages"] as? [[String: Any]])?.count == 3)
    }

    private func checkSettingsChange(_ kind: String) async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        var options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let firstModel = threadModel(reasoning: kind == "thinking level")
        if kind == "thinking level" { options.thinkingEnabled = true; options.thinkingBudgetTokens = 1024 }
        let initialTools = kind == "tools" ? [threadTool("lookup")] : nil
        let first = await streamAnthropic(model: firstModel,
            context: threadContext([threadUser("Hi")], tools: initialTools), options: options).result()
        var nextOptions = options
        var nextModel = firstModel
        var nextTools = initialTools
        switch kind {
        case "tools": nextTools = [threadTool("lookup"), threadTool("other")]
        case "model": nextModel = threadModel(id: "claude-other")
        case "tool choice": nextOptions.toolChoice = .any
        case "cache retention": nextOptions.cacheRetention = .long
        case "thinking level": nextOptions.thinkingBudgetTokens = 2048
        default: break
        }
        _ = await streamAnthropic(model: nextModel,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)], tools: nextTools),
            options: nextOptions).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "create")
        #expect((bodies[1]["messages"] as? [[String: Any]])?.count == 3)
    }

    @Test("creates a new thread when the tools changes")
    func toolsChangeCreatesNewThread() async throws { try await checkSettingsChange("tools") }

    @Test("creates a new thread when the model changes")
    func modelChangeCreatesNewThread() async throws { try await checkSettingsChange("model") }

    @Test("creates a new thread when the tool choice changes")
    func toolChoiceChangeCreatesNewThread() async throws { try await checkSettingsChange("tool choice") }

    @Test("creates a new thread when the cache retention changes")
    func cacheRetentionChangeCreatesNewThread() async throws { try await checkSettingsChange("cache retention") }

    @Test("creates a new thread when the thinking level changes")
    func thinkingLevelChangeCreatesNewThread() async throws { try await checkSettingsChange("thinking level") }

    @Test("creates a new thread when the request has no messages beyond the stored prefix")
    func noNewMessagesCreatesThread() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first)]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "create")
    }

    @Test("creates a new thread after an edit of earlier history")
    func historyEditCreatesThread() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Edited"), .assistant(first), threadUser("More", 2)]), options: options).result()
        let body = try await threadBodies(client)[1]
        #expect((body["thread"] as? [String: String])?["type"] == "create")
    }

    private func checkUnsuccessfulReplyIsNotRecorded(_ kind: String) async throws {
        let client = ThreadHTTPClient([threadIncomplete(kind), threadSuccess("msg_after")])
        var options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        if kind == "abort" {
            let signal = CancellationToken()
            options.signal = signal
            options.onProviderStreamEvent = { _, _ in signal.cancel() }
        }
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        options.signal = nil
        options.onProviderStreamEvent = nil
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "create")
    }

    @Test("does not record an aborted reply")
    func abortedReplyIsNotRecorded() async throws { try await checkUnsuccessfulReplyIsNotRecorded("abort") }

    @Test("does not record a stream error")
    func streamErrorIsNotRecorded() async throws { try await checkUnsuccessfulReplyIsNotRecorded("stream error") }

    @Test("does not record a stream that ends early")
    func earlyEndIsNotRecorded() async throws { try await checkUnsuccessfulReplyIsNotRecorded("early end") }

    @Test("does not record a refusal")
    func refusalIsNotRecorded() async throws { try await checkUnsuccessfulReplyIsNotRecorded("refusal") }

    @Test("does not record a fallback model reply")
    func fallbackModelReplyIsNotRecorded() async throws { try await checkUnsuccessfulReplyIsNotRecorded("fallback model") }

    @Test("uses the supportsMessageThreads compatibility override in both directions", arguments: [false, true])
    func compatibilityOverride(_ enabled: Bool) async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel(compat: OpenAICompat(supportsMessageThreads: enabled),
            baseUrl: enabled ? "https://proxy.invalid" : "https://api.anthropic.com")
        _ = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        let body = try await threadBodies(client)[0]
        #expect((body["thread"] != nil) == enabled)
    }

    @Test("starts a new thread with the full request after thread_not_found")
    func refusalCreatesNewThread() async throws {
        try await checkThreadRefusal("thread_not_found", status: 404)
    }

    @Test("starts a new thread with the full request after thread_already_continued")
    func alreadyContinuedCreatesNewThread() async throws {
        try await checkThreadRefusal("thread_already_continued", status: 400)
    }

    @Test("starts a new thread with the full request after thread_continue_in_flight")
    func inFlightCreatesNewThread() async throws {
        try await checkThreadRefusal("thread_continue_in_flight", status: 400)
    }

    @Test("starts a new thread with the full request after thread_fingerprint_mismatch")
    func fingerprintMismatchCreatesNewThread() async throws {
        try await checkThreadRefusal("thread_fingerprint_mismatch", status: 400)
    }

    @Test("turns threads off after unsupported-request code")
    func unsupportedTurnsOff() async throws {
        let client = ThreadHTTPClient([threadError("thread_unsupported_request"), threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        _ = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        _ = await streamAnthropic(model: model, context: threadContext([threadUser("Again")]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect(bodies.count == 3)
        #expect(bodies[0]["thread"] != nil)
        #expect(bodies[1]["thread"] == nil)
        #expect(bodies[2]["thread"] == nil)
    }

    @Test("turns threads off for the session after thread_unsupported_request on continue")
    func unsupportedCodeTurnsOffAfterResend() async throws {
        try await checkUnsupportedThread("thread_unsupported_request", message: "rejected")
    }

    @Test("turns threads off for the session after a 400 without error code about the thread field on continue")
    func uncodedThreadErrorTurnsOffAfterResend() async throws {
        try await checkUnsupportedThread(nil, message: "thread: Extra inputs are not permitted")
    }

    @Test("shows the error when the resend fails too and keeps threads on")
    func failedResendKeepsThreadsOn() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"),
            threadError(nil, message: "thread: Extra inputs are not permitted"),
            threadError(nil, message: "Real problem"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("first")]), options: options).result()
        let next = threadContext([threadUser("first"), .assistant(first), threadUser("second", 2)])
        let failed = await streamAnthropic(model: model, context: next, options: options).result()
        #expect(failed.stopReason == .error)
        #expect(failed.errorMessage?.contains("Real problem") == true)
        _ = await streamAnthropic(model: model, context: next, options: options).result()
        let bodies = try await threadBodies(client)
        #expect(bodies.count == 4)
        #expect((bodies[3]["thread"] as? [String: String])?["type"] == "create")
    }

    @Test("passes a 400 that is not about the thread on without resending")
    func unrelated400Surfaces() async throws { try await checkUnrelatedThreadError(400, "prompt is too long") }

    @Test("passes a 404 that is not about the thread on without resending")
    func unrelated404Surfaces() async throws { try await checkUnrelatedThreadError(404, "model: unknown") }

    @Test("leaves strict tool rejections to the strict tool fallback")
    func strictFallbackKeepsThread() async throws {
        let grammar = "The compiled grammar is too large, which would cause performance issues. Simplify your tool schemas or reduce the number of strict tools."
        let client = ThreadHTTPClient([threadError(nil, message: grammar), threadSuccess("msg_a")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel(compat: OpenAICompat(supportsStrictTools: true))
        let tool = AITool(name: "lookup", description: "Look up",
            parameters: ["type": AnyCodable("object"), "properties": AnyCodable([String: Any]())],
            constrainedSampling: .jsonSchema(strict: .prefer))
        let result = await streamAnthropic(model: model,
            context: threadContext([threadUser("first")], tools: [tool]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect(result.stopReason == .stop)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { ($0["thread"] as? [String: String])?["type"] == "create" })
        #expect(result.diagnostics?.map(\.type) == ["anthropic_strict_tools_fallback"])
    }

    @Test("starts a new thread when a retried continue finds the thread in flight")
    func retriedContinueInFlightStartsNewThread() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"),
            threadError(nil, status: 503, message: "overloaded"),
            threadError("thread_continue_in_flight", message: "in flight"), threadSuccess("msg_b")])
        var options = threadOptions(client)
        options.maxRetries = 1
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("first")]), options: options).result()
        let second = await streamAnthropic(model: model,
            context: threadContext([threadUser("first"), .assistant(first), threadUser("second", 2)]),
            options: options).result()
        let bodies = try await threadBodies(client)
        #expect(second.stopReason == .stop)
        #expect(bodies.map { ($0["thread"] as? [String: String])?["type"] } == ["create", "continue", "continue", "create"])
    }

    @Test("fails once, then turns threads off, with an explicit anthropic-beta header without the threads beta")
    func explicitBetaWithoutThreadsTurnsOff() async throws {
        try await checkExplicitBetaOverride("fine-grained-tool-streaming-2025-05-14")
    }

    @Test("fails once, then turns threads off, with an explicit anthropic-beta header set to null")
    func explicitNullBetaTurnsOff() async throws {
        try await checkExplicitBetaOverride(nil)
    }

    @Test("does not use threads with cacheRetention none")
    func noCacheNoThreads() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a")])
        let options = threadOptions(client, retention: .none)
        _ = await streamAnthropic(model: threadModel(), context: threadContext([threadUser("Hi")]), options: options).result()
        #expect(try await threadBodies(client)[0]["thread"] == nil)
    }

    @Test("sends cache warming replays without a thread and keeps the conversation's thread")
    func replayKeepsThread() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_warm"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        var warming = options
        warming.disableContinuation = true
        _ = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: warming).result()
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect(bodies[1]["thread"] == nil)
        #expect((bodies[2]["thread"] as? [String: String])?["previous_message_id"] == "msg_a")
    }

    @Test("session id reused after cleanup starts with no thread")
    func cleanupAndReuse() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b")])
        let options = threadOptions(client)
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        try cleanupSessionResources(options.sessionId)
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)]), options: options).result()
        let bodies = try await threadBodies(client)
        #expect((bodies[1]["thread"] as? [String: String])?["type"] == "create")
        try cleanupSessionResources(options.sessionId)
    }

    @Test("two concurrent requests of one session use the saved reply only once")
    func concurrentRequestsTakeContinuationOnce() async throws {
        let client = ThreadHTTPClient([threadSuccess("msg_a"), threadSuccess("msg_b"), threadSuccess("msg_c")])
        let options = threadOptions(client)
        defer { try? cleanupSessionResources(options.sessionId) }
        let model = threadModel()
        let first = await streamAnthropic(model: model, context: threadContext([threadUser("Hi")]), options: options).result()
        let next = threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)])
        async let second = streamAnthropic(model: model, context: next, options: options).result()
        async let third = streamAnthropic(model: model, context: next, options: options).result()
        let results = await (second, third)
        #expect(results.0.stopReason == .stop)
        #expect(results.1.stopReason == .stop)
        let bodies = try await threadBodies(client)
        let kinds = bodies.dropFirst().compactMap { ($0["thread"] as? [String: String])?["type"] }
        #expect(kinds.sorted() == ["continue", "create"])
    }

    @Test("cleanup during a request in flight prevents a late state write")
    func cleanupDuringRequestPreventsLateState() async throws {
        let client = GatedThreadHTTPClient()
        let sessionId = UUID().uuidString
        let options = AnthropicOptions(apiKey: "test-key", httpClient: client, cacheRetention: .short,
            sessionId: sessionId, maxRetries: 0)
        let model = threadModel()
        let firstTask = Task { await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi")]), options: options).result() }
        while await client.requestCount() == 0 { await Task.yield() }
        try cleanupSessionResources(sessionId)
        await client.release()
        let first = await firstTask.value
        #expect(first.stopReason == .stop)
        _ = await streamAnthropic(model: model,
            context: threadContext([threadUser("Hi"), .assistant(first), threadUser("More", 2)]), options: options).result()
        let bodies = await client.requests
        let secondBody = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect((secondBody["thread"] as? [String: String])?["type"] == "create")
        try cleanupSessionResources(sessionId)
    }

    @Test("twenty thousand finished sessions retain at most ten thousand thread entries")
    func finishedSessionsStayBounded() throws {
        let store = AnthropicMessageThreadStore(registerForCleanup: false)
        let model = threadModel()
        let body = Data(#"{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8)
        let reply: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "done"]]]
        for index in 0..<20_000 {
            let request = try #require(try store.prepare(model: model, sessionId: "bounded-\(index)",
                fullBody: body, betas: ["message-threads-2026-08-12"]))
            try store.record(request, model: model, fullBody: body,
                betas: ["message-threads-2026-08-12"], reply: reply, replyId: "msg_\(index)")
        }
        #expect(store.storedSessionCount() == 10_000)
        // The oldest completed session was evicted; the newest remains ready.
        let old = try #require(try store.prepare(model: model, sessionId: "bounded-0", fullBody: body,
            betas: ["message-threads-2026-08-12"]))
        let oldBody = try #require(JSONSerialization.jsonObject(with: old.body) as? [String: Any])
        #expect((oldBody["thread"] as? [String: String])?["type"] == "create")
        #expect(store.storedSessionCount() == 10_000)
    }
}
