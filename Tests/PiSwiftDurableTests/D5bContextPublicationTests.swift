import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d5bContextUser(_ text: String) throws -> EntryDraft {
    EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([
        .user(UserMessage(content: .text(text), timestamp: 1))
    ]))
}

private func d5bExpectSameContext(_ actual: ContextView, _ expected: ContextView) throws {
    #expect(actual.head == expected.head)
    #expect(actual.entries == expected.entries)
    #expect(try EntryRecord.encodeMessages(actual.messages) == EntryRecord.encodeMessages(expected.messages))
    #expect(try actual.contributions.map(EntryRecord.encodeMessages) == expected.contributions.map(EntryRecord.encodeMessages))
}

private func d5bContextCase(
    _ name: String,
    run: @escaping @Sendable (TaskRuntime, ChordContext, Conversation, H6CountingStorage, [EntryRecord]) async throws -> Void
) async throws {
    let storage = H6CountingStorage(), registry = Registry()
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: registry), context: .background)
    let root = try await harness.root(context: .background)
    var records: [EntryRecord] = []
    for text in ["first", "second", "third"] {
        records.append(try await root.commit({ tx in
            try await tx.appendEntry(root.id, value: d5bContextUser(text))
        }, context: .background))
    }
    let entries = records
    let definition = harnessOneStep("test.d5b-context-\(name)") { _, runtime, context in
        try await run(runtime, context, root, storage, entries)
        try await runtime.commit({ _, _ in try completed(1) }, context: context)
    }
    try registry.install(Extension(name: "d5b-context-\(name)", tasks: [AnyTaskDefinition(definition)]))
    #expect(try await harness.waitForTask(id: harnessStart(root, definition), context: .background).outcome == .completed(result: 1))
    try await harness.close(context: .background)
}

@Suite struct D5bContextPublicationTests {
    // v1.5.2 harness-context.test.ts:452,458. The existing test covers plain entries and edits.
    @Test("extends a task's context read with only newer entries — forward heads", .timeLimit(.minutes(1)))
    func forwardHeadsUsePublishedEntries() async throws {
        try await d5bContextCase("forward-head") { runtime, context, root, storage, entries in
            _ = try await runtime.context(root.id, context: context)
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "summary", model: d5bContextUser("summary").model, head: .entry(entries[1].id)))
                _ = try await tx.appendEntry(root.id, value: d5bContextUser("tail"))
                return nil
            }, context: context)
            var before = storage.rangeScans
            let summary = try await runtime.context(root.id, context: context)
            #expect(storage.rangeScans == before)
            try d5bExpectSameContext(summary, await root.context(context: context))
            #expect(summary.entries.map(\.kind) == ["summary", "message", "message", "message"])
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "reset", model: d5bContextUser("fresh").model, head: .self))
                return nil
            }, context: context)
            before = storage.rangeScans
            let reset = try await runtime.context(root.id, context: context)
            #expect(storage.rangeScans == before)
            #expect(reset.entries.map(\.kind) == ["reset"])
            try d5bExpectSameContext(reset, await root.context(context: context))
        }
    }

    @Test("extends a task's context read with only newer entries — an older head needs a scan", .timeLimit(.minutes(1)))
    func backwardHeadLoadsDiscardedEntries() async throws {
        try await d5bContextCase("older-head") { runtime, context, root, storage, entries in
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "summary", head: .entry(entries[2].id)))
                return nil
            }, context: context)
            _ = try await runtime.context(root.id, context: context)
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "summary", head: .entry(entries[0].id)))
                return nil
            }, context: context)
            let before = storage.rangeScans
            let restored = try await runtime.context(root.id, context: context)
            #expect(storage.rangeScans == before + 1)
            #expect(restored.entries.contains { $0.id == entries[0].id })
            try d5bExpectSameContext(restored, await root.context(context: context))
        }
    }

    @Test("reads the context as of an earlier entry, as a fork at that entry starts — publication after a cutoff", .timeLimit(.minutes(1)))
    func historicalRangeDoesNotConsumePublishedEntries() async throws {
        try await d5bContextCase("cutoff") { runtime, context, root, storage, entries in
            let cut = try await runtime.context(root.id, at: entries[1].id, context: context)
            #expect(cut.entries.map(\.id) == Array(entries.prefix(2)).map(\.id))
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: d5bContextUser("new"))
                return nil
            }, context: context)
            let before = storage.rows
            let current = try await runtime.context(root.id, context: context)
            #expect(storage.rows - before == 2)
            #expect(current.entries.count == 4)
            try d5bExpectSameContext(current, await root.context(context: context))
            let scans = storage.rangeScans
            try d5bExpectSameContext(await runtime.context(root.id, at: entries[1].id, context: context), cut)
            #expect(storage.rangeScans == scans)
        }
    }

    @Test("derives the same view from extended reads as from whole reads — publication during a scan", .timeLimit(.minutes(1)))
    func publicationDuringScanDoesNotMarkAnOldRangeCurrent() async throws {
        try await d5bContextCase("scan-race") { runtime, context, root, storage, entries in
            let gate = SessionTestGate()
            storage.holdNextRange(gate)
            let reading = Task { try await runtime.context(root.id, context: context) }
            await storage.scanStarted.wait()
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: d5bContextUser("during scan"))
                return nil
            }, context: context)
            gate.release()
            let old = try await reading.value
            #expect(old.entries.map(\.id) == entries.map(\.id))
            // A later publication must not extend the old range across the missing entry.
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: d5bContextUser("after scan"))
                return nil
            }, context: context)
            let before = storage.rows
            let current = try await runtime.context(root.id, context: context)
            #expect(storage.rows - before == 2)
            #expect(current.entries.count == 5)
            try d5bExpectSameContext(current, await root.context(context: context))
        }
    }
}
