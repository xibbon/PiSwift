import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

private struct PromptTranscript {
    var entries: [EntryRecord] = []
    var next: Int64 = 1
    mutating func append(_ draft: EntryDraft) throws -> EntryID {
        let id = try EntryID(next); next += 1
        let head: EntryID?
        switch draft.head { case .self?: head = id; case .entry(let target)?: head = target; case nil: head = nil }
        entries.append(EntryRecord(id: id, conversationId: rootConversationID, kind: draft.kind,
                                   model: draft.model, data: draft.data, head: head, edits: draft.edits))
        return id
    }
    mutating func apply(_ desired: JSONObject, tools: [DurableToolDeclaration] = []) throws -> [EntryDraft] {
        let drafts = try planSystemEntries(view: deriveContext(entries: entries), desired: desired, tools: tools, timestamp: 7)
        for draft in drafts { _ = try append(draft) }
        let view = try deriveContext(entries: entries)
        #expect(replaySections(view.messages) == desired)
        #expect(getCurrentTools(view.messages).map(\.name) == tools.map { $0.declaration.name })
        for draft in drafts { #expect(draft.model?.first?["timestamp"] == .number(7)) }
        return drafts
    }
    mutating func marker(_ head: EntryDraftHead) throws -> EntryID {
        try append(EntryDraft(kind: "summary", model: try EntryRecord.encodeMessages([promptUser("summary")]), head: head))
    }
}
private func promptUser(_ text: String) -> Message { .user(UserMessage(content: .text(text), timestamp: 1)) }
private func patch(_ draft: EntryDraft) -> JSONValue? { draft.model?.first?["sections"] }
private func promptTool(_ name: String, _ description: String? = nil) throws -> DurableToolDeclaration {
    try DurableToolDeclaration(name: name, description: description ?? name, parameters: ["type": .string("object"), "properties": .object([:])])
}
private enum PromptTestError: Error { case render, cancelled }

@Suite struct HarnessPromptTests {
    @Test("renders sections in order with tags, omissions, wrappers, and failures")
    func rendering() async throws {
        let registry = createRegistry()
        try registry.install(Extension(name: "base", sections: [
            section("preamble", tag: false) { _, _ in "You are helpful." },
            section("cwd") { _, _ in "/repo" }, section("skipped") { _, _ in nil },
            section("failing") { _, _ in throw PromptTestError.render },
            section("new-failing") { _, _ in throw PromptTestError.render }
        ]))
        try registry.install(Extension(name: "git", wraps: [wrapSection("cwd") { inner in
            var result = inner
            result.render = { input, context in "\(try await inner.render(input, context) ?? "") (git)" }
            return result
        }]))
        let reports = Mutex(0)
        let agent = resolveAgent(state: nil, snapshot: registry.snapshot(), settings: resolveSettings(nil))
        let shown: JSONObject = ["failing": .string("<failing>\nold\n</failing>"), "cwd": .string("stale")]
        let desired = try await renderSections(agent.sections, input: PromptInput(conversationId: rootConversationID, agent: agent), shown: shown,
                                             report: { _ in reports.withLock { $0 += 1 } }, context: .background)
        #expect(desired == ["preamble": .string("You are helpful."), "cwd": .string("<cwd>\n/repo (git)\n</cwd>"), "failing": .string("<failing>\nold\n</failing>")])
        #expect(reports.withLock { $0 } == 2)
    }

    @Test("propagates section errors after cancellation")
    func cancellation() async throws {
        let cancelled = ChordContext.background.withCancel(); cancelled.cancel()
        let input = PromptInput(conversationId: rootConversationID, agent: Agent())
        await #expect(throws: PromptTestError.cancelled) {
            try await renderSections([section("a") { _, _ in throw PromptTestError.cancelled }], input: input, shown: [:], context: cancelled.context)
        }
    }

    @Test("replays sections in place, deletes on null, and appends re-additions")
    func replay() {
        func system(_ sections: [(String, String?)]) -> Message { .system(SystemMessage(content: .text(""), sections: .init(sections), timestamp: 1)) }
        #expect(replaySections([system([("a", "1"), ("b", "2"), ("c", "3")]), promptUser("x"), system([("b", "20"), ("a", nil)]), system([("a", "10")])]) == ["b": .string("20"), "c": .string("3"), "a": .string("10")])
    }

    @Test("emits minimal value patches, removals, and additions")
    func minimal() throws {
        var transcript = PromptTranscript()
        #expect(try transcript.apply(["a": "1", "b": "2", "c": "3"]).map(patch) == [.object(["a": "1", "b": "2", "c": "3"])])
        #expect(try transcript.apply(["a": "1", "b": "20", "c": "3", "d": "4"]).map(patch) == [.object(["b": "20", "d": "4"])])
        #expect(try transcript.apply(["a": "1", "c": "3", "d": "4"]).map(patch) == [.object(["b": .null])])
        #expect(try transcript.apply(["a": "1", "c": "3", "d": "4"]).isEmpty)
        #expect(try transcript.apply([:]).map(patch) == [.object(["a": .null, "c": .null, "d": .null])])
    }

    @Test("rewrites order-only changes and re-additions as two entries")
    func reorder() throws {
        var transcript = PromptTranscript()
        _ = try transcript.apply(["a": "1", "b": "2"])
        #expect(try transcript.apply(["b": "2", "a": "1"]).map(patch) == [.object(["a": .null, "b": .null]), .object(["b": "2", "a": "1"])])
        var readded = PromptTranscript()
        _ = try readded.apply(["a": "1", "b": "2", "c": "3"])
        #expect(try readded.apply(["a": "1", "c": "3"]).map(patch) == [.object(["b": .null])])
        #expect(try readded.apply(["a": "1", "b": "2", "c": "3"]).map(patch) == [.object(["a": .null, "c": .null]), .object(["a": "1", "b": "2", "c": "3"])])
    }

    @Test("rebaselines after a head marker, omitting retained deltas on both sides of it")
    func rebaseline() throws {
        var transcript = PromptTranscript()
        _ = try transcript.apply(["a": "1", "b": "2"])
        _ = try transcript.append(EntryDraft(kind: "pi.user", model: EntryRecord.encodeMessages([promptUser("hi")])))
        _ = try transcript.apply(["a": "1", "b": "20"])
        let delta = transcript.entries.last!.id
        _ = try transcript.marker(.entry(delta))
        let first = try transcript.apply(["a": "1", "b": "20"])
        #expect(first.first?.edits == [.omit(target: delta)])
        let baseline = transcript.entries.last!.id
        #expect(try transcript.apply(["a": "1", "b": "21"]).map(patch) == [.object(["b": "21"])])
        let after = transcript.entries.last!.id
        _ = try transcript.marker(.entry(delta))
        #expect(try transcript.apply(["a": "1", "b": "21"]).first?.edits == [.omit(target: delta), .omit(target: baseline), .omit(target: after)])
    }

    @Test("writes a complete post-head baseline even when replay already matches")
    func baselineMatches() throws {
        var transcript = PromptTranscript()
        _ = try transcript.apply(["a": "1"])
        let baseline = transcript.entries.last!.id
        _ = try transcript.marker(.entry(baseline))
        let first = try transcript.apply(["a": "1"])
        #expect(first.first?.edits == [.omit(target: baseline)])
        #expect(first.map(patch) == [.object(["a": "1"])])
        _ = try transcript.marker(.self)
        #expect(try transcript.apply([:]).map(patch) == [.object([:])])
        #expect(try transcript.apply([:]).isEmpty)
    }

    @Test("adds, removes, replaces changed declarations, and rewrites the order when needed")
    func toolChanges() throws {
        var transcript = PromptTranscript()
        let a = try promptTool("a"), b = try promptTool("b"), c = try promptTool("c")
        func names(_ drafts: [EntryDraft], _ key: String) -> [String]? {
            drafts.last?.model?.first?[key]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        }
        #expect(try names(transcript.apply([:], tools: [a,b]), "toolsAdded") == ["a","b"])
        #expect(try transcript.apply([:], tools: [a,b]).isEmpty)
        #expect(try names(transcript.apply([:], tools: [a,b,c]), "toolsAdded") == ["c"])
        #expect(try names(transcript.apply([:], tools: [a,c]), "toolsRemoved") == ["b"])
        let c2 = try promptTool("c", "changed")
        let replaced = try transcript.apply([:], tools: [a,c2])
        #expect(names(replaced, "toolsRemoved") == ["c"]); #expect(names(replaced, "toolsAdded") == ["c"])
        let a2 = try promptTool("a", "changed")
        #expect(try names(transcript.apply([:], tools: [a2,c2]), "toolsRemoved") == ["a","c"])
        #expect(try names(transcript.apply([:], tools: [c2,a2]), "toolsAdded") == ["c","a"])
        #expect(try names(transcript.apply([:], tools: []), "toolsRemoved") == ["c","a"])
    }

    @Test("puts tool changes on the last section entry and re-declares every tool after a head cut")
    func toolChangesLast() throws {
        var transcript = PromptTranscript()
        let a = try promptTool("a"), b = try promptTool("b")
        _ = try transcript.apply(["x": "1", "y": "2"], tools: [a])
        let reordered = try transcript.apply(["y": "2", "x": "1"], tools: [a,b])
        #expect(reordered.count == 2)
        #expect(reordered.first?.model?.first?["toolsAdded"] == nil)
        #expect(reordered.last?.model?.first?["toolsAdded"]?.arrayValue?.count == 1)
        _ = try transcript.marker(.self)
        #expect(try transcript.apply(["y": "2", "x": "1"], tools: [a,b]).first?.model?.first?["toolsAdded"]?.arrayValue?.count == 2)
    }

    @Test("schema key order changes cause a new declaration")
    func schemaOrder() throws {
        let left = try DurableToolDeclaration(name: "x", description: "x", parameters: ["type": "object", "properties": .object([:])])
        let right = try DurableToolDeclaration(name: "x", description: "x", parameters: ["properties": .object([:]), "type": "object"])
        #expect(try !durableDeclarationsEqual(left, right))
        var transcript = PromptTranscript()
        _ = try transcript.apply([:], tools: [left])
        let changed = try transcript.apply([:], tools: [right])
        #expect(changed.first?.model?.first?["toolsRemoved"]?.arrayValue?.count == 1)
        #expect(changed.first?.model?.first?["toolsAdded"]?.arrayValue?.count == 1)
    }
}
