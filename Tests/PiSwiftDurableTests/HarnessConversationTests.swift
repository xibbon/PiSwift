import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func harnessNote() throws -> RewindableConversationDocToken<JSONObject> {
    try RewindableConversationDocToken(kind: "h5.note", version: 1, fork: .asOf, initial: { ["text": ""] })
}
private func harnessAppend(_ conversation: Conversation, _ text: String) async throws -> EntryRecord {
    try await conversation.commit({ tx in try await tx.appendEntry(conversation.id, value: EntryDraft(kind: "message", data: .string(text))) }, context: .background)
}
private func harnessEntries(_ conversation: Conversation, order: ScanOrder? = nil) async throws -> [String] {
    var values: [String] = []; var cursor: Cursor?
    repeat {
        let page = try await conversation.entries(order: order, limit: 2, cursor: cursor, context: .background)
        values += page.items.compactMap { $0.data?.stringValue }; cursor = page.next
    } while cursor != nil
    return values
}
private func facadeError(_ text: String, _ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected \(text)") }
    catch { #expect(String(describing: error).contains(text)) }
}
private let dormantKind = TaskKind<JSONObject, JSONObject>(name: "h5.dormant", version: 1, initial: { _ in ["phase": "run"] })

@Suite struct HarnessConversationTests {
    // harness-conversations.test.ts:77. H6 creates the remaining built-in documents.
    @Test func rootCreatedWithAgentAndInitInOneCommit() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage); let note = try harnessNote()
        #expect(await storage.commits.isEmpty)
        let root = try await h.harness.root(options: .init(agent: .init(thinkingLevel: .set(.high)), initialize: { tx, id in
            let draft = try await tx.doc(AgentDoc, conversationId: id)
            #expect(try draft.snapshot()["thinkingLevel"] == "high")
            try await tx.doc(note, conversationId: id).set("text", "root note")
        }), context: .background)
        #expect(root.id == rootConversationID); #expect(await storage.commits.count == 1)
        #expect(try await root.agent(context: .background).thinkingLevel == .high)
        #expect(try await h.harness.snapshot(note, conversationId: root.id, context: .background) == ["text": "root note"])
        let again = try await h.harness.root(options: .init(agent: .init(thinkingLevel: .set(.low)), initialize: { _, _ in Issue.record("Root init repeated") }), context: .background)
        #expect(again.id == root.id); #expect(await storage.commits.count == 1)
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:116. Provider identity belongs to H8.
    @Test func identityAndStateSurviveSQLiteReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("harness.sqlite").path
        let first = try await openHarness(storage: SqliteStorage.open(path: path))
        let root = try await first.harness.root(context: .background)
        try await root.configure(change: .init(model: .set(.init(provider: "anthropic", modelId: "claude")), cwd: .set("/repo")), context: .background)
        let entry = try await harnessAppend(root, "hello")
        let child = try await first.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let fork = try await root.fork(at: entry.id, options: .init(ownership: .ownerless()), context: .background)
        try await first.harness.close(context: .background)
        await facadeError("closed") { _ = try await root.agent(context: .background) }
        let second = try await openHarness(storage: SqliteStorage.open(path: path))
        let reopened = try await second.harness.root(options: .init(initialize: { _, _ in Issue.record("Init repeated") }), context: .background)
        #expect(reopened.id == rootConversationID); #expect(try await reopened.agent(context: .background).cwd == "/repo")
        #expect(try await harnessEntries(reopened) == ["hello"])
        #expect(try await second.harness.conversation(id: child.id, context: .background)?.id == child.id)
        let reopenedFork = try #require(await second.harness.conversation(id: fork.id, context: .background))
        #expect(try await harnessEntries(reopenedFork) == ["hello"])
        #expect(try await second.harness.conversation(id: ConversationID(999), context: .background) == nil)
        try await second.harness.close(context: .background)
    }
    // harness-conversations.test.ts:167
    @Test func independentCreationIsAtomicAndRollsBackFailure() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage)
        let created = try await h.harness.createConversation(options: .init(ownership: .ownerless(), initialize: { tx, id in
            _ = try await tx.appendEntry(id, value: EntryDraft(kind: "message", data: .string("seed")))
        }), context: .background)
        #expect(await storage.commits.count == 1); #expect(try await harnessEntries(created) == ["seed"])
        await facadeError("init failed") {
            _ = try await h.harness.createConversation(options: .init(ownership: .ownerless(), agent: .init(thinkingLevel: .set(.high)), initialize: { _, _ in throw StorageRejected("init failed") }), context: .background)
        }
        #expect(await storage.commits.count == 1)
        try h.registry.install(Extension(name: "live")); #expect(try await created.agent(context: .background).extensions.map(\.name) == ["live"])
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:211
    @Test func forkUsesAsOfAgentAndAppliesOverrides() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(context: .background)
        try await root.configure(change: .init(thinkingLevel: .set(.low)), context: .background)
        let at = try await harnessAppend(root, "one")
        try await root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        _ = try await harnessAppend(root, "two")
        let child = try await root.fork(at: at.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(try await child.agent(context: .background).thinkingLevel == .low)
        #expect(try await harnessEntries(child) == ["one"])
        let overridden = try await root.fork(at: at.id, options: .init(ownership: .ownerless(), agent: .init(thinkingLevel: .set(.minimal)), initialize: { tx, id in
            let value = try await tx.doc(AgentDoc, conversationId: id).snapshot()
            #expect(value["thinkingLevel"] == "minimal")
        }), context: .background)
        #expect(try await overridden.agent(context: .background).thinkingLevel == .minimal)
        let unrelated = try await h.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        await facadeError("not visible") { _ = try await unrelated.fork(at: at.id, options: .init(ownership: .ownerless()), context: .background) }
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:261
    @Test func deepForkHistoryIsPagedAndBounded() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(context: .background)
        _ = try await harnessAppend(root, "r1")
        let r2 = try await root.commit({ tx in
            let r2 = try await tx.appendEntry(root.id, value: EntryDraft(kind: "message", data: .string("r2")))
            _ = try await tx.appendEntry(root.id, value: EntryDraft(kind: "message", data: .string("r3")))
            return r2
        }, context: .background)
        let child = try await root.fork(at: r2.id, options: .init(ownership: .ownerless()), context: .background)
        let c1 = try await harnessAppend(child, "c1"); _ = try await harnessAppend(child, "c2")
        let grandchild = try await child.fork(at: c1.id, options: .init(ownership: .ownerless()), context: .background)
        _ = try await harnessAppend(grandchild, "g1")
        #expect(try await harnessEntries(root) == ["r3", "r2", "r1"])
        #expect(try await harnessEntries(child) == ["c2", "c1", "r2", "r1"])
        #expect(try await harnessEntries(grandchild, order: .ascending) == ["r1", "r2", "c1", "g1"])
        let bounded = try await grandchild.entries(minEntryId: r2.id, maxEntryId: c1.id, limit: 10, context: .background)
        #expect(bounded.items.map(\.id) == [c1.id, r2.id]); try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:301
    @Test func commitsDefaultTaskCreationToConversation() async throws {
        let h = try await openHarness(); let conversation = try await h.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let id = try await conversation.commit({ tx in try await tx.createTask(dormantKind, input: [:], options: .init(ownership: .conversation())) }, context: .background)
        #expect(try await h.harness.getTask(id: id, context: .background)?.conversationId == conversation.id)
        await facadeError("requires options.conversationId") { _ = try await h.harness.commit({ tx in try await tx.createTask(dormantKind, input: [:], options: .init(ownership: .conversation())) }, context: .background) }
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:325
    @Test func creationHookPrecedesAgentChangeAndInit() async throws {
        let seen = Mutex<[String]>([]); let note = try harnessNote()
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: createRegistry(), conversationCreated: { tx, record in
            let value = try await tx.doc(AgentDoc, conversationId: record.id).snapshot()
            seen.withLock { $0.append(value["cwd"]?.stringValue ?? "empty") }
            try await tx.doc(note, conversationId: record.id).set("text", "created")
            if value["cwd"] == "/fail" { throw StorageRejected("no") }
        }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(cwd: .set("/root")), initialize: { tx, id in
            let value = try await tx.doc(note, conversationId: id).snapshot()
            #expect(value["text"] == "created")
            seen.withLock { $0.append("init") }
        }), context: .background)
        _ = try await harness.commit({ tx in try await tx.createConversation(ownership: .ownerless()) }, context: .background)
        let entry = try await harnessAppend(root, "hello")
        _ = try await root.fork(at: entry.id, options: .init(ownership: .ownerless()), context: .background)
        #expect(seen.withLock { $0 } == ["empty", "init", "empty", "/root"])
        try await root.configure(change: .init(cwd: .set("/fail")), context: .background)
        let fail = try await harnessAppend(root, "after")
        await facadeError("no") { _ = try await root.fork(at: fail.id, options: .init(ownership: .ownerless()), context: .background) }
        try await harness.close(context: .background)
    }
    // harness-conversations.test.ts:382
    @Test func agentFieldsReplaceClearAndLeaveUnchanged() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(context: .background)
        try await root.configure(change: .init(model: .set(.init(provider: "openai", modelId: "gpt")), thinkingLevel: .set(.medium)), context: .background)
        try await root.configure(change: .init(instructions: .set("Be terse.")), context: .background)
        #expect(try await root.agent(context: .background).model?.modelId == "gpt")
        try await root.configure(change: .init(model: .clear, instructions: .clear), context: .background)
        let agent = try await root.agent(context: .background)
        #expect(agent.model == nil); #expect(agent.instructions == nil); #expect(agent.thinkingLevel == .medium)
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:428. Live/provider documents move to H6/H8.
    @Test func taskOwnedConversationsCopyOwnerAgentAndForksKeepAsOfCopy() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(options: .init(agent: .init(instructions: .set("Main role."), cwd: .set("/repo"))), context: .background)
        let ids = try await root.commit({ tx in
            let task = try await tx.createTask(dormantKind, input: [:], options: .init(ownership: .conversation()))
            let plain = try await tx.createConversation(ownership: .ownerless())
            let owned = try await tx.createConversation(ownership: .task(taskId: task))
            #expect(try await tx.doc(AgentDoc, conversationId: owned.id).snapshot()["cwd"] == "/repo")
            try await configure(tx: tx, conversationId: owned.id, change: .init(cwd: .set("/worktree")))
            return (task, plain.id, owned.id)
        }, context: .background)
        #expect(try await h.harness.snapshot(AgentDoc, conversationId: ids.1, context: .background) == AgentState())
        #expect(try await h.harness.snapshot(AgentDoc, conversationId: ids.2, context: .background)?.cwd == "/worktree")
        try await root.configure(change: .init(thinkingLevel: .set(.high)), context: .background)
        #expect(try await h.harness.snapshot(AgentDoc, conversationId: ids.2, context: .background)?.thinkingLevel == nil)
        let at = try await root.commit({ tx in try await tx.appendEntry(ids.1, value: EntryDraft(kind: "note")) }, context: .background)
        let fork = try await root.commit({ tx in try await tx.forkConversation(ids.1, at: at.id, ownership: .task(taskId: ids.0)) }, context: .background)
        #expect(try await h.harness.snapshot(AgentDoc, conversationId: fork.id, context: .background) == AgentState())
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:491
    @Test func absentAgentFromPlainSessionIsReadWithoutWrite() async throws {
        let storage = ControlledStorage(); let session = try await Session.open(storage: storage, context: .background)
        let id = try await session.commit({ tx in try await tx.createConversation(ownership: .ownerless()).id }, context: .background)
        let h = try await openHarness(storage: storage); let before = await storage.commits.count
        let conversation = try #require(await h.harness.conversation(id: id, context: .background))
        #expect(try await conversation.agent(context: .background).thinkingLevel == .off)
        #expect(await storage.commits.count == before)
        try await conversation.configure(change: .init(thinkingLevel: .set(.low)), context: .background)
        #expect(try await h.harness.snapshot(AgentDoc, conversationId: id, context: .background)?.thinkingLevel == .low)
        try await h.harness.close(context: .background)
    }
    // harness-conversations.test.ts:514
    @Test func handlesAreStatelessAndRejectAfterClose() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(context: .background); let again = try await h.harness.root(context: .background)
        #expect(root !== again); #expect(root.id == again.id); try await h.harness.close(context: .background)
        await facadeError("Harness is closed") { _ = try await h.harness.root(context: .background) }
        await facadeError("Harness is closed") { _ = try await h.harness.createConversation(options: .init(ownership: .ownerless()), context: .background) }
        await facadeError("Harness is closed") { _ = try await h.harness.conversation(id: root.id, context: .background) }
    }
    // harness-conversations.test.ts:532
    @Test func genericSessionDocumentsAreForwarded() async throws {
        let h = try await openHarness(); let root = try await h.harness.root(context: .background); let note = try harnessNote()
        let at = try await root.commit({ tx in
            try await tx.doc(note, conversationId: root.id).set("text", "first")
            return try await tx.appendEntry(root.id, value: EntryDraft(kind: "message"))
        }, context: .background)
        try await h.harness.commit({ tx in try await tx.doc(note, conversationId: root.id).set("text", "second") }, context: .background)
        #expect(try await h.harness.snapshot(note, conversationId: root.id, context: .background) == ["text": "second"])
        #expect(try await h.harness.snapshotAsOf(note, conversationId: root.id, at: at.id, context: .background) == ["text": "first"])
        let state = try #require(await h.harness.documentState(note, conversationId: root.id, context: .background))
        #expect(state.value == ["text": "second"]); state.dispose()
        try await h.harness.close(context: .background)
    }
}
