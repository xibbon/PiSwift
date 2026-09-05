import Foundation
import Testing
@testable import PiSwiftAI

private func frameSeed(_ content: [ContentBlock] = []) -> AssistantMessage {
    AssistantMessage(content: content, api: .openAIResponses, provider: "test-provider", model: "test-model",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .pending, timestamp: 1)
}
private func requiredFrame(_ encoder: inout AssistantMessageFrameEncoder, _ event: AssistantMessageEvent) throws -> AssistantMessageFrame {
    let frame = try encoder.encode(event)
    return try #require(frame)
}
private func frameContents(_ frames: [AssistantMessageFrame]) throws -> [AnyCodable] {
    try #require(try reduceAssistantMessageFrames(frames)).content.map { AnyCodable(contentBlockToJSONObject($0)) }
}
private func frameTool(_ arguments: [String: AnyCodable] = [:]) -> ToolCall { ToolCall(id: "call", name: "run", arguments: arguments) }

@Test func framesAuthoritativeTextEnd() throws {
    var encoder = AssistantMessageFrameEncoder()
    var partial = frameSeed()
    var frames = [try requiredFrame(&encoder, .start(partial: partial))]
    partial.content = [.text(TextContent(text: "Hello "))]
    frames.append(try requiredFrame(&encoder, .textStart(contentIndex: 0, partial: partial)))
    partial.content = [.text(TextContent(text: "Hello world", textSignature: "sig-text"))]
    frames.append(try requiredFrame(&encoder, .textDelta(contentIndex: 0, delta: "incorrect", partial: partial)))
    frames.append(try requiredFrame(&encoder, .textEnd(contentIndex: 0, content: "Hello world", partial: partial)))
    #expect(try frameContents(frames) == [AnyCodable(["type": "text", "text": "Hello world", "textSignature": "sig-text"])])
}
@Test func framesPreserveProviderThinkingLevel() throws {
    var partial = frameSeed(); partial.providerThinkingLevel = "high"
    var encoder = AssistantMessageFrameEncoder()
    let start = try requiredFrame(&encoder, .start(partial: partial))
    #expect(try reduceAssistantMessageFrames([start])?.providerThinkingLevel == "high")
}
@Test func framesPreserveThinkingMetadata() throws {
    var encoder = AssistantMessageFrameEncoder()
    var partial = frameSeed()
    var frames = [try requiredFrame(&encoder, .start(partial: partial))]
    partial.content = [.thinking(ThinkingContent(thinking: "[redacted]", thinkingSignature: "encrypted-start", redacted: true))]
    frames.append(try requiredFrame(&encoder, .thinkingStart(contentIndex: 0, partial: partial)))
    partial.content = [.thinking(ThinkingContent(thinking: "[redacted]", thinkingSignature: "encrypted-final", redacted: true))]
    frames.append(try requiredFrame(&encoder, .thinkingEnd(contentIndex: 0, content: "[redacted]", partial: partial)))
    #expect(try frameContents(frames) == partial.content.map { AnyCodable(contentBlockToJSONObject($0)) })
}
@Test func framesUnfinishedAndFinalToolArguments() throws {
    var frames: [AssistantMessageFrame] = [.start(partial: frameSeed()), .toolCallStart(contentIndex: 0, toolCall: frameTool()),
        .toolCallDelta(contentIndex: 0, delta: "{\"path\":\"READ")]
    let unfinished = try #require(try reduceAssistantMessageFrames(frames))
    guard case .toolCall(let tool) = unfinished.content[0] else { Issue.record("Expected tool"); return }
    #expect(tool.arguments["path"] == AnyCodable("READ"))
    let final = ToolCall(id: "final-id", name: "write_file", arguments: ["path": AnyCodable("final.md"), "lines": AnyCodable([3])], thoughtSignature: "thought", namespace: "files")
    frames += [.toolCallDelta(contentIndex: 0, delta: "ME.md\",\"lines\":[1,2]}"), .toolCallEnd(contentIndex: 0, toolCall: final)]
    #expect(try frameContents(frames) == [AnyCodable(contentBlockToJSONObject(.toolCall(final)))])
}

private struct FrameHTTPClient: ProviderHTTPClient {
    let data: Data
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse { ProviderHTTPResponse(statusCode: 200, body: data) }
}
@Test func framesRoundTripAuthoritativeResponsesEndEvents() async throws {
    let sse = """
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg","content":[]}}

    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg","content":[{"type":"output_text","text":"final text"}]}}

    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc","call_id":"call","name":"lookup","arguments":""}}

    data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc","call_id":"call","name":"lookup","arguments":"{\"value\":\"final\"}","namespace":"tools"}}

    data: {"type":"response.completed","response":{"status":"completed"}}

    """
    let model = Model(id: "test", name: "test", api: .openAIResponses, provider: "openai", baseUrl: "https://example.test/v1", reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 100)
    let stream = streamOpenAIResponses(model: model, context: Context(messages: []), options: OpenAIResponsesOptions(apiKey: "test", httpClient: FrameHTTPClient(data: Data(sse.utf8))))
    var encoder = AssistantMessageFrameEncoder(); var frames: [AssistantMessageFrame] = []
    for await event in stream { if let frame = try encoder.encode(event) { frames.append(frame) } }
    let output = await stream.result()
    #expect(try frameContents(frames) == output.content.map { AnyCodable(contentBlockToJSONObject($0)) })
    #expect(output.content.contains { if case .text(let text) = $0 { text.text == "final text" } else { false } })
}
@Test func framesQueuedTextDoesNotDuplicate() throws {
    let partial = frameSeed([.text(TextContent(text: "Hello world"))])
    let events: [AssistantMessageEvent] = [.start(partial: partial), .textStart(contentIndex: 0, partial: partial)]
        + ["Hel", "lo", " ", "world"].map { .textDelta(contentIndex: 0, delta: $0, partial: partial) }
    var encoder = AssistantMessageFrameEncoder()
    let frames = try events.compactMap { try encoder.encode($0) }
    #expect(frames.map(\.type) == ["start", "text_start"])
    #expect(try frameContents(frames) == [AnyCodable(["type": "text", "text": "Hello world"])])
}
@Test func framesTrimCoveredDeltaPrefix() throws {
    let partial = frameSeed([.text(TextContent(text: "Hel"))]); var encoder = AssistantMessageFrameEncoder()
    var frames = [try requiredFrame(&encoder, .start(partial: partial)), try requiredFrame(&encoder, .textStart(contentIndex: 0, partial: partial))]
    #expect(try encoder.encode(.textDelta(contentIndex: 0, delta: "He", partial: partial)) == nil)
    frames.append(try requiredFrame(&encoder, .textDelta(contentIndex: 0, delta: "llo", partial: partial)))
    #expect(try frameContents(frames) == [AnyCodable(["type": "text", "text": "Hello"])])
}
@Test func framesCheckpointQueuedToolJSON() throws {
    let partial = frameSeed([.toolCall(frameTool(["path": AnyCodable("README.md")]))]); var encoder = AssistantMessageFrameEncoder()
    let events: [AssistantMessageEvent] = [.start(partial: partial), .toolCallStart(contentIndex: 0, partial: partial),
        .toolCallDelta(contentIndex: 0, delta: "{\"path\":\"READ", partial: partial), .toolCallDelta(contentIndex: 0, delta: "ME.md\"}", partial: partial)]
    let frames = try events.compactMap { try encoder.encode($0) }
    #expect(frames.map(\.type) == ["start", "toolcall_start", "toolcall_checkpoint"])
    #expect(try frameContents(frames) == partial.content.map { AnyCodable(contentBlockToJSONObject($0)) })
}
@Test func framesResumeLegacyGrammarJSON() throws {
    let partial = frameSeed([.toolCall(frameTool(["input": AnyCodable("a")]))]); var encoder = AssistantMessageFrameEncoder()
    let events: [AssistantMessageEvent] = [.start(partial: partial), .toolCallStart(contentIndex: 0, partial: partial),
        .toolCallDelta(contentIndex: 0, delta: "{\"input\":\"ab", partial: partial), .toolCallDelta(contentIndex: 0, delta: "c\"}", partial: partial)]
    let frames = try events.compactMap { try encoder.encode($0) }
    #expect(frames.map(\.type) == ["start", "toolcall_start", "toolcall_checkpoint", "toolcall_delta"])
    #expect(try frameContents(frames) == [AnyCodable(contentBlockToJSONObject(.toolCall(frameTool(["input": AnyCodable("abc")]))))])
}
@Test func framesStreamEmptyToolJSON() throws {
    let partial = frameSeed([.toolCall(frameTool())]); var encoder = AssistantMessageFrameEncoder()
    let events: [AssistantMessageEvent] = [.start(partial: partial), .toolCallStart(contentIndex: 0, partial: partial),
        .toolCallDelta(contentIndex: 0, delta: "{\"command\":\"ls -la /tmp\"}", partial: partial)]
    let frames = try events.compactMap { try encoder.encode($0) }
    #expect(frames.last?.type == "toolcall_delta")
    #expect(try frameContents(frames) == [AnyCodable(contentBlockToJSONObject(.toolCall(frameTool(["command": AnyCodable("ls -la /tmp")]))))])
}
@Test func framesAcceptErrorBeforeStartButRejectSuccessAndUpdates() throws {
    var encoder = AssistantMessageFrameEncoder()
    #expect(try encoder.encode(.error(reason: .error, error: frameSeed())) == nil)
    var success = AssistantMessageFrameEncoder()
    #expect(throws: AssistantMessageFrameError.self) { try success.encode(.done(reason: .stop, message: frameSeed())) }
    var update = AssistantMessageFrameEncoder()
    #expect(throws: AssistantMessageFrameError.self) { try update.encode(.textDelta(contentIndex: 0, delta: "x", partial: frameSeed())) }
}
@Test func framesEndMetadataAbsenceIsAuthoritative() throws {
    let frames: [AssistantMessageFrame] = [.start(partial: frameSeed()),
        .textStart(contentIndex: 0, content: TextContent(text: "", textSignature: "stale")), .textEnd(contentIndex: 0, content: ""),
        .thinkingStart(contentIndex: 1, content: ThinkingContent(thinking: "", thinkingSignature: "stale", redacted: true)),
        .thinkingEnd(contentIndex: 1, content: "", thinkingSignature: "", redacted: false),
        .toolCallStart(contentIndex: 2, toolCall: ToolCall(id: "call", name: "run", arguments: [:], thoughtSignature: "stale", namespace: "stale")),
        .toolCallEnd(contentIndex: 2, toolCall: frameTool())]
    #expect(try frameContents(frames) == [AnyCodable(["type": "text", "text": ""]),
        AnyCodable(["type": "thinking", "thinking": "", "thinkingSignature": "", "redacted": false]), AnyCodable(contentBlockToJSONObject(.toolCall(frameTool())))])
}
@Test func framesStoreFinalToolArgumentsAndSignatures() throws {
    let tool = ToolCall(id: "call-1", name: "read", arguments: ["path": AnyCodable("README.md")], thoughtSignature: "thought", namespace: "files")
    let partial = frameSeed([.toolCall(tool)]); var encoder = AssistantMessageFrameEncoder()
    _ = try encoder.encode(.start(partial: partial)); _ = try encoder.encode(.toolCallStart(contentIndex: 0, partial: partial))
    let end = try requiredFrame(&encoder, .toolCallEnd(contentIndex: 0, toolCall: tool, partial: partial))
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(end)) as? [String: Any])
    #expect(object["type"] as? String == "toolcall_end")
    #expect(object["thoughtSignature"] as? String == "thought")
    #expect(object["namespace"] as? String == "files")
    #expect((object["arguments"] as? [String: String])?["path"] == "README.md")
}
@Test func framesWhitelistCanonicalBlockFields() throws {
    let source: [String: Any] = ["type": "toolCall", "id": "call", "name": "run", "arguments": [:], "partialJson": "scratch", "streamIndex": 6]
    let content = try #require(contentBlockFromJSONObject(source)); let partial = frameSeed([content])
    var encoder = AssistantMessageFrameEncoder()
    let start = try requiredFrame(&encoder, .start(partial: partial))
    let block = try requiredFrame(&encoder, .toolCallStart(contentIndex: 0, partial: partial))
    let data = try JSONEncoder().encode([start, block]); let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("partialJson")); #expect(!text.contains("streamIndex"))
    #expect(try reduceAssistantMessageFrames([start])?.content.isEmpty == true)
}
@Test func framesSupportInterleavedBlocks() throws {
    let tool = ToolCall(id: "call", name: "lookup", arguments: ["query": AnyCodable("pi")])
    let frames: [AssistantMessageFrame] = [.start(partial: frameSeed()), .textStart(contentIndex: 0, content: TextContent(text: "")),
        .toolCallStart(contentIndex: 1, toolCall: frameTool()), .thinkingStart(contentIndex: 2, content: ThinkingContent(thinking: "")),
        .textDelta(contentIndex: 0, delta: "answer"), .toolCallDelta(contentIndex: 1, delta: "{\"query\":\"pi\"}"),
        .thinkingDelta(contentIndex: 2, delta: "check"), .toolCallEnd(contentIndex: 1, toolCall: tool),
        .textEnd(contentIndex: 0, content: "answer"), .thinkingEnd(contentIndex: 2, content: "check")]
    #expect(try frameContents(frames) == [AnyCodable(["type": "text", "text": "answer"]), AnyCodable(contentBlockToJSONObject(.toolCall(tool))), AnyCodable(["type": "thinking", "thinking": "check"])])
}
@Test func framesSnapshotValuesAndReduceWithoutMutation() throws {
    var partial = frameSeed(); partial.diagnostics = [AssistantMessageDiagnostic(type: "test", timestamp: 2, details: ["value": AnyCodable("original")])]
    var encoder = AssistantMessageFrameEncoder(); let start = try requiredFrame(&encoder, .start(partial: partial))
    partial.diagnostics?[0].details["value"] = AnyCodable("mutated"); partial.usage.cost.total = 99
    let tool = frameTool(["nested": AnyCodable(["value": "original"])])
    partial.content = [.toolCall(tool)]
    let toolStart = try requiredFrame(&encoder, .toolCallStart(contentIndex: 0, partial: partial))
    partial.content = [.toolCall(frameTool(["nested": AnyCodable("mutated")]))]
    var result = try #require(try reduceAssistantMessageFrames([start, toolStart]))
    #expect(result.diagnostics?[0].details["value"] == AnyCodable("original")); #expect(result.usage.cost.total == 0)
    result.content = []
    #expect(try frameContents([start, toolStart]) == [AnyCodable(contentBlockToJSONObject(.toolCall(tool)))])
}
@Test func framesOmitTerminalSettlement() throws {
    var encoder = AssistantMessageFrameEncoder(); _ = try encoder.encode(.start(partial: frameSeed()))
    #expect(try encoder.encode(.done(reason: .stop, message: frameSeed())) == nil)
    #expect(throws: AssistantMessageFrameError.self) { try encoder.encode(.start(partial: frameSeed())) }
    var failed = AssistantMessageFrameEncoder()
    #expect(try failed.encode(.error(reason: .error, error: frameSeed())) == nil)
}
@Test func framesWithoutStartReturnNil() throws {
    #expect(try reduceAssistantMessageFrames([AssistantMessageFrame]()) == nil)
    #expect(try reduceAssistantMessageFrames([.textDelta(contentIndex: 0, delta: "x")]) == nil)
}
@Test func framesRejectInvalidSequences() throws {
    let cases: [[AssistantMessageFrame]] = [
        [.textDelta(contentIndex: 0, delta: "x"), .start(partial: frameSeed())],
        [.start(partial: frameSeed()), .toolCallStart(contentIndex: 0, toolCall: frameTool()), .textDelta(contentIndex: 0, delta: "wrong")],
        [.start(partial: frameSeed()), .textStart(contentIndex: 0, content: TextContent(text: "")), .textEnd(contentIndex: 0, content: ""), .textEnd(contentIndex: 0, content: "")],
        [.start(partial: frameSeed()), .textStart(contentIndex: 1, content: TextContent(text: ""))],
    ]
    for frames in cases { #expect(throws: AssistantMessageFrameError.self) { try reduceAssistantMessageFrames(frames) } }
}
@Test func framesRejectWrongEventBlockKind() throws {
    var encoder = AssistantMessageFrameEncoder(); _ = try encoder.encode(.start(partial: frameSeed()))
    #expect(throws: AssistantMessageFrameError.self) { try encoder.encode(.textStart(contentIndex: 0, partial: frameSeed([.thinking(ThinkingContent(thinking: ""))]))) }
}
@Test func framesJSONRoundTrip() throws {
    let frames: [AssistantMessageFrame] = [.start(partial: frameSeed()), .toolCallStart(contentIndex: 0, toolCall: frameTool()),
        .toolCallCheckpoint(contentIndex: 0, json: "{\"a\":1}"), .toolCallEnd(contentIndex: 0, toolCall: frameTool(["a": AnyCodable(1)]))]
    let decoded = try JSONDecoder().decode([AssistantMessageFrame].self, from: JSONEncoder().encode(frames))
    #expect(try frameContents(decoded) == frameContents(frames))
}

@Test func framesRetainNestedPartialJSONAndEscapedStrings() throws {
    let frames: [AssistantMessageFrame] = [.start(partial: frameSeed()),
        .toolCallStart(contentIndex: 0, toolCall: frameTool()),
        .toolCallDelta(contentIndex: 0, delta: "{\"items\":[{\"path\":\"line\\nREAD")]
    let result = try #require(try reduceAssistantMessageFrames(frames))
    guard case .toolCall(let tool) = result.content[0] else { Issue.record("Expected tool"); return }
    #expect(tool.arguments["items"] == AnyCodable([["path": "line\nREAD"]]))
}
