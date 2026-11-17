import Foundation
import Testing
@testable import PiSwiftAI

private actor ServerToolHTTP: ProviderHTTPClient {
    let body: Data
    var requests: [URLRequest] = []
    init(events: [[String: Any]]) throws {
        var body = Data()
        for event in events {
            body.append(Data("event: \(event["type"] as? String ?? "error")\ndata: ".utf8))
            body.append(try JSONSerialization.data(withJSONObject: event))
            body.append(Data("\n\n".utf8))
        }
        self.body = body
    }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return ProviderHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: body)
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

private func reply(_ blocks: [(start: [String: Any], deltas: [[String: Any]])]) -> [[String: Any]] {
    var events: [[String: Any]] = [["type": "message_start", "message": ["type": "message", "role": "assistant",
        "content": [], "id": "msg-1", "model": "claude-test", "usage": ["input_tokens": 1, "output_tokens": 0]]]]
    for (index, block) in blocks.enumerated() {
        events.append(["type": "content_block_start", "index": index, "content_block": block.start])
        events += block.deltas.map { ["type": "content_block_delta", "index": index, "delta": $0] }
        events.append(["type": "content_block_stop", "index": index])
    }
    return events + [["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
                     ["type": "message_stop"]]
}

private var searchReply: [[String: Any]] { reply([
    (["type": "text", "text": ""], [["type": "text_delta", "text": "Searching."]]),
    (["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": [:]],
     [["type": "input_json_delta", "partial_json": "{\"query\": "], ["type": "input_json_delta", "partial_json": "\"codea\"}"]]),
    (["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [searchResult]], []),
    (["type": "text", "text": "", "citations": NSNull()],
     [["type": "citations_delta", "citation": citation], ["type": "text_delta", "text": "Found it."]]),
]) }

private var expectedBlocks: [[String: Any]] { [
    ["type": "text", "text": "Searching."],
    ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "codea"]],
    ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [searchResult]],
    ["type": "text", "text": "Found it.", "citations": [citation]],
] }

private func stream(_ client: ServerToolHTTP, model: Model = serverToolModel(), messages: [Message]) async -> AssistantMessage {
    var options = AnthropicOptions()
    options.apiKey = "fixture-key"
    options.httpClient = client
    return await streamAnthropic(model: model, context: normalizeContext(Context(messages: messages)), options: options).result()
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
