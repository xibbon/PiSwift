import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent

private func f2Assistant(_ calls: [ToolCall], model: Model) -> AssistantMessage {
    AssistantMessage(
        content: calls.map(ContentBlock.toolCall),
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse
    )
}

private func f2RunLoop(
    calls: [ToolCall], tools: [AgentTool], config: AgentLoopConfig
) async -> (events: [AgentEvent], messages: [AgentMessage]) {
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("run")))],
        context: AgentContext(messages: [], tools: tools),
        config: config,
        streamFn: { model, _, _ in
            let message = f2Assistant(calls, model: model)
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
            return stream
        }
    )
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return (events, await stream.result())
}

// Port of v0.99.1 agent-loop.test.ts: "should prepare tool arguments for validation".
// Added hook and event checks follow prepareToolCall and emitToolExecutionUpdate at that tag.
@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel])
func agentLoopPreparedEditsKeepOriginalCallPayloads(mode: ToolExecutionMode) async throws {
    let original = ToolCall(id: "edit-1", name: "edit", arguments: [
        "oldText": AnyCodable("before"), "newText": AnyCodable("after")
    ], thoughtSignature: "signature", namespace: "editor")
    let prepared: [String: AnyCodable] = [
        "edits": AnyCodable([["oldText": "before", "newText": "after"]])
    ]
    let before = LockedState<[BeforeToolCallContext]>([])
    let after = LockedState<[AfterToolCallContext]>([])
    let executed = LockedState<[[String: AnyCodable]]>([])
    let messageInputs = LockedState<[ToolResultMessage]>([])
    let tool = AgentTool(
        label: "Edit", name: "edit", description: "Edit tool",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "edits": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["oldText": ["type": "string"], "newText": ["type": "string"]],
                    "required": ["oldText", "newText"]
                ]] as [String: Any]
            ]),
            "required": AnyCodable(["edits"])
        ],
        execute: { _, args, _, update in
            executed.withLock { $0.append(args) }
            update?(AgentToolResult(content: [.text(TextContent(text: "editing"))]))
            return AgentToolResult(content: [.text(TextContent(text: "edited 1"))], details: AnyCodable(["count": 1]))
        },
        prepareArguments: { raw in
            guard let oldText = raw["oldText"]?.value as? String,
                  let newText = raw["newText"]?.value as? String else { return nil }
            let edits = raw["edits"]?.value as? [[String: String]] ?? []
            return ["edits": AnyCodable(edits + [["oldText": oldText, "newText": newText]])]
        }
    )
    let config = AgentLoopConfig(
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"),
        toolExecution: mode,
        beforeToolCall: { context, _ in before.withLock { $0.append(context) }; return nil },
        afterToolCall: { context, _ in after.withLock { $0.append(context) }; return nil },
        prepareToolResultMessage: { message in messageInputs.withLock { $0.append(message) }; return message },
        convertToLlm: { $0.compactMap(\.asMessage) },
        finishTurn: { _, _ in .end }
    )
    let output = await f2RunLoop(calls: [original], tools: [tool], config: config)
    let beforeContext = try #require(before.withLock { $0.first })
    let afterContext = try #require(after.withLock { $0.first })
    #expect(before.withLock { $0.count } == 1)
    #expect(after.withLock { $0.count } == 1)
    #expect(beforeContext.toolCall.id == original.id)
    #expect(beforeContext.toolCall.name == original.name)
    #expect(beforeContext.toolCall.arguments == original.arguments)
    #expect(beforeContext.toolCall.thoughtSignature == original.thoughtSignature)
    #expect(beforeContext.toolCall.namespace == original.namespace)
    #expect(afterContext.toolCall.arguments == original.arguments)
    #expect(afterContext.toolCall.thoughtSignature == original.thoughtSignature)
    #expect(afterContext.toolCall.namespace == original.namespace)
    #expect(beforeContext.args == prepared)
    #expect(afterContext.args == prepared)
    #expect(executed.withLock { $0 } == [prepared])
    for message in [beforeContext.assistantMessage, afterContext.assistantMessage] {
        guard case .toolCall(let call) = message.content.first else {
            Issue.record("Expected the original assistant tool call")
            continue
        }
        #expect(call.arguments == original.arguments)
    }

    var payloadEvents: [String] = []
    for event in output.events {
        switch event {
        case .toolExecutionStart(let id, let name, let args):
            #expect(id == original.id && name == original.name)
            #expect(args == original.arguments)
            payloadEvents.append("start")
        case .toolExecutionUpdate(let id, let name, let args, _):
            #expect(id == original.id && name == original.name)
            #expect(args == original.arguments)
            payloadEvents.append("update")
        case .toolExecutionEnd(let id, let name, let result, let isError):
            #expect(id == original.id && name == original.name)
            #expect(result.details == AnyCodable(["count": 1]))
            #expect(!isError)
            payloadEvents.append("end")
        case .messageStart(.toolResult(let message)), .messageEnd(.toolResult(let message)):
            #expect(message.toolCallId == original.id && message.toolName == original.name)
            #expect(message.details == AnyCodable(["count": 1]))
            #expect(!message.isError)
        default: break
        }
    }
    #expect(payloadEvents == ["start", "update", "end"])
    let messageInput = try #require(messageInputs.withLock { $0.first })
    #expect(messageInputs.withLock { $0.count } == 1)
    #expect(messageInput.toolCallId == original.id && messageInput.toolName == original.name)
    #expect(messageInput.details == AnyCodable(["count": 1]))
    let storedResults = output.messages.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message else { return nil }
        return result
    }
    let storedResult = try #require(storedResults.first)
    #expect(storedResults.count == 1)
    #expect(storedResult.toolCallId == original.id && storedResult.toolName == original.name)
    #expect(storedResult.details == AnyCodable(["count": 1]))
    #expect(!storedResult.isError)
    #expect(output.messages.compactMap { message -> [String: AnyCodable]? in
        guard case .assistant(let assistant) = message, case .toolCall(let call) = assistant.content.first else { return nil }
        return call.arguments
    } == [original.arguments])
}

// v0.99.1 prepareToolCall sends validated args to hooks while it retains the original call.
@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel])
func agentLoopHooksReceivePreparedAndCoercedArguments(mode: ToolExecutionMode) async {
    let original = ToolCall(id: "count-1", name: "count", arguments: ["oldCount": AnyCodable("3")])
    let validated: [String: AnyCodable] = ["count": AnyCodable(3)]
    let received = LockedState<[[String: AnyCodable]]>([])
    let tool = AgentTool(
        label: "Count", name: "count", description: "Count tool",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["count": ["type": "integer"]]),
                     "required": AnyCodable(["count"])],
        execute: { _, args, _, _ in
            received.withLock { $0.append(args) }
            return AgentToolResult(content: [])
        },
        prepareArguments: { raw in ["count": raw["oldCount"] ?? AnyCodable(0)] }
    )
    let config = AgentLoopConfig(
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"), toolExecution: mode,
        beforeToolCall: { context, _ in
            #expect(context.toolCall.arguments == original.arguments)
            received.withLock { $0.append(context.args) }
            return nil
        },
        afterToolCall: { context, _ in
            #expect(context.toolCall.arguments == original.arguments)
            received.withLock { $0.append(context.args) }
            return nil
        },
        convertToLlm: { $0.compactMap(\.asMessage) }, finishTurn: { _, _ in .end }
    )
    _ = await f2RunLoop(calls: [original], tools: [tool], config: config)
    #expect(received.withLock { $0 } == [validated, validated, validated])
}

private enum F2ToolFailure: String, CaseIterable, Sendable {
    case missing, invalid, preparation, blocked, execution
}

private enum F2ToolError: LocalizedError, Sendable {
    case failed
    var errorDescription: String? { "Tool failed" }
}

// v0.99.1 immediate and executed errors retain the original tool identity and call payload.
@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel], F2ToolFailure.allCases)
private func agentLoopPreparedArgumentFailuresKeepOriginalPayloads(mode: ToolExecutionMode, failure: F2ToolFailure) async {
    let original = ToolCall(id: failure.rawValue, name: "count", arguments: ["oldCount": AnyCodable("3")])
    let hooks = LockedState<[String]>([])
    let tool = AgentTool(
        label: "Count", name: "count", description: "Count tool",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["count": ["type": "integer"]]),
                     "required": AnyCodable(["count"])],
        execute: { _, _, _, update in
            #expect(failure == .execution)
            update?(AgentToolResult(content: []))
            throw F2ToolError.failed
        },
        prepareArguments: { raw in
            if failure == .preparation { throw F2ToolError.failed }
            if failure == .invalid { return ["count": AnyCodable(["invalid": true])] }
            return ["count": raw["oldCount"] ?? AnyCodable(0)]
        }
    )
    let config = AgentLoopConfig(
        model: getModel(provider: .openai, modelId: "gpt-4o-mini"), toolExecution: mode,
        beforeToolCall: { context, _ in
            #expect(context.toolCall.arguments == original.arguments)
            #expect(context.args == ["count": AnyCodable(3)])
            hooks.withLock { $0.append("before") }
            return failure == .blocked ? BeforeToolCallResult(block: true, reason: "Blocked") : nil
        },
        afterToolCall: { context, _ in
            #expect(context.toolCall.arguments == original.arguments)
            #expect(context.args == ["count": AnyCodable(3)])
            #expect(context.isError)
            hooks.withLock { $0.append("after") }
            return nil
        },
        convertToLlm: { $0.compactMap(\.asMessage) }, finishTurn: { _, _ in .end }
    )
    let output = await f2RunLoop(calls: [original], tools: failure == .missing ? [] : [tool], config: config)
    let expectedHooks = failure == .execution ? ["before", "after"] : failure == .blocked ? ["before"] : []
    #expect(hooks.withLock { $0 } == expectedHooks)
    var starts = 0
    var updates = 0
    var ends = 0
    var results = 0
    for event in output.events {
        switch event {
        case .toolExecutionStart(let id, let name, let args):
            starts += 1
            #expect(id == original.id && name == original.name && args == original.arguments)
        case .toolExecutionUpdate(let id, let name, let args, _):
            updates += 1
            #expect(id == original.id && name == original.name && args == original.arguments)
        case .toolExecutionEnd(let id, let name, _, let isError):
            ends += 1
            #expect(id == original.id && name == original.name && isError)
        case .messageEnd(.toolResult(let result)):
            results += 1
            #expect(result.toolCallId == original.id && result.toolName == original.name && result.isError)
        default: break
        }
    }
    #expect(starts == 1 && ends == 1 && results == 1)
    #expect(updates == (failure == .execution ? 1 : 0))
}
