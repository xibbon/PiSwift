import Foundation
import Testing
@testable import PiSwiftAI

private func transcriptTool(_ name: String, _ description: String = "first") -> AITool {
    AITool(name: name, description: description, parameters: ["type": AnyCodable("object")])
}

@Test func transcriptSectionsKeepMapOrder() {
    var sections = SystemPromptSections([("z", "one"), ("a", "two"), ("m", nil)])
    sections["z"] = "changed"
    #expect(sections.entries.map(\.name) == ["z", "a", "m"])
    sections.remove("a")
    sections["a"] = "again"
    #expect(sections.entries.map(\.name) == ["z", "m", "a"])
    #expect(sections.entries[1].value == nil)
}

@Test func transcriptReplayContentSectionsAndToolDeltas() {
    let first = transcriptTool("search")
    let replacement = transcriptTool("search", "new")
    let context = normalizeContext(Context(systemPrompt: "Base", messages: [
        .system(SystemMessage(content: .text("More"), sections: SystemPromptSections([("z", "Z"), ("a", "A")]),
                              toolsAdded: [replacement], toolsRemoved: [ToolReference(name: "search")], timestamp: 5)),
        .system(SystemMessage(content: .blocks([TextContent(text: "Last")]), sections: SystemPromptSections([("z", nil), ("b", "B")]), timestamp: 6))
    ], tools: [first]))
    #expect(getCurrentSystemPrompt(context.messages) == "Base\n\nMore\n\nLast\n\nA\n\nB")
    #expect(getCurrentTools(context.messages).map(\.description) == ["new"])
    #expect(getCurrentSystemMessage(context.messages)?.timestamp == 0)
}

@Test func transcriptCollapseAndEmptyNormalization() {
    #expect(normalizeContext(Context(messages: [])).messages.isEmpty)
    let context = normalizeContext(Context(systemPrompt: "Base", messages: [
        .user(UserMessage(content: .text("Hello"))),
        .system(SystemMessage(content: .text("Later"), timestamp: 10))
    ]))
    let collapsed = collapseSystemMessages(context)
    #expect(collapsed.messages.count == 2)
    #expect(getInitialSystemMessage(collapsed.messages).map(getSystemMessageText) == "Base\n\nLater")
    #expect(getCurrentSystemPrompt(collapseSystemMessages(collapsed).messages) == "Base\n\nLater")
}

@Test func transcriptToolResolutionAndCanonicalEquality() {
    let a = transcriptTool("a")
    let b = transcriptTool("b")
    let redefined = transcriptTool("a", "other")
    let additive = normalizeContext(Context(messages: [
        .system(SystemMessage(content: .text(""), toolsAdded: [b]))
    ], tools: [a]))
    #expect(resolveTranscriptTools(additive.messages, supportsToolAdditions: true).anchorsAdditions)
    #expect(resolveTranscriptTools(additive.messages, supportsToolAdditions: true).requestTools.map(\.name) == ["a"])
    let removed = normalizeContext(Context(messages: [
        .system(SystemMessage(content: .text(""), toolsRemoved: [ToolReference(name: "a")]))
    ], tools: [a]))
    #expect(!resolveTranscriptTools(removed.messages, supportsToolAdditions: true).anchorsAdditions)
    let changed = getToolStateChanges([a], [redefined])
    #expect(changed.toolsAdded.map(\.name) == ["a"])
    #expect(changed.toolsRemoved == [ToolReference(name: "a")])
    #expect(hasToolRedefinitions(normalizeContext(Context(messages: [.system(SystemMessage(content: .text(""), toolsAdded: [redefined]))], tools: [a])).messages))
    let left = AITool(name: "x", description: "x", parameters: ["a": AnyCodable(1), "b": AnyCodable(2)])
    let right = AITool(name: "x", description: "x", parameters: ["b": AnyCodable(2), "a": AnyCodable(1)])
    #expect(declarationsEqual(left, right))
}

@Test func transcriptTextRendering() {
    let message = SystemMessage(content: .blocks([TextContent(text: "one"), TextContent(text: "two")]),
        sections: SystemPromptSections([("x", "section"), ("y", nil)]))
    #expect(contentText(message.content) == "one\ntwo")
    #expect(getSystemMessageText(message) == "one\ntwo\n\nsection")
    #expect(renderSystemMessageUpdate(message) == "one\ntwo\n\nUpdated system prompt section \"x\":\n\nsection\n\nRemoved system prompt section \"y\".")
}

@Test func orderedJSONStrictRoundTrip() throws {
    let text = #"{"z":"a/b","x":null,"a":[1,true]}"#
    let json = try OrderedJSON.parse(text)
    #expect(json.objectEntries?.map(\.0) == ["z", "x", "a"])
    #expect(json.serialized() == #"{"z":"a\/b","x":null,"a":[1,true]}"#)
    #expect(json.serialized(escapeSlashes: false) == text)
    #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"a":1,"a":2}"#) }
}

@Test func transcriptTransformKeepsSystemAfterToolResults() {
    let model = Model(id: "test", name: "Test", api: .openAICompletions, provider: "test",
        baseUrl: "https://example.invalid", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, maxTokens: 100)
    let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: "call", name: "search", arguments: [:]))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let messages: [Message] = [
        .assistant(assistant),
        .system(SystemMessage(content: .text("new rule"), timestamp: 2)),
        .toolResult(ToolResultMessage(toolCallId: "call", toolName: "search", content: [.text(TextContent(text: "done"))], isError: false)),
        .user(UserMessage(content: .text("next")))
    ]
    #expect(transformMessages(messages, model: model).map(\.role) == ["assistant", "toolResult", "system", "user"])
    #expect(transformMessages(Array(messages.prefix(2)), model: model).map(\.role) == ["assistant", "toolResult", "system"])
}

@Test func transcriptFauxSerializesOrderedUpdatesAndToolDeltas() {
    let first = transcriptTool("first")
    let second = transcriptTool("second")
    let context = normalizeContext(Context(systemPrompt: "Base", messages: [
        .system(SystemMessage(content: .text("Later"), sections: SystemPromptSections([("z", "Z"), ("a", "A")]),
                              toolsAdded: [second], toolsRemoved: [ToolReference(name: "first")], timestamp: 1))
    ], tools: [first]))
    let rendered = serializeFauxContext(context)
    #expect(rendered.contains("system:Base\ntool+:{\"name\":\"first\""))
    #expect(rendered.contains("system:Later\n\nZ\n\nA\ntool-:{\"name\":\"first\"}\ntool+:{\"name\":\"second\""))
}

@Test func transcriptToolDiffAcceptsRepeatedNames() {
    let first = transcriptTool("repeat", "old")
    let last = transcriptTool("repeat", "new")
    let changes = getToolStateChanges([first, last], [last])
    #expect(changes.toolsAdded.isEmpty)
    #expect(changes.toolsRemoved.map(\.name) == ["repeat"])
}
