import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private enum CachePublicationD3bError: Error, Equatable { case injected }

@Suite("PiSwiftDurableTests.SessionCachePublicationD3b", .timeLimit(.minutes(1)))
struct SessionCachePublicationD3bTests {
    #if DEBUG
    @Test("fails the Session for a throw in the read caches' write-through, and leaves later parts unpublished")
    func writeThroughFailureStopsLaterPublication() async throws {
        let backend = ControlledStorage()
        let session = try await Session.open(storage: backend, context: .background)
        let published = SessionTestLog<Seq>()
        _ = try session.observeCommits(.init(advance: { commit, _ in published.append(commit.seq) }, end: { _ in }))
        _ = try await createConversation(session)
        let gate = await backend.holdPublication(at: 2)
        let failing = Task { try await createConversation(session) }
        await gate.waitUntilEntered()
        let later = Task { try await createConversation(session) }
        for _ in 0..<10_000 {
            if session.writerPendingParts > 0 { break }
            await Task.yield()
        }
        session.failNextCachePublication(CachePublicationD3bError.injected)
        await gate.release()
        await #expect(throws: CachePublicationD3bError.injected) { try await failing.value }
        await #expect(throws: SessionFailed.self) { try await later.value }
        #expect(published.count == 1)
        #expect(session.recordCacheSizes.conversations == 1)
    }
    #endif

    @Test("Session reads use published write-through and conversation tails")
    func sessionConnectsCacheAndTails() async throws {
        let backend = ControlledStorage()
        let session = try await Session.open(storage: backend, context: .background)
        let id = try await createConversation(session)
        let before = await backend.conversationReadCount
        for _ in 0..<8 {
            _ = try await session.commit({ tx in try await tx.conversation(id) }, context: .background)
        }
        #expect(await backend.conversationReadCount == before)
        #expect(try await session.latestEntryId(id, context: .background) == nil)
        #expect(await backend.entryScanCount == 0)
        _ = try await session.commit({ tx in try await tx.appendEntry(id, value: .init(kind: "note")) }, context: .background)
        #expect(try await session.latestEntryId(id, context: .background) != nil)
        #expect(await backend.entryScanCount == 0)
        try await session.close(context: .background)
    }

    @Test("fork tail reads before and after its first own entry")
    func forkTailBeforeAndAfterWrite() async throws {
        let backend = ControlledStorage()
        let session = try await Session.open(storage: backend, context: .background)
        let root = try await createConversation(session)
        let parentEntry = try await session.commit({ tx in
            try await tx.appendEntry(root, value: .init(kind: "parent"))
        }, context: .background)
        let fork = try await session.commit({ tx in
            try await tx.forkConversation(root, at: parentEntry.id, ownership: .ownerless()).id
        }, context: .background)
        #expect(try await session.latestEntryId(fork, context: .background) == parentEntry.id)
        let scans = await backend.entryScanCount
        #expect(try await session.latestEntryId(fork, context: .background) == parentEntry.id)
        #expect(await backend.entryScanCount == scans)
        let own = try await session.commit({ tx in
            try await tx.appendEntry(fork, value: .init(kind: "own"))
        }, context: .background)
        #expect(try await session.latestEntryId(fork, context: .background) == own.id)
        #expect(await backend.entryScanCount == scans)
        try await session.close(context: .background)
    }
}
