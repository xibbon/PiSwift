import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum WriterD3aError: Error, Equatable { case refused, rejected }

@Suite("PiSwiftDurableTests.SessionWriterD3a", .timeLimit(.minutes(1)))
struct SessionWriterD3aTests {
    @Test func guardedStorageDoesNotRetainWriter() {
        let latch = SessionFailureLatch()
        let guarded = GuardedStorage(MemoryStorage(), latch: latch)
        var writer: SessionWriter? = SessionWriter(storage: guarded, latch: latch,
            fail: { _ in }, report: { _ in })
        weak var retained = writer
        guarded.installWriter(writer!)
        writer = nil
        #expect(retained == nil)
    }

    private func waitForKeys(_ session: Session, _ count: Int) async {
        for _ in 0..<50_000 {
            if session.writerUnpublished >= count { return }
            await Task.yield()
        }
        Issue.record("Writer did not admit \(count) unpublished keys")
    }

    private func append(_ session: Session, _ conversation: ConversationID, _ kind: String) -> Task<EntryRecord, any Error> {
        Task {
            try await session.commit({ tx in
                try await tx.appendEntry(conversation, value: EntryDraft(kind: kind))
            }, context: .background)
        }
    }

    @Test func disjointReadRunsOnReleasedLineWhileStorageWaits() async throws {
        let harness = try await openTestSession()
        let writing = try await createConversation(harness.session)
        let reading = try await createConversation(harness.session)
        let gate = await harness.storage.holdCommits()
        let first = append(harness.session, writing, "held")
        await gate.waitUntilEntered()
        let before = await harness.storage.conversationReadCount
        let read = Task {
            try await harness.session.commit({ tx in
                try await tx.conversation(reading)
            }, context: .background)
        }
        for _ in 0..<50_000 {
            if await harness.storage.conversationReadCount > before { break }
            await Task.yield()
        }
        // v1.5.2 D3a group-commit.md:144–148: the callback and its read
        // reach Storage while an unrelated commit is still in flight.
        #expect(await harness.storage.conversationReadCount > before)
        await gate.release()
        _ = try await first.value
        #expect(try await read.value?.id == reading)
        try await harness.session.close(context: .background)
    }

    @Test func leakedEntryReadWaitsAtItsUnpublishedKey() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let gate = await harness.storage.holdCommits()
        let leaked = SessionTestLog<EntryID>()
        let first = Task {
            try await harness.session.commit({ tx in
                let entry = try await tx.appendEntry(conversation, value: EntryDraft(kind: "leaked"))
                leaked.append(entry.id)
                return entry
            }, context: .background)
        }
        await gate.waitUntilEntered()
        let id = try #require(leaked.values.first)
        let before = await harness.storage.entryReadCount
        let entered = SessionTestGate()
        let second = Task {
            try await harness.session.commit({ tx in
                entered.release()
                return try await tx.entry(id)
            }, context: .background)
        }
        await entered.wait()
        for _ in 0..<100 { await Task.yield() }
        #expect(await harness.storage.entryReadCount == before)
        await gate.release()
        let stored = try await first.value
        let read = try await second.value
        #expect(read == stored)
        #expect(await harness.storage.entryReadCount == before + 1)
        try await harness.session.close(context: .background)
    }

    @Test func storagePublicationScopeDelaysObserverAndCaller() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let before = harness.publications.count
        let gate = await harness.storage.holdPublication()
        let commit = append(harness.session, conversation, "scoped")
        await gate.waitUntilEntered()
        #expect(harness.publications.count == before)
        await gate.release()
        _ = try await commit.value
        #expect(harness.publications.count == before + 1)
        try await harness.session.close(context: .background)
    }

    @Test func groupsFourWaitingCommitsAndPublishesInLineOrder() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let gate = await harness.storage.holdCommits()
        let first = append(harness.session, conversation, "first")
        await gate.waitUntilEntered()
        var waiting: [Task<EntryRecord, any Error>] = []
        for index in 0..<4 {
            waiting.append(append(harness.session, conversation, "waiting.\(index)"))
            await waitForKeys(harness.session, index + 3)
        }
        await gate.release()
        _ = try await first.value
        for task in waiting { _ = try await task.value }
        #expect(await harness.storage.callBatchCounts == [1, 1, 4])
        let kinds = harness.publications.values.flatMap(\.changes).compactMap { change -> String? in
            if case .entry(let entry) = change { return entry.kind }
            return nil
        }
        #expect(kinds == ["first", "waiting.0", "waiting.1", "waiting.2", "waiting.3"])
        try await harness.session.close(context: .background)
    }

    @Test func refusalAtBatchTwoOfFourPublishesOnlyThePrefix() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        await harness.storage.refuseCall(3, afterStored: 1, error: WriterD3aError.refused)
        let gate = await harness.storage.holdCommits()
        let first = append(harness.session, conversation, "first")
        await gate.waitUntilEntered()
        var waiting: [Task<EntryRecord, any Error>] = []
        for index in 0..<4 {
            waiting.append(append(harness.session, conversation, "waiting.\(index)"))
            await waitForKeys(harness.session, index + 3)
        }
        await gate.release()
        _ = try await first.value
        _ = try await waiting[0].value
        await #expect(throws: WriterD3aError.refused) { _ = try await waiting[1].value }
        for index in 2..<4 {
            await #expect(throws: SessionFailed.self) { _ = try await waiting[index].value }
        }
        #expect(await harness.storage.callBatchCounts == [1, 1, 4])
        #expect(harness.publications.values.flatMap(\.changes).compactMap { change -> String? in
            if case .entry(let entry) = change { return entry.kind }; return nil
        } == ["first", "waiting.0"])
        guard case .failed(let error) = await harness.session.closed else {
            Issue.record("Refusal did not fail Session at the tagged writer boundary"); return
        }
        #expect(error as? WriterD3aError == .refused)
    }

    @Test func rejectionAfterTwoReceiptsPublishesPrefixThenFailsAllCallers() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        await harness.storage.rejectCall(3, afterStored: 2, error: WriterD3aError.rejected)
        let gate = await harness.storage.holdCommits()
        let first = append(harness.session, conversation, "first")
        await gate.waitUntilEntered()
        var waiting: [Task<EntryRecord, any Error>] = []
        for index in 0..<4 {
            waiting.append(append(harness.session, conversation, "waiting.\(index)"))
            await waitForKeys(harness.session, index + 3)
        }
        await gate.release()
        _ = try await first.value
        for task in waiting {
            await #expect(throws: WriterD3aError.rejected) { _ = try await task.value }
        }
        #expect(await harness.storage.callBatchCounts == [1, 1, 4])
        #expect(harness.publications.values.flatMap(\.changes).compactMap { change -> String? in
            if case .entry(let entry) = change { return entry.kind }; return nil
        } == ["first", "waiting.0", "waiting.1"])
        guard case .failed(let error) = await harness.session.closed else {
            Issue.record("Unknown storage outcome did not fail Session"); return
        }
        #expect(error as? WriterD3aError == .rejected)
    }

    @Test func failureBeforeDeferredScopeStopsLaterPublication() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let gate = await harness.storage.holdCommits()
        let lead = append(harness.session, conversation, "lead")
        await gate.waitUntilEntered()
        let one = append(harness.session, conversation, "one")
        await waitForKeys(harness.session, 3)
        let two = append(harness.session, conversation, "two")
        await waitForKeys(harness.session, 4)
        // The conversation and lead already entered their scopes. Hold the
        // scope for `two`, after the writer has published `one`.
        let scope = await harness.storage.holdPublication(at: 4)
        await gate.release()
        _ = try await lead.value
        _ = try await one.value
        await scope.waitUntilEntered()
        harness.session.fail(WriterD3aError.rejected)
        await scope.release()
        await #expect(throws: SessionFailed.self) { _ = try await two.value }
        let kinds = harness.publications.values.flatMap(\.changes).compactMap { change -> String? in
            if case .entry(let entry) = change { return entry.kind }
            return nil
        }
        // v1.5.2 D3a session-group-commit.test.ts:815–835.
        #expect(kinds == ["lead", "one"])
    }
}
