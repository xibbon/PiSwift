import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum SessionKernelFailure: Error, Equatable { case storage, callback }

@Suite struct SessionKernelTests {
    @Test func SessionPoisonAfterStorageAdmission() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocToken<JSONObject>(kind: "poison", version: 1, initial: { ["count": 0] })
        try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let before = try await harness.session.snapshot(token, context: .background)
        let published = harness.publications.count
        await harness.storage.failNextCommit(SessionKernelFailure.storage)
        await #expect(throws: SessionKernelFailure.storage) {
            try await harness.session.commit({ tx in
                try await tx.doc(token).set("count", 1)
            }, context: .background)
        }
        #expect(harness.publications.count == published)
        #expect(before == ["count": 0])
        await #expect(throws: SessionError.poisoned) {
            try await harness.session.snapshot(token, context: .background)
        }
        await #expect(throws: SessionError.poisoned) {
            try await harness.session.commit({ _ in }, context: .background)
        }
        try await harness.session.close(context: .background)
    }

    @Test func SessionStorageRejectedRollsBackAndRemainsUsable() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let published = harness.publications.count
        await harness.storage.failNextCommit(StorageRejected("rejected"))
        await #expect(throws: StorageRejected("rejected")) {
            try await harness.session.commit({ tx in
                try await tx.appendEntry(conversation, value: EntryDraft(kind: "rejected"))
            }, context: .background)
        }
        #expect(harness.publications.count == published)
        let entry = try await harness.session.commit({ tx in
            try await tx.appendEntry(conversation, value: EntryDraft(kind: "accepted"))
        }, context: .background)
        #expect(try await harness.storage.entry(entry.id, context: .background)?.entry == entry)
        #expect(harness.publications.count == published + 1)
        try await harness.session.close(context: .background)
    }

    @Test func SessionPublicationIsSynchronousAndCarriesContext() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocToken<JSONObject>(kind: "publication", version: 1, initial: { ["count": 0] })
        let marker = ContextKey<Int>("Session test")
        let context = PiSwiftChord.Context.background.withValue(42, for: marker)
        let values = SessionTestLog<Int>()
        let subscription = try harness.session.subscribeCommits { _, delivered in
            values.append(delivered.value(marker) ?? -1)
        }
        let before = harness.publications.count
        let result = try await harness.session.commit({ tx in
            _ = try await tx.createConversation(ownership: .ownerless())
            try await tx.doc(token).set("count", 1)
            return "done"
        }, context: context)
        #expect(result == "done")
        #expect(values.values == [42])
        #expect(harness.publications.count == before + 1)
        let publication = try #require(harness.publications.values.last)
        let document = try #require(documentChanges(publication).first)
        #expect(document.record.createdAt == publication.seq)
        #expect(document.value == ["count": 1])
        #expect(try await harness.session.snapshot(token, context: .background) == document.value)
        subscription.cancel()
        _ = try await createConversation(harness.session)
        #expect(values.values == [42])
        try await harness.session.close(context: .background)
    }

    @Test func SessionCloseIsSynchronousAndCanUnsubscribe() async throws {
        let harness = try await openTestSession()
        let calls = SessionTestLog<String>()
        _ = try harness.session.subscribeClose { calls.append("active") }
        let removed = try harness.session.subscribeClose { calls.append("removed") }
        removed.cancel()
        try await harness.session.close(context: .background)
        #expect(calls.values == ["active"])
        try await harness.session.close(context: .background)
        #expect(calls.values == ["active"])
    }

    @Test func SessionCloseDrainsAdmittedCommitsAndSealsAdmission() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let gate = await harness.storage.holdCommits()
        let first = Task {
            try await harness.session.commit({ tx in
                try await tx.appendEntry(conversation, value: EntryDraft(kind: "first"))
            }, context: .background)
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await harness.session.commit({ tx in
                try await tx.appendEntry(conversation, value: EntryDraft(kind: "second"))
            }, context: .background)
        }
        while harness.session.line.queuedCount < 1 { await Task.yield() }
        let closing = SessionTestGate()
        _ = try harness.session.subscribeClose { closing.release() }
        let close = Task { try await harness.session.close(context: .background) }
        await closing.wait()
        await #expect(throws: SessionError.closed) {
            try await harness.session.commit({ _ in }, context: .background)
        }
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        try await close.value
        #expect(harness.publications.values.suffix(2).count == 2)
        await #expect(throws: DurableStorageError.closed(backend: "MemoryStorage")) {
            try await harness.storage.conversation(conversation, context: .background)
        }
    }

    @Test func SessionFIFOAndCommitPublicationOrderAcrossAwait() async throws {
        let harness = try await openTestSession()
        let conversation = try await createConversation(harness.session)
        let callbacks = SessionTestLog<Int>()
        let completed = SessionTestLog<Int>()
        let publications = SessionTestLog<String>()
        let active = Mutex(0)
        let maximumActive = Mutex(0)
        let firstEntered = SessionTestGate()
        let releaseFirst = SessionTestGate()
        _ = try harness.session.subscribeCommits { publication, _ in
            for change in publication.changes {
                if case .entry(let entry) = change { publications.append(entry.kind) }
            }
        }
        var jobs: [Task<Void, any Error>] = []
        for index in 0..<20 {
            let job = Task {
                try await harness.session.commit({ tx in
                    let count = active.withLock { $0 += 1; return $0 }
                    maximumActive.withLock { $0 = max($0, count) }
                    callbacks.append(index)
                    if index == 0 {
                        firstEntered.release()
                        await releaseFirst.wait()
                    }
                    await Task.yield()
                    #expect(active.withLock { $0 } == 1)
                    _ = try await tx.appendEntry(conversation, value: EntryDraft(kind: "fifo.\(index)"))
                    completed.append(index)
                    active.withLock { $0 -= 1 }
                }, context: .background)
            }
            jobs.append(job)
            if index == 0 { await firstEntered.wait() }
            else {
                while harness.session.line.queuedCount < index { await Task.yield() }
            }
        }
        #expect(callbacks.values == [0])
        releaseFirst.release()
        for job in jobs { try await job.value }
        #expect(maximumActive.withLock { $0 } == 1)
        #expect(callbacks.values == Array(0..<20))
        #expect(completed.values == Array(0..<20))
        #expect(publications.values == (0..<20).map { "fifo.\($0)" })
        try await harness.session.close(context: .background)
    }

    @Test func SessionChecksContextAbortOnlyBeforeCallback() async throws {
        let harness = try await openTestSession()
        let cancelled = PiSwiftChord.Context.background.withCancel()
        cancelled.cancel()
        let calls = SessionTestLog<String>()
        await #expect(throws: AbortError.self) {
            try await harness.session.commit({ _ in calls.append("unexpected") }, context: cancelled.context)
        }
        #expect(calls.values.isEmpty)
        let admitted = PiSwiftChord.Context.background.withCancel()
        let conversation = try await harness.session.commit({ tx in
            admitted.cancel()
            return try await tx.createConversation(ownership: .ownerless())
        }, context: admitted.context)
        #expect(try await harness.storage.conversation(conversation.id, context: .background) == conversation)
        try await harness.session.close(context: .background)
    }
}

extension SessionKernelTests {
    @Test func SessionCallbackFailureRevokesDraftAndRollsBack() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocToken<JSONObject>(kind: "callback.rollback", version: 1, initial: { ["count": 0] })
        try await harness.session.commit({ tx in
            _ = try await tx.doc(token)
        }, context: .background)
        let before = try await harness.session.snapshot(token, context: .background)
        let commits = await harness.storage.commits.count
        let draft = SessionTestLog<JSONDraft>()
        await #expect(throws: SessionKernelFailure.callback) {
            try await harness.session.commit({ tx in
                let change = try await tx.doc(token)
                draft.append(change)
                try change.set("count", 1)
                throw SessionKernelFailure.callback
            }, context: .background)
        }
        let escaped = try #require(draft.values.first)
        #expect(throws: TrackerError.self) { try escaped.snapshot() }
        #expect(throws: TrackerError.self) { try escaped.set("count", 2) }
        #expect(await harness.storage.commits.count == commits)
        #expect(try await harness.session.snapshot(token, context: .background) == before)
        try await harness.session.close(context: .background)
    }

    @Test func SessionQueuedCommitChecksAbortBeforeCallback() async throws {
        let harness = try await openTestSession()
        let entered = SessionTestGate()
        let release = SessionTestGate()
        let first = Task {
            try await harness.session.commit({ _ in
                entered.release()
                await release.wait()
            }, context: .background)
        }
        await entered.wait()
        let cancelled = PiSwiftChord.Context.background.withCancel()
        let calls = SessionTestLog<String>()
        let second = Task {
            try await harness.session.commit({ _ in calls.append("unexpected") }, context: cancelled.context)
        }
        while harness.session.line.queuedCount < 1 { await Task.yield() }
        cancelled.cancel()
        release.release()
        try await first.value
        await #expect(throws: AbortError.self) { try await second.value }
        #expect(calls.values.isEmpty)
        try await harness.session.close(context: .background)
    }

    @Test func SessionAbortAfterStorageAdmissionDoesNotAbortCommit() async throws {
        let harness = try await openTestSession()
        let cancelled = PiSwiftChord.Context.background.withCancel()
        let gate = await harness.storage.holdCommits()
        let commit = Task {
            try await harness.session.commit({ tx in
                try await tx.createConversation(ownership: .ownerless())
            }, context: cancelled.context)
        }
        await gate.waitUntilEntered()
        cancelled.cancel()
        await gate.release()
        let conversation = try await commit.value
        #expect(try await harness.storage.conversation(conversation.id, context: .background) == conversation)
        try await harness.session.close(context: .background)
    }

    @Test func SessionReadOnLineHoldsAcrossAwait() async throws {
        let harness = try await openTestSession()
        let entered = SessionTestGate()
        let release = SessionTestGate()
        let read = Task {
            try await harness.session.readOnLine {
                let before = try await harness.storage.scanConversations(ConversationQuery(), limit: 10, cursor: nil, context: .background)
                entered.release()
                await release.wait()
                let after = try await harness.storage.scanConversations(ConversationQuery(), limit: 10, cursor: nil, context: .background)
                return (before.items, after.items)
            }
        }
        await entered.wait()
        let write = Task { try await createConversation(harness.session) }
        while harness.session.line.queuedCount < 1 { await Task.yield() }
        release.release()
        let (before, after) = try await read.value
        #expect(before == after)
        #expect(before.isEmpty)
        _ = try await write.value
        try await harness.session.close(context: .background)
    }
}

private struct SessionCreationHooks: SessionHooks {
    let document: ConversationDocToken<JSONObject>
    let calls: SessionTestLog<ConversationID>
    let fail: Bool
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {
        calls.append(record.id)
        try await tx.doc(document, conversationId: record.id).set("created", true)
        if fail { throw SessionKernelFailure.callback }
    }
}

extension SessionKernelTests {
    @Test func SessionConversationCreatedHookStagesDocumentsAtomically() async throws {
        let token = try ConversationDocToken<JSONObject>(kind: "hook.created", version: 1, fork: .initial, initial: { ["created": false] })
        for fail in [false, true] {
            let calls = SessionTestLog<ConversationID>()
            let storage = ControlledStorage()
            let hooks = SessionCreationHooks(document: token, calls: calls, fail: fail)
            let session = try await Session.open(storage: storage, hooks: hooks, context: .background)
            if fail {
                await #expect(throws: SessionKernelFailure.callback) { try await createConversation(session) }
                #expect(await storage.commits.isEmpty)
                let conversation = try #require(calls.values.first)
                #expect(try await storage.conversation(conversation, context: .background) == nil)
                #expect(try await session.snapshot(token, conversationId: conversation, context: .background) == nil)
            } else {
                let conversation = try await createConversation(session)
                #expect(calls.values == [conversation])
                #expect(try await session.snapshot(token, conversationId: conversation, context: .background) == ["created": true])
                let writes = try #require(await storage.commits.last)
                #expect(writes.count == 2)
                #expect(writes.map(\.type) == ["conversation", "document.create"])
            }
            try await session.close(context: .background)
        }
    }
}

private final class SessionCleanupHooks: SessionHooks {
    let session = Mutex<Session?>(nil)
    let calls = SessionTestLog<String>()
    func beforeClose() async {
        let owner = session.withLock { state in
            let owner = state
            state = nil
            return owner
        }
        guard let owner else { calls.append("missing"); return }
        do {
            try await owner.unloadDocuments()
            calls.append("unloaded")
        } catch {
            calls.append("failed")
        }
    }
}

extension SessionKernelTests {
    @Test func SessionBeforeCloseHookCanDrainDocumentCache() async throws {
        let hooks = SessionCleanupHooks()
        let storage = ControlledStorage()
        let session = try await Session.open(storage: storage, hooks: hooks, context: .background)
        hooks.session.withLock { $0 = session }
        let token = try SessionDocToken<JSONObject>(kind: "hook.cleanup", version: 1, initial: { ["value": 0] })
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await session.close(context: .background)
        #expect(hooks.calls.values == ["unloaded"])
        await #expect(throws: DurableStorageError.closed(backend: "MemoryStorage")) {
            try await storage.findDocument(DocumentAddress(kind: token.definition.kind, scope: .session()), at: .current, context: .background)
        }
    }
}
