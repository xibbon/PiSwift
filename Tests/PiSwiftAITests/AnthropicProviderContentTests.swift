import Foundation
import Testing
@testable import PiSwiftAI

/// Answers each request with the next of `responses`, repeating the last.
private actor ServerToolHTTP: ProviderHTTPClient {
    let bodies: [Data]
    var requests: [URLRequest] = []
    init(events: [[String: Any]]...) throws {
        bodies = try events.map { events in
            var body = Data()
            for event in events {
                body.append(Data("event: \(event["type"] as? String ?? "error")\ndata: ".utf8))
                body.append(try JSONSerialization.data(withJSONObject: event))
                body.append(Data("\n\n".utf8))
            }
            return body
        }
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"],
            body: bodies[min(requests.count, bodies.count) - 1])
    }
    func body(_ index: Int) -> Data { requests[index].httpBody ?? Data() }
}

private func serverToolModel(_ id: String = "claude-test") -> Model {
    Model(id: id, name: id, api: .anthropicMessages, provider: "anthropic", baseUrl: "https://example.invalid",
        reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 4096)
}

private var searchResult: [String: Any] { ["type": "web_search_result", "url": "https://example.com/a",
    "title": "A", "encrypted_content": "opaque", "page_age": "1 day"] }
private var citation: [String: Any] { ["type": "web_search_result_location", "url": "https://example.com/a",
    "title": "A", "encrypted_index": "idx", "cited_text": "cited"] }

private func reply(_ blocks: [(start: [String: Any], deltas: [[String: Any]])], id: String = "msg-1",
                   stopReason: String = "end_turn") -> [[String: Any]] {
    var events: [[String: Any]] = [["type": "message_start", "message": ["type": "message", "role": "assistant",
        "content": [], "id": id, "model": "claude-test", "usage": ["input_tokens": 1, "output_tokens": 0]]]]
    for (index, block) in blocks.enumerated() {
        events.append(["type": "content_block_start", "index": index, "content_block": block.start])
        events += block.deltas.map { ["type": "content_block_delta", "index": index, "delta": $0] }
        events.append(["type": "content_block_stop", "index": index])
    }
    return events + [["type": "message_delta", "delta": ["stop_reason": stopReason], "usage": ["output_tokens": 1]],
                     ["type": "message_stop"]]
}

private var searchReply: [[String: Any]] { searchEvents() }

private func searchEvents(stopReason: String = "end_turn") -> [[String: Any]] { reply([
    (["type": "text", "text": ""], [["type": "text_delta", "text": "Searching."]]),
    (["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": [:]],
     [["type": "input_json_delta", "partial_json": "{\"query\": "], ["type": "input_json_delta", "partial_json": "\"codea\"}"]]),
    (["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [searchResult]], []),
    (["type": "text", "text": "", "citations": NSNull()],
     [["type": "citations_delta", "citation": citation], ["type": "text_delta", "text": "Found it."]]),
], stopReason: stopReason) }

private var expectedBlocks: [[String: Any]] { [
    ["type": "text", "text": "Searching."],
    ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "codea"]],
    ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [searchResult]],
    ["type": "text", "text": "Found it.", "citations": [citation]],
] }

private func options(_ client: ServerToolHTTP) -> AnthropicOptions {
    var options = AnthropicOptions()
    options.apiKey = "fixture-key"
    options.httpClient = client
    return options
}

private func stream(_ client: ServerToolHTTP, model: Model = serverToolModel(), messages: [Message]) async -> AssistantMessage {
    await streamAnthropic(model: model, context: normalizeContext(Context(messages: messages)), options: options(client)).result()
}

private func wireMessages(_ body: Data) throws -> [[String: Any]] {
    (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
}

private func same(_ a: Any?, _ b: Any) -> Bool {
    guard let a else { return false }
    return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
}

@Test(.timeLimit(.minutes(1))) func anthropicKeepsAndReplaysServerToolBlocks() async throws {
    let client = try ServerToolHTTP(events: searchReply)
    let question = Message.user(UserMessage(content: .text("search")))
    let answer = await stream(client, messages: [question])
    #expect(answer.stopReason == .stop)
    #expect(answer.content.count == 2)
    #expect(same(answer.providerContent?.value, expectedBlocks))

    _ = await stream(client, messages: [question, .assistant(answer), .user(UserMessage(content: .text("next")))])
    let messages = try wireMessages(await client.body(1))
    #expect(messages.count == 3)
    #expect(same(messages[1]["content"], expectedBlocks))
}

@Test(.timeLimit(.minutes(1))) func anthropicConvertsServerToolRepliesForAnotherModel() async throws {
    let client = try ServerToolHTTP(events: searchReply)
    let question = Message.user(UserMessage(content: .text("search")))
    let answer = await stream(client, messages: [question])
    _ = await stream(client, model: serverToolModel("claude-other"),
        messages: [question, .assistant(answer), .user(UserMessage(content: .text("next")))])
    let messages = try wireMessages(await client.body(1))
    let types = (messages[1]["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
    #expect(types == ["text", "text"])
}

@Test(.timeLimit(.minutes(1))) func anthropicLeavesPlainRepliesWithoutProviderContent() async throws {
    let client = try ServerToolHTTP(events: reply([(["type": "text", "text": ""], [["type": "text_delta", "text": "Hi."]])]))
    let answer = await stream(client, messages: [.user(UserMessage(content: .text("hello")))])
    #expect(answer.providerContent == nil)
}

@Test func providerContentSurvivesMessageJSON() throws {
    var message = AssistantMessage(content: [.text(TextContent(text: "Found it."))], api: .anthropicMessages,
        provider: "anthropic", model: "claude-test", responseId: "msg-1",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
    message.providerContent = AnyCodable(expectedBlocks)
    let object = assistantMessageToJSONObject(message)
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = assistantMessageFromJSONObject(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    #expect(same(decoded.providerContent?.value, expectedBlocks))
}

// A follow-up can cite an earlier search without a new server tool call.
@Test(.timeLimit(.minutes(1))) func anthropicKeepsAndReplaysCitedTextWithoutServerToolBlocks() async throws {
    let cited: [[String: Any]] = [["type": "text", "text": "Found it.", "citations": [citation]]]
    let client = try ServerToolHTTP(events: reply([
        (["type": "text", "text": "", "citations": [Any]()],
         [["type": "citations_delta", "citation": citation], ["type": "text_delta", "text": "Found it."]]),
    ]))
    let question = Message.user(UserMessage(content: .text("which page?")))
    let answer = await stream(client, messages: [question])
    #expect(same(answer.providerContent?.value, cited))

    let restored = assistantMessageFromJSONObject(assistantMessageToJSONObject(answer))
    _ = await stream(client, messages: [question, .assistant(restored), .user(UserMessage(content: .text("next")))])
    #expect(same(try wireMessages(await client.body(1))[1]["content"], cited))
}

@Test(.timeLimit(.minutes(1))) func anthropicLeavesTextWithEmptyCitationsWithoutProviderContent() async throws {
    let client = try ServerToolHTTP(events: reply([
        (["type": "text", "text": "", "citations": [Any]()], [["type": "text_delta", "text": "Hi."]]),
    ]))
    let answer = await stream(client, messages: [.user(UserMessage(content: .text("hello")))])
    #expect(answer.providerContent == nil)
}

// The API rejects text blocks without visible characters, so the replay must not send them.
@Test(.timeLimit(.minutes(1))) func anthropicReplayDropsBlocksTheAPIRejects() async throws {
    let client = try ServerToolHTTP(events: reply([
        (["type": "text", "text": ""], []),
        (["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "codea"]], []),
        (["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [searchResult]], []),
        (["type": "text", "text": ""], [["type": "text_delta", "text": "\n\n"]]),
        (["type": "text", "text": ""], [["type": "text_delta", "text": "Found it."]]),
    ]))
    let question = Message.user(UserMessage(content: .text("search")))
    let answer = await stream(client, messages: [question])
    _ = await stream(client, messages: [question, .assistant(answer), .user(UserMessage(content: .text("next")))])
    let content = try wireMessages(await client.body(1))[1]["content"] as? [[String: Any]] ?? []
    #expect(content.compactMap { $0["type"] as? String } == ["server_tool_use", "web_search_tool_result", "text"])
    #expect(content.last?["text"] as? String == "Found it.")
}

// A reply that holds only server tool blocks has empty `content` but still has a wire message.
@Test func anthropicManagedEffortMarkersStayAlignedWithReplayedReplies() throws {
    let model = Model(id: "claude-test", name: "claude-test", api: .anthropicMessages, provider: "anthropic",
        baseUrl: "https://example.invalid", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 200_000, maxTokens: 4096,
        compat: OpenAICompat(forceAdaptiveThinking: true, supportsMidConvoEffort: true))
    func assistant(_ id: String, level: String, content: [ContentBlock]) -> AssistantMessage {
        AssistantMessage(content: content, api: .anthropicMessages, provider: "anthropic", model: "claude-test",
            responseId: id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
            stopReason: .stop, providerThinkingLevel: level)
    }
    var searchOnly = assistant("msg-1", level: "low", content: [])
    searchOnly.providerContent = AnyCodable(Array(expectedBlocks[1...2]))
    let user = Message.user(UserMessage(content: .text("next")))
    let context = Context(messages: [user, .assistant(searchOnly), user,
        .assistant(assistant("msg-2", level: "max", content: [.text(TextContent(text: "answer"))])), user])
    let wire: [[String: Any]] = [
        ["role": "user", "content": "next"], ["role": "assistant", "content": Array(expectedBlocks[1...2])],
        ["role": "user", "content": "next"], ["role": "assistant", "content": [["type": "text", "text": "answer"]]],
        ["role": "user", "content": "next"],
    ]
    let body = try JSONSerialization.data(withJSONObject: ["messages": wire])
    let payload = try #require(JSONSerialization.jsonObject(with: prepareAnthropicRawPayload(body, model: model,
        context: context, options: AnthropicOptions(thinkingEnabled: true, effort: .high))) as? [String: Any])
    let messages = payload["messages"] as? [[String: Any]] ?? []
    let efforts = messages.map { ($0["output_config"] as? [String: String])?["effort"] ?? ($0["role"] as? String ?? "") }
    #expect(efforts == ["user", "low", "assistant", "user", "max", "assistant", "user", "high"])
}

@Test(.timeLimit(.minutes(1))) func anthropicContinuesAPausedTurnIntoOneReply() async throws {
    let client = try ServerToolHTTP(events: searchEvents(stopReason: "pause_turn"),
        reply([(["type": "text", "text": ""], [["type": "text_delta", "text": " Done."]])], id: "msg-2"))
    let question = Message.user(UserMessage(content: .text("search")))
    let events = streamAnthropic(model: serverToolModel(), context: normalizeContext(Context(messages: [question])),
        options: options(client))
    var streamed: [Int: String] = [:]
    var finished = 0
    for await event in events {
        if case .textDelta(let index, let delta, _) = event { streamed[index, default: ""] += delta }
        if case .done = event { finished += 1 }
    }
    let answer = await events.result()

    #expect(await client.requests.count == 2)
    let continued = try wireMessages(await client.body(1))
    #expect(continued.count == 2)
    #expect(same(continued[1]["content"], expectedBlocks))

    #expect(finished == 1)
    #expect(answer.stopReason == .stop)
    #expect(answer.responseId == "msg-2")
    #expect(answer.diagnostics?.map(\.type) == ["anthropic_pause_turn"])
    let texts = answer.content.compactMap { block -> String? in if case .text(let text) = block { return text.text }; return nil }
    #expect(texts == ["Searching.", "Found it.", " Done."])
    #expect(streamed == [0: "Searching.", 1: "Found it.", 2: " Done."])
    #expect(same(answer.providerContent?.value, expectedBlocks + [["type": "text", "text": " Done."]]))
}

private func events(_ client: ServerToolHTTP) async -> (events: [AssistantMessageEvent], answer: AssistantMessage) {
    let stream = streamAnthropic(model: serverToolModel(),
        context: normalizeContext(Context(messages: [.user(UserMessage(content: .text("search")))])), options: options(client))
    var events: [AssistantMessageEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

@Test(.timeLimit(.minutes(1))) func anthropicStopsAfterTheMaximumContinuations() async throws {
    let client = try ServerToolHTTP(events: searchEvents(stopReason: "pause_turn"))
    let (events, answer) = await events(client)
    #expect(await client.requests.count == anthropicMaximumContinuations + 1)
    #expect(events.filter { if case .done = $0 { return true }; return false }.count == 1)
    #expect(answer.stopReason == .stop)
    #expect(answer.rawStopReason == "pause_turn")
    #expect(answer.content.count == 2 * (anthropicMaximumContinuations + 1))
}

@Test(.timeLimit(.minutes(1))) func anthropicReportsAnErrorInAContinuationWithThePausedContent() async throws {
    let client = try ServerToolHTTP(events: searchEvents(stopReason: "pause_turn"),
        reply([(["type": "text", "text": ""], [["type": "text_delta", "text": " Do"]])], id: "msg-2", stopReason: "refusal"))
    let (events, answer) = await events(client)
    #expect(await client.requests.count == 2)
    #expect(events.filter { if case .done = $0 { return true }; return false }.isEmpty)
    #expect(events.filter { if case .error = $0 { return true }; return false }.count == 1)
    #expect(answer.stopReason == .error)
    #expect(answer.content.count == 3)
}

// A paused part without blocks adds no message to the next request, so that request would repeat.
@Test(.timeLimit(.minutes(1))) func anthropicDoesNotContinueAPausedTurnWithoutBlocks() async throws {
    let client = try ServerToolHTTP(events: reply([], stopReason: "pause_turn"))
    let (_, answer) = await events(client)
    #expect(await client.requests.count == 1)
    #expect(answer.stopReason == .stop)
}

// The partial messages of a continuation keep the paused reply's wire blocks as they are.
@Test(.timeLimit(.minutes(1))) func anthropicContinuationPartialsKeepThePausedBlocks() async throws {
    let client = try ServerToolHTTP(events: searchEvents(stopReason: "pause_turn"),
        reply([(["type": "text", "text": ""], [["type": "text_delta", "text": " Done."]])], id: "msg-2"))
    let (events, answer) = await events(client)
    let partials = events.compactMap { event -> AssistantMessage? in
        if case .textDelta(2, _, let partial) = event { return partial }
        return nil
    }
    #expect(partials.count == 1)
    #expect(same(partials.first?.providerContent?.value, expectedBlocks))
    #expect(partials.first?.content.count == 3)
    #expect(same(answer.providerContent?.value, expectedBlocks + [["type": "text", "text": " Done."]]))
}
