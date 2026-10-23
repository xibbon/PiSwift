import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func baselineUser(_ text: String) throws -> EntryDraft {
    EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([.user(UserMessage(content: .text(text), timestamp: 1))]))
}
private func baselineSystem(_ key: String, kind: String = "pi.system") throws -> EntryDraft {
    EntryDraft(kind: kind, model: try EntryRecord.encodeMessages([.system(SystemMessage(content: .text(""), sections: .init([(key, key)]), timestamp: 1))]))
}
private func baselineDescription(_ messages: [Message]) -> [String] {
    messages.map { message in
        if case .system(let system) = message { return "system:\(system.sections?.entries.map(\.name).joined(separator: ",") ?? "")" }
        return "\(message.role):\(textOf(message) ?? "")"
    }
}

@Suite struct HarnessBaselineContextTests {
    // v1.3.0 harness-context.test.ts:712–790. Each read uses the task runtime's range cache.
    @Test func runtimeFindsLateBaselineAndKeepsDisqualifiedBaselineAcrossForkReads() async throws {
        let storage = H6CountingStorage(), registry = Registry()
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry), context: .background)
        let root = try await harness.root(context: .background)
        let first = try await root.commit({ tx in try await tx.appendEntry(root.id, value: baselineUser("first")) }, context: .background)
        for index in 0..<20 {
            _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "message", model: EntryRecord.encodeMessages([.assistant(chatAssistant("old \(index)"))]))) }, context: .background)
        }
        let definition = harnessOneStep("test.D5-context-baseline") { _, runtime, context in
            func append(_ conversation: Conversation, _ draft: EntryDraft) async throws -> EntryRecord {
                let appended = SessionTestLog<EntryRecord>()
                try await runtime.commit({ tx, _ in appended.append(try await tx.appendEntry(conversation.id, value: draft)); return nil }, context: context)
                return try #require(appended.values.first)
            }
            func read(_ conversation: Conversation) async throws -> (messages: [String], rows: Int) {
                let before = storage.rows
                let view = try await runtime.context(conversation.id, context: context), rows = storage.rows - before
                let whole = try await conversation.context(context: context)
                #expect(view.entries == whole.entries)
                #expect(try EntryRecord.encodeMessages(view.messages) == EntryRecord.encodeMessages(whole.messages))
                return (baselineDescription(view.messages), rows)
            }
            #expect(try await read(root).messages.first == "user:first")
            _ = try await append(root, baselineSystem("plan"))
            let discovered = try await read(root)
            #expect(discovered.rows == 2)
            #expect(Array(discovered.messages.prefix(3)) == ["system:plan", "user:first", "assistant:old 0"])

            let fork = try await root.fork(at: first.id, options: .init(ownership: .ownerless()), context: context)
            _ = try await append(fork, EntryDraft(kind: "message", model: EntryRecord.encodeMessages([.assistant(chatAssistant("answer"))])))
            _ = try await append(fork, baselineSystem("note", kind: "host.system"))
            #expect(try await read(fork).messages == ["user:first", "assistant:answer", "system:note"])
            _ = try await append(fork, baselineSystem("note"))
            let positional = try await read(fork)
            #expect(positional.rows == 2)
            #expect(positional.messages == ["user:first", "assistant:answer", "system:note", "system:note"])

            let omitted = try await root.fork(at: first.id, options: .init(ownership: .ownerless()), context: context)
            _ = try await append(omitted, EntryDraft(kind: "message", model: EntryRecord.encodeMessages([.assistant(chatAssistant("answer"))])))
            let host = try await append(omitted, baselineSystem("legacy", kind: "host.system"))
            _ = try await append(omitted, EntryDraft(kind: "edit", edits: [.omit(target: host.id)]))
            #expect(try await read(omitted).messages == ["user:first", "assistant:answer"])
            _ = try await append(omitted, baselineSystem("legacy"))
            let legacy = try await read(omitted)
            #expect(legacy.rows == 2)
            #expect(legacy.messages == ["user:first", "assistant:answer", "system:legacy"])

            let empty = try await root.fork(at: first.id, options: .init(ownership: .ownerless()), context: context)
            _ = try await append(empty, EntryDraft(kind: "pi.system"))
            _ = try await append(empty, EntryDraft(kind: "message", model: EntryRecord.encodeMessages([.assistant(chatAssistant("answer"))])))
            #expect(try await read(empty).messages == ["user:first", "assistant:answer"])
            _ = try await append(empty, baselineSystem("s"))
            let delta = try await read(empty)
            #expect(delta.rows == 2)
            #expect(delta.messages == ["user:first", "assistant:answer", "system:s"])
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "D5-baseline", tasks: [AnyTaskDefinition(definition)]))
        #expect(try await harness.waitForTask(id: harnessStart(root, definition), context: .background).outcome == .completed(result: 1))
        try await harness.close(context: .background)
    }

    @Test func byteEqualReplacementDoesNotTakeBaselineIdentity() throws {
        let user = try baselineUser("kept").model, assistant = try EntryRecord.encodeMessages([.assistant(chatAssistant("answer"))]), system = try baselineSystem("preamble").model
        let kept = try EntryRecord(id: EntryID(1), conversationId: rootConversationID, kind: "message", model: user)
        let answer = try EntryRecord(id: EntryID(2), conversationId: rootConversationID, kind: "message", model: assistant)
        let head = try EntryRecord(id: EntryID(3), conversationId: rootConversationID, kind: "summary", model: user, head: kept.id)
        let baseline = try EntryRecord(id: EntryID(4), conversationId: rootConversationID, kind: "pi.system", model: system)
        let edit = try EntryRecord(id: EntryID(5), conversationId: rootConversationID, kind: "edit", edits: [.replace(target: baseline.id, messages: #require(system))])
        #expect(try baselineDescription(deriveContext(entries: [kept, answer, head, baseline]).messages) == ["system:preamble", "user:kept", "user:kept", "assistant:answer"])
        #expect(try baselineDescription(deriveContext(entries: [kept, answer, head, baseline, edit]).messages) == ["user:kept", "user:kept", "assistant:answer", "system:preamble"])
    }
}
