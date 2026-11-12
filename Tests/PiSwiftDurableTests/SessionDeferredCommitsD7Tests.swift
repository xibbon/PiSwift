import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct D7Value: Codable, Sendable, Equatable {
    var text = ""
    var base: Bool? = nil
    var keys: [String: Int]? = nil
}
private enum D7Failure: Error { case callback }
private func d7Token() throws -> ConversationDocToken<D7Value> {
    try ConversationDocToken(kind: "test.d7.progress", version: 1, fork: .initial,
                             initial: { D7Value() }, checkpointWhen: { value, _, _ in value["base"] == .bool(true) })
}

@Suite("PiSwiftDurableTests.SessionDeferredCommitsD7", .timeLimit(.minutes(3)))
struct SessionDeferredCommitsD7Tests {
    private func setup(_ clock: TestClock = TestClock(now: 1_000), within: Double? = nil) async throws ->
        (Session, ControlledStorage, ConversationID, ConversationDocToken<D7Value>, SessionTestLog<CommitPublication>) {
        let storage = ControlledStorage()
        let session = try await Session.open(storage: storage, now: { clock.now() },
            documentRetentionMs: 600_000,
            documentTimer: .init(now: { clock.now() }, sleep: { try await clock.sleep(until: $0) }),
            persistWithinMs: { within }, context: .background)
        let publications = SessionTestLog<CommitPublication>()
        _ = try session.subscribeCommits { publication, _ in publications.append(publication) }
        let id = try await createConversation(session)
        let token = try d7Token()
        try await session.commit({ tx in _ = try await tx.doc(token, conversationId: id) }, context: .background)
        return (session, storage, id, token, publications)
    }

    private func overflow(_ session: Session, id: ConversationID, token: ConversationDocToken<D7Value>) async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:501-519: each commit stays below its tracker limit.
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("keys", .object([:])) }, context: .background)
        for start in stride(from: 0, through: maxPendingOps, by: 4_000) {
            try await session.commit({ tx in
                let keys = try #require(try await tx.doc(token, conversationId: id).child("keys"))
                for index in start..<(start + 4_000) { try keys.set("k\(index)", .number(Double(index))) }
            }, context: .background, persistence: .deferred(withinMs: .infinity))
        }
    }

    @Test func holdsEligibleChangeInMemoryUntilDependentWritingRead() async throws {
        let (session, storage, id, token, publications) = try await setup()
        let before = await storage.commits.count
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "one") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        #expect(await storage.commits.count == before)
        #expect(publications.count == before)
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.text == "one")
        try await session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            let text = try draft.get("text")
            _ = try await tx.appendEntry(id, value: EntryDraft(kind: "derived", data: text))
        }, context: .background)
        #expect(await storage.commits.count == before + 1)
        #expect(publications.count == before + 1)
        #expect(documentChanges(publications.values.last!).last?.value?["text"] == .string("one"))
        try await session.close(context: .background)
    }

    @Test func readOnlyTransactionLeavesHoldForNextWritingCommit() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let before = await storage.commits.count
        try await session.commit({ tx in _ = try await tx.doc(token, conversationId: id) }, context: .background)
        #expect(await storage.commits.count == before)
        try await session.close(context: .background)
        #expect(await storage.commits.count == before + 1)
    }

    @Test func unrelatedCommitLeavesHoldAndCloseStoresIt() async throws {
        let (session, storage, id, token, _) = try await setup()
        let before = await storage.commits.count
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        _ = try await createConversation(session)
        #expect(await storage.commits.count == before + 1)
        try await session.close(context: .background)
        #expect(await storage.commits.count == before + 2)
    }

    @Test func finiteDeadlineUsesFakeClockAndInfiniteWindowArmsNone() async throws {
        let clock = TestClock(now: 1_000)
        let (session, storage, id, token, _) = try await setup(clock, within: 20)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "first") },
                                 context: .background, persistence: .deferred())
        try await eventually { clock.pendingSleeperCount == 1 }
        let before = await storage.commits.count
        clock.advance(by: 20)
        try await eventually { await storage.commits.count == before + 1 }
        #expect(clock.pendingSleeperCount == 0)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "second") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        #expect(clock.pendingSleeperCount == 0)
        try await session.close(context: .background)
    }

    @Test func invalidWindowUsesTaggedErrorText() async throws {
        let (session, _, id, token, _) = try await setup()
        do {
            try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "x") },
                                     context: .background, persistence: .deferred(withinMs: -.infinity))
            Issue.record("Expected invalid window")
        } catch {
            #expect(String(describing: error).contains("CommitPersistence.withinMs must be a number of milliseconds, 0 or more"))
        }
        try await session.close(context: .background)
    }

    @Test func deferredChangeWithOtherWriteStoresAtOnce() async throws {
        let (session, storage, id, token, publications) = try await setup()
        let before = await storage.commits.count
        try await session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("text", "x")
            _ = try await tx.appendEntry(id, value: EntryDraft(kind: "note"))
        }, context: .background, persistence: .deferred(withinMs: .infinity))
        #expect(await storage.commits.count == before + 1)
        #expect(session.documentCacheSizes.attached == 0)
        try await session.close(context: .background)
    }

    @Test func deferredMigrationStoresBaseAtOnce() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:254-266.
        let (session, storage, id, _, _) = try await setup()
        let v2 = try ConversationDocToken<D7Value>(kind: "test.d7.progress", version: 2, fork: .initial,
            initial: { D7Value() }, migrate: { value, _ in value }, checkpointWhen: { _, _, _ in false })
        let before = await storage.commits.count
        try await session.commit({ tx in try await tx.doc(v2, conversationId: id).set("text", "migrated") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        #expect(await storage.commits.count == before + 1)
        let writes = await storage.commits.last ?? []
        #expect(writes.contains { if case .documentChange(_, .base, _) = $0 { true } else { false } })
        try await session.close(context: .background)
    }

    @Test func readOnlySessionRejectsDeferredWrite() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:268-272.
        let (session, storage, id, token, _) = try await setup()
        let viewer = try await Session.openWithDocumentRetention(storage: storage,
            documentRetentionMs: { 600_000 }, readOnly: true, context: .background)
        await #expect(throws: ReadOnlySession.self) {
            try await viewer.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "rejected") },
                                    context: .background, persistence: .deferred(withinMs: .infinity))
        }
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.text == "")
        try await session.close(context: .background)
    }

    @Test func earliestDeadlineStoresAllHeldDocumentsInOneBatch() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:347-378.
        let clock = TestClock(now: 1_000)
        let (session, storage, id, token, _) = try await setup(clock, within: 500)
        let other = try ConversationDocToken<D7Value>(kind: "test.d7.other", version: 1, fork: .initial,
            initial: { D7Value() }, checkpointWhen: { _, _, _ in false })
        try await session.commit({ tx in _ = try await tx.doc(other, conversationId: id) }, context: .background)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "first") },
                                 context: .background, persistence: .deferred(withinMs: 80))
        try await session.commit({ tx in try await tx.doc(other, conversationId: id).set("text", "second") },
                                 context: .background, persistence: .deferred())
        let before = await storage.commits.count
        try await eventually { clock.pendingSleeperCount == 1 }
        clock.advance(by: 79)
        #expect(await storage.commits.count == before)
        clock.advance(by: 1)
        try await eventually { await storage.commits.count == before + 1 }
        #expect((await storage.commits.last ?? []).filter { if case .documentChange = $0 { true } else { false } }.count == 2)
        #expect(clock.pendingSleeperCount == 0)
        try await session.close(context: .background)
    }

    @Test func storingOneHoldMovesTimerToTheNextDeadline() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:379-389.
        let clock = TestClock(now: 1_000)
        let (session, storage, id, token, _) = try await setup(clock)
        let other = try ConversationDocToken<D7Value>(kind: "test.d7.other", version: 1, fork: .initial,
            initial: { D7Value() }, checkpointWhen: { _, _, _ in false })
        try await session.commit({ tx in _ = try await tx.doc(other, conversationId: id) }, context: .background)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "first") },
                                 context: .background, persistence: .deferred(withinMs: 20))
        try await session.commit({ tx in try await tx.doc(other, conversationId: id).set("text", "second") },
                                 context: .background, persistence: .deferred(withinMs: 100))
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "stored") }, context: .background)
        let before = await storage.commits.count
        clock.advance(by: 20)
        #expect(await storage.commits.count == before)
        clock.advance(by: 80)
        try await eventually { await storage.commits.count == before + 1 }
        try await session.close(context: .background)
    }

    @Test func failedSessionDoesNotStoreHeldChanges() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:410-418.
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "lost") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let before = await storage.commits.count
        session.fail(D7Failure.callback)
        _ = try? await session.close(context: .background)
        #expect(await storage.commits.count == before)
    }

    @Test(.timeLimit(.minutes(2))) func overflowedHoldStoresWholeValue() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:477-486.
        let (session, storage, id, token, publications) = try await setup()
        try await overflow(session, id: id, token: token)
        let before = await storage.commits.count
        try await session.close(context: .background)
        #expect(await storage.commits.count == before + 1)
        guard case .documentChange(_, .base(_, let value, _), _) = await storage.commits.last?.first else {
            Issue.record("Expected a whole-value store after overflow"); return
        }
        #expect(value["keys"]?.objectValue?.count == 12_000)
        #expect(documentChanges(publications.values.last!).last?.ops == [.replace(.object(value))])
    }

    @Test(.timeLimit(.minutes(2))) func ownWriteAfterOverflowStoresOwnBase() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:488-500.
        let (session, storage, id, token, _) = try await setup()
        try await overflow(session, id: id, token: token)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "own") }, context: .background)
        guard case .documentChange(_, .base(_, let value, _), _) = await storage.commits.last?.first else {
            Issue.record("Expected the own value as a base"); return
        }
        #expect(value["text"] == .string("own"))
        #expect(value["keys"]?.objectValue?.count == 12_000)
        try await session.close(context: .background)
    }

    @Test func heldBaseRemainsBaseAndLaterHoldCountsAsDelta() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:458-475.
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in
            let doc = try await tx.doc(token, conversationId: id)
            try doc.set("text", "x"); try doc.set("base", true)
        }, context: .background, persistence: .deferred(withinMs: .infinity))
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "xy") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        try await session.unloadDocuments()
        guard case .documentChange(_, .base(_, let base, _), _) = await storage.commits.last?.first else {
            Issue.record("A selected held base was lost"); return
        }
        #expect(base["text"] == .string("xy"))
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("base", false) }, context: .background)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "xyz") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        try await session.close(context: .background)
        guard case .documentChange(_, .delta, _) = await storage.commits.last?.first else {
            Issue.record("A non-base hold must count as one delta"); return
        }
    }

    @Test func retentionZeroKeepsHeldTrackerOnlyUntilStored() async throws {
        // v1.5.2 D7 session-deferred-commits.test.ts:600-611.
        let clock = TestClock(now: 1_000), storage = ControlledStorage()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 0,
            documentTimer: .init(now: { clock.now() }, sleep: { try await clock.sleep(until: $0) }), context: .background)
        let id = try await createConversation(session), token = try d7Token()
        try await session.commit({ tx in _ = try await tx.doc(token, conversationId: id) }, context: .background)
        _ = try await session.readOnLine { () }
        #expect(session.documentCacheSizes.attached == 0)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        _ = try await session.readOnLine { () }
        #expect(session.documentCacheSizes.attached == 1)
        try await session.unloadDocuments()
        #expect(session.documentCacheSizes.attached == 0)
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.text == "held")
        try await session.close(context: .background)
    }

    @Test func immediateWriteFoldsHeldOperationsIntoItsOwnDelta() async throws {
        let (session, storage, id, token, publications) = try await setup()
        for text in ["a", "ab"] {
            try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", .string(text)) },
                                     context: .background, persistence: .deferred(withinMs: .infinity))
        }
        let before = await storage.commits.count
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "abc") }, context: .background)
        let writes = await storage.commits
        #expect(writes.count == before + 1)
        guard case .documentChange(_, .delta(_, let ops, _), _) = writes.last?.first else {
            Issue.record("Expected folded delta"); return
        }
        #expect(ops == [.append(["text"], "abc")])
        #expect(documentChanges(publications.values.last!).last?.ops == ops)
        try await session.close(context: .background)
    }

    @Test func failedReadingCommitKeepsItsHold() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let before = await storage.commits.count
        await #expect(throws: D7Failure.self) {
            try await session.commit({ tx in
                _ = try await tx.doc(token, conversationId: id)
                _ = try await tx.appendEntry(id, value: EntryDraft(kind: "lost"))
                throw D7Failure.callback
            }, context: .background)
        }
        #expect(await storage.commits.count == before)
        try await session.close(context: .background)
        #expect(await storage.commits.count == before + 1)
    }

    @Test func unloadStoresHoldBeforeDroppingTracker() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let before = await storage.commits.count
        try await session.unloadDocuments()
        #expect(await storage.commits.count == before + 1)
        #expect(session.documentCacheSizes.cached == 0)
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.text == "held")
        try await session.close(context: .background)
    }

    @Test func retirementStoresHeldDeltaBeforeRetireWrite() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        try await session.commit({ tx in try await tx.retireDoc(token, conversationId: id) }, context: .background)
        let writes = await storage.commits.last ?? []
        #expect(writes.map(\.type) == ["document.change", "document.retire"])
        #expect(try await session.snapshot(token, conversationId: id, context: .background) == nil)
        try await session.close(context: .background)
    }

    @Test func versionReloadStoresHeldValueBeforeMigration() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let before = await storage.commits.count
        let v2 = try ConversationDocToken<D7Value>(kind: "test.d7.progress", version: 2, fork: .initial,
            initial: { D7Value() }, migrate: { value, _ in value }, checkpointWhen: { _, _, _ in false })
        #expect(try await session.snapshot(v2, conversationId: id, context: .background)?.text == "held")
        #expect(await storage.commits.count == before + 1)
        try await session.close(context: .background)
    }

    @Test func heldCommitsAdvanceOwnObserversAndWatchOnceEach() async throws {
        let (session, storage, id, token, publications) = try await setup()
        let own = SessionTestLog<String>()
        let subscription = try session.observeCommits { publication, _ in
            if case .memory(let changes) = publication, let text = changes.last?.value?["text"]?.stringValue { own.append(text) }
        }
        let watch = try #require(try await session.watchDoc(token, conversationId: id, context: .background))
        let frames = SessionTestLog<String>()
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { frames.append(value.text) }
        }
        let before = await storage.commits.count
        for text in ["a", "ab"] {
            try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", .string(text)) },
                                     context: .background, persistence: .deferred(withinMs: .infinity))
            await watch.waitUntilIdle()
        }
        #expect(own.values == ["a", "ab"])
        #expect(frames.values == ["a", "ab"])
        #expect(await storage.commits.count == before)
        #expect(publications.count == before)
        subscription.cancel(); _ = await watch.stop()
        try await session.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func deferredPublicationWaitsForTheStoredPartBeforeIt() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:360-385,662-678.
        let (session, storage, id, token, publications) = try await setup()
        let other = try await createConversation(session)
        let own = SessionTestLog<String>()
        let subscription = try session.observeCommits { publication, _ in
            switch publication {
            case .stored: own.append("stored")
            case .memory: own.append("memory")
            }
        }
        let gate = await storage.holdCommits()
        let first = Task { try await session.commit({ tx in
            _ = try await tx.appendEntry(other, value: EntryDraft(kind: "first"))
        }, context: .background) }
        await gate.waitUntilEntered()
        let before = publications.count
        let deferred = Task { try await session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("text", "held")
        }, context: .background, persistence: .deferred(withinMs: .infinity)) }
        try await eventually { session.writerPendingParts >= 2 }
        #expect(publications.count == before)
        #expect(own.values.isEmpty)
        await gate.release()
        try await first.value
        try await deferred.value
        #expect(own.values == ["stored", "memory"])
        #expect(publications.count == before + 1)
        subscription.cancel()
        try await session.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStoredPartPreventsLaterDeferredPublication() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:680-694.
        let (session, storage, id, token, publications) = try await setup()
        let other = try await createConversation(session)
        let own = SessionTestLog<String>()
        let subscription = try session.observeCommits { publication, _ in
            if case .memory = publication { own.append("memory") }
        }
        let gate = await storage.holdCommits()
        let first = Task { try await session.commit({ tx in
            _ = try await tx.appendEntry(other, value: EntryDraft(kind: "first"))
        }, context: .background) }
        await gate.waitUntilEntered()
        let before = publications.count
        let deferred = Task { try await session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("text", "lost")
        }, context: .background, persistence: .deferred(withinMs: .infinity)) }
        try await eventually { session.writerPendingParts >= 2 }
        await storage.failNextCommit(D7Failure.callback)
        await gate.release()
        await #expect(throws: (any Error).self) { try await first.value }
        await #expect(throws: (any Error).self) { try await deferred.value }
        #expect(own.values.isEmpty)
        #expect(publications.count == before)
        subscription.cancel()
        try await session.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedHeldAdoptionSettlesAndClosesTheSession() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:596-633.
        let (session, storage, id, token, publications) = try await setup()
        let before = await storage.commits.count
        session.failNextAdoption(D7Failure.callback)
        await #expect(throws: (any Error).self) {
            try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "lost") },
                                     context: .background, persistence: .deferred(withinMs: .infinity))
        }
        #expect(await storage.commits.count == before)
        #expect(publications.count == before)
        try await session.close(context: .background)
        #expect(session.writerPendingParts == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func unloadWaitsForEarlierStorageThenStoresTheHold() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:839-855.
        let (session, storage, id, token, _) = try await setup()
        let other = try await createConversation(session)
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let gate = await storage.holdCommits()
        let first = Task { try await session.commit({ tx in
            _ = try await tx.appendEntry(other, value: EntryDraft(kind: "first"))
        }, context: .background) }
        await gate.waitUntilEntered()
        let before = await storage.commits.count
        let unloading = Task { try await session.unloadDocuments() }
        #expect(await storage.commits.count == before)
        await gate.release()
        try await first.value
        try await unloading.value
        #expect(await storage.commits.count == before + 1)
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.text == "held")
        try await session.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeDrainsEarlierStorageAndThenStoresTheHold() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:902-916.
        let (session, storage, id, token, publications) = try await setup()
        let other = try await createConversation(session)
        let gate = await storage.holdCommits()
        let first = Task { try await session.commit({ tx in
            _ = try await tx.appendEntry(other, value: EntryDraft(kind: "first"))
        }, context: .background) }
        await gate.waitUntilEntered()
        let deferred = Task { try await session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("text", "held")
        }, context: .background, persistence: .deferred(withinMs: .infinity)) }
        try await eventually { session.writerPendingParts >= 2 }
        let before = await storage.commits.count
        let closing = Task { try await session.close(context: .background) }
        await gate.release()
        try await first.value
        try await deferred.value
        try await closing.value
        #expect(await storage.commits.count == before + 1)
        #expect(documentChanges(publications.values.last!).last?.value?["text"] == .string("held"))
    }

    @Test(.timeLimit(.minutes(1)))
    func readNoWriteErrorAndDeferredCallbacksKeepLineOrder() async throws {
        // v1.5.2 D7 session-group-commit.test.ts:390-412.
        let (session, storage, id, token, publications) = try await setup()
        let other = try await createConversation(session)
        let gate = await storage.holdCommits()
        let first = Task { try await session.commit({ tx in
            _ = try await tx.appendEntry(other, value: EntryDraft(kind: "first"))
        }, context: .background) }
        await gate.waitUntilEntered()
        let prepared = SessionTestLog<String>()
        let read = Task { try await session.readOnLine { prepared.append("read"); return "read" } }
        try await eventually { session.outstandingJobs >= 2 }
        let none = Task { try await session.commit({ _ in prepared.append("none"); return "none" }, context: .background) }
        try await eventually { session.outstandingJobs >= 3 }
        let failed = Task { try await session.commit({ _ -> Void in
            prepared.append("error"); throw D7Failure.callback
        }, context: .background) }
        try await eventually { session.outstandingJobs >= 4 }
        let deferred = Task { try await session.commit({ tx in
            prepared.append("deferred")
            try await tx.doc(token, conversationId: id).set("text", "held")
        }, context: .background, persistence: .deferred(withinMs: .infinity)) }
        try await eventually { session.outstandingJobs >= 5 }
        let before = publications.count
        await gate.release()
        try await first.value
        #expect(try await read.value == "read")
        #expect(try await none.value == "none")
        await #expect(throws: D7Failure.self) { try await failed.value }
        try await deferred.value
        #expect(prepared.values == ["read", "none", "error", "deferred"])
        #expect(publications.count == before + 1)
        try await session.close(context: .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func heldStoreReceiptPublishesBeforeStorageRejects() async throws {
        // v1.5.2 D7 session-adoption.test.ts:382-408.
        let (session, storage, id, token, publications) = try await setup()
        let before = publications.count
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        let nextCall = await storage.callBatchCounts.count + 1
        await storage.rejectCall(nextCall, afterStored: 1, error: D7Failure.callback)
        await #expect(throws: (any Error).self) { try await session.unloadDocuments() }
        #expect(publications.count == before + 1)
        #expect(documentChanges(publications.values.last!).last?.value?["text"] == .string("held"))
        #expect(session.failure != nil)
        try await session.close(context: .background)
    }

    @Test func crashReopenSeesOnlyLastStoredValue() async throws {
        let storage = MemoryStorage()
        let token = try d7Token()
        var crashed: Session? = try await Session.open(storage: storage, context: .background)
        let id = try await createConversation(crashed!)
        try await crashed!.commit({ tx in _ = try await tx.doc(token, conversationId: id) }, context: .background)
        try await crashed!.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "stored") }, context: .background)
        try await crashed!.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "held") },
                                  context: .background, persistence: .deferred(withinMs: .infinity))
        #expect(try await crashed!.snapshot(token, conversationId: id, context: .background)?.text == "held")
        crashed = nil // Simulate a process crash: no clean close or held store.
        let reopened = try await Session.open(storage: storage, context: .background)
        #expect(try await reopened.snapshot(token, conversationId: id, context: .background)?.text == "stored")
        try await reopened.close(context: .background)
    }

    @Test func closeStillClosesStorageWhenHeldStoreFails() async throws {
        let (session, storage, id, token, _) = try await setup()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("text", "lost") },
                                 context: .background, persistence: .deferred(withinMs: .infinity))
        await storage.failNextCommit(D7Failure.callback)
        await #expect(throws: D7Failure.self) { try await session.close(context: .background) }
        guard case .failed = await session.closed else { Issue.record("Expected failed Session"); return }
    }
}
