import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func h6User(_ text: String) throws -> EntryDraft {
    EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([.user(UserMessage(content: .text(text), timestamp: 1))]))
}
private func h6Assistant(_ text: String, calls: [String] = [], reason: StopReason = .stop) throws -> EntryDraft {
    var message = chatAssistant(text, reason: reason)
    message.content += calls.map { .toolCall(ToolCall(id: $0, name: "tool", arguments: [:])) }
    return EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([.assistant(message)]))
}
private func h6SameView(_ left: ContextView, _ right: ContextView) throws -> Bool {
    let leftMessages = try EntryRecord.encodeMessages(left.messages)
    let rightMessages = try EntryRecord.encodeMessages(right.messages)
    let leftContributions = try left.contributions.map(EntryRecord.encodeMessages)
    let rightContributions = try right.contributions.map(EntryRecord.encodeMessages)
    return left.head == right.head && left.entries == right.entries && leftMessages == rightMessages && leftContributions == rightContributions
}
private func h6ContextSetup(settings: HarnessSettings = .init(), clock: any DurableClock = SystemDurableClock()) async throws -> (Harness, Registry, Conversation, H6CountingStorage, EntryRecord) {
    let storage = H6CountingStorage(), registry = Registry()
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: registry, settings: HarnessSettingsProvider { settings }, clock: clock), context: .background)
    let root = try await harness.root(context: .background)
    let first = try await root.commit({ tx in try await tx.appendEntry(root.id, value: h6User("first")) }, context: .background)
    for index in 0..<20 { _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: h6Assistant("old \(index)")) }, context: .background) }
    return (harness, registry, root, storage, first)
}

@Suite struct HarnessRunControlContextTests {
    // upstream harness-context.test.ts:223. H3 covered pure bounds; this checks Session visibility.
    @Test func asOfContextMatchesForkAndRejectsInvisibleEntry() async throws {
        let opened = try await openHarness(); let harness = opened.harness
        let root = try await harness.root(context: .background)
        let first = try await root.commit({ tx in try await tx.appendEntry(root.id, value: h6User("first")) }, context: .background)
        let call = try await root.commit({ tx in try await tx.appendEntry(root.id, value: h6Assistant("calling", calls: ["x", "y"])) }, context: .background)
        let edit = try await root.commit({ tx in
            try await tx.appendEntry(root.id, value: EntryDraft(kind: "edit", edits: [.replace(target: first.id, messages: EntryRecord.encodeMessages([.user(UserMessage(content: .text("first v2"), timestamp: 1))]))]))
        }, context: .background)
        let reset = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "reset", model: h6User("fresh").model, head: .self)) }, context: .background)
        let tail = try await root.commit({ tx in try await tx.appendEntry(root.id, value: h6Assistant("after")) }, context: .background)
        for at in [first, call, edit, reset, tail] {
            let fork = try await root.fork(at: at.id, options: .init(ownership: .ownerless()), context: .background)
            #expect(try h6SameView(await root.context(at: at.id, context: .background), await fork.context(context: .background)))
        }
        let other = try await root.fork(at: first.id, options: .init(ownership: .ownerless()), context: .background)
        do { _ = try await other.context(at: tail.id, context: .background); Issue.record("Invisible entry returned") }
        catch { #expect(String(describing: error).contains("is not visible")) }
        try await harness.close(context: .background)
    }

    // upstream harness-context.test.ts:254.
    @Test func runtimeExtendsOnlyNewRowsAndReusesCutoffBeforeAnEdit() async throws {
        let (harness, registry, root, storage, first) = try await h6ContextSetup()
        let rows = SessionTestLog<Int>()
        let definition = harnessOneStep("test.h6-context-range") { _, runtime, context in
            let initial = try await runtime.context(root.id, context: context)
            #expect(try h6SameView(initial, await root.context(context: context)))
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: h6User("new"))
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "note"))
                _ = try await tx.appendEntry(root.id, value: h6Assistant("answer"))
                return nil
            }, context: context)
            var before = storage.rows
            let extended = try await runtime.context(root.id, context: context); rows.append(storage.rows - before)
            #expect(try h6SameView(extended, await root.context(context: context)))
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "edit", edits: [.omit(target: first.id)])); return nil
            }, context: context)
            before = storage.rows
            let edited = try await runtime.context(root.id, context: context); rows.append(storage.rows - before)
            #expect(try h6SameView(edited, await root.context(context: context)))
            before = storage.rows
            let cutoff = try await runtime.context(root.id, at: extended.entries.last!.id, context: context); rows.append(storage.rows - before)
            #expect(try h6SameView(cutoff, extended))
            try await runtime.commit({ tx, _ in
                _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "reset", model: h6User("fresh").model, head: .self)); return nil
            }, context: context)
            #expect(try h6SameView(await runtime.context(root.id, context: context), await root.context(context: context)))
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "range", tasks: [AnyTaskDefinition(definition)]))
        #expect(try await harness.waitForTask(id: harnessStart(root, definition), context: .background).outcome == .completed(result: 1))
        #expect(rows.values == [4, 2, 0])
        try await harness.close(context: .background)
    }

    // upstream harness-context.test.ts:322,644,671. The clock replaces fake JavaScript timers.
    @Test(arguments: [Int64(0), 1000, 600000])
    func contextRetentionExpiresWithNoOtherWork(retention: Int64) async throws {
        let clock = TestClock(now: 1000)
        let (harness, registry, root, storage, _) = try await h6ContextSetup(settings: .init(contextRetentionMs: retention), clock: clock)
        let rows = SessionTestLog<Int>()
        let definition = harnessOneStep("test.h6-context-retention") { _, runtime, context in
            let before = storage.rows
            _ = try await runtime.context(root.id, context: context)
            rows.append(storage.rows - before)
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "retention", tasks: [AnyTaskDefinition(definition)]))
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        try await root.waitForIdle(context: .background)
        if retention > 0 {
            try await eventually { clock.pendingSleeperCount == 1 }
            _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
            try await root.waitForIdle(context: .background)
            #expect(rows.values == [22, 1])
            clock.advance(by: retention)
            try await eventually { clock.pendingSleeperCount == 0 }
        }
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        #expect(rows.values.last == 22)
        try await harness.close(context: .background)
    }

    // upstream harness-context.test.ts:322.
    @Test func parentChildAndLaterTaskShareTheConversationRangeUntilExpiry() async throws {
        let clock = TestClock(now: 1000)
        let (harness, registry, root, storage, _) = try await h6ContextSetup(clock: clock)
        let rows = SessionTestLog<Int>()
        let child = harnessOneStep("test.h6-context-child") { _, runtime, context in
            try await runtime.commit({ tx, _ in _ = try await tx.appendEntry(root.id, value: h6User("from child")); return nil }, context: context)
            let before = storage.rows
            let view = try await runtime.context(root.id, context: context)
            rows.append(storage.rows - before)
            #expect(try h6SameView(view, await root.context(context: context)))
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let parent = harnessOneStep("test.h6-context-parent") { task, runtime, context in
            let before = storage.rows
            let view = try await runtime.context(root.id, context: context)
            rows.append(storage.rows - before)
            #expect(try h6SameView(view, await root.context(context: context)))
            if task.checkpoint.phase == .run {
                try await runtime.commit({ tx, _ in
                    let childId = try await tx.createTask(child, input: 0, options: .init(ownership: .task(taskId: runtime.taskId)))
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [childId], policy: .allSettled)
                }, context: context)
            } else { try await runtime.commit({ _, _ in try completed(1) }, context: context) }
        }
        let probe = harnessOneStep("test.h6-context-next") { _, runtime, context in
            let before = storage.rows
            _ = try await runtime.context(root.id, context: context)
            rows.append(storage.rows - before)
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "family", tasks: [AnyTaskDefinition(parent), AnyTaskDefinition(child), AnyTaskDefinition(probe)]))
        _ = try await harness.waitForTask(id: harnessStart(root, parent), context: .background)
        try await root.waitForIdle(context: .background)
        _ = try await harness.waitForTask(id: harnessStart(root, probe), context: .background)
        try await root.waitForIdle(context: .background)
        clock.advance(by: 600000)
        _ = try await harness.waitForTask(id: harnessStart(root, probe), context: .background)
        #expect(rows.values == [22, 2, 1, 1, 23])
        try await harness.close(context: .background)
    }

    // upstream harness-context.test.ts:523. Swift value copies replace JS frozen arrays.
    @Test func changingReturnedValueCopiesDoesNotChangeCachedContext() async throws {
        let (harness, registry, root, _, _) = try await h6ContextSetup()
        let definition = harnessOneStep("test.h6-context-copies") { _, runtime, context in
            let original = try await runtime.context(root.id, context: context)
            var messages = original.messages, entries = original.entries, contributions = original.contributions
            messages.removeAll(); entries.removeLast(); contributions[0].removeAll()
            #expect(messages.isEmpty && entries.count == 20 && contributions[0].isEmpty)
            #expect(try h6SameView(original, await runtime.context(root.id, context: context)))
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "copies", tasks: [AnyTaskDefinition(definition)]))
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        try await harness.close(context: .background)
    }
    // upstream harness-context.test.ts:602.
    @Test func aReadThatEndsAfterItsInvocationDoesNotEnterTheCache() async throws {
        let (harness, registry, root, storage, _) = try await h6ContextSetup(settings: .init(contextRetentionMs: 0))
        let scanGate = SessionTestGate(), probeGate = SessionTestGate()
        let late = Mutex<Task<ContextView, any Error>?>(nil), rows = SessionTestLog<Int>()
        let reader = harnessOneStep("test.h6-late-context") { _, runtime, context in
            storage.holdNextRange(scanGate)
            let operation = Task { try await runtime.context(root.id, context: context) }
            late.withLock { $0 = operation }
            await storage.scanStarted.wait()
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let probe = harnessOneStep("test.h6-probe-context") { _, runtime, context in
            await probeGate.wait()
            let before = storage.rows
            _ = try await runtime.context(root.id, context: context)
            rows.append(storage.rows - before)
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(reader), AnyTaskDefinition(probe)]))
        _ = try await harness.waitForTask(id: harnessStart(root, reader), context: .background)
        let probeId = try await harnessStart(root, probe)
        scanGate.release()
        let operation = try #require(late.withLock { $0 })
        _ = try? await operation.value
        probeGate.release()
        _ = try await harness.waitForTask(id: probeId, context: .background)
        #expect(rows.values == [22])
        try await harness.close(context: .background)
    }

    // upstream harness-context.test.ts:396. A fixed sequence includes edits, heads, cutoffs, and forks.
    @Test func incrementalReadsMatchWholeReadsThroughMixedTranscriptChanges() async throws {
        let (harness, registry, root, _, _) = try await h6ContextSetup()
        let definition = harnessOneStep("test.h6-mixed-context") { _, runtime, context in
            var written: [EntryRecord] = []
            var seed: UInt32 = 7
            func random(_ maximum: Int) -> Int {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return Int((UInt64(seed) * UInt64(maximum)) >> 32)
            }
            for index in 0..<150 {
                let pick = random(14)
                let draft: EntryDraft
                switch pick {
                case 0...2: draft = try h6User("u\(index)")
                case 3...4:
                    draft = try h6Assistant("a\(index)", calls: index.isMultiple(of: 2) ? ["c\(index)"] : [], reason: [.stop, .aborted, .error, .deferred][random(4)])
                case 5...7:
                    draft = EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([.toolResult(ToolResultMessage(toolCallId: "c\(index - 1)", toolName: "tool", content: [.text(TextContent(text: "result"))], isError: false, timestamp: 1))]))
                case 8:
                    draft = EntryDraft(kind: "message", model: try EntryRecord.encodeMessages([.system(SystemMessage(content: .text(""), sections: .init([("s", "v\(index)")]), timestamp: 1))]))
                case 9: draft = EntryDraft(kind: "note")
                case 10...11 where !written.isEmpty:
                    let target = written[random(written.count)].id
                    draft = EntryDraft(kind: "edit", edits: pick == 10 ? [.omit(target: target)] : [.replace(target: target, messages: try h6User("r\(index)").model!)])
                case 12 where !written.isEmpty:
                    draft = EntryDraft(kind: "summary", model: try h6User("h\(index)").model, head: .entry(written[random(written.count)].id))
                default: draft = try h6User("u\(index)")
                }
                try await runtime.commit({ tx, _ in
                    _ = try await tx.appendEntry(root.id, value: draft); return nil
                }, context: context)
                let view = try await runtime.context(root.id, context: context)
                #expect(try h6SameView(view, await root.context(context: context)))
                written = try await allEntries(root, context: context)
                if index.isMultiple(of: 10) {
                    let at = written[random(written.count)].id
                    async let whole = runtime.context(root.id, context: context)
                    async let cut = runtime.context(root.id, at: at, context: context)
                    #expect(try h6SameView(await whole, await root.context(context: context)))
                    #expect(try h6SameView(await cut, await root.context(at: at, context: context)))
                }
            }
            let fork = try await root.fork(at: written[random(written.count)].id, options: .init(ownership: .ownerless()), context: context)
            for index in 0..<20 {
                #expect(try h6SameView(await runtime.context(fork.id, context: context), await fork.context(context: context)))
                try await runtime.commit({ tx, _ in _ = try await tx.appendEntry(fork.id, value: h6User("fork \(index)")); return nil }, context: context)
            }
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try registry.install(Extension(name: "mixed", tasks: [AnyTaskDefinition(definition)]))
        _ = try await harness.waitForTask(id: harnessStart(root, definition), context: .background)
        try await harness.close(context: .background)
    }

}
import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Reject one selected write batch before it reaches storage.
final class H6CountingStorage: DurableStorage, Sendable {
    let base: any DurableStorage
    private let count = Mutex(0)
    private let holdState = Mutex<SessionTestGate?>(nil)
    let scanStarted = SessionTestGate()
    let submissionReadStarted = SessionTestGate()
    private let submissionHold = Mutex<SessionTestGate?>(nil)
    func holdSubmissionRead(_ gate: SessionTestGate) { submissionHold.withLock { $0 = gate } }
    var rows: Int { count.withLock { $0 } }
    init(_ base: any DurableStorage = MemoryStorage()) { self.base = base }
    func holdNextRange(_ gate: SessionTestGate) { holdState.withLock { $0 = gate } }
    func commit(_ writes: [StorageWrite], context: PiSwiftChord.Context) async throws -> Seq {
        try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await base.mintId()
    }

    func conversation(_ id: ConversationID, context: PiSwiftChord.Context) async throws -> ConversationRecord? {
        try await base.conversation(id, context: context)
    }

    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<ConversationRecord, Cursor> {
        try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }

    func entry(_ id: EntryID, context: PiSwiftChord.Context) async throws -> EntryLookup? {
        try await base.entry(id, context: context)
    }

    func entry(_ conversationId: ConversationID, id: EntryID, context: PiSwiftChord.Context) async throws -> EntryLookup? {
        try await base.entry(conversationId, id: id, context: context)
    }

    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: PiSwiftChord.Context) async throws -> EntryRecord? {
        try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }

    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<EntryRecord, Cursor> {
        if limit > 1 {
            let gate = holdState.withLock { state in let gate = state; state = nil; return gate }
            if let gate { scanStarted.release(); await gate.wait() }
        }
        let page = try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
        count.withLock { $0 += page.items.count }
        return page
    }

    func task(_ id: TaskID, context: PiSwiftChord.Context) async throws -> TaskRecord? {
        try await base.task(id, context: context)
    }

    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }

    func submission(_ id: SubmissionID, context: PiSwiftChord.Context) async throws -> SubmissionRecord? {
        let gate = submissionHold.withLock { value in let gate = value; value = nil; return gate }
        if let gate { submissionReadStarted.release(); await gate.wait() }
        return try await base.submission(id, context: context)
    }

    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<SubmissionRecord, Cursor> {
        try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }

    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: PiSwiftChord.Context) async throws -> SubmissionRecord? {
        try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }

    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: PiSwiftChord.Context) async throws -> DocumentRecord? {
        try await base.findDocument(address, at: at, context: context)
    }

    func document(_ id: DocumentID, at: DocumentPoint, context: PiSwiftChord.Context) async throws -> StoredDocument? {
        try await base.document(id, at: at, context: context)
    }

    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: PiSwiftChord.Context) async throws -> Page<DocumentRecord, Cursor> {
        try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }

    func close(context: PiSwiftChord.Context) async throws { try await base.close(context: context) }
}
