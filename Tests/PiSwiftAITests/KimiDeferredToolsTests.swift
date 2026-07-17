import Foundation
import Testing
@testable import PiSwiftAI

private final class KimiDeferredToolsURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "kimi-deferred.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = """
        data: {"id":"chatcmpl-kimi","object":"chat.completion.chunk","created":0,"model":"kimi-test","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func kimiModel() -> Model {
    Model(
        id: "kimi-test",
        name: "Kimi Test",
        api: .openAICompletions,
        provider: "moonshotai",
        baseUrl: "https://kimi-deferred.example/v1",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000,
        maxTokens: 4_096,
        compat: OpenAICompat(deferredToolsMode: .kimi)
    )
}

private func kimiTools() -> [AITool] {
    [
        AITool(
            name: "search",
            description: "Search the web",
            parameters: ["type": AnyCodable("object")]
        ),
        AITool(
            name: "read",
            description: "Read a file",
            parameters: ["type": AnyCodable("object")]
        ),
    ]
}

private func kimiAssistantToolCalls(_ calls: [(id: String, name: String)]) -> Message {
    .assistant(AssistantMessage(
        content: calls.map { .toolCall(ToolCall(id: $0.id, name: $0.name, arguments: [:])) },
        api: .openAICompletions,
        provider: "moonshotai",
        model: "kimi-test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse,
        timestamp: 0
    ))
}

private func kimiToolResult(id: String, addedToolNames: [String]) -> Message {
    .toolResult(ToolResultMessage(
        toolCallId: id,
        toolName: "loader",
        content: [.text(TextContent(text: "loaded"))],
        addedToolNames: addedToolNames,
        isError: false,
        timestamp: 0
    ))
}

private func captureKimiPayload(messages: [Message]) async throws -> [String: Any] {
    let capturedJSON = LockedState<String?>(nil)
    let stream = streamOpenAICompletions(
        model: kimiModel(),
        context: Context(messages: messages, tools: kimiTools()),
        options: OpenAICompletionsOptions(
            apiKey: "test-key",
            onPayload: { snapshot in
                capturedJSON.withLock { $0 = snapshot.json }
            }
        )
    )
    _ = await stream.result()

    let json = try #require(capturedJSON.withLock { $0 })
    let data = try #require(json.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func functionName(_ tool: [String: Any]) -> String? {
    (tool["function"] as? [String: Any])?["name"] as? String
}

@Suite(.serialized)
struct KimiDeferredToolsTests {
    init() {
        URLProtocol.registerClass(KimiDeferredToolsURLProtocol.self)
    }

    @Test func activeToolsOmitDeferredToolAndSystemMessageDeclaresIt() async throws {
        let payload = try await captureKimiPayload(messages: [
            kimiAssistantToolCalls([(id: "call-1", name: "loader")]),
            kimiToolResult(id: "call-1", addedToolNames: ["search"]),
        ])

        let activeToolNames = try #require(payload["tools"] as? [[String: Any]]).compactMap(functionName)
        #expect(activeToolNames == ["read"])

        let messages = try #require(payload["messages"] as? [[String: Any]])
        let toolResultIndex = try #require(messages.firstIndex { $0["role"] as? String == "tool" })
        let systemIndex = try #require(messages.firstIndex { $0["role"] as? String == "system" })
        #expect(systemIndex == toolResultIndex + 1)

        let systemMessage = messages[systemIndex]
        #expect(systemMessage["content"] == nil)
        let declaredTools = try #require(systemMessage["tools"] as? [[String: Any]])
        #expect(declaredTools.compactMap(functionName) == ["search"])
        let searchFunction = try #require(declaredTools[0]["function"] as? [String: Any])
        #expect(searchFunction["description"] as? String == "Search the web")
    }

    @Test func consecutiveToolResultsEmitOneDeduplicatedSystemMessageInToolOrder() async throws {
        let payload = try await captureKimiPayload(messages: [
            kimiAssistantToolCalls([
                (id: "call-1", name: "loader"),
                (id: "call-2", name: "loader"),
            ]),
            kimiToolResult(id: "call-1", addedToolNames: ["search", "search"]),
            kimiToolResult(id: "call-2", addedToolNames: ["read", "search"]),
            .user(UserMessage(content: .text("continue"), timestamp: 0)),
        ])

        let messages = try #require(payload["messages"] as? [[String: Any]])
        let systemMessages = messages.filter { $0["role"] as? String == "system" }
        #expect(systemMessages.count == 1)
        let declaredTools = try #require(systemMessages[0]["tools"] as? [[String: Any]])
        #expect(declaredTools.compactMap(functionName) == ["search", "read"])
    }

    @Test func separateToolResultRunsEachEmitTheirOwnSystemMessage() async throws {
        let payload = try await captureKimiPayload(messages: [
            kimiAssistantToolCalls([(id: "call-1", name: "loader")]),
            kimiToolResult(id: "call-1", addedToolNames: ["search"]),
            kimiAssistantToolCalls([(id: "call-2", name: "loader")]),
            kimiToolResult(id: "call-2", addedToolNames: ["search"]),
            .user(UserMessage(content: .text("continue"), timestamp: 0)),
        ])

        let messages = try #require(payload["messages"] as? [[String: Any]])
        let systemMessages = messages.filter { $0["role"] as? String == "system" }
        #expect(systemMessages.count == 2)
        for message in systemMessages {
            let declaredTools = try #require(message["tools"] as? [[String: Any]])
            #expect(declaredTools.compactMap(functionName) == ["search"])
            #expect(message["content"] == nil)
        }
    }

    @Test func unknownAddedToolDoesNotLeakSentinel() async throws {
        let payload = try await captureKimiPayload(messages: [
            kimiAssistantToolCalls([(id: "call-1", name: "loader")]),
            kimiToolResult(id: "call-1", addedToolNames: ["missing"]),
            .user(UserMessage(content: .text("continue"), timestamp: 0)),
        ])

        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(!messages.contains { $0["role"] as? String == "system" })
        #expect(!String(describing: payload).contains("__PI_KIMI_DEFERRED_TOOLS__"))
        let activeToolNames = try #require(payload["tools"] as? [[String: Any]]).compactMap(functionName)
        #expect(activeToolNames == ["search", "read"])
    }
}
