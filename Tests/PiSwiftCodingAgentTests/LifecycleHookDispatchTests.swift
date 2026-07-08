import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func lifecycleAssistantMessage(
    _ content: [ContentBlock],
    stopReason: StopReason = .stop,
    model: Model
) -> AssistantMessage {
    AssistantMessage(
        content: content,
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: stopReason
    )
}

private func waitForEvents(
    _ events: LockedState<[String]>,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> [String] {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let snapshot = events.withLock { $0 }
        if snapshot.count >= count {
            return snapshot
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return events.withLock { $0 }
}

private func containsOrderedSubsequence(_ values: [String], _ expected: [String]) -> Bool {
    var index = 0
    for value in values where index < expected.count && value == expected[index] {
        index += 1
    }
    return index == expected.count
}

@Test func agentSessionDispatchesMessageLifecycleHooks() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-lifecycle-message-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let events = LockedState<[String]>([])
    let api = HookAPI(hookPath: "/fake/lifecycle-message-hook")
    api.on("message_start") { (event: MessageStartEvent, _: HookContext) in
        events.withLock { $0.append("message_start:\(event.message.role)") }
        return nil
    }
    api.on("message_update") { (event: MessageUpdateEvent, _: HookContext) in
        if case .assistant = event.message {
            events.withLock { $0.append("message_update:assistant") }
        }
        return nil
    }
    api.on("message_end") { (event: MessageEndEvent, _: HookContext) in
        events.withLock { $0.append("message_end:\(event.message.role)") }
        return nil
    }

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { model, _, _ in
            let stream = AssistantMessageEventStream()
            Task {
                let empty = lifecycleAssistantMessage([], model: model)
                let partial = lifecycleAssistantMessage([.text(TextContent(text: "Hel"))], model: model)
                let final = lifecycleAssistantMessage([.text(TextContent(text: "Hello"))], model: model)
                stream.push(.start(partial: empty))
                stream.push(.textDelta(contentIndex: 0, delta: "Hel", partial: partial))
                stream.push(.done(reason: .stop, message: final))
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let sessionManager = SessionManager.inMemory()
    let settingsManager = SettingsManager.inMemory()
    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    let modelRegistry = ModelRegistry(authStorage)
    let hook = LoadedHook(
        path: "/fake/lifecycle-message-hook",
        resolvedPath: "/fake/lifecycle-message-hook",
        handlers: api.handlers
    )
    let hookRunner = HookRunner([hook], tempDir, sessionManager, modelRegistry)
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        hookRunner: hookRunner,
        modelRegistry: modelRegistry
    ))
    defer { session.dispose() }

    try await session.prompt("hello")
    let snapshot = await waitForEvents(events, count: 5)

    #expect(containsOrderedSubsequence(snapshot, [
        "message_start:user",
        "message_end:user",
        "message_start:assistant",
        "message_update:assistant",
        "message_end:assistant",
    ]))
}

@Test func agentSessionDispatchesToolExecutionLifecycleHooks() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-lifecycle-tool-\(UUID().uuidString)")
        .path
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let events = LockedState<[String]>([])
    let api = HookAPI(hookPath: "/fake/lifecycle-tool-hook")
    api.on("tool_execution_start") { (event: ToolExecutionStartEvent, _: HookContext) in
        events.withLock { $0.append("tool_start:\(event.toolName):\(event.args["value"]?.value as? String ?? "")") }
        return nil
    }
    api.on("tool_execution_update") { (event: ToolExecutionUpdateEvent, _: HookContext) in
        let text = event.partialResult.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        events.withLock { $0.append("tool_update:\(event.toolName):\(text)") }
        return nil
    }
    api.on("tool_execution_end") { (event: ToolExecutionEndEvent, _: HookContext) in
        let text = event.result.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        events.withLock { $0.append("tool_end:\(event.toolName):\(event.isError):\(text)") }
        return nil
    }

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let streamCount = LockedState(0)
    let agent = Agent(AgentOptions(
        initialState: AgentState(
            systemPrompt: "Test",
            model: model,
            tools: [
                AgentTool(
                    label: "Lifecycle Tool",
                    name: "lifecycle_tool",
                    description: "Emits updates",
                    parameters: [:],
                    execute: { _, _, _, onUpdate in
                        onUpdate?(AgentToolResult(content: [.text(TextContent(text: "partial"))]))
                        return AgentToolResult(content: [.text(TextContent(text: "final"))])
                    }
                ),
            ]
        ),
        streamFn: { model, _, _ in
            let stream = AssistantMessageEventStream()
            let callIndex = streamCount.withLock { value -> Int in
                value += 1
                return value
            }
            Task {
                if callIndex == 1 {
                    let toolCall = ToolCall(
                        id: "tool-1",
                        name: "lifecycle_tool",
                        arguments: ["value": AnyCodable("input")]
                    )
                    let message = lifecycleAssistantMessage([.toolCall(toolCall)], stopReason: .toolUse, model: model)
                    stream.push(.done(reason: .toolUse, message: message))
                } else {
                    let message = lifecycleAssistantMessage([.text(TextContent(text: "done"))], model: model)
                    stream.push(.done(reason: .stop, message: message))
                }
            }
            return stream
        },
        getApiKey: { _ in "test-key" }
    ))

    let sessionManager = SessionManager.inMemory()
    let settingsManager = SettingsManager.inMemory()
    let authStorage = AuthStorage(":memory:")
    authStorage.setRuntimeApiKey(model.provider, "test-key")
    let modelRegistry = ModelRegistry(authStorage)
    let hook = LoadedHook(
        path: "/fake/lifecycle-tool-hook",
        resolvedPath: "/fake/lifecycle-tool-hook",
        handlers: api.handlers
    )
    let hookRunner = HookRunner([hook], tempDir, sessionManager, modelRegistry)
    let session = AgentSession(config: AgentSessionConfig(
        agent: agent,
        sessionManager: sessionManager,
        settingsManager: settingsManager,
        resourceLoader: TestResourceLoader(),
        hookRunner: hookRunner,
        modelRegistry: modelRegistry
    ))
    defer { session.dispose() }

    try await session.prompt("run tool")
    let snapshot = await waitForEvents(events, count: 3)

    #expect(containsOrderedSubsequence(snapshot, [
        "tool_start:lifecycle_tool:input",
        "tool_update:lifecycle_tool:partial",
        "tool_end:lifecycle_tool:false:final",
    ]))
}
