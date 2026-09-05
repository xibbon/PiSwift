import Foundation
import Testing
@testable import PiSwiftAI

private let bedrockHeaderAuditModelID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
private let bedrockHeaderAuditHost = "bedrock-response-audit.invalid"

private final class BedrockHeaderAuditProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == bedrockHeaderAuditHost }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "content-type": "application/vnd.amazon.eventstream", "x-amzn-requestid": "req-123",
            "x-bifrost-provider": "bedrock", "x-bifrost-resolved-model": bedrockHeaderAuditModelID,
        ]) else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func bedrockHeaderAuditModel() -> Model {
    Model(id: bedrockHeaderAuditModelID, name: "Haiku", api: .bedrockConverseStream, provider: "amazon-bedrock",
        baseUrl: "https://\(bedrockHeaderAuditHost)", reasoning: true, input: [.text],
        cost: ModelCost(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25), contextWindow: 200_000, maxTokens: 4096)
}

@Test func bedrockForwardsActualResponseHeadersBeforeEmptyStreamFails() async throws {
    try await codexRequestLock.withLock {
        #expect(URLProtocol.registerClass(BedrockHeaderAuditProtocol.self))
        defer { URLProtocol.unregisterClass(BedrockHeaderAuditProtocol.self) }
        let responses = LockedState<[ResponseSnapshot]>([])
        let result = await streamBedrock(model: bedrockHeaderAuditModel(),
            context: Context(messages: [.user(UserMessage(content: .text("hello")))]),
            options: BedrockOptions(region: "us-east-1", cacheRetention: .none, bearerToken: "fixture-token",
                onResponse: { snapshot in responses.withLock { $0.append(snapshot) } }, timeoutMs: 5000, maxRetries: 0)).result()
        #expect(result.stopReason == .error)
        #expect(result.errorMessage?.contains("without a stop reason") == true)
        let snapshots = responses.withLock { $0 }
        #expect(snapshots.count == 1)
        let response = try #require(snapshots.first)
        #expect(response.statusCode == 200)
        let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
        #expect(headers["x-amzn-requestid"] == "req-123")
        #expect(headers["x-bifrost-provider"] == "bedrock")
        #expect(headers["x-bifrost-resolved-model"] == bedrockHeaderAuditModelID)
    }
}

@Test func bedrockPreservesEmptyArgumentKeysUntilReplay() throws {
    let model = bedrockHeaderAuditModel()
    var output = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .pending)
    var state = BedrockStreamState()
    let stream = AssistantMessageEventStream()
    let input = #"{"path":"/workspace/foobar/file.js","edits":[{"oldText":"first","newText":"updated first"},{"oldText":"second","newText":"updated second","":""}]}"#
    let events: [(String, [String: Any])] = [
        ("messageStart", ["role": "assistant"]),
        ("contentBlockStart", ["contentBlockIndex": 0, "start": ["toolUse": ["toolUseId": "tool-1", "name": "edit"]]]),
        ("contentBlockDelta", ["contentBlockIndex": 0, "delta": ["toolUse": ["input": input]]]),
        ("contentBlockStop", ["contentBlockIndex": 0]), ("messageStop", ["stopReason": "tool_use"]),
    ]
    for (type, payload) in events {
        try processBedrockFixture(type: type, payload: JSONSerialization.data(withJSONObject: payload), model: model,
            output: &output, state: &state, stream: stream)
    }
    finalizeBedrockBlocks(output: &output, state: &state)
    stream.end()
    #expect(output.stopReason == .toolUse)
    guard case .toolCall(let call) = try #require(output.content.first) else { Issue.record("Missing tool call"); return }
    let originalEdits = try #require(call.arguments["edits"]?.value as? [[String: Any]])
    #expect(originalEdits[1][""] as? String == "")
    let context = Context(messages: [.assistant(output),
        .toolResult(ToolResultMessage(toolCallId: "tool-1", toolName: "edit", content: [.text(TextContent(text: "done"))], isError: false)),
        .user(UserMessage(content: .text("Continue")))])
    let body = try bedrockReplayFixture(context: context, model: model)
    let messages = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
    let blocks = try #require(assistant["content"] as? [[String: Any]])
    let tool = try #require(blocks.first?["toolUse"] as? [String: Any])
    let replayedInput = try #require(tool["input"] as? [String: Any])
    let replayedEdits = try #require(replayedInput["edits"] as? [[String: Any]])
    #expect(replayedEdits[1][""] == nil)
    #expect(replayedEdits[1]["newText"] as? String == "updated second")
    #expect(originalEdits[1][""] as? String == "")
}
