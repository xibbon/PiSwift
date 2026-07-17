import Testing
@testable import PiSwiftAI

private func deferredTool(_ name: String, description: String? = nil) -> AITool {
    AITool(name: name, description: description ?? name, parameters: [:])
}

private func deferredToolResult(addedToolNames: [String]) -> Message {
    .toolResult(ToolResultMessage(
        toolCallId: "call-1",
        toolName: "loader",
        content: [],
        addedToolNames: addedToolNames,
        isError: false,
        timestamp: 0
    ))
}

private func deferredAssistantToolCall(named name: String) -> Message {
    .assistant(AssistantMessage(
        content: [.toolCall(ToolCall(id: "call-1", name: name, arguments: [:]))],
        api: .openAICompletions,
        provider: "test",
        model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: .toolUse,
        timestamp: 0
    ))
}

@Test func splitDeferredToolsDisabledReturnsUniqueToolsInOriginalOrder() {
    let context = Context(
        messages: [deferredToolResult(addedToolNames: ["search"])],
        tools: [
            deferredTool("search", description: "first"),
            deferredTool("read"),
            deferredTool("SEARCH", description: "last"),
        ]
    )

    let result = splitDeferredTools(context, enabled: false) { $0.lowercased() }

    #expect(result.immediate.map(\.name) == ["SEARCH", "read"])
    #expect(result.immediate.map(\.description) == ["last", "read"])
    #expect(result.deferred.isEmpty)
}

@Test func splitDeferredToolsDefersAddedUnusedTool() {
    let context = Context(
        messages: [deferredToolResult(addedToolNames: ["search"])],
        tools: [deferredTool("read"), deferredTool("search"), deferredTool("write")]
    )

    let result = splitDeferredTools(context, enabled: true)

    #expect(result.immediate.map(\.name) == ["read", "write"])
    #expect(result.deferred.map(\.name) == ["search"])
}

@Test func splitDeferredToolsKeepsPreviouslyUsedAddedToolImmediate() {
    let context = Context(
        messages: [
            deferredAssistantToolCall(named: "search"),
            deferredToolResult(addedToolNames: ["search"]),
        ],
        tools: [deferredTool("read"), deferredTool("search")]
    )

    let result = splitDeferredTools(context, enabled: true)

    #expect(result.immediate.map(\.name) == ["read", "search"])
    #expect(result.deferred.isEmpty)
}

@Test func splitDeferredToolsNormalizesToolCallsResultsAndAvailableTools() {
    let context = Context(
        messages: [
            deferredAssistantToolCall(named: "already-used"),
            deferredToolResult(addedToolNames: ["ALREADY_USED", "WEB_SEARCH"]),
        ],
        tools: [deferredTool("Already_Used"), deferredTool("Web-Search"), deferredTool("read")]
    )
    let normalize: (String) -> String = {
        $0.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    let result = splitDeferredTools(context, enabled: true, normalizeName: normalize)

    #expect(result.immediate.map(\.name) == ["Already_Used", "read"])
    #expect(result.deferred.map(\.name) == ["Web-Search"])
}
