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
        var requests = Set<Data>()
        for attempt in 0..<8 {
            let fields = [("oldText", "before"), ("newText", "after")]
            let edit = Dictionary(uniqueKeysWithValues: attempt.isMultiple(of: 2) ? fields : fields.reversed())
            let call = ToolCall(id: "call_1", name: "edit", arguments: [
                "path": AnyCodable("Main.lua"),
                "edits": AnyCodable([edit])
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
            requests.insert(try #require(await client.body))
        }
        // Replaying unchanged history must not invalidate its prompt-cache prefix.
        #expect(requests.count == 1)
    }
}
