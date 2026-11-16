import Foundation
import Testing
@testable import PiSwiftAI

private enum CacheCaptureError: Error { case captured }
private actor CacheCaptureClient: ProviderHTTPClient {
    var body: Data?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        body = request.httpBody
        throw CacheCaptureError.captured
    }
}

@Suite("Anthropic cache serialization")
struct AnthropicCacheSerializationTests {
    @Test(arguments: ["test-key", "sk-ant-oat01-test-token"])
    func outgoingHistoryHasStableNestedKeyOrder(apiKey: String) async throws {
        let model = Model(id: "claude-sonnet-4-5", name: "Test", api: .anthropicMessages,
            provider: "anthropic", baseUrl: "https://cache-test.invalid", reasoning: false,
            input: [.text], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 200_000, maxTokens: 4096)
        var previous: Data?
        for _ in 0..<8 {
            let call = ToolCall(id: "call_1", name: "edit", arguments: [
                "path": AnyCodable("Main.lua"),
                "edits": AnyCodable([["oldText": "before", "newText": "after", "options": ["z": 1, "a": 2]]])
            ])
            let assistant = AssistantMessage(content: [.toolCall(call)], api: model.api,
                provider: model.provider, model: model.id,
                usage: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
            let context = Context(messages: [
                .user(UserMessage(content: .text("Edit the project"))), .assistant(assistant),
                .toolResult(ToolResultMessage(toolCallId: call.id, toolName: call.name,
                    content: [.text(TextContent(text: "Updated"))], isError: false))
            ])
            let client = CacheCaptureClient()
            _ = await streamAnthropic(model: model, context: normalizeContext(context),
                options: AnthropicOptions(apiKey: apiKey, httpClient: client, cacheRetention: .short, maxRetries: 0)).result()
            let body = try #require(await client.body)
            let object = try JSONSerialization.jsonObject(with: body)
            let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(body == canonical)
            if let previous { #expect(body == previous) }
            previous = body
            let payload = try #require(object as? [String: Any])
            let messages = try #require(payload["messages"] as? [[String: Any]])
            #expect(messages.count == 3)
            let blocks = try #require(messages[1]["content"] as? [[String: Any]])
            let input = try #require(blocks.first?["input"] as? [String: Any])
            #expect(input["path"] as? String == "Main.lua")
            let results = try #require(messages[2]["content"] as? [[String: Any]])
            #expect(results.last?["cache_control"] != nil)
        }
    }
}
