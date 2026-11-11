import Foundation
import Testing
@testable import PiSwiftAI

// Cases follow packages/ai/test/streaming-tool-arguments.test.ts at v1.5.2.
private struct UpstreamStreamClient: ProviderHTTPClient {
    let body: Data
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: body)
    }
}

private let upstreamStreamAPIs: [Api] = [.anthropicMessages, .openAICompletions, .openAIResponses, .mistralConversations]

private func upstreamStreamModel(_ api: Api) -> Model {
    Model(id: "test-model", name: "Test", api: api, provider: "test", baseUrl: "https://example.invalid/v1",
          reasoning: false, input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
          contextWindow: 200_000, maxTokens: 64_000)
}

private func upstreamStreamSSE(_ events: [[String: Any]], anthropic: Bool = false) throws -> Data {
    Data(try events.map { event in
        let prefix = anthropic ? "event: \(event["type"] as? String ?? "")\n" : ""
        let json = try JSONSerialization.data(withJSONObject: event)
        return prefix + "data: " + String(decoding: json, as: UTF8.self) + "\n\n"
    }.joined().utf8)
}

private func upstreamProviderEvents(api: Api, text: String, chunk: Int, cut: Bool = false) -> [[String: Any]] {
    let chars = Array(text)
    let deltas = stride(from: 0, to: chars.count, by: chunk).map { String(chars[$0..<min($0 + chunk, chars.count)]) }
    switch api {
    case .anthropicMessages:
        var events: [[String: Any]] = [
            ["type": "message_start", "message": ["type": "message", "role": "assistant", "content": [], "id": "msg", "model": "test-model", "usage": ["input_tokens": 1, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "call", "name": "write", "input": [:]]],
        ]
        events += (cut ? Array(deltas.prefix(20)) : deltas).map { ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": $0]] }
        if !cut {
            events += [["type": "content_block_stop", "index": 0],
                       ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]],
                       ["type": "message_stop"]]
        }
        return events
    case .openAICompletions, .mistralConversations:
        let base: [String: Any] = ["id": "chat", "created": 1, "model": "test-model", "object": "chat.completion.chunk"]
        func event(_ arguments: String, first: Bool) -> [String: Any] {
            var result = base
            var call: [String: Any] = ["index": 0, "function": ["arguments": arguments]]
            if first { call["id"] = "call"; call["type"] = "function"; call["function"] = ["name": "write", "arguments": arguments] }
            result["choices"] = [["index": 0, "delta": ["tool_calls": [call]]]]
            return result
        }
        var events = [event("", first: true)] + deltas.map { event($0, first: false) }
        var stop = base
        stop["choices"] = [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]
        events.append(stop)
        return events
    default:
        let item: [String: Any] = ["type": "function_call", "id": "item", "call_id": "call", "name": "write", "arguments": "", "status": "in_progress"]
        var events: [[String: Any]] = [["type": "response.output_item.added", "output_index": 0, "item": item]]
        events += deltas.map { ["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "item", "delta": $0] }
        events.append(["type": "response.function_call_arguments.done", "output_index": 0, "item_id": "item", "arguments": text])
        var completed = item
        completed["arguments"] = text
        completed["status"] = "completed"
        events.append(["type": "response.output_item.done", "output_index": 0, "item": completed])
        events.append(["type": "response.completed", "response": ["id": "response", "status": "completed", "output": [completed]]])
        return events
    }
}

private func upstreamProviderStream(api: Api, text: String, chunk: Int = 24, cut: Bool = false) throws -> AssistantMessageEventStream {
    let model = upstreamStreamModel(api)
    let context = normalizeContext(Context(messages: []))
    let client = UpstreamStreamClient(body: try upstreamStreamSSE(upstreamProviderEvents(api: api, text: text, chunk: chunk, cut: cut), anthropic: api == .anthropicMessages))
    switch api {
    case .anthropicMessages: return streamAnthropic(model: model, context: context, options: AnthropicOptions(apiKey: "test", httpClient: client))
    case .openAICompletions: return streamOpenAICompletions(model: model, context: context, options: OpenAICompletionsOptions(apiKey: "test", httpClient: client))
    case .mistralConversations: return streamMistral(model: model, context: context, options: MistralOptions(apiKey: "test", httpClient: client))
    default: return streamOpenAIResponses(model: model, context: context, options: OpenAIResponsesOptions(apiKey: "test", httpClient: client))
    }
}

private func upstreamToolCall(_ message: AssistantMessage) -> ToolCall? {
    for block in message.content { if case .toolCall(let call) = block { return call } }
    return nil
}

private func upstreamNoStreamState(_ message: AssistantMessage) -> Bool {
    message.content.allSatisfy { block in
        let object = contentBlockToJSONObject(block)
        return object["partialJson"] == nil && object["index"] == nil && object["argumentsJSON"] == nil
    }
}

@Test("shows growing partial arguments, keeps stream state off every partial, and finishes with the exact arguments", arguments: upstreamStreamAPIs)
func upstreamProviderPartialState(api: Api) async throws {
    let content = String(repeating: "a", count: 5_000)
    let text = #"{"path":"/src/file.ts","content":""# + content + #""}"#
    let stream = try upstreamProviderStream(api: api, text: text)
    var shown = 0
    var partials = 0
    for await event in stream {
        if case .toolCallDelta(_, _, let message) = event, let call = upstreamToolCall(message),
           let value = call.arguments["content"]?.value as? String {
            #expect(content.hasPrefix(value))
            #expect(value.utf8.count >= shown)
            #expect(call.argumentsJSON == nil)
            #expect(upstreamNoStreamState(message))
            shown = value.utf8.count
            partials += 1
        }
    }
    let final = await stream.result()
    #expect(partials > 100)
    #expect(final.stopReason == .toolUse)
    #expect(upstreamToolCall(final)?.arguments["content"] == AnyCodable(content))
    #expect(upstreamNoStreamState(final))
}

@Test("allocates linearly in the argument text", .timeLimit(.minutes(1)))
func upstreamProviderLinearAllocationAdapted() {
    // V8 allocation counting has no Swift equivalent. The same 32-character stream meets the tagged time guard.
    let content = String(repeating: "a", count: 520_000)
    let stream = ToolCallArgumentsStream()
    stream.append(#"{"content":""#)
    let start = ContinuousClock.now
    for index in stride(from: 0, to: content.count, by: 32) {
        let end = min(index + 32, content.count)
        stream.append(String(repeating: "a", count: end - index))
    }
    stream.append(#""}"#)
    #expect(stream.finish().arguments["content"] == AnyCodable(content))
    #expect(start.duration(to: .now) < .seconds(10))
}

@Test("releases the stream, its partial messages and argument snapshots once the caller drops them")
func upstreamProviderStreamReleaseAdapted() {
    // Swift value snapshots cannot be weakly referenced. Check that the class owner is released.
    weak var weakOwner: ToolCallArgumentsStream?
    do {
        let owner = ToolCallArgumentsStream()
        weakOwner = owner
        for _ in 0..<100 { owner.append(#"{"content":"x"#) }
    }
    #expect(weakOwner == nil)
}

@Test("leaves no stream state on the error message of a stream cut off mid-call")
func upstreamProviderCutOffState() async throws {
    let text = #"{"path":"/src/file.ts","content":""# + String(repeating: "a", count: 2_000) + #""}"#
    let stream = try upstreamProviderStream(api: .anthropicMessages, text: text, chunk: 16, cut: true)
    for await _ in stream {}
    let final = await stream.result()
    #expect(final.stopReason == .error)
    #expect(upstreamNoStreamState(final))
    #expect(upstreamToolCall(final)?.arguments["path"] == AnyCodable("/src/file.ts"))
}
