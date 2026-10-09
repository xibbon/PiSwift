import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessCompactionFacadeTests {
    // H6 H8 deferral: harness-lifecycle.test.ts:393.
    @Test func compactRejectsWhenCloseStartsDuringCommit() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup()
        let opened = try await openChat(storage: storage, setup: setup)
        let tasks = Mutex<[TaskRecord]>([])
        let subscription = try opened.harness.subscribeCommits { publication, _ in
            for change in publication.changes { if case .task(let record) = change { tasks.withLock { $0.append(record) } } }
        }
        defer { subscription.cancel() }
        let held = await storage.holdCommits(), root = opened.root
        let writing = Task { try await root.commit({ tx in
            _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "blocker"))
        }, context: .background) }
        await held.waitUntilEntered()
        let closing = Task { try await opened.harness.close(context: .background) }
        try await eventually { opened.harness.tasks.closing }
        do {
            _ = try await root.compact(context: .background)
            Issue.record("compact admitted after close started")
        } catch { #expect(String(describing: error).contains("closed")) }
        await held.release()
        try await writing.value
        try await closing.value
        #expect(tasks.withLock { !$0.contains { $0.kind == "pi.compaction" } })
    }
    // H6 H8 deferral: harness-lifecycle.test.ts:565, D3 SQLite paused reopen.
    @Test func compactResumesSchedulingAfterPausedSqliteReopen() async throws {
        let directory = try sqliteTestDirectory(), path = directory.appendingPathComponent("compact-resume.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = HarnessChatSetup(settings: .init(compaction: .init(enabled: false, keepRecentTokens: 1)))
        let ran = HarnessChatSignal()
        let definition = harnessOneStep("test.h8-resume") { _, runtime, context in
            ran.signal()
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try setup.registry.install(Extension(name: "resume", tasks: [AnyTaskDefinition(definition)]))
        var opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        let background = try await opened.root.commit({ tx in
            for text in ["old history", "recent input"] {
                _ = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: userEntry.kind,
                    model: EntryRecord.encodeMessages([.user(UserMessage(content: .text(text), timestamp: 1))])))
            }
            return try await tx.createTask(definition, input: 0,
                options: .init(ownership: .conversation(), conversationId: opened.root.id, background: true))
        }, context: .background)
        #expect(try await opened.harness.inspect(context: .background).scheduling == .paused)
        try await opened.harness.close(context: .background)
        opened = try await openChat(storage: SqliteStorage.open(path: path.path), setup: setup)
        #expect(try await opened.harness.getTask(id: background, context: .background)?.state.status == "pending")
        #expect(try await opened.harness.inspect(context: .background).scheduling == .paused)
        #expect(!ran.isSignalled)
        let held = HarnessUnanswered()
        setup.models.setResponses([held.step])
        let compact = try await opened.root.compact(context: .background)
        await held.reached.wait()
        await ran.wait()
        #expect(try await opened.harness.getTask(id: compact, context: .background)?.state.status == "running")
        #expect(try await opened.harness.inspect(context: .background).scheduling == .running)
        try await opened.root.abort(context: .background)
        #expect(try await opened.harness.waitForTask(id: compact, context: .background).outcome.status == "aborted")
        try await opened.harness.close(context: .background)
    }
    @Test func publicCompactionExampleWaitsForPlacedSummary() async throws {
        let settings = HarnessSettings(compaction: .init(enabled: true, reserveTokens: 1000,
            keepRecentTokens: 150, backgroundTokens: 300))
        let models = FakeDurableModels(responses: [.message(chatAssistant("SUMMARY"))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models,
            registry: createRegistry(), settings: HarnessSettingsProvider { settings }), context: .background)
        let conversation = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        for text in [compactionText("old", 200), compactionText("recent", 200)] {
            _ = try await conversation.submit(.write(entry: EntryDraft(kind: userEntry.kind,
                model: EntryRecord.encodeMessages([.user(UserMessage(content: .text(text), timestamp: 1))]))), context: .background)
        }
        let id = try await conversation.compact(instructions: "Preserve file paths", context: .background)
        let task = try await harness.waitForTask(id: id, context: .background)
        guard case .completed(let value, _) = task.outcome else { Issue.record("Compaction failed"); return }
        let result = try value.decode(CompactionResult.self)
        let submissionId = try #require(result.submissionId)
        let write = try #require(await harness.submission(id: submissionId, context: .background))
        let placed = try await write.wait(context: .background)
        #expect(placed.status == "done")
        #expect(try await allEntries(conversation).last?.kind == "pi.compaction")
        try await harness.close(context: .background)
    }
}
