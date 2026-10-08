import Testing
import PiSwiftAI
import PiSwiftAgent

private func g1Assistant(_ content: [ContentBlock] = [], stopReason: StopReason = .stop) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: .openAIResponses,
        provider: "openai",
        model: "mock",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason
    )
}

private func g1Call(_ id: String, _ name: String, _ args: [String: AnyCodable] = [:]) -> ToolCall {
    ToolCall(id: id, name: name, arguments: args)
}

private func g1Text(_ result: AgentToolResult) -> String? {
    guard case .text(let text) = result.content.first else { return nil }
    return text.text
}

private func g1EchoTool() -> AgentTool {
    let schema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["value": ["type": "string"]]),
        "required": AnyCodable(["value"]),
    ]
    return AgentTool(
        label: "Echo",
        name: "echo",
        description: "Echo tool",
        parameters: schema,
        execute: { _, args, _, onUpdate in
            onUpdate?(AgentToolResult(content: [.text(TextContent(text: "partial"))], details: AnyCodable([String: String]())))
            let value = args["value"]?.value as? String ?? ""
            return AgentToolResult(
                content: [.text(TextContent(text: value))],
                details: AnyCodable([String: String]()),
                structuredContent: AnyCodable(["value": value])
            )
        },
        outputSchema: schema
    )
}

@Test func runToolCallValidatesHooksAndErrorOutcomes() async {
    let echo = g1EchoTool()
    let failing = AgentTool(
        label: "Failing",
        name: "failing",
        description: "Returns an error result",
        parameters: ["type": AnyCodable("object")]
    ) { _, _, _, _ in
        AgentToolResult(
            content: [.text(TextContent(text: "bad"))],
            details: AnyCodable(["partial": true]),
            structuredContent: AnyCodable(["errorCode": "bad-input"]),
            isError: true
        )
    }
    let hookCalls = LockedState<[String]>([])
    let updates = LockedState<[AgentToolResult]>([])
    let options = RunToolCallOptions(
        tools: [echo, failing],
        assistantMessage: g1Assistant(),
        context: AgentContext(messages: []),
        onUpdate: { partial in updates.withLock { $0.append(partial) } },
        beforeToolCall: { context, _ in
            hookCalls.withLock { $0.append("before \(context.toolCall.id)") }
            if context.args["value"]?.value as? String == "blocked" {
                return BeforeToolCallResult(block: true, reason: "nope")
            }
            return nil
        },
        afterToolCall: { context, _ in
            hookCalls.withLock { $0.append("after \(context.toolCall.id)") }
            return nil
        }
    )

    let success = await runToolCall(g1Call("a", "echo", ["value": AnyCodable("a")]), options: options)
    #expect(success.toolCall.id == "a")
    #expect(success.result.structuredContent == AnyCodable(["value": "a"]))
    #expect(success.isError == false)

    let invalid = await runToolCall(g1Call("b", "echo", ["value": AnyCodable(["nested": true])]), options: options)
    #expect(invalid.isError)
    let blocked = await runToolCall(g1Call("c", "echo", ["value": AnyCodable("blocked")]), options: options)
    #expect(blocked.isError)
    #expect(g1Text(blocked.result) == "nope")
    let missing = await runToolCall(g1Call("d", "missing"), options: options)
    #expect(missing.isError)
    #expect(g1Text(missing.result) == "Tool missing not found")
    let failed = await runToolCall(g1Call("e", "failing"), options: options)
    #expect(failed.isError)
    #expect(failed.result.details == AnyCodable(["partial": true]))
    #expect(failed.result.structuredContent == AnyCodable(["errorCode": "bad-input"]))
    #expect(failed.result.isError == true)

    #expect(updates.withLock { $0.map(g1Text) } == ["partial"])
    #expect(hookCalls.withLock { $0 } == ["before a", "after a", "before c", "before e", "after e"])
}

@Test func runToolCallStructuredContentMergeRules() async {
    let echo = g1EchoTool()
    let redacted: [ContentBlock] = [.text(TextContent(text: "redacted"))]
    let overrides: [AfterToolCallResult] = [
        AfterToolCallResult(content: redacted),
        AfterToolCallResult(structuredContent: .set(AnyCodable(["value": "replaced"]))),
        AfterToolCallResult(content: redacted, structuredContent: .set(AnyCodable(["value": "both"]))),
        AfterToolCallResult(details: AnyCodable(["note": "kept"])),
        AfterToolCallResult(structuredContent: .cleared),
    ]
    let expected: [AnyCodable?] = [
        nil,
        AnyCodable(["value": "replaced"]),
        AnyCodable(["value": "both"]),
        AnyCodable(["value": "original"]),
        nil,
    ]
    for (override, value) in zip(overrides, expected) {
        let outcome = await runToolCall(
            g1Call("x", "echo", ["value": AnyCodable("original")]),
            options: RunToolCallOptions(
                tools: [echo],
                assistantMessage: g1Assistant(),
                context: AgentContext(messages: []),
                afterToolCall: { _, _ in override }
            )
        )
        #expect(outcome.result.structuredContent == value)
        #expect(outcome.isError == false)
    }
}

@Test func agentToolOutputSchemaPassesThroughWithoutResultValidation() async {
    let echo = g1EchoTool()
    #expect(echo.outputSchema == echo.parameters)
    let outcome = await runToolCall(
        g1Call("schema", "echo", ["value": AnyCodable("hi")]),
        options: RunToolCallOptions(tools: [echo], assistantMessage: g1Assistant(), context: AgentContext(messages: []))
    )
    #expect(outcome.result.structuredContent == AnyCodable(["value": "hi"]))
    #expect(outcome.isError == false)

    let mismatched = AgentTool(
        label: "Mismatch",
        name: "mismatch",
        description: "The output schema is metadata",
        parameters: ["type": AnyCodable("object")],
        execute: { _, _, _, _ in
            AgentToolResult(content: [.text(TextContent(text: "ok"))], structuredContent: AnyCodable(["other": true]))
        },
        outputSchema: echo.outputSchema
    )
    let mismatchOutcome = await runToolCall(
        g1Call("mismatch", "mismatch"),
        options: RunToolCallOptions(tools: [mismatched], assistantMessage: g1Assistant(), context: AgentContext(messages: []))
    )
    #expect(mismatchOutcome.isError == false)
    #expect(mismatchOutcome.result.structuredContent == AnyCodable(["other": true]))
}

@Test func runToolCallPreparesArgumentsAndCatchesThrows() async {
    let observed = LockedState<[String]>([])
    var prepared = g1EchoTool()
    prepared.prepareArguments = { raw in ["value": raw["oldValue"] ?? AnyCodable("")] }
    let original = g1Call("prepared", "echo", ["oldValue": AnyCodable("adapted")])
    let success = await runToolCall(
        original,
        options: RunToolCallOptions(
            tools: [prepared],
            assistantMessage: g1Assistant(),
            context: AgentContext(messages: []),
            beforeToolCall: { context, _ in
                observed.withLock { $0.append("before \(context.toolCall.arguments["oldValue"]?.value as? String ?? "") \(context.args["value"]?.value as? String ?? "")") }
                return nil
            },
            afterToolCall: { context, _ in
                observed.withLock { $0.append("after \(context.toolCall.arguments["oldValue"]?.value as? String ?? "") \(context.args["value"]?.value as? String ?? "")") }
                return nil
            }
        )
    )
    #expect(success.isError == false)
    #expect(success.toolCall.arguments["oldValue"] == AnyCodable("adapted"))
    #expect(g1Text(success.result) == "adapted")
    #expect(observed.withLock { $0 } == ["before adapted adapted", "after adapted adapted"])

    enum ToolFailure: Error { case failed }
    let throwing = AgentTool(label: "Throwing", name: "throwing", description: "Throws", parameters: [:]) { _, _, _, _ in
        throw ToolFailure.failed
    }
    let failed = await runToolCall(
        g1Call("throw", "throwing"),
        options: RunToolCallOptions(tools: [throwing], assistantMessage: g1Assistant(), context: AgentContext(messages: []))
    )
    #expect(failed.isError)
    #expect(g1Text(failed.result) != nil)
}

@Test(.timeLimit(.minutes(1))) func agentLoopTreatsReturnedIsErrorAsErrorAndKeepsMetadata() async {
    let call = g1Call("error-1", "failing")
    let tool = AgentTool(label: "Failing", name: "failing", description: "Fails", parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
        AgentToolResult(
            content: [.text(TextContent(text: "bad"))],
            details: AnyCodable(["partial": true]),
            structuredContent: AnyCodable(["code": "failed"]),
            isError: true
        )
    }
    let calls = LockedState(0)
    let streamFn: StreamFn = { _, _, _ in
        let index = calls.withLock { current -> Int in current += 1; return current }
        let message = index == 1
            ? g1Assistant([.toolCall(call)], stopReason: .toolUse)
            : g1Assistant([.text(TextContent(text: "done"))])
        let stream = AssistantMessageEventStream()
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
        return stream
    }
    let config = AgentLoopConfig(model: getModel(provider: .openai, modelId: "gpt-4o-mini"), convertToLlm: { $0.compactMap(\.asMessage) })
    let stream = agentLoop(
        prompts: [.user(UserMessage(content: .text("run")))],
        context: AgentContext(messages: [], tools: [tool]),
        config: config,
        streamFn: streamFn
    )
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    let ends = events.compactMap { event -> (AgentToolResult, Bool)? in
        guard case .toolExecutionEnd(_, _, let result, let isError, _) = event else { return nil }
        return (result, isError)
    }
    #expect(ends.count == 1)
    #expect(ends.first?.1 == true)
    #expect(ends.first?.0.details == AnyCodable(["partial": true]))
    #expect(ends.first?.0.structuredContent == AnyCodable(["code": "failed"]))
    let messages = await stream.result()
    let toolResults = messages.compactMap { message -> ToolResultMessage? in
        guard case .toolResult(let result) = message else { return nil }
        return result
    }
    #expect(toolResults.count == 1)
    #expect(toolResults.first?.isError == true)
    #expect(toolResults.first?.details == AnyCodable(["partial": true]))
    #expect(toolResults.first?.content.count == 1)
}
