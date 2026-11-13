import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum Round1WriterError: Error, Equatable { case refused, rejected, read, adoption, scope, between }

// The displayed test names follow v1.5.2 session-group-commit.test.ts and
// session-adoption.test.ts. Gates replace the tag's flush/macrotask witnesses.
@Suite("PiSwiftDurableTests.SessionWriterRound1Failures", .timeLimit(.minutes(2)))
struct SessionWriterRound1FailureTests {
    private func append(_ session: Session, _ id: ConversationID, _ kind: String) -> Task<EntryRecord, any Error> {
        Task { try await session.commit({ tx in try await tx.appendEntry(id, value: EntryDraft(kind: kind)) },
                                        context: .background) }
    }
    private func waitParts(_ session: Session, _ count: Int) async {
        for _ in 0..<50_000 {
            if session.writerPendingParts >= count { return }
            await Task.yield()
        }
        Issue.record("Only \(session.writerPendingParts) of \(count) parts were admitted")
    }
    private func kinds(_ h: SessionTestHarness) -> [String] {
        h.publications.values.flatMap(\.changes).compactMap {
            if case .entry(let entry) = $0 { return entry.kind }; return nil
        }
    }

    @Test("delivers a read, a commit without writes, and a callback error after an earlier commit")
    func outcomeOrderWithoutDeferredCommit() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let hold = await h.storage.holdCommits()
        let first = append(h.session, id, "first")
        await hold.waitUntilEntered()
        let prepared = SessionTestLog<String>(), resolved = SessionTestLog<String>()
        let read = Task {
            let value = try await h.session.readOnLine { prepared.append("read"); return "read" }
            resolved.append("read"); return value
        }
        await waitOutstanding(h.session, 2)
        let none = Task {
            let value = try await h.session.commit({ _ in prepared.append("none"); return "none" }, context: .background)
            resolved.append("none"); return value
        }
        await waitOutstanding(h.session, 3)
        let own = Task {
            do { _ = try await h.session.commit({ _ -> String in
                prepared.append("error"); throw Round1WriterError.read
            }, context: .background) }
            catch { resolved.append("error"); throw error }
        }
        await waitOutstanding(h.session, 4)
        #expect(h.session.outstandingJobs == 4)
        for _ in 0..<50_000 {
            if prepared.count == 3 { break }
            await Task.yield()
        }
        #expect(prepared.values == ["read", "none", "error"])
        #expect(resolved.values.isEmpty)
        await hold.release()
        _ = try await first.value
        #expect(try await read.value == "read")
        #expect(try await none.value == "none")
        await #expect(throws: Round1WriterError.read) { _ = try await own.value }
        #expect(kinds(h) == ["first"])
        #expect(h.session.failure == nil)
        try await h.session.close(context: .background)
    }

    private func waitOutstanding(_ session: Session, _ count: Int) async {
        for _ in 0..<50_000 {
            if session.outstandingJobs == count { return }
            await Task.yield()
        }
        Issue.record("Only \(session.outstandingJobs) of \(count) outcomes were admitted")
    }

    @Test("starts no job past 256 without a delivered outcome, and returns its line state to zero when idle")
    func backpressureAtJob257() async throws {
        let h = try await openTestSession()
        let a = try await createConversation(h.session)
        let b = try await createConversation(h.session)
        let hold = await h.storage.holdCommits()
        let first = append(h.session, a, "held")
        await hold.waitUntilEntered()
        let entered = SessionTestLog<Int>()
        var jobs: [Task<EntryRecord, any Error>] = []
        for index in 0..<300 {
            jobs.append(Task {
                try await h.session.commit({ tx in
                    entered.append(index)
                    return try await tx.appendEntry(b, value: EntryDraft(kind: "note"))
                }, context: .background)
            })
        }
        for _ in 0..<100_000 {
            if entered.count == 255 { break }
            await Task.yield()
        }
        #expect(entered.count == 255)
        #expect(h.session.outstandingJobs == 256)
        await hold.release()
        _ = try await first.value
        for job in jobs { _ = try await job.value }
        #expect(entered.count == 300)
        #expect(h.session.outstandingJobs == 0)
        #expect(h.session.writerUnpublished == 0)
        try await h.session.close(context: .background)
    }

    @Test("makes every outcome after a fatal failure SessionFailed, and keeps the earlier ones")
    func refusalBoundary() async throws {
        let h = try await openTestSession()
        let ids = try await (createConversation(h.session), createConversation(h.session),
                             createConversation(h.session), createConversation(h.session))
        let gate = await h.storage.holdCommits()
        let first = append(h.session, ids.0, "first")
        await gate.waitUntilEntered()
        let stored = append(h.session, ids.1, "stored")
        await waitParts(h.session, 2)
        let refused = append(h.session, ids.2, "refused")
        await waitParts(h.session, 3)
        let after = append(h.session, ids.3, "after")
        await waitParts(h.session, 4)
        let read = Task { try await h.session.readOnLine { "read" } }
        await h.storage.refuseCall(6, afterStored: 1, error: Round1WriterError.refused)
        await gate.release()
        _ = try await first.value
        _ = try await stored.value
        await #expect(throws: Round1WriterError.refused) { _ = try await refused.value }
        await #expect(throws: SessionFailed.self) { _ = try await after.value }
        await #expect(throws: SessionFailed.self) { _ = try await read.value }
        #expect(kinds(h) == ["first", "stored"])
        #expect(await h.storage.callBatchCounts.last == 3)
        guard h.session.failure != nil else {
            Issue.record("Refusal did not fail the Session")
            try await h.session.close(context: .background)
            return
        }
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? Round1WriterError == .refused)
    }

    @Test("fails every job after the first part of a call that rejects, except its other parts, with their storage error")
    func rejectedPrefixWithNoWriteBetween() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let gate = await h.storage.holdCommits()
        let first = append(h.session, id, "a")
        await gate.waitUntilEntered()
        let before = append(h.session, id, "b")
        await waitParts(h.session, 2)
        let none = Task { try await h.session.commit({ _ in "no write" }, context: .background) }
        for _ in 0..<50_000 {
            if h.session.outstandingJobs >= 3 { break }
            await Task.yield()
        }
        let after = append(h.session, id, "d")
        await waitParts(h.session, 3)
        await h.storage.rejectCall(3, afterStored: 2, error: Round1WriterError.rejected)
        await gate.release()
        _ = try await first.value
        await #expect(throws: Round1WriterError.rejected) { _ = try await before.value }
        await #expect(throws: SessionFailed.self) { _ = try await none.value }
        await #expect(throws: Round1WriterError.rejected) { _ = try await after.value }
        #expect(kinds(h) == ["a", "b", "d"])
        #expect(await h.storage.callBatchCounts.last == 2)
    }

    @Test("reports SessionFailed with the first error for a call that rejects after another failure failed the Session")
    func earlierReadFailureWins() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let gate = await h.storage.holdCommits()
        let inflight = append(h.session, id, "a")
        await gate.waitUntilEntered()
        await h.storage.failNextTaskRead(Round1WriterError.read)
        let reading = Task {
            try await h.session.commit({ tx in try await tx.task(TaskID(999)) }, context: .background)
        }
        for _ in 0..<50_000 {
            if h.session.failure != nil { break }
            await Task.yield()
        }
        #expect(h.session.failure as? Round1WriterError == .read)
        await h.storage.rejectCall(2, afterStored: 0, error: Round1WriterError.rejected)
        await gate.release()
        await #expect(throws: Round1WriterError.read) { _ = try await reading.value }
        do { _ = try await inflight.value; Issue.record("In-flight commit resolved after earlier failure") }
        catch let failed as SessionFailed { #expect(failed.cause as? Round1WriterError == .read) }
        #expect(kinds(h).isEmpty)
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? Round1WriterError == .read)
    }

    @Test("fails the Session when Storage resolves without adopting")
    func noReceipt() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        await h.storage.skipReceipts(onCall: 2)
        await #expect(throws: StorageRequestError.self) { _ = try await append(h.session, id, "stored").value }
        #expect(kinds(h).isEmpty)
        guard case .failed = await h.session.closed else { Issue.record("Missing receipt did not fail Session"); return }
    }

    @Test("publishes a commit that Storage rejects after adopting it, then fails the Session")
    func rejectAfterAdoption() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        await h.storage.rejectCall(2, afterStored: 1, error: Round1WriterError.rejected)
        await #expect(throws: Round1WriterError.rejected) { _ = try await append(h.session, id, "stored").value }
        #expect(kinds(h) == ["stored"])
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? Round1WriterError == .rejected)
    }

    #if DEBUG
    @Test("fails the Session with its own adoption error, which never reaches Storage")
    func ownAdoptionThrow() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        h.session.failNextAdoption(Round1WriterError.adoption)
        await #expect(throws: Round1WriterError.adoption) { _ = try await append(h.session, id, "stored").value }
        #expect(kinds(h).isEmpty)
        #expect(await h.storage.callBatchCounts == [1, 1])
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? Round1WriterError == .adoption)
    }

    @Test("leaves the parts after one whose adoption throws unpublished, rejected with SessionFailed")
    func adoptionThrowStopsLaterGroupParts() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let held = await h.storage.holdCommits()
        let lead = append(h.session, id, "lead")
        await held.waitUntilEntered()
        let before = append(h.session, id, "before")
        await waitParts(h.session, 2)
        let failing = append(h.session, id, "failing")
        await waitParts(h.session, 3)
        let after = append(h.session, id, "after")
        await waitParts(h.session, 4)
        let scope = await h.storage.holdPublication(at: 4)
        await held.release()
        _ = try await lead.value
        _ = try await before.value
        await scope.waitUntilEntered()
        h.session.failNextAdoption(Round1WriterError.adoption)
        await scope.release()
        await #expect(throws: Round1WriterError.adoption) { _ = try await failing.value }
        await #expect(throws: SessionFailed.self) { _ = try await after.value }
        #expect(kinds(h) == ["lead", "before"])
        #expect(await h.storage.callBatchCounts == [1, 1, 3])
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? Round1WriterError == .adoption)
    }
    #endif

    @Test("reports a scope that throws instead of running the publication, and publishes the commit")
    func scopeThrowRunsPublication() async throws {
        let storage = ControlledStorage()
        let reports = SessionTestLog<(String, ReportInfo)>()
        let session = try await Session.open(storage: storage,
            onReport: { error, info in reports.append((String(describing: error), info)) }, context: .background)
        let published = SessionTestLog<CommitPublication>()
        let listener = try session.observeCommits(.init(advance: { publication, _ in published.append(publication) }, end: { _ in }))
        let id = try await createConversation(session)
        let before = published.count
        await storage.failNextPublicationScope(Round1WriterError.scope)
        _ = try await append(session, id, "stored").value
        #expect(published.count == before + 1)
        #expect(reports.values.count == 1)
        #expect(reports.values[0].0.contains("scope"))
        #expect(reports.values[0].1 == .listenerError)
        #expect(session.failure == nil)
        listener.detach()
        try await session.close(context: .background)
    }

    @Test("publishes each commit inside the storage's scope, the next only once one it runs later ran")
    func nextScopeWaitsForHeldPublication() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let held = await h.storage.holdCommits()
        let lead = append(h.session, id, "lead")
        await held.waitUntilEntered()
        let one = append(h.session, id, "one")
        await waitParts(h.session, 2)
        let two = append(h.session, id, "two")
        await waitParts(h.session, 3)
        let scope = await h.storage.holdPublication(at: 3)
        await held.release()
        _ = try await lead.value
        await scope.waitUntilEntered()
        #expect(await h.storage.publicationCalls == 3)
        #expect(kinds(h) == ["lead"])
        await scope.release()
        _ = try await one.value
        _ = try await two.value
        #expect(await h.storage.publicationCalls == 4)
        #expect(kinds(h) == ["lead", "one", "two"])
        try await h.session.close(context: .background)
    }

    @Test("publishes the parts of one call a macrotask apart: what one resolves runs before the next is published")
    func resolvedCallerCanIssueNextCommitBeforeNextPublication() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let hold = await h.storage.holdCommits()
        let lead = append(h.session, id, "lead")
        await hold.waitUntilEntered()
        let one = append(h.session, id, "one")
        await waitParts(h.session, 2)
        let two = append(h.session, id, "two")
        await waitParts(h.session, 3)
        let beforeTwo = await h.storage.holdPublication(at: 4)
        await hold.release()
        _ = try await lead.value
        _ = try await one.value
        await beforeTwo.waitUntilEntered()
        #expect(kinds(h) == ["lead", "one"])
        let next = append(h.session, id, "next")
        await waitParts(h.session, 2)
        await beforeTwo.release()
        _ = try await two.value
        _ = try await next.value
        #expect(kinds(h) == ["lead", "one", "two", "next"])
    }

    @Test("publishes no part of a call after a failure that a continuation of an earlier part caused")
    func callerReadFailureBetweenPublications() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let hold = await h.storage.holdCommits()
        let lead = append(h.session, id, "lead")
        await hold.waitUntilEntered()
        let one = append(h.session, id, "one")
        await waitParts(h.session, 2)
        let two = append(h.session, id, "two")
        await waitParts(h.session, 3)
        let beforeTwo = await h.storage.holdPublication(at: 4)
        await hold.release()
        _ = try await lead.value
        _ = try await one.value
        await beforeTwo.waitUntilEntered()
        await h.storage.failNextTaskRead(Round1WriterError.between)
        let failing = Task {
            try await h.session.commit({ tx in try await tx.task(TaskID(999)) }, context: .background)
        }
        for _ in 0..<50_000 {
            if h.session.failure != nil { break }
            await Task.yield()
        }
        #expect(h.session.failure as? Round1WriterError == .between)
        await beforeTwo.release()
        await #expect(throws: Round1WriterError.between) { _ = try await failing.value }
        await #expect(throws: SessionFailed.self) { _ = try await two.value }
        #expect(kinds(h) == ["lead", "one"])
    }

    @Test("publishes no part of a call after the Session fails in a continuation of an earlier part")
    func callerFailsSessionBetweenPublications() async throws {
        let h = try await openTestSession()
        let id = try await createConversation(h.session)
        let hold = await h.storage.holdCommits()
        let lead = append(h.session, id, "lead")
        await hold.waitUntilEntered()
        let one = append(h.session, id, "one")
        await waitParts(h.session, 2)
        let two = append(h.session, id, "two")
        await waitParts(h.session, 3)
        let beforeTwo = await h.storage.holdPublication(at: 4)
        await hold.release()
        _ = try await lead.value
        _ = try await one.value
        await beforeTwo.waitUntilEntered()
        h.session.fail(Round1WriterError.between)
        await beforeTwo.release()
        await #expect(throws: SessionFailed.self) { _ = try await two.value }
        #expect(kinds(h) == ["lead", "one"])
    }
}
