import Foundation
import Testing
import PiSwiftChord
import PiSwiftAI
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessSubmissionTests {
    @Test func idleWriteSettlesWithoutTurn() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let submission = try await chat.root.submit(.write(entry: EntryDraft(kind: "note", data: .object(["text": .string("x")]))), context: .background)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try await allEntries(chat.root).map(\.kind) == ["note"])
        #expect(try await chat.harness.inspect(context: .background).tasks.isEmpty)
        try await chat.harness.close(context: .background)
    }
    @Test func idleInputIsPlacedAndBusyRejectWritesNothing() async throws {
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let storage = ControlledStorage(); let chat = try await openChat(storage: storage, setup: setup)
        let submission = try await chat.root.submit(.input(content: .text("hi")), context: .background)
        await held.reached.wait()
        #expect(try await submission.status(context: .background).status == "placed")
        let count = await storage.commits.count, minted = await storage.mintCount
        await #expect(throws: ConversationBusy.self) { try await chat.root.submit(.input(content: .text("again"), whenBusy: .reject), context: .background) }
        #expect(await storage.commits.count == count); #expect(await storage.mintCount == minted)
        #expect(try await chat.harness.snapshot(InboxDoc, conversationId: chat.root.id, context: .background)?.items.isEmpty == true)
        try await chat.harness.close(context: .background)
    }
    @Test func requestIDsDeduplicateBeforeAnyWriteAndWithinConversation() async throws {
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let storage = ControlledStorage(); let chat = try await openChat(storage: storage, setup: setup)
        let first = try await chat.root.submit(.input(content: .text("hi"), requestId: "r1"), context: .background)
        await held.reached.wait(); let count = await storage.commits.count, minted = await storage.mintCount
        let again = try await chat.root.submit(.input(content: .text("different"), whenBusy: .reject, requestId: "r1"), context: .background)
        #expect(again.id == first.id); #expect(await storage.commits.count == count); #expect(await storage.mintCount == minted)
        await #expect(throws: SessionError.self) { try await chat.root.submit(.write(entry: EntryDraft(kind: "note"), requestId: "r1"), context: .background) }
        let other = try await chat.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let write = try await other.submit(.write(entry: EntryDraft(kind: "note"), requestId: "r1"), context: .background)
        let repeatWrite = try await other.submit(.write(entry: EntryDraft(kind: "different"), requestId: "r1"), context: .background)
        #expect(write.id != first.id); #expect(write.id == repeatWrite.id)
        try await chat.harness.close(context: .background)
    }
    @Test func abortResultsAndScopedLookup() async throws {
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("hi")), context: .background); await held.reached.wait()
        let queued = try await chat.root.submit(.input(content: .text("later")), context: .background)
        #expect(try await input.abort(context: .background) == .alreadyPlaced)
        #expect(try await chat.harness.submission(id: input.id, context: .background)?.id == input.id)
        #expect(try await chat.harness.submission(id: SubmissionID(999999), context: .background) == nil)
        #expect(try await chat.harness.abortSubmission(id: queued.id, conversationId: ConversationID(999999), context: .background) == .notFound)
        #expect(try await queued.abort(context: .background) == .aborted)
        #expect(try await queued.abort(context: .background) == .settled)
        #expect(try await queued.wait(context: .background).reason == "aborted")
        try await chat.root.abort(context: .background)
        #expect(try await input.wait(context: .background).reason == "aborted")
        #expect(try await input.abort(context: .background) == .settled)
        try await chat.harness.close(context: .background)
    }
    @Test func cancellationStopsOnlyWaitAndCloseRejectsOtherWaits() async throws {
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let chat = try await openChat(setup: setup)
        let input = try await chat.root.submit(.input(content: .text("hi")), context: .background); await held.reached.wait()
        let controller = AbortController()
        let cancelled = Task { try await input.wait(context: ChordContext.background.withAbortSignal(controller.signal)) }
        let pending = Task { try await input.wait(context: .background) }
        try await eventually { chat.harness.session.line.queuedCount == 0 }
        controller.abort()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        try await eventually { chat.harness.submissions.hasPendingWait(id: input.id) }
        #expect(try await input.status(context: .background).status == "placed")
        try await chat.harness.close(context: .background)
        await #expect(throws: (any Error).self) { try await pending.value }
    }
    @Test func reacquiresSubmissionAfterSQLiteReopenAndDeduplicatesDurableRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("submission.sqlite").path
        let setup = HarnessChatSetup(); let held = HarnessUnanswered(); setup.models.setResponses([held.step])
        let chat = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let input = try await chat.root.submit(.input(content: .text("hi"), requestId: "print"), context: .background)
        await held.reached.wait(); try await chat.harness.close(context: .background)
        setup.models.setResponses([.message(chatAssistant("answer"))])
        let reopened = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try #require(try await reopened.harness.submission(id: input.id, context: .background))
        let settled = try await submission.wait(context: .background)
        #expect(settled.status == "done")
        #expect(try await submission.wait(context: .background) == settled)
        #expect(try await reopened.root.submit(.input(content: .text("hi"), requestId: "print"), context: .background).id == input.id)
        try await reopened.harness.close(context: .background)
    }
    @Test func submitAndWaitEnableScheduling() async throws {
        let setup = HarnessChatSetup(); setup.models.setResponses([.message(chatAssistant("answer"))])
        let chat = try await openChat(setup: setup)
        #expect(try await chat.harness.inspect(context: .background).scheduling == .paused)
        let input = try await chat.root.submit(.input(content: .text("hi")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        #expect(try await chat.harness.inspect(context: .background).scheduling == .running)
        try await chat.harness.close(context: .background)
    }
    @Test func settlementUsesCurrentTransactionRecordAndFirstOutcomeWins() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let entry = try await chat.root.commit({ tx in try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note")) }, context: .background)
        let queued = try await chat.root.commit({ tx in try await tx.createSubmission(.input(conversationId: chat.root.id)).id }, context: .background)
        let write = try await chat.root.commit({ tx in try await tx.createSubmission(.write(conversationId: chat.root.id)).id }, context: .background)
        for id in [queued, write] {
            await #expect(throws: (any Error).self) { try await chat.root.commit({ tx in try tx.settleSubmission(id, settlement: .done(answer: entry.id)) }, context: .background) }
        }
        let placed = try await chat.root.commit({ tx in
            let record = try await tx.createSubmission(.input(conversationId: chat.root.id, state: .placed(entry: entry.id)))
            try tx.settleSubmission(record.id, settlement: .done(answer: entry.id))
            try tx.settleSubmission(record.id, settlement: .unanswered(reason: "late"))
            return record.id
        }, context: .background)
        let receipt = try #require(try await chat.harness.submission(id: placed, context: .background))
        #expect(try await receipt.wait(context: .background).answer == entry.id)
        try await chat.harness.close(context: .background)
    }
    @Test func typedEntriesAppendAndReadThroughTokens() async throws {
        struct Counter: Sendable, Codable, Equatable { var n: Int }
        let token = try EntryKind<Counter>("counter")
        let other = try EntryKind<Counter>("other")
        let chat = try await openChat(setup: HarnessChatSetup())
        let counter = try await chat.root.commit({ tx in try await tx.appendEntry(token, conversationId: chat.root.id, value: TypedEntryDraft(data: Counter(n: 1))) }, context: .background)
        #expect(try await chat.root.commit({ tx in try await tx.entry(token, id: counter.id)?.data }, context: .background) == Counter(n: 1))
        #expect(try await chat.root.commit({ tx in try await tx.entry(other, id: counter.id) }, context: .background) == nil)
        #expect(try await chat.root.commit({ tx in try await tx.entry(token, id: EntryID(999999)) }, context: .background) == nil)
        try await chat.harness.close(context: .background)
    }
}
