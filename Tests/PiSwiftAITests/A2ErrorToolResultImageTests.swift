import Foundation
import Testing
@testable import PiSwiftAI

private actor A2ImageHTTPClient: ProviderHTTPClient {
    var request: URLRequest?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 400, body: Data("fixture request captured".utf8))
    }
}

private func a2ImageModel(bedrock: Bool = false, claude: Bool = true) -> Model {
    let id = claude ? "claude-test" : "amazon.nova-pro-v1:0"
    return Model(id: id, name: id, api: bedrock ? .bedrockConverseStream : .anthropicMessages,
        provider: bedrock ? "amazon-bedrock" : "anthropic", baseUrl: "https://example.invalid",
        reasoning: false, input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000, maxTokens: 1024)
}

private func a2Image(_ data: String) -> ContentBlock { .image(ImageContent(data: data, mimeType: "image/png")) }
private func a2ImageText(_ text: String) -> ContentBlock { .text(TextContent(text: text)) }
private let a2ImageNote = "(image attached after the tool results)"

private func a2ImageContext(model: Model, multipleRuns: Bool = false) -> Context {
    let assistant = AssistantMessage(content: [
        .toolCall(ToolCall(id: "call-1", name: "codemode", arguments: [:])),
        .toolCall(ToolCall(id: "call-2", name: "read", arguments: [:])),
    ], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    var error = [a2ImageText("Script failed"), a2Image("AAAA"), a2Image("CCCC"), a2ImageText("Script error")]
    if multipleRuns { error += [a2Image("DDDD"), a2Image("EEEE"), a2ImageText("Last error"), a2Image("FFFF")] }
    return Context(messages: [.user(UserMessage(content: .text("Show the screenshots"))), .assistant(assistant),
        .toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "codemode", content: error, isError: true)),
        .toolResult(ToolResultMessage(toolCallId: "call-2", toolName: "read", content: [a2Image("BBBB")], isError: false))])
}

private func a2AnthropicImagePayload(_ context: Context, model: Model) async throws -> [String: Any] {
    let client = A2ImageHTTPClient()
    let snapshot = LockedState<Data?>(nil)
    _ = await streamAnthropic(model: model, context: normalizeContext(context),
        options: AnthropicOptions(apiKey: "fake-key", httpClient: client, cacheRetention: .short,
            onPayload: { value in snapshot.withLock { $0 = Data(value.json.utf8) } }, maxRetries: 0)).result()
    let request = try #require(await client.request)
    let body = try #require(request.httpBody)
    let captured = try #require(snapshot.withLock { $0 })
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(NSDictionary(dictionary: payload).isEqual(to: try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])))
    return payload
}

private func a2AnthropicWireImage(_ data: String) -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data]]
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func a2AnthropicErrorImagesFollowAllResultsInSameMessage(_ multipleRuns: Bool) async throws {
    let model = a2ImageModel()
    let context = a2ImageContext(model: model, multipleRuns: multipleRuns)
    let payload = try await a2AnthropicImagePayload(context, model: model)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    var errorText = "Script failed\n\(a2ImageNote)\nScript error"
    var images = ["AAAA", "CCCC"]
    if multipleRuns { errorText += "\n\(a2ImageNote)\nLast error\n\(a2ImageNote)"; images += ["DDDD", "EEEE", "FFFF"] }
    // Short retention puts the cache breakpoint on the last image of this user message.
    var expectedImages = images.map(a2AnthropicWireImage)
    expectedImages[expectedImages.count - 1]["cache_control"] = ["type": "ephemeral"]
    let expected: [String: Any] = ["role": "user", "content": [
        ["type": "tool_result", "tool_use_id": "call-1", "content": errorText, "is_error": true],
        ["type": "tool_result", "tool_use_id": "call-2", "content": [["type": "text", "text": "(see attached image)"], a2AnthropicWireImage("BBBB")], "is_error": false],
        ["type": "text", "text": "Images from the error result of tool call call-1 (codemode):"],
    ] + expectedImages]
    #expect(NSDictionary(dictionary: messages[2]).isEqual(to: expected))
    // Conversion must not remove images from stored history.
    guard case .toolResult(let original) = context.messages[2] else { Issue.record("Missing original tool result"); return }
    #expect(original.content.filter { if case .image = $0 { return true }; return false }.count == images.count)
}

@Test(.timeLimit(.minutes(1))) func a2AnthropicTextOnlyErrorResultIsUnchanged() async throws {
    let model = a2ImageModel()
    let context = Context(messages: [.user(UserMessage(content: .text("Run it"))),
        .toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "codemode", content: [a2ImageText("Script failed")], isError: true))])
    let messages = try #require(try await a2AnthropicImagePayload(context, model: model)["messages"] as? [[String: Any]])
    let expected: [String: Any] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call-1", "content": "Script failed", "is_error": true, "cache_control": ["type": "ephemeral"]]]]
    #expect(NSDictionary(dictionary: messages[1]).isEqual(to: expected))
}

@Test func a2ImageSplitOnlyAppliesToErrorsAndMergesImageRuns() throws {
    let blocks = [a2Image("AAAA"), a2Image("BBBB"), a2ImageText("middle"), a2Image("CCCC"), a2ImageText(a2ImageNote), a2Image("DDDD")]
    let error = ToolResultMessage(toolCallId: "call-1", toolName: "read", content: blocks, isError: true)
    let split = try #require(splitErrorToolResultImages(error))
    #expect(split.images.map(\.data) == ["AAAA", "BBBB", "CCCC", "DDDD"])
    #expect(split.content.compactMap { if case .text(let text) = $0 { return text.text }; return nil } == [a2ImageNote, "middle", a2ImageNote, a2ImageNote])
    var success = error; success.isError = false
    #expect(splitErrorToolResultImages(success) == nil)
    var textOnly = error; textOnly.content = [a2ImageText("error")]
    #expect(splitErrorToolResultImages(textOnly) == nil)
}

@Test(arguments: [false, true]) func a2BedrockClaudeErrorImagesFollowAllResults(_ multipleRuns: Bool) throws {
    let model = a2ImageModel(bedrock: true)
    let context = a2ImageContext(model: model, multipleRuns: multipleRuns)
    let messages = try #require(JSONSerialization.jsonObject(with: bedrockReplayFixture(context: context, model: model)) as? [[String: Any]])
    #expect(messages.count == 3)
    let content = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(content.count == (multipleRuns ? 8 : 5))
    let error = try #require(content[0]["toolResult"] as? [String: Any])
    var text = ["Script failed", a2ImageNote, "Script error"]
    if multipleRuns { text += [a2ImageNote, "Last error", a2ImageNote] }
    #expect(NSDictionary(dictionary: error).isEqual(to: ["toolUseId": "call-1", "content": text.map { ["text": $0] }, "status": "error"]))
    let success = try #require(content[1]["toolResult"] as? [String: Any])
    #expect(success["status"] as? String == "success")
    let nested = try #require(success["content"] as? [[String: Any]])
    #expect(nested.count == 1)
    #expect((nested[0]["image"] as? [String: Any])?["format"] as? String == "png")
    #expect(content[2]["text"] as? String == "Images from the error result of tool call call-1 (codemode):")
    let data = content.dropFirst(3).compactMap { ($0["image"] as? [String: Any])?["source"] as? [String: Any] }.compactMap { $0["bytes"] as? String }
    #expect(data == (multipleRuns ? ["AAAA", "CCCC", "DDDD", "EEEE", "FFFF"] : ["AAAA", "CCCC"]))
}

@Test func a2BedrockNonClaudeKeepsErrorImagesNested() throws {
    let model = a2ImageModel(bedrock: true, claude: false)
    let context = Context(messages: [.toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "codemode",
        content: [a2ImageText("Script failed"), a2Image("AAAA")], isError: true))])
    let messages = try #require(JSONSerialization.jsonObject(with: bedrockReplayFixture(context: context, model: model)) as? [[String: Any]])
    let content = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(content.count == 1)
    let tool = try #require(content[0]["toolResult"] as? [String: Any])
    let nested = try #require(tool["content"] as? [[String: Any]])
    #expect(nested.count == 2)
    #expect(nested[0]["text"] as? String == "Script failed")
    #expect((nested[1]["image"] as? [String: Any])?["format"] as? String == "png")
    #expect(tool["status"] as? String == "error")
}

@Test(.timeLimit(.minutes(1))) func a2AnthropicMultipleErrorCaptionsKeepToolOrder() async throws {
    let model = a2ImageModel()
    let context = Context(messages: [
        .toolResult(ToolResultMessage(toolCallId: "first", toolName: "one", content: [a2Image("AAAA")], isError: true)),
        .toolResult(ToolResultMessage(toolCallId: "second", toolName: "two", content: [a2Image("BBBB"), a2Image("CCCC")], isError: true)),
        .toolResult(ToolResultMessage(toolCallId: "success", toolName: "three", content: [a2ImageText("before"), a2Image("DDDD"), a2ImageText("after")], isError: false)),
    ])
    let payload = try await a2AnthropicImagePayload(context, model: model)
    let messages = try #require(payload["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    let blocks = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(blocks.count == 8)
    #expect(blocks.prefix(3).allSatisfy { $0["type"] as? String == "tool_result" })
    let nested = try #require(blocks[2]["content"] as? [[String: Any]])
    #expect(NSArray(array: nested).isEqual(to: [["type": "text", "text": "before"], a2AnthropicWireImage("DDDD"), ["type": "text", "text": "after"]]))
    var expected: [[String: Any]] = [
        ["type": "text", "text": "Images from the error result of tool call first (one):"], a2AnthropicWireImage("AAAA"),
        ["type": "text", "text": "Images from the error result of tool call second (two):"], a2AnthropicWireImage("BBBB"), a2AnthropicWireImage("CCCC"),
    ]
    expected[expected.count - 1]["cache_control"] = ["type": "ephemeral"]
    #expect(NSArray(array: Array(blocks.dropFirst(3))).isEqual(to: expected))
}
