import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private actor NestedTestEvents {
    var entries: [(String, String, String)] = []

    func append(_ event: NestedToolExecutionEvent) {
        switch event {
        case .start(let id, _, _, let parent): entries.append(("start", id, parent))
        case .update(let id, _, _, _, let parent): entries.append(("update", id, parent))
        // v1.1.0 nested tool events include durationMs.
        case .end(let id, _, _, _, let parent, _): entries.append(("end", id, parent))
        }
    }

    func snapshot() -> [(String, String, String)] { entries }
}

private actor NestedConcurrencyCount {
    var active = 0
    var maximum = 0

    func begin() {
        active += 1
        maximum = max(maximum, active)
    }

    func end() { active -= 1 }
    func peak() -> Int { maximum }
}

private func nestedUsage(_ input: Int) -> Usage {
    Usage(input: input, output: 0, cacheRead: 0, cacheWrite: 0,
          totalTokens: input, cost: UsageCost(input: Double(input) / 1000,
                                               total: Double(input) / 1000))
}

private func nestedTestTool(_ name: String, mode: ToolExecutionMode? = nil) -> AgentTool {
    AgentTool(label: name, name: name, description: name, parameters: [:],
              execute: { _, _, _, _ in AgentToolResult(content: []) },
              outputSchema: nil, executionMode: mode)
}

@Test func nestedRecorderBoundsArgumentsCountAndErrors() throws {
    var recorder = NestedCallRecorder()
    #expect(recorder.snapshot() == nil)
    let first = recorder.start(AgentToolCall(id: "a", name: "t", arguments: ["x": AnyCodable(1)]))
    recorder.finish(first, isError: false, errorText: "")
    #expect(recorder.snapshot()?.complete == true)
    #expect(recorder.snapshot()?.calls[0].status == .ok)

    let oversized = recorder.start(AgentToolCall(id: "b", name: "t",
                                                 arguments: ["text": AnyCodable(String(repeating: "x", count: 8192))]))
    recorder.finish(oversized, isError: true, errorText: String(repeating: "e", count: 1000))
    let second = try #require(recorder.snapshot()?.calls[1])
    #expect(second.arguments == nil)
    #expect((second.argumentsBytes ?? 0) > NestedCallLimits.maxArgumentBytesPerCall)
    #expect(second.error?.count == NestedCallLimits.maxErrorChars)
    #expect(recorder.snapshot()?.complete == false)

    for index in 0..<NestedCallLimits.maxCalls {
        let record = recorder.start(AgentToolCall(id: "c\(index)", name: "t", arguments: [:]))
        recorder.finish(record, isError: false, errorText: "")
    }
    #expect(recorder.snapshot()?.calls.count == NestedCallLimits.maxCalls)
}

@Test func nestedRecorderCapsTotalArgumentsAndMarksUnfinishedCalls() throws {
    var recorder = NestedCallRecorder()
    let chunk = ["text": AnyCodable(String(repeating: "x", count: 7000))]
    for index in 0..<6 {
        _ = recorder.start(AgentToolCall(id: "c\(index)", name: "t", arguments: chunk))
    }
    let snapshot = try #require(recorder.snapshot())
    #expect(snapshot.calls.filter { $0.arguments != nil }.count == 4)
    #expect(snapshot.calls.allSatisfy { $0.status == .unfinished })
    #expect(snapshot.complete == false)
}

@Test func nestedRunnerRecordsDescendantsUsageAndParentEvents() async throws {
    let events = NestedTestEvents()
    let runnerBox = LockedState<NestedToolCallRunner?>(nil)
    let tools = [nestedTestTool("middle"), nestedTestTool("leaf")]
    let host = NestedToolCallHost(
        getTools: { tools }, isSequential: { false },
        runToolCall: { call, _, _, onUpdate in
            if call.name == "middle", let runner = runnerBox.withLock({ $0 }) {
                _ = await runner.execute(callerId: call.id, name: "leaf", args: [:])
                return AgentToolCallOutcome(toolCall: call,
                    result: AgentToolResult(content: [], usage: nestedUsage(5)), isError: false)
            }
            await onUpdate(AgentToolResult(content: [.text(TextContent(text: "partial"))]))
            return AgentToolCallOutcome(toolCall: call,
                result: AgentToolResult(content: [], usage: nestedUsage(10)), isError: false)
        },
        emit: { event in await events.append(event) }
    )
    let runner = NestedToolCallRunner(host: host)
    runnerBox.withLock { $0 = runner }

    let outcome = await runner.execute(callerId: "call", name: "middle", args: [:])
    #expect(outcome.toolCall.id == "call/1")
    let summary = try #require(await runner.takeRecord(toolCallId: "call"))
    #expect(summary.calls?.calls.map(\.id) == ["call/1", "call/1/1"])
    #expect(summary.calls?.complete == true)
    #expect(summary.usage?.input == 15)
    #expect(summary.usage?.cost.total == 0.015)
    #expect(await runner.takeRecord(toolCallId: "call") == nil)
    let entries = await events.snapshot()
    #expect(entries.contains { $0.0 == "start" && $0.1 == "call/1/1" && $0.2 == "call/1" })
    #expect(entries.contains { $0.0 == "update" && $0.1 == "call/1/1" && $0.2 == "call/1" })
    #expect(entries.contains { $0.0 == "end" && $0.1 == "call/1" && $0.2 == "call" })
}

@Test func nestedRunnerSerializesSequentialTools() async {
    let count = NestedConcurrencyCount()
    let tool = nestedTestTool("serial", mode: .sequential)
    let host = NestedToolCallHost(
        getTools: { [tool] }, isSequential: { false },
        runToolCall: { call, _, _, _ in
            await count.begin()
            try? await Task.sleep(for: .milliseconds(5))
            await count.end()
            return AgentToolCallOutcome(toolCall: call, result: AgentToolResult(content: []), isError: false)
        }, emit: { _ in }
    )
    let runner = NestedToolCallRunner(host: host)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<3 {
            group.addTask { _ = await runner.execute(callerId: "call", name: "serial", args: [:]) }
        }
    }
    #expect(await count.peak() == 1)
}

@Test func customToolWrapperUsesPerCallContextAndOutputSchema() async throws {
    let session = SessionManager.inMemory()
    let registry = ModelRegistry(AuthStorage(":memory:"))
    let schema: [String: AnyCodable] = ["type": AnyCodable("object")]
    let tool = CustomTool(
        name: "nested", label: "Nested", description: "Calls a tool", parameters: [:],
        execute: { _, _, _, context, _ in
            let outcome = await context.executeTool(name: "missing", args: [:])
            return outcome.result
        }, outputSchema: schema
    )
    let wrapped = wrapCustomTool(tool, contextFactory: { _, _ in
        CustomToolContext(sessionManager: session, modelRegistry: registry, model: nil,
                          isIdle: { true }, hasPendingMessages: { false }, abort: {},
                          events: createEventBus(), sendMessage: { _, _ in })
    })
    #expect(wrapped.outputSchema?["type"]?.value as? String == "object")
    let result = try await wrapped.execute("parent", [:], nil, nil)
    #expect(result.isError == true)
    let text = result.content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
    }.joined()
    #expect(text == "Nested tool calls are not available in this context")
}

@Test func toolResultHookDropsStructuredContentWhenContentChanges() async throws {
    let observed = LockedState<AnyCodable?>(AnyCodable("unseen"))
    let first: HookHandler = { event, _ in
        guard event is ToolResultEvent else { return nil }
        return ToolResultEventResult(content: [.text(TextContent(text: "redacted"))])
    }
    let second: HookHandler = { event, _ in
        guard let event = event as? ToolResultEvent else { return nil }
        observed.withLock { $0 = event.structuredContent }
        return ToolResultEventResult(isError: false)
    }
    let hook = LoadedHook(path: "/test", resolvedPath: "/test",
                          handlers: ["tool_result": [first, second]])
    let runner = HookRunner([hook], "/tmp", SessionManager.inMemory(),
                            ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil }, mode: .print, hasUI: false)
    let event = ToolResultEvent(toolName: "test", toolCallId: "call", input: [:],
                                content: [.text(TextContent(text: "before"))], details: nil,
                                isError: true,
                                structuredContent: AnyCodable(["secret": AnyCodable("value")]))
    let result = try #require(await runner.emitToolResult(event))
    #expect(observed.withLock { $0 } == nil)
    #expect(result.structuredContent == nil)
    #expect(result.isError == false)
}

@Test func standaloneToolWrapperReportsReturnedErrorAndStructuredContent() async throws {
    let observed = LockedState<(Bool, AnyCodable?)?>(nil)
    let handler: HookHandler = { event, _ in
        guard let event = event as? ToolResultEvent else { return nil }
        observed.withLock { $0 = (event.isError, event.structuredContent) }
        return nil
    }
    let hook = LoadedHook(path: "/test", resolvedPath: "/test",
                          handlers: ["tool_result": [handler]])
    let runner = HookRunner([hook], "/tmp", SessionManager.inMemory(),
                            ModelRegistry(AuthStorage(":memory:")))
    runner.initialize(getModel: { nil }, mode: .print, hasUI: false)
    let schema = ["type": AnyCodable("object")]
    let tool = AgentTool(label: "Failure", name: "failure", description: "Failure", parameters: [:],
                         execute: { _, _, _, _ in
                             AgentToolResult(content: [.text(TextContent(text: "failed"))],
                                             structuredContent: AnyCodable(["code": AnyCodable(7)]),
                                             isError: true)
                         }, outputSchema: schema)
    let wrapped = wrapToolWithHooks(tool, runner)
    let result = try await wrapped.execute("call", [:], nil, nil)
    #expect(observed.withLock { $0?.0 } == true)
    #expect(observed.withLock { $0?.1 } != nil)
    #expect(result.isError == true)
    #expect(result.structuredContent != nil)
    #expect(wrapped.outputSchema?["type"]?.value as? String == "object")
}
