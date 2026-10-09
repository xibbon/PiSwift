import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

private func user(_ text: String) -> Message { .user(UserMessage(content: .text(text), timestamp: 0)) }
private func assistant(_ text: String, _ calls: [String] = [], reason: StopReason = .stop) -> Message {
    var message = chatAssistant(text, reason: reason)
    message.content += calls.map { .toolCall(ToolCall(id: $0, name: "read", arguments: [:])) }
    return .assistant(message)
}
private func result(_ id: String, _ text: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: id, toolName: "read", content: [.text(TextContent(text: text))], isError: false, timestamp: 0))
}
private func rangeView(_ entries: [(String, Message)], marker: String? = nil) throws -> ContextView {
    var records: [EntryRecord] = []
    if let marker { records.append(EntryRecord(id: try EntryID(1), conversationId: rootConversationID, kind: "pi.compaction", model: try EntryRecord.encodeMessages([user(marker)]), head: try EntryID(1))) }
    records += try entries.enumerated().map { index, value in
        EntryRecord(id: try EntryID(Int64(index + 2)), conversationId: rootConversationID, kind: value.0, model: try EntryRecord.encodeMessages([value.1]))
    }
    let contributions = try records.map { record in
        try (record.messages() ?? []).filter { message in
            if case .assistant(let assistant) = message { return ![StopReason.error, .aborted, .deferred].contains(assistant.stopReason) }
            return true
        }
    }
    return ContextView(head: marker == nil ? nil : records[0], entries: records, contributions: contributions, messages: orderToolResults(contributions.flatMap { $0 }))
}

struct HarnessCompactionRangeTests {
    // harness-compaction.test.ts:231
    @Test func keepsRecentBudgetAtNextCandidate() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("1", 10))), ("pi.assistant", assistant("2", ["c1"])),
            ("pi.tool-result", result("c1", compactionText("3", 3000))), ("pi.assistant", assistant(compactionText("4", 10))),
            ("pi.user", user(compactionText("5", 10))), ("pi.assistant", assistant(compactionText("6", 10)))
        ])
        #expect(generationSelectCut(view: view, keepRecentTokens: 2000) == 3)
    }
    // harness-compaction.test.ts:243
    @Test func cutsAtUserEntry() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("u1", 100))), ("pi.assistant", assistant(compactionText("a1", 100))),
            ("pi.user", user(compactionText("u2", 100))), ("pi.assistant", assistant(compactionText("a2", 100)))
        ])
        #expect(generationSelectCut(view: view, keepRecentTokens: 150) == 2)
    }
    // harness-compaction.test.ts:253
    @Test func longRunCutsAtAssistantAndRetainsItsResult() throws {
        var entries: [(String, Message)] = [("pi.user", user("do it"))]
        for index in 0..<5 {
            entries.append(("pi.assistant", assistant("step \(index)", ["c\(index)"])))
            entries.append(("pi.tool-result", result("c\(index)", compactionText("r\(index)", 100))))
        }
        let view = try rangeView(entries)
        let cut = try #require(generationSelectCut(view: view, keepRecentTokens: 150))
        #expect(cut == 9 && view.entries[cut].kind == "pi.assistant")
    }
    // harness-compaction.test.ts:265
    @Test func largeLastResultStaysWithItsAssistant() throws {
        let view = try rangeView([("pi.user", user("u")), ("pi.assistant", assistant("a", ["c"])), ("pi.tool-result", result("c", compactionText("big", 5000)))])
        #expect(generationSelectCut(view: view, keepRecentTokens: 100) == 1)
    }
    // harness-compaction.test.ts:274
    @Test func systemAndExcludedAnswersAreNotCandidates() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("u1", 100))), ("pi.assistant", assistant(compactionText("a1", 100))),
            ("pi.system", .system(SystemMessage(content: .text(""), sections: SystemPromptSections([("s", compactionText("s", 100))]), timestamp: 0))),
            ("pi.assistant", assistant(compactionText("err", 100), reason: .error)),
            ("pi.assistant", assistant(compactionText("stopped", 100), reason: .aborted)),
            ("pi.assistant", assistant(compactionText("a2", 100)))
        ])
        #expect(generationSelectCut(view: view, keepRecentTokens: 150) == 5)
    }
    // harness-compaction.test.ts:287
    @Test func omittedContributionChangesCut() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("u1", 100))), ("pi.assistant", assistant(compactionText("a1", 100))),
            ("pi.user", user(compactionText("u2", 100))), ("pi.assistant", assistant(compactionText("a2", 100)))
        ])
        #expect(generationSelectCut(view: view, keepRecentTokens: 150) == 2)
        var contributions = view.contributions; contributions[2] = []
        let omitted = ContextView(entries: view.entries, contributions: contributions, messages: orderToolResults(contributions.flatMap { $0 }))
        #expect(generationSelectCut(view: omitted, keepRecentTokens: 150) == 1)
    }
    // harness-compaction.test.ts:301
    @Test func userBeforePendingResultIsNotCandidate() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("u1", 100))), ("pi.assistant", assistant("a", ["c"])),
            ("pi.user", user(compactionText("steer", 100))), ("pi.tool-result", result("c", compactionText("r", 100))),
            ("pi.assistant", assistant(compactionText("a2", 100)))
        ])
        #expect(generationSelectCut(view: view, keepRecentTokens: 250) == 4)
    }
    // harness-compaction.test.ts:313
    @Test func noCutWithoutBudgetOrWithOnlyMarkerPrefix() throws {
        #expect(try generationSelectCut(view: rangeView([("pi.user", user("hi")), ("pi.assistant", assistant("hello"))]), keepRecentTokens: 150) == nil)
        #expect(try generationSelectCut(view: rangeView([("pi.user", user(compactionText("u", 200)))], marker: "summary"), keepRecentTokens: 150) == nil)
    }
    // harness-compaction.test.ts:321
    @Test func earlierSummaryIsSerializedFirst() throws {
        let view = try rangeView([
            ("pi.user", user(compactionText("u1", 100))), ("pi.assistant", assistant(compactionText("a1", 100))),
            ("pi.user", user(compactionText("u2", 100))), ("pi.assistant", assistant(compactionText("a2", 100)))
        ], marker: "EARLIER")
        #expect(generationSelectCut(view: view, keepRecentTokens: 150) == 3)
        #expect(serializeConversation(view.contributions.prefix(3).flatMap { $0 }).hasPrefix("[User]: EARLIER"))
    }
    // harness-compaction.test.ts:336
    @Test func serializationWritesTranscriptAndTruncatesResults() {
        var message = chatAssistant("sure")
        message.content = [.thinking(ThinkingContent(thinking: "hmm")), .text(TextContent(text: "sure")), .toolCall(ToolCall(id: "c", name: "read", arguments: ["path": AnyCodable("a.ts")]))]
        let serialized = serializeConversation([
            .system(SystemMessage(content: .text(""), sections: SystemPromptSections([("s", "hidden")]), timestamp: 0)), user("hello"), .assistant(message), result("c", String(repeating: "y", count: 2500))
        ])
        #expect(!serialized.contains("hidden"))
        #expect(serialized.contains("[User]: hello"))
        #expect(serialized.contains("[Assistant thinking]: hmm"))
        #expect(serialized.contains("[Assistant]: sure"))
        #expect(serialized.contains("[Assistant tool calls]: read(path=\"a.ts\")"))
        #expect(serialized.contains("[Tool result]: " + String(repeating: "y", count: 2000) + "\n\n[... 500 more characters truncated]"))
    }
    // Extra Swift regression: JavaScript sorts integer keys before other keys.
    @Test func serializationUsesJavaScriptArgumentKeyOrder() throws {
        let source = try OrderedJSON.parse("{\"z\":{\"10\":10,\"2\":2,\"a\":1},\"10\":10,\"2\":2,\"01\":1}")
        var message = chatAssistant("")
        message.content = [.toolCall(ToolCall(id: "ordered", name: "read", arguments: ["z": AnyCodable(["10": 10, "2": 2, "a": 1]), "10": AnyCodable(10), "2": AnyCodable(2), "01": AnyCodable(1)], argumentsJSON: source))]
        #expect(serializeConversation([.assistant(message)]) == "[Assistant tool calls]: read(2=2, 10=10, z={\"2\":2,\"10\":10,\"a\":1}, 01=1)")
    }
    // Extra Swift regression: count UTF-16 units as JavaScript does.
    @Test func serializationTruncatesToolResultByUTF16Units() {
        let serialized = serializeConversation([result("utf16", String(repeating: "😀", count: 1001))])
        #expect(serialized == "[Tool result]: " + String(repeating: "😀", count: 1000) + "\n\n[... 2 more characters truncated]")
    }
}
