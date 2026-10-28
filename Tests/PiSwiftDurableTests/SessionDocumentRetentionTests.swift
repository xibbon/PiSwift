import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Upstream v1.4.0 types.ts:78 requires an explicit checkpoint policy in each definition.

func retentionTestTimer(_ clock: any DurableClock) -> SessionDocumentTimer {
    .init(now: { clock.now() }, sleep: { try await clock.sleep(until: $0) })
}

private struct RetentionCount: Codable, Sendable, Equatable { var count: Int = 0 }
private enum RetentionFailure: Error { case clock, checkpoint, timer }
private func retentionCounter() throws -> ConversationDocToken<RetentionCount> {
    try ConversationDocToken(kind: "test.retention.counter", version: 1, fork: .initial, initial: { RetentionCount() }, checkpointWhen: { _, _, _ in false })
}
private struct RetentionSetup: Sendable {
    let storage: ControlledStorage
    let session: Session
    let clock: TestClock
    static func open(_ milliseconds: Double) async throws -> Self {
        let storage = ControlledStorage(), clock = TestClock(now: 1_000)
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: milliseconds, documentTimer: retentionTestTimer(clock), context: .background)
        return Self(storage: storage, session: session, clock: clock)
    }
    func bump(_ id: ConversationID, by: Int = 1) async throws {
        let token = try retentionCounter()
        try await session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            try draft.set("count", .number(try draft.get("count")!.numberValue! + Double(by)))
        }, context: .background)
    }
    func count(_ id: ConversationID) async throws -> Int? {
        try await session.snapshot(retentionCounter(), conversationId: id, context: .background)?.count
    }
    func settle() async throws { try await session.readOnLine {} }
    func close() async throws { try await session.close(context: .background) }
}
private func retentionEventually(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<10_000 {
        if try await condition() { return }
        await Task.yield()
    }
    Issue.record("The retention condition did not become true")
}

@Suite struct SessionDocumentRetentionTests {
    // Upstream session-document-retention.test.ts:109.
    @Test func expiryReloadsTheStoredValue() async throws {
        let h = try await RetentionSetup.open(60_000), id = try await createConversation(h.session)
        try await h.bump(id, by: 3); #expect(h.session.documentCacheSizes.cached > 0)
        h.clock.advance(by: 59_000); try await h.bump(id, by: 0); try await h.settle()
        #expect(h.session.documentCacheSizes.cached > 0)
        h.clock.advance(by: 61_000); try await h.session.commit({ _ in }, context: .background); try await h.settle()
        let reads = await h.storage.documentReadCount
        #expect(try await h.count(id) == 3); #expect(await h.storage.documentReadCount > reads)
        try await h.close()
    }

    // :132.
    @Test func zeroRetentionEvictsAfterUse() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session)
        try await h.bump(id)
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        #expect(try await h.count(id) == 1); try await h.close()
    }

    // :144.
    @Test func observersKeepDocumentsUntilTheLastDetach() async throws {
        let h = try await RetentionSetup.open(1_000), id = try await createConversation(h.session), token = try retentionCounter()
        try await h.bump(id)
        let watch = try #require(try await h.session.watchDoc(token, conversationId: id, context: .background))
        let state = try #require(try await h.session.documentState(token, conversationId: id, context: .background))
        let seen = SessionTestLog<Int>()
        try watch.start { value, _, _ in seen.append(value?.count ?? -1) }
        h.clock.advance(by: 1_000_000); try await h.bump(id); await state.waitUntilIdle(); await watch.waitUntilIdle()
        #expect(state.value?.count == 2); #expect(seen.values.contains(2))
        let reads = await h.storage.documentReadCount
        h.clock.advance(by: 1_000_000); try await h.session.commit({ _ in }, context: .background)
        #expect(try await h.count(id) == 2); #expect(await h.storage.documentReadCount == reads)
        _ = await watch.stop(); h.clock.advance(by: 1_000_000); try await h.bump(id); await state.waitUntilIdle()
        #expect(state.value?.count == 3)
        state.dispose(); h.clock.advance(by: 1_000_000)
        try await h.session.commit({ _ in }, context: .background); try await h.settle()
        #expect(h.session.documentCacheSizes.cached == 0); try await h.close()
    }

    // :185.
    @Test func aTransactionKeepsItsTracker() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session), token = try retentionCounter()
        try await h.bump(id)
        let entered = SessionTestGate(), release = SessionTestGate()
        let commit = Task { try await h.session.commit({ tx in
            let draft = try await tx.doc(token, conversationId: id)
            entered.release(); await release.wait()
            try draft.set("count", .number(try draft.get("count")!.numberValue! + 10))
        }, context: .background) }
        await entered.wait(); h.clock.advance(by: 1_000_000); release.release(); try await commit.value
        #expect(try await h.count(id) == 11); try await h.bump(id); #expect(try await h.count(id) == 12)
        try await h.close()
    }

    // :208. A second session reads the same storage before either session closes it.
    @Test func reloadPreservesDeltasAndBases() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session)
        for _ in 0..<5 { try await h.bump(id); try await h.settle() }
        #expect(try await h.count(id) == 5)
        let creations = await h.storage.commits.flatMap { $0 }.filter { write in
            if case .documentCreate(let record, _, _) = write { return record.kind == "test.retention.counter" }
            return false
        }
        #expect(creations.count == 1)
        let second = try await Session.open(storage: h.storage, documentRetentionMs: 0, documentTimer: retentionTestTimer(h.clock), context: .background)
        #expect(try await second.snapshot(retentionCounter(), conversationId: id, context: .background)?.count == 5)
        try await second.close(context: .background); try await h.close()
    }

    // :234.
    @Test func evictionPreservesHistoryAndForks() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session)
        let token = try RewindableConversationDocToken<RetentionCount>(kind: "test.retention.rewindable", version: 1, fork: .asOf, initial: { RetentionCount() }, checkpointWhen: { _, _, _ in false })
        let first = try await h.session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("count", 1)
            return try await tx.appendEntry(id, value: EntryDraft(kind: "note")).id
        }, context: .background)
        try await h.settle()
        let second = try await h.session.commit({ tx in
            try await tx.doc(token, conversationId: id).set("count", 2)
            return try await tx.appendEntry(id, value: EntryDraft(kind: "note")).id
        }, context: .background)
        try await h.settle()
        #expect(try await h.session.snapshotAsOf(token, conversationId: id, at: first, context: .background)?.count == 1)
        #expect(try await h.session.snapshotAsOf(token, conversationId: id, at: second, context: .background)?.count == 2)
        let fork = try await h.session.commit({ tx in try await tx.forkConversation(id, at: first, ownership: .ownerless()).id }, context: .background)
        try await h.settle()
        #expect(try await h.session.snapshot(token, conversationId: fork, context: .background)?.count == 1)
        #expect(try await h.session.snapshot(token, conversationId: id, context: .background)?.count == 2)
        try await h.close()
    }

    // :259.
    @Test func familyMembersLeaveTheCache() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session)
        let token = try ConversationDocFamilyToken<JSONObject, Int>(kind: "test.retention.event", version: 1, fork: .initial, initial: { ["seq": .number(Double($0))] }, checkpointWhen: { _, _, _ in false })
        for seq in 0..<200 { try await h.session.commit({ tx in _ = try await tx.doc(token, conversationId: id, key: String(seq), seed: seq) }, context: .background) }
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        #expect(try await h.session.snapshot(token, conversationId: id, key: "123", context: .background) == ["seq": 123])
        try await h.close()
    }

    // :275.
    @Test func manyConversationsKeepABoundedCache() async throws {
        let h = try await RetentionSetup.open(10_000)
        for _ in 0..<300 { let id = try await createConversation(h.session); try await h.bump(id); h.clock.advance(by: 1_000) }
        try await h.settle(); #expect(h.session.documentCacheSizes.cached <= 12); try await h.close()
    }

    // :288.
    @Test func aThrowingCacheClockDoesNotFailTheCommit() async throws {
        let storage = ControlledStorage(), fail = Mutex(false), clock = TestClock(now: 1_000)
        let session = try await Session.openWithDocumentRetention(storage: storage, now: { clock.now() }, documentRetentionMs: { 0 }, documentTimer: retentionTestTimer(clock), cacheNow: {
            if fail.withLock({ $0 }) { throw RetentionFailure.clock }; return clock.now()
        }, context: .background)
        let id = try await createConversation(session), token = try retentionCounter()
        fail.withLock { $0 = true }
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 42) }, context: .background)
        fail.withLock { $0 = false }
        #expect(try await session.snapshot(token, conversationId: id, context: .background)?.count == 42)
        try await session.close(context: .background)
    }

    // :307.
    @Test func failedSettlementStillEvicts() async throws {
        let h = try await RetentionSetup.open(10_000), id = try await createConversation(h.session)
        try await h.bump(id)
        let failing = try SessionDocToken<RetentionCount>(kind: "test.retention.failing", version: 1, initial: { RetentionCount() }, checkpointWhen: { _, _, _ in throw RetentionFailure.checkpoint })
        try await h.session.commit({ tx in _ = try await tx.doc(failing) }, context: .background)
        await #expect(throws: RetentionFailure.self) {
            try await h.session.commit({ tx in try await tx.doc(failing).set("count", 1); h.clock.advance(by: 1_000_000) }, context: .background)
        }
        #expect(h.session.documentCacheSizes.cached == 0); try await h.close()
    }

    // :325.
    @Test func aReadAppliesShorterRetention() async throws {
        let storage = ControlledStorage(), clock = TestClock(now: 1_000), retention = Mutex<Double>(600_000)
        let session = try await Session.openWithDocumentRetention(storage: storage, now: { clock.now() }, documentRetentionMs: { retention.withLock { $0 } }, documentTimer: retentionTestTimer(clock), context: .background)
        let id = try await createConversation(session), token = try retentionCounter()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 1) }, context: .background)
        retention.withLock { $0 = 0 }; clock.advance(by: 2_000)
        _ = try await session.snapshot(token, conversationId: id, context: .background)
        try await retentionEventually { try await session.readOnLine {}; return session.documentCacheSizes.cached == 0 }
        try await session.close(context: .background)
    }

    // :347.
    @Test func retiredObserversDoNotPinReplacements() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session), token = try retentionCounter()
        try await h.bump(id)
        let state = try #require(try await h.session.documentState(token, conversationId: id, context: .background))
        try await h.session.commit({ tx in try await tx.retireDoc(token, conversationId: id) }, context: .background)
        await state.waitUntilIdle(); #expect(state.value == nil)
        try await h.bump(id, by: 5)
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        #expect(try await h.count(id) == 5); state.dispose(); try await h.close()
    }

    // :364.
    @Test func closeDuringObserverLoadLeavesNoPin() async throws {
        let h = try await RetentionSetup.open(0), id = try await createConversation(h.session), token = try retentionCounter()
        try await h.bump(id)
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        let gate = await h.storage.holdFindDocument()
        let attaching = Task { try await h.session.documentState(token, conversationId: id, context: .background) }
        await gate.waitUntilEntered()
        let closeStarted = SessionTestGate()
        let subscription = try h.session.subscribeClose { closeStarted.release() }
        let closing = Task { try await h.close() }
        await closeStarted.wait()
        _ = subscription
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await attaching.value }
        try await closing.value
        #expect(h.session.documentCacheSizes.cached == 0); #expect(h.session.documentCacheSizes.idle == 0); #expect(h.session.documentCacheSizes.attached == 0)
    }

    // :382.
    @Test func timerEvictsWithoutACommitAndDetachIsIdempotent() async throws {
        let h = try await RetentionSetup.open(20), id = try await createConversation(h.session), token = try retentionCounter()
        try await h.bump(id)
        let state = try #require(try await h.session.documentState(token, conversationId: id, context: .background))
        state.dispose(); state.dispose()
        try await retentionEventually { h.clock.pendingSleeperCount > 0 }
        h.clock.advance(by: 20)
        try await retentionEventually { h.session.documentCacheSizes.cached == 0 }
        try await h.close()
    }

    // :397.
    @Test func coldReadsRepeatMigration() async throws {
        let h = try await RetentionSetup.open(0), migrations = SessionTestLog<Int>()
        let old = try SessionDocToken<JSONObject>(kind: "test.retention.migrating", version: 1, initial: { ["count": 1] }, checkpointWhen: { _, _, _ in false })
        let current = try SessionDocToken<JSONObject>(kind: "test.retention.migrating", version: 2, initial: { ["count": 0, "migrated": true] }, migrate: { value, _ in migrations.append(1); var value = value; value["migrated"] = true; return value }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in _ = try await tx.doc(old) }, context: .background)
        try await h.settle()
        #expect(try await h.session.snapshot(current, context: .background) == ["count": 1, "migrated": true])
        try await h.settle()
        #expect(try await h.session.snapshot(current, context: .background) == ["count": 1, "migrated": true])
        #expect(migrations.count == 2); try await h.close()
    }

    // :426. Swift's Double API excludes the JavaScript string case.
    @Test func invalidNumbersUseTheDefaultAndInfinityKeepsDocuments() async throws {
        for value in [Double.nan, -5, -Double.infinity] {
            let h = try await RetentionSetup.open(value), id = try await createConversation(h.session)
            try await h.bump(id)
            if Session.defaultDocumentRetentionMs > 0 {
                h.clock.advance(by: 60_000); try await h.session.commit({ _ in }, context: .background)
                #expect(h.session.documentCacheSizes.cached == 1)
            } else {
                try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
            }
            try await h.close()
        }
        let h = try await RetentionSetup.open(.infinity), id = try await createConversation(h.session)
        try await h.bump(id); h.clock.advance(by: 1_000_000_000_000_000)
        try await h.session.commit({ _ in }, context: .background); try await h.settle()
        #expect(h.session.documentCacheSizes.cached == 1); try await h.close()
    }

    // :451. A failed DurableClock sleep is the Swift equivalent of an unavailable timer.
    @Test func failedTimersLeaveCommitEvictionEnabled() async throws {
        let clock = RetentionUnavailableClock(), storage = ControlledStorage()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        let id = try await createConversation(session), token = try retentionCounter()
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 1) }, context: .background)
        try await retentionEventually { clock.attempts.count == 1 }
        try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("count", 2) }, context: .background)
        #expect(clock.attempts.count == 1)
        clock.advance(); try await session.commit({ _ in }, context: .background); try await session.readOnLine {}
        #expect(session.documentCacheSizes.cached == 0); try await session.close(context: .background)
    }

    // :539.
    @Test func anOldVersionObserverPinsANewVersionReload() async throws {
        let h = try await RetentionSetup.open(0)
        let old = try SessionDocToken<JSONObject>(kind: "test.retention.versioned", version: 1, initial: { ["count": 3] }, checkpointWhen: { _, _, _ in false })
        let current = try SessionDocToken<JSONObject>(kind: "test.retention.versioned", version: 2, initial: { ["count": 0, "v2": true] }, migrate: { value, _ in var value = value; value["v2"] = true; return value }, checkpointWhen: { _, _, _ in false })
        try await h.session.commit({ tx in _ = try await tx.doc(old) }, context: .background)
        let state = try #require(try await h.session.documentState(old, context: .background))
        #expect(try await h.session.snapshot(current, context: .background) == ["count": 3, "v2": true])
        try await h.settle(); #expect(h.session.documentCacheSizes.cached == 1)
        state.dispose()
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        try await h.close()
    }

    // :567.
    @Test func onePendingSweepServesManyLoads() async throws {
        let h = try await RetentionSetup.open(0), token = try retentionCounter()
        var ids: [ConversationID] = []
        for _ in 0..<50 { let id = try await createConversation(h.session); try await h.bump(id); ids.append(id) }
        try await retentionEventually { try await h.settle(); return h.session.documentCacheSizes.cached == 0 }
        let before = h.session.documentCacheSizes.sweeps
        let conversationIDs = ids
        try await h.session.commit({ tx in
            for id in conversationIDs {
                let draft = try await tx.doc(token, conversationId: id)
                try draft.set("count", .number(try draft.get("count")!.numberValue! + 1))
                await Task.yield()
            }
        }, context: .background)
        try await h.settle()
        #expect(h.session.documentCacheSizes.cached == 0)
        #expect(h.session.documentCacheSizes.sweeps - before <= 2)
        try await h.close()
    }
}

private final class RetentionUnavailableClock: DurableClock, Sendable {
    private let time = Mutex<Int64>(1_000)
    let attempts = SessionTestLog<Int>()
    func now() -> Int64 { time.withLock { $0 } }
    func advance() { time.withLock { $0 += 10_000 } }
    func sleep(until deadline: Int64) async throws { attempts.append(1); throw RetentionFailure.timer }
}
