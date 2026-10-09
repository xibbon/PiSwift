import Testing
import PiSwiftChord
import PiSwiftAI
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessInboxTests {
    private func openBusy(storage: any DurableStorage = MemoryStorage()) async throws -> (Harness, Conversation) {
        let opened = try await openHarness(storage: storage)
        let root = try await opened.harness.root(context: .background)
        try await root.commit({ tx in
            let live = try await tx.doc(LiveDoc, conversationId: root.id)
            try live.set("run", JSONValue(encoding: LiveRun(taskId: TaskID(999_999), inputs: [])))
        }, context: .background)
        return (opened.harness, root)
    }
    private func boundary(_ root: Conversation, at: BoundaryPoint = .final, settings: Settings = resolveSettings()) async throws -> BoundaryResult {
        try await root.commit({ tx in
            let boundary = try await prepareBoundary(tx: tx, conversationId: root.id, modes: settings)
            return try await applyBoundary(tx: tx, boundary: boundary, at: at, now: 1000)
        }, context: .background)
    }
    @Test func boundariesPlaceWritesFirstAndSelectModesInIDOrder() async throws {
        let (h, root) = try await openBusy()
        let follow1 = try await root.submit(.input(content: .text("f1")), context: .background)
        let write = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let steer1 = try await root.submit(.input(content: .text("s1"), whenBusy: .steer), context: .background)
        let follow2 = try await root.submit(.input(content: .text("f2")), context: .background)
        let steer2 = try await root.submit(.input(content: .text("s2"), whenBusy: .steer), context: .background)
        let post = try await boundary(root, at: .postTools)
        #expect(post.users == [steer1.id]); #expect(!post.reset)
        #expect(try await write.status(context: .background).status == "done")
        #expect(try await follow1.status(context: .background).status == "queued")
        let final = try await boundary(root)
        #expect(final.users == [follow1.id, steer2.id])
        #expect(try await root.harness.snapshot(InboxDoc, conversationId: root.id, context: .background)?.items.map(\.id) == [follow2.id])
        let entries = try await root.entries(order: .ascending, limit: 20, context: .background).items
        #expect(entries.map(\.kind) == ["note", "pi.user", "pi.user", "pi.user"])
        try await h.close(context: .background)
    }
    @Test func allModesSelectAllUsersAfterWrites() async throws {
        let (h, root) = try await openBusy()
        let f1 = try await root.submit(.input(content: .text("f1")), context: .background)
        let s1 = try await root.submit(.input(content: .text("s1"), whenBusy: .steer), context: .background)
        let f2 = try await root.submit(.input(content: .text("f2")), context: .background)
        let s2 = try await root.submit(.input(content: .text("s2"), whenBusy: .steer), context: .background)
        let settings = resolveSettings(HarnessSettings(steeringMode: .all, followUpMode: .all))
        let result = try await boundary(root, settings: settings)
        #expect(result.users == [f1.id, s1.id, f2.id, s2.id])
        #expect(try await root.harness.snapshot(InboxDoc, conversationId: root.id, context: .background)?.items.isEmpty == true)
        try await h.close(context: .background)
    }
    @Test func queuedResetPromotesPostToolsAndMakesEarlierHeadStale() async throws {
        let (h, root) = try await openBusy()
        let target = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "old")) }, context: .background)
        let follow = try await root.submit(.input(content: .text("follow")), context: .background)
        try await root.reset(handoff: "handoff", context: .background)
        let summary = try await root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(target.id))), context: .background)
        let result = try await boundary(root, at: .postTools)
        #expect(result.reset); #expect(result.users == [follow.id])
        #expect(try await summary.wait(context: .background).reason == "stale")
        let context = try await root.context(context: .background)
        #expect(context.entries.map(\.kind) == ["pi.reset", "pi.user"])
        try await h.close(context: .background)
    }
    @Test func writesBeforeActiveHeadAreStaleButActiveAndLaterWritesRemain() async throws {
        let (h, root) = try await openBusy()
        let old = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "old")) }, context: .background)
        let reset = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "pi.reset", head: .self)) }, context: .background)
        let stale = try await root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(old.id))), context: .background)
        let fresh = try await root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(reset.id))), context: .background)
        _ = try await boundary(root)
        #expect(try await stale.wait(context: .background).reason == "stale")
        #expect(try await fresh.wait(context: .background).status == "done")
        try await h.close(context: .background)
    }
    @Test func queuedRequestIsIdempotentAndMiddleWithdrawalIsOnePositionalRemoval() async throws {
        let (h, root) = try await openBusy()
        let changes = SessionTestLog<DocumentCommitChange>()
        _ = try h.subscribeCommits { publication, _ in
            for change in publication.changes { if case .document(let doc) = change, doc.record.kind == "pi.inbox" { changes.append(doc) } }
        }
        let x = try await root.submit(.input(content: .text("x")), context: .background)
        let y = try await root.submit(.input(content: .text("y"), requestId: "y"), context: .background)
        let z = try await root.submit(.input(content: .text("z")), context: .background)
        let repeatY = try await root.submit(.input(content: .text("different"), whenBusy: .reject, requestId: "y"), context: .background)
        #expect(repeatY.id == y.id); #expect(changes.count == 3)
        #expect(try await y.abort(context: .background) == .aborted)
        #expect(try await y.wait(context: .background).reason == "aborted")
        #expect(changes.values.last?.ops == [.splice([.key("items")], index: 1, remove: 1, items: [])])
        #expect(try await root.harness.snapshot(InboxDoc, conversationId: root.id, context: .background)?.items.map(\.id) == [x.id, z.id])
        try await h.close(context: .background)
    }
    @Test func literalInboxOpsRemoveOnlySelectedPositionsAndCheckpointEmpty() async throws {
        let storage = ControlledStorage()
        let (h, root) = try await openBusy(storage: storage)
        let changes = SessionTestLog<DocumentCommitChange>()
        _ = try h.subscribeCommits { publication, _ in
            for change in publication.changes { if case .document(let doc) = change, doc.record.kind == "pi.inbox", !doc.ops.isEmpty { changes.append(doc) } }
        }
        let w1 = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let f1 = try await root.submit(.input(content: .text("f1")), context: .background)
        let w2 = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let f2 = try await root.submit(.input(content: .text("f2")), context: .background)
        let w3 = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let expected = [InboxItem(id: w1.id, mode: .write, entry: EntryDraft(kind: "note")), InboxItem(id: f1.id, mode: .followUp, content: .string("f1")), InboxItem(id: w2.id, mode: .write, entry: EntryDraft(kind: "note")), InboxItem(id: f2.id, mode: .followUp, content: .string("f2")), InboxItem(id: w3.id, mode: .write, entry: EntryDraft(kind: "note"))]
        for index in expected.indices {
            #expect(changes.values[index].ops == [.splice([.key("items")], index: index, remove: 0, items: [try JSONValue(encoding: expected[index])])])
        }
        _ = try await boundary(root)
        let removal = changes.values[5].ops
        #expect(removal.contains(.splice([.key("items")], index: 4, remove: 1, items: [])))
        #expect(removal.allSatisfy { op in if case .splice(_, _, _, let insert) = op { return insert.isEmpty }; return false })
        let inboxId = changes.values[0].record.id
        let beforeEmpty = await storage.commits.flatMap { $0 }.compactMap { write -> DocumentContent? in
            if case .documentChange(let id, let content, _) = write, id == inboxId { return content }; return nil
        }
        #expect(beforeEmpty.count == 6)
        #expect(beforeEmpty.allSatisfy { if case .delta = $0 { return true }; return false })
        _ = try await boundary(root)
        #expect(changes.values.last?.value == ["items": .array([])])
        let afterEmpty = await storage.commits.flatMap { $0 }.compactMap { write -> DocumentContent? in
            if case .documentChange(let id, let content, _) = write, id == inboxId { return content }; return nil
        }
        #expect(afterEmpty.last == .base(version: 1, value: ["items": .array([])]))
        try await h.close(context: .background)
    }
    @Test func withdrawQueuedInputsRetainsPassiveWrites() async throws {
        let (h, root) = try await openBusy()
        let f = try await root.submit(.input(content: .text("follow")), context: .background)
        let w = try await root.submit(.write(entry: EntryDraft(kind: "note")), context: .background)
        let s = try await root.submit(.input(content: .text("steer"), whenBusy: .steer), context: .background)
        try await root.commit({ tx in try await withdrawQueuedInputs(tx: tx, conversationId: root.id) }, context: .background)
        #expect(try await f.wait(context: .background).reason == "aborted")
        #expect(try await s.wait(context: .background).reason == "aborted")
        #expect(try await root.harness.snapshot(InboxDoc, conversationId: root.id, context: .background)?.items.map(\.id) == [w.id])
        try await h.close(context: .background)
    }
    @Test func idleResetAndIdleStaleWriteDoNotCreateGeneration() async throws {
        let opened = try await openHarness(); let root = try await opened.harness.root(context: .background)
        let old = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "old")) }, context: .background)
        try await root.reset(context: .background)
        try await root.reset(handoff: "handoff", context: .background)
        let stale = try await root.submit(.write(entry: EntryDraft(kind: "summary", head: .entry(old.id))), context: .background)
        #expect(try await stale.wait(context: .background).reason == "stale")
        #expect(try await root.harness.snapshot(LiveDoc, conversationId: root.id, context: .background)?.run == nil)
        #expect(try await root.context(context: .background).entries.count == 1)
        try await opened.harness.close(context: .background)
    }
}
