import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// v0.99.1 agent-session.ts _beforeToolCall and _afterToolCall use validated args for input.
// The agent hook context still contains the original tool call from agent-loop.ts.
@Test(.timeLimit(.minutes(1)), arguments: [ToolExecutionMode.sequential, .parallel], [false, true])
func codingAgentToolHooksUsePreparedInputAndOriginalIdentity(mode: ToolExecutionMode, block: Bool) async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let original = ToolCall(id: "prepared-1", name: "prepared", arguments: ["oldCount": AnyCodable("3")])
    let validated: [String: AnyCodable] = ["count": AnyCodable(3)]
    let callEvents = LockedState<[ToolCallEvent]>([])
    let resultEvents = LockedState<[ToolResultEvent]>([])
    let executed = LockedState<[[String: AnyCodable]]>([])
    let callHandler: HookHandler = { event, _ in
        guard let event = event as? ToolCallEvent else { return nil }
        callEvents.withLock { $0.append(event) }
        return block ? ToolCallEventResult(block: true, reason: "Blocked") : nil
    }
    let resultHandler: HookHandler = { event, _ in
        guard let event = event as? ToolResultEvent else { return nil }
        resultEvents.withLock { $0.append(event) }
        return nil
    }
    let runner = HookRunner(
        [LoadedHook(path: "<test:payload>", resolvedPath: "<test:payload>",
                    handlers: ["tool_call": [callHandler], "tool_result": [resultHandler]])],
        FileManager.default.currentDirectoryPath,
        SessionManager.inMemory(),
        ModelRegistry(AuthStorage(":memory:"))
    )
    runner.initialize(getModel: { model }, hasUI: false)
    defer { runner.dispose() }
    let beforeHook = makeHookRunnerBeforeToolCallHook(runner)
    let afterHook = makeHookRunnerAfterToolCallHook(runner)
    let tool = AgentTool(
        label: "Prepared", name: "prepared", description: "Prepares the count",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["count": ["type": "integer"]]),
                     "required": AnyCodable(["count"])],
        execute: { _, args, _, update in
            executed.withLock { $0.append(args) }
            update?(AgentToolResult(content: [.text(TextContent(text: "partial"))]))
            return AgentToolResult(content: [.text(TextContent(text: "done"))], details: AnyCodable(["count": 3]))
        },
        prepareArguments: { raw in ["count": raw["oldCount"] ?? AnyCodable(0)] }
    )
    let config = AgentLoopConfig(
        model: model, toolExecution: mode,
        beforeToolCall: { context, signal in
            #expect(context.toolCall.arguments == original.arguments)
            return await beforeHook(context, signal)
        },
        afterToolCall: { context, signal in
            #expect(context.toolCall.arguments == original.arguments)
            return try await afterHook(context, signal)
        },
        convertToLlm: { $0.compactMap(\.asMessage) }, finishTurn: { _, _ in .end }
    )
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("run")))],
        context: AgentContext(messages: [], tools: [tool]),
        config: config,
        streamFn: { model, _, _ in
            let message = AssistantMessage(
                content: [.toolCall(original)], api: model.api, provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse
            )
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .toolUse, message: message))
            stream.end(message)
            return stream
        }
    )
    var updateCount = 0
    for await event in stream {
        if case .toolExecutionUpdate(let id, let name, let args, _) = event {
            updateCount += 1
            #expect(id == original.id && name == original.name)
            #expect(args == original.arguments)
        }
    }
    let callEvent = try #require(callEvents.withLock { $0.first })
    #expect(callEvents.withLock { $0.count } == 1)
    #expect(callEvent.toolCallId == original.id && callEvent.toolName == original.name)
    #expect(callEvent.input == validated)
    #expect(callEvent.parentToolCallId == nil)
    #expect(executed.withLock { $0 } == (block ? [] : [validated]))
    #expect(updateCount == (block ? 0 : 1))
    #expect(resultEvents.withLock { $0.count } == (block ? 0 : 1))
    if !block {
        let resultEvent = try #require(resultEvents.withLock { $0.first })
        #expect(resultEvent.toolCallId == original.id && resultEvent.toolName == original.name)
        #expect(resultEvent.input == validated)
        #expect(resultEvent.details == AnyCodable(["count": 3]))
        #expect(!resultEvent.isError)
    }
}
