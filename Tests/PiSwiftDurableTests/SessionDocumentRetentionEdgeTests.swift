import Foundation
import Dispatch
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Upstream v1.4.0 types.ts:78 requires an explicit checkpoint policy in each definition.

private enum RetentionEdgeFailure: Error { case callback, setting, timer }
private func retentionEdgeToken(_ kind: String = "retention.edge") throws -> SessionDocToken<JSONObject> {
    try SessionDocToken(kind: kind, version: 1, initial: { ["count": 0] }, checkpointWhen: { _, _, _ in false })
}
private func retentionEdgeWait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<10_000 {
        if try await condition() { return }
        await Task.yield()
    }
    Issue.record("The retention condition did not become true")
}
private func retentionEdgeDrain(_ session: Session) async throws { try await session.readOnLine {} }
private final class RetentionEdgeNoTimer: DurableClock, Sendable {
    let clock = TestClock(now: 1_000)
    let attempts = SessionTestLog<Int>()
    func now() -> Int64 { clock.now() }
    func sleep(until deadline: Int64) async throws { attempts.append(1); throw RetentionEdgeFailure.timer }
}

@Suite struct SessionDocumentRetentionEdgeTests {
    @Test func timerDeadlinesUseTheTimerTimeSource() async throws {
        let ageClock = TestClock(now: 1_000), timerClock = TestClock(now: 9_000)
        let deadlines = SessionTestLog<Int64>()
        let timer = SessionDocumentTimer(now: { timerClock.now() }, sleep: { deadline in
            deadlines.append(deadline)
            try await timerClock.sleep(until: deadline)
        })
        let token = try retentionEdgeToken()
        let session = try await Session.open(storage: MemoryStorage(), now: { ageClock.now() },
            documentRetentionMs: 1_000, documentTimer: timer, context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { timerClock.pendingSleeperCount == 1 }
        #expect(deadlines.values == [10_000])
        #expect(ageClock.pendingSleeperCount == 0)

        ageClock.advance(by: 1_000)
        timerClock.advance(by: 999)
        try await retentionEdgeDrain(session)
        #expect(session.documentCacheSizes.cached == 1)
        timerClock.advance(by: 1)
        try await retentionEdgeWait { session.documentCacheSizes.cached == 0 }
        try await session.close(context: .background)
    }

    @Test func longRetentionUsesBoundedTimerSteps() async throws {
        let maximumDelay: Int64 = 2_147_483_647
        let retention = maximumDelay + 500
        let clock = TestClock(now: 1_000), deadlines = SessionTestLog<Int64>()
        let timer = SessionDocumentTimer(now: { clock.now() }, sleep: { deadline in
            deadlines.append(deadline)
            try await clock.sleep(until: deadline)
        })
        let token = try retentionEdgeToken()
        let session = try await Session.open(storage: MemoryStorage(), now: { clock.now() },
            documentRetentionMs: Double(retention), documentTimer: timer, context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { deadlines.count == 1 && clock.pendingSleeperCount == 1 }
        #expect(deadlines.values == [1_000 + maximumDelay])

        clock.advance(by: maximumDelay - 1)
        try await retentionEdgeDrain(session)
        #expect(session.documentCacheSizes.cached == 1)
        #expect(deadlines.count == 1)
        clock.advance(by: 1)
        try await retentionEdgeWait { deadlines.count == 2 && clock.pendingSleeperCount == 1 }
        #expect(deadlines.values == [1_000 + maximumDelay, 1_000 + retention])
        #expect(session.documentCacheSizes.cached == 1)

        clock.advance(by: 499)
        try await retentionEdgeDrain(session)
        #expect(session.documentCacheSizes.cached == 1)
        clock.advance(by: 1)
        try await retentionEdgeWait { session.documentCacheSizes.cached == 0 }
        #expect(deadlines.count == 2)
        try await session.close(context: .background)
    }

    @Test func aClockAdvanceDuringATouchDoesNotDelayTheTimer() async throws {
        let clock = TestClock(now: 1_000), entered = SessionTestGate(), release = DispatchSemaphore(value: 0)
        let armed = Mutex(false), retention = Mutex(Double.infinity)
        let token = try retentionEdgeToken()
        let session = try await Session.openWithDocumentRetention(storage: MemoryStorage(), now: { clock.now() },
            documentRetentionMs: { retention.withLock { $0 } }, documentTimer: retentionTestTimer(clock), cacheNow: {
                let time = clock.now()
                let pause = armed.withLock { armed in
                    let pause = armed; armed = false; return pause
                }
                if pause { entered.release(); release.wait() }
                return time
            }, context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        clock.advance(by: 1_000)
        retention.withLock { $0 = 1_000 }; armed.withLock { $0 = true }
        let reading = Task { try await session.snapshot(token, context: .background) }
        await entered.wait()
        defer { release.signal() }
        clock.advance(by: 500); release.signal(); _ = try await reading.value
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        clock.advance(by: 500)
        try await retentionEdgeWait { session.documentCacheSizes.cached == 0 }
        try await session.close(context: .background)
    }

    @Test func concurrentClockSamplesKeepIdleTimesInOrder() async throws {
        let clock = TestClock(now: 1_000), entered = SessionTestGate(), release = DispatchSemaphore(value: 0)
        let sampling = Mutex((armed: false, calls: 0))
        let first = try retentionEdgeToken("retention.edge.first")
        let second = try retentionEdgeToken("retention.edge.second")
        let session = try await Session.openWithDocumentRetention(storage: MemoryStorage(), now: { clock.now() },
            documentRetentionMs: { 10_000 }, documentTimer: retentionTestTimer(clock), cacheNow: {
                let call = sampling.withLock { state in
                    guard state.armed else { return 0 }
                    state.calls += 1; return state.calls
                }
                if call == 1 {
                    entered.release(); release.wait()
                    return 2_000
                }
                return clock.now()
            }, context: .background)
        try await session.commit({ tx in
            _ = try await tx.doc(first); _ = try await tx.doc(second)
        }, context: .background)
        sampling.withLock { $0.armed = true }
        let reading = Task { try await session.snapshot(first, context: .background) }
        await entered.wait()
        defer { release.signal() }
        clock.advance(by: 2_000)
        _ = try await session.snapshot(second, context: .background)
        release.signal(); _ = try await reading.value
        sampling.withLock { $0.armed = false }
        clock.advance(by: 9_500)
        let observer = try #require(try await session.documentState(second, context: .background))
        try await session.commit({ _ in }, context: .background)
        // The first read completed after the second read. It uses at least that later time.
        #expect(session.documentCacheSizes.cached == 2)
        clock.advance(by: 500)
        try await session.commit({ _ in }, context: .background)
        #expect(session.documentCacheSizes.cached == 1)
        observer.dispose(); try await session.close(context: .background)
    }

    @Test(arguments: [1_000, 100_000])
    func repeatedReadsCanExpireWithinOneGranule(_ retention: Int64) async throws {
        let clock = TestClock(now: 1_000), storage = ControlledStorage(), token = try retentionEdgeToken()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: Double(retention), documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in try await tx.doc(token).set("count", 7) }, context: .background)
        let granule = min(1_000, retention / 10)
        clock.advance(by: granule - 1)
        let reads = await storage.documentReadCount
        #expect(try await session.snapshot(token, context: .background) == ["count": 7])
        #expect(await storage.documentReadCount == reads)
        // This read is inside the granule. It does not move the expiry time.
        clock.advance(by: retention - granule + 1)
        try await retentionEdgeWait { try await retentionEdgeDrain(session); return session.documentCacheSizes.cached == 0 }
        #expect(try await session.snapshot(token, context: .background) == ["count": 7])
        #expect(await storage.documentReadCount > reads)
        try await session.close(context: .background)
    }

    @Test func aNoWriteCommitExtendsRetention() async throws {
        let clock = TestClock(now: 1_000), storage = ControlledStorage(), token = try retentionEdgeToken()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let commits = await storage.commits.count
        clock.advance(by: 500)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        #expect(await storage.commits.count == commits)
        clock.advance(by: 500)
        try await session.commit({ _ in }, context: .background)
        #expect(session.documentCacheSizes.cached == 1)
        clock.advance(by: 500)
        try await retentionEdgeWait { try await retentionEdgeDrain(session); return session.documentCacheSizes.cached == 0 }
        try await session.close(context: .background)
    }

    @Test func aNoWriteCommitExtendsRetentionWithoutTimers() async throws {
        let clock = RetentionEdgeNoTimer(), storage = ControlledStorage(), token = try retentionEdgeToken()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { clock.attempts.count == 1 }
        clock.clock.advance(by: 500)
        let commits = await storage.commits.count
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        #expect(await storage.commits.count == commits)
        clock.clock.advance(by: 500)
        try await session.commit({ _ in }, context: .background)
        #expect(session.documentCacheSizes.cached == 1)
        clock.clock.advance(by: 500)
        try await session.commit({ _ in }, context: .background)
        #expect(session.documentCacheSizes.cached == 0)
        #expect(clock.attempts.count == 1)
        try await session.close(context: .background)
    }

    @Test func callbackFailureSweepsALoadedUnchangedDocument() async throws {
        let clock = TestClock(now: 1_000), token = try retentionEdgeToken()
        let session = try await Session.open(storage: MemoryStorage(), now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in try await tx.doc(token).set("count", 9) }, context: .background)
        try await session.unloadDocuments()
        await #expect(throws: RetentionEdgeFailure.self) {
            try await session.commit({ tx in
                _ = try await tx.doc(token)
                clock.advance(by: 2_000)
                throw RetentionEdgeFailure.callback
            }, context: .background)
        }
        #expect(session.documentCacheSizes.cached == 0)
        #expect(try await session.snapshot(token, context: .background) == ["count": 9])
        try await session.close(context: .background)
    }

    @Test func aThrowingRetentionProviderUsesTheDefault() async throws {
        let clock = TestClock(now: 1_000), fail = Mutex(false), token = try retentionEdgeToken()
        let session = try await Session.openWithDocumentRetention(storage: MemoryStorage(), now: { clock.now() }, documentRetentionMs: {
            if fail.withLock({ $0 }) { throw RetentionEdgeFailure.setting }
            return .infinity
        }, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        fail.withLock { $0 = true }
        try await session.commit({ tx in try await tx.doc(token).set("count", 42) }, context: .background)
        if Session.defaultDocumentRetentionMs == 0 {
            try await retentionEdgeWait { try await retentionEdgeDrain(session); return session.documentCacheSizes.cached == 0 }
        } else {
            #expect(session.documentCacheSizes.cached == 1)
            clock.advance(by: Int64(Session.defaultDocumentRetentionMs))
            try await session.commit({ _ in }, context: .background)
            #expect(session.documentCacheSizes.cached == 0)
        }
        fail.withLock { $0 = false }
        #expect(try await session.snapshot(token, context: .background) == ["count": 42])
        try await session.close(context: .background)
    }

    @Test func pinnedUnloadedAndClosedDocumentsLeaveNoSleepingTimer() async throws {
        let clock = TestClock(now: 1_000), token = try retentionEdgeToken()
        let session = try await Session.open(storage: MemoryStorage(), now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        let state = try #require(try await session.documentState(token, context: .background))
        try await retentionEdgeWait { clock.pendingSleeperCount == 0 }
        #expect(session.documentCacheSizes.attached == 1)
        state.dispose()
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        try await session.unloadDocuments()
        try await retentionEdgeWait { clock.pendingSleeperCount == 0 }
        #expect(session.documentCacheSizes.cached == 0)
        _ = try await session.snapshot(token, context: .background)
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        try await session.close(context: .background)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test func infiniteRetentionDoesNotStartASleep() async throws {
        let clock = TestClock(now: 1_000), token = try retentionEdgeToken()
        let session = try await Session.open(storage: MemoryStorage(), now: { clock.now() }, documentRetentionMs: .infinity, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeDrain(session)
        #expect(session.documentCacheSizes.cached == 1)
        #expect(clock.pendingSleeperCount == 0)
        #expect(session.documentCacheSizes.sweeps == 0)
        try await session.close(context: .background)
    }

    @Test func expiryWaitsForStorageSettlementAndPublication() async throws {
        let clock = TestClock(now: 1_000), storage = ControlledStorage(), token = try retentionEdgeToken()
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        let publications = SessionTestLog<JSONObject?>()
        let subscription = try session.subscribeCommits { publication, _ in
            for change in documentChanges(publication) { publications.append(change.value) }
        }
        let gate = await storage.holdCommits()
        let commit = Task { try await session.commit({ tx in try await tx.doc(token).set("count", 1) }, context: .background) }
        await gate.waitUntilEntered()
        clock.advance(by: 2_000)
        try await retentionEdgeWait { session.documentCacheSizes.sweeps > 0 }
        #expect(session.documentCacheSizes.cached == 1)
        #expect(publications.count == 0)
        #expect(try await session.snapshot(token, context: .background) == ["count": 0])
        await gate.release(); try await commit.value
        try await retentionEdgeDrain(session)
        #expect(publications.values == [["count": 1]])
        #expect(try await session.snapshot(token, context: .background) == ["count": 1])
        clock.advance(by: 1_000)
        try await session.commit({ _ in }, context: .background)
        #expect(session.documentCacheSizes.cached == 0)
        subscription.cancel(); try await session.close(context: .background)
    }

    @Test func droppingTheSessionCancelsItsSleepingTimer() async throws {
        let clock = TestClock(now: 1_000), token = try retentionEdgeToken()
        var session: Session? = try await Session.open(storage: MemoryStorage(), now: { clock.now() }, documentRetentionMs: 1_000, documentTimer: retentionTestTimer(clock), context: .background)
        weak let releasedSession = session
        try await session!.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        try await retentionEdgeWait { clock.pendingSleeperCount == 1 }
        session = nil
        #expect(releasedSession == nil)
        try await retentionEdgeWait { clock.pendingSleeperCount == 0 }
    }

    @Test func checkpointTailSurvivesSqliteCloseAndReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("retention.sqlite").path
        let clock = TestClock(now: 1_000), counts = SessionTestLog<Int>()
        let token = try SessionDocToken<JSONObject>(kind: "retention.edge.persisted", version: 1, initial: { ["count": 0] }, checkpointWhen: { _, _, info in
            counts.append(info.deltasSinceBase)
            return info.deltasSinceBase >= 2
        })
        let storage = try await SqliteStorage.open(path: path)
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 0, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        for n in 1...5 {
            try await retentionEdgeWait { try await retentionEdgeDrain(session); return session.documentCacheSizes.cached == 0 }
            try await session.commit({ tx in try await tx.doc(token).set("count", .number(Double(n))) }, context: .background)
        }
        #expect(counts.values == [0, 1, 2, 0, 1])
        try await session.close(context: .background)
        let reopenedStorage = try await SqliteStorage.open(path: path)
        let reopened = try await Session.open(storage: reopenedStorage, now: { clock.now() }, documentRetentionMs: 0, documentTimer: retentionTestTimer(clock), context: .background)
        #expect(try await reopened.snapshot(token, context: .background) == ["count": 5])
        try await retentionEdgeWait { try await retentionEdgeDrain(reopened); return reopened.documentCacheSizes.cached == 0 }
        try await reopened.commit({ tx in try await tx.doc(token).set("count", 6) }, context: .background)
        #expect(counts.values == [0, 1, 2, 0, 1, 2])
        try await reopened.close(context: .background)
        let finalStorage = try await SqliteStorage.open(path: path)
        let final = try await Session.open(storage: finalStorage, documentRetentionMs: 0, context: .background)
        #expect(try await final.snapshot(token, context: .background) == ["count": 6])
        try await final.close(context: .background)
    }

    @Test func zeroRetentionKeepsCheckpointDeltaCountsAcrossReloads() async throws {
        let clock = TestClock(now: 1_000), storage = ControlledStorage(), counts = SessionTestLog<Int>()
        let token = try SessionDocToken<JSONObject>(kind: "retention.edge.checkpoint", version: 1, initial: { ["count": 0] }, checkpointWhen: { _, _, info in
            counts.append(info.deltasSinceBase)
            return info.deltasSinceBase >= 2
        })
        let session = try await Session.open(storage: storage, now: { clock.now() }, documentRetentionMs: 0, documentTimer: retentionTestTimer(clock), context: .background)
        try await session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        for n in 1...5 {
            try await retentionEdgeWait { try await retentionEdgeDrain(session); return session.documentCacheSizes.cached == 0 }
            try await session.commit({ tx in try await tx.doc(token).set("count", .number(Double(n))) }, context: .background)
        }
        #expect(counts.values == [0, 1, 2, 0, 1])
        let contents = await storage.commits.flatMap { $0 }.compactMap { write -> String? in
            guard case .documentChange(_, let content, _) = write else { return nil }
            switch content { case .base: return "base"; case .delta: return "delta" }
        }
        #expect(contents == ["delta", "delta", "base", "delta", "delta"])
        #expect(try await session.snapshot(token, context: .background) == ["count": 5])
        try await session.close(context: .background)
    }
}
