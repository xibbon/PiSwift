import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel])
func f3AgentEventsAndPreparationKeepOriginalOrder(mode: ToolExecutionMode) async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    var original = ToolCall(id: "call", name: "test", arguments: [:])
    original.setArguments(from: #"{"z":1,"a":2}"#)
    let call = original
    let tool = AgentTool(label: "Test", name: "test", description: "Test", parameters: [:], execute: { _, args, _, update in
        #expect(args == ["prepared": AnyCodable(3)])
        update?(AgentToolResult(content: []))
        return AgentToolResult(content: [])
    }, prepareArguments: { _ in ["prepared": AnyCodable(3)] })
    let config = AgentLoopConfig(model: model, toolExecution: mode, beforeToolCall: { context, _ in
        #expect(orderedToolArguments(context.toolCall).map(\.key) == ["z", "a"])
        #expect(context.args == ["prepared": AnyCodable(3)])
        return nil
    }, afterToolCall: { context, _ in
        #expect(orderedToolArguments(context.toolCall).map(\.key) == ["z", "a"])
        return nil
    }, convertToLlm: { $0.compactMap(\.asMessage) }, finishTurn: { _, _ in .end })
    let stream = agentLoop(prompts: [.user(UserMessage(content: .text("run")))],
        context: AgentContext(messages: [], tools: [tool]), config: config, streamFn: { model, _, _ in
            let message = AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .toolUse, message: message)); stream.end(message)
            return stream
        })
    var starts = 0; var updates = 0
    for await event in stream {
        switch event {
        case .toolExecutionStart(_, _, let args):
            starts += 1
            #expect(orderedToolArguments(args).map(\.key) == ["z", "a"])
        case .toolExecutionUpdate(_, _, let args, _):
            updates += 1
            #expect(toolArgumentsToOrderedJSON(args).serialized() == #"{"z":1,"a":2}"#)
        default: break
        }
    }
    #expect(starts == 1 && updates == 1)
    let messages = await stream.result()
    let stored = try #require(messages.compactMap { message -> ToolCall? in
        if case .assistant(let assistant) = message, case .toolCall(let call) = assistant.content.first { return call }
        return nil
    }.first)
    #expect(orderedToolArguments(stored).map(\.key) == ["z", "a"])
}

@Test func f3ProxyRequestsKeepTheirExistingArgumentEncoding() throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    var call = ToolCall(id: "call", name: "test", arguments: [:])
    call.setArguments(from: #"{"z":1,"a":2}"#)
    let message = AssistantMessage(content: [.toolCall(call)], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let data = try encodeProxyRequestPayload(model: model, context: normalizeContext(Context(messages: [.assistant(message)])),
        options: ProxyStreamOptions(authToken: "test", proxyUrl: "https://example.invalid"))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let context = try #require(root["context"] as? [String: Any])
    let messages = try #require(context["messages"] as? [[String: Any]])
    let blocks = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(blocks.first?["argumentsJSON"] == nil)
    #expect((blocks.first?["arguments"] as? [String: Int]) == ["z": 1, "a": 2])
}

@Test func f3ProxyFinalObjectReadsOrderWithoutMetadata() throws {
    let text = #"{"type":"toolcall_end","contentIndex":0,"toolCall":{"type":"toolCall","id":"id","name":"test","arguments":{"z":{"b":1,"a":2},"a":3}}}"#
    guard case .toolCallEnd(_, let call?) = try decodeProxyAssistantMessageEventJSON(Data(text.utf8)) else {
        Issue.record("Missing final call"); return
    }
    #expect(orderedToolArguments(call).map(\.key) == ["z", "a"])
    #expect(toolArgumentsToOrderedJSON(call.arguments).serialized() == #"{"z":{"b":1,"a":2},"a":3}"#)
}
