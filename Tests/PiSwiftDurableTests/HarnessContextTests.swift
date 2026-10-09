import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

private func contextUser(_ text: String) -> Message { .user(UserMessage(content: .text(text), timestamp: 1)) }
private func contextSystem(_ key: String) -> Message { .system(SystemMessage(content: .text(""), sections: .init([(key, key)]), timestamp: 1)) }
private func contextAssistant(_ text: String, reason: StopReason = .stop, calls: [String] = []) -> Message {
    .assistant(AssistantMessage(content: [.text(TextContent(text: text))] + calls.map { .toolCall(ToolCall(id: $0, name: "tool-\($0)", arguments: [:])) }, api: .openAIResponses, provider: "faux", model: "faux", usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason, timestamp: 1))
}
private func contextResult(_ id: String) -> Message { .toolResult(ToolResultMessage(toolCallId: id, toolName: "tool-\(id)", content: [.text(TextContent(text: "result \(id)"))], isError: false, timestamp: 1)) }
private func contextDescription(_ message: Message) -> String {
    switch message {
    case .user(let user): if case .text(let text) = user.content { return "user:\(text)" }; return "user"
    case .assistant(let assistant): return "assistant:\(assistant.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined())"
    case .system(let system): return "system:\(system.sections?.entries.map(\.name).joined(separator: ",") ?? "")"
    case .toolResult(let result): return "result:\(result.toolCallId):\(result.isError ? "error" : "result \(result.toolCallId)")"
    }
}
private struct ContextTranscript {
    var entries: [EntryRecord] = []
    mutating func append(_ message: Message? = nil, kind: String = "message", head: Int64? = nil, edits: [ContextEdit]? = nil) throws -> EntryRecord {
        let record = try EntryRecord.withMessages(id: EntryID(Int64(entries.count + 1)), conversationId: rootConversationID,
                                                  kind: kind, messages: message.map { [$0] } ?? [], head: head.map { try EntryID($0) }, edits: edits)
        entries.append(record); return record
    }
    func view(at: EntryID? = nil) throws -> ContextView { try deriveContext(entries: entries, at: at) }
}

@Suite struct HarnessContextTests {
    @Test("returns the whole transcript without a head and excludes model-less entries from messages")
    func whole() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("hi")); _ = try transcript.append(kind: "note"); _ = try transcript.append(contextAssistant("hello"))
        let view = try transcript.view()
        #expect(view.head == nil); #expect(view.entries.count == 3)
        #expect(view.messages.map(contextDescription) == ["user:hi", "assistant:hello"])
    }
    @Test("excludes aborted, error, and deferred assistant messages but keeps their raw entries")
    func excluded() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("q"))
        for reason in [StopReason.aborted, .error, .deferred] { _ = try transcript.append(contextAssistant("partial", reason: reason)) }
        _ = try transcript.append(contextAssistant("done", reason: .length))
        #expect(try transcript.view().entries.count == 5)
        #expect(try transcript.view().messages.map(contextDescription) == ["user:q", "assistant:done"])
    }
    @Test("resolves self heads and uses the newest head marker")
    func heads() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("old"))
        let reset = try transcript.append(contextUser("fresh start"), kind: "pi.reset", head: 2)
        let after = try transcript.append(contextAssistant("after reset"))
        #expect(try transcript.view().entries.map(\.id) == [reset.id, after.id])
        let summary = try transcript.append(contextUser("summary"), kind: "pi.compaction", head: after.id.rawValue)
        let tail = try transcript.append(contextUser("next"))
        let view = try transcript.view()
        #expect(view.head?.id == summary.id)
        #expect(view.entries.map(\.id) == [summary.id, after.id, tail.id])
        #expect(view.messages.map(contextDescription) == ["user:summary", "assistant:after reset", "user:next"])
    }
    @Test("applies the newest edit per target within the active range")
    func edits() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first")), second = try transcript.append(contextUser("second"))
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v2")]))])
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v3")]))])
        _ = try transcript.append(kind: "edit", edits: [.omit(target: second.id)])
        #expect(try transcript.view().messages.map(contextDescription) == ["user:first v3"])
        _ = try transcript.append(kind: "reset", head: second.id.rawValue)
        #expect(try transcript.view().messages.isEmpty)
        _ = try transcript.append(kind: "edit", edits: [.replace(target: second.id, messages: EntryRecord.encodeMessages([contextUser("second v2")]))])
        #expect(try transcript.view().messages.map(contextDescription) == ["user:second v2"])
    }
    @Test("keeps positional system messages and orders tool results by call order")
    func results() throws {
        var transcript = ContextTranscript()
        for message in [contextSystem("preamble"), contextUser("run tools"), contextAssistant("calling", calls: ["b","a"]), contextResult("a"), contextSystem("cwd"), contextResult("b"), contextResult("zz"), contextAssistant("done")] { _ = try transcript.append(message) }
        #expect(try transcript.view().messages.map(contextDescription) == ["system:preamble", "user:run tools", "assistant:calling", "result:b:result b", "result:a:result a", "system:cwd", "assistant:done"])
    }
    @Test("leads with a system message that only user messages precede, and keeps later ones in place")
    func leading() throws {
        var transcript = ContextTranscript()
        for message in [contextUser("first"), contextUser("steered"), contextSystem("preamble"), contextAssistant("answer"), contextUser("next"), contextSystem("cwd")] { _ = try transcript.append(message) }
        let view = try transcript.view()
        #expect(view.messages.map(contextDescription) == ["system:preamble", "user:first", "user:steered", "assistant:answer", "user:next", "system:cwd"])
        #expect(view.contributions.flatMap { $0 }.prefix(3).map(contextDescription) == ["user:first", "user:steered", "system:preamble"])
        _ = try transcript.append(contextUser("handoff"), kind: "reset", head: 7)
        _ = try transcript.append(contextSystem("preamble"))
        #expect(try transcript.view().messages.map(contextDescription) == ["system:preamble", "user:handoff"])
    }
    @Test("synthesizes missing tool results after a fork and drops results cut from their call")
    func missing() throws {
        var transcript = ContextTranscript()
        _ = try transcript.append(contextUser("go"))
        let call = try transcript.append(contextAssistant("calling", calls: ["x","y"]))
        _ = try transcript.append(contextResult("x")); let second = try transcript.append(contextResult("y"))
        let cut = try transcript.view(at: call.id)
        #expect(cut.messages.map(contextDescription) == ["user:go", "assistant:calling", "result:x:error", "result:y:error"])
        if case .toolResult(let result) = cut.messages[2] {
            #expect(result.toolName == "tool-x"); #expect(result.details == AnyCodable(["reason":"missing_result"]))
        } else { Issue.record("Missing error result") }
        _ = try transcript.append(kind: "reset", head: second.id.rawValue)
        #expect(try transcript.view().messages.isEmpty)
        #expect(try transcript.view().entries.map(\.kind) == ["reset", "message"])
    }
    @Test("reads the context as of an earlier entry, as a fork at that entry starts")
    func earlier() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first"))
        let call = try transcript.append(contextAssistant("calling", calls: ["x","y"]))
        _ = try transcript.append(contextResult("x")); _ = try transcript.append(contextResult("y"))
        _ = try transcript.append(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([contextUser("first v2")]))])
        _ = try transcript.append(contextUser("fresh start"), kind: "reset", head: 6)
        let tail = try transcript.append(contextAssistant("after reset"))
        for at in transcript.entries.map(\.id) {
            let fork = try deriveContext(entries: transcript.entries.filter { $0.id <= at })
            #expect(try transcript.view(at: at).messages.map(contextDescription) == fork.messages.map(contextDescription))
        }
        #expect(try transcript.view(at: call.id).messages.map(contextDescription) == ["user:first", "assistant:calling", "result:x:error", "result:y:error"])
        #expect(try transcript.view(at: tail.id).messages.map(contextDescription) == transcript.view().messages.map(contextDescription))
    }
    @Test("edits of discarded older heads affect kept entries")
    func olderHeadEdits() throws {
        var transcript = ContextTranscript()
        let first = try transcript.append(contextUser("first"))
        _ = try transcript.append(kind: "old-head", head: first.id.rawValue, edits: [.omit(target: first.id)])
        _ = try transcript.append(contextUser("summary"), kind: "new-head", head: first.id.rawValue)
        #expect(try transcript.view().messages.map(contextDescription) == ["user:summary"])
    }
}
