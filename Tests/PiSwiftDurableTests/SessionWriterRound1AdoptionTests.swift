import Foundation
import Testing
import Synchronization
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private enum AdoptionRound1Error: Error { case own }

// v1.5.2 session-adoption.test.ts:137,153,205,336.
@Suite("PiSwiftDurableTests.SessionWriterRound1Adoption", .timeLimit(.minutes(2)))
struct SessionWriterRound1AdoptionTests {
    private func bump(_ session: Session, _ token: SessionDocToken<JSONObject>, _ count: Int) async throws {
        try await session.commit({ tx in
            try await tx.doc(token).set("count", .number(Double(count)))
        }, context: .background)
    }

    @Test("discards the staged changes when Storage rejects before adoption")
    func rejectBeforeAdoptionDiscardsDraft() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("adoption-before-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let controlled = ControlledStorage(try await SqliteStorage.open(path: path))
        let session = try await Session.open(storage: controlled, context: .background)
        let token = try SessionDocToken<JSONObject>(kind: "adoption.before", version: 1,
            initial: { ["count": .number(0)] }, checkpointWhen: { _, _, _ in false })
        try await bump(session, token, 1)
        await controlled.failNextCommit(AdoptionRound1Error.own)
        await #expect(throws: AdoptionRound1Error.own) { try await bump(session, token, 2) }
        guard case .failed(let cause) = await session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? AdoptionRound1Error == .own)
        let reopenedStorage = try await SqliteStorage.open(path: path)
        let reopened = try await Session.open(storage: reopenedStorage, context: .background)
        let saved = try await reopened.snapshot(token, context: .background)
        #expect(saved?["count"] == .number(1))
        try await reopened.close(context: .background)
    }

    @Test("runs its own observers once Storage resolved, and host listeners after them")
    func ownAndHostAfterStorage() async throws {
        let h = try await openTestSession()
        let order = SessionTestLog<String>()
        let held = await h.storage.holdPublication()
        _ = try h.session.observeCommits { _, _ in order.append("own") }
        _ = try h.session.subscribeCommits { _, _ in order.append("host") }
        let writing = Task { try await h.session.commit({ tx in
            try await tx.createConversation(ownership: .ownerless())
        }, context: .background) }
        await held.waitUntilEntered()
        #expect(order.values.isEmpty)
        await held.release()
        _ = try await writing.value
        #expect(order.values == ["own", "host"])
        try await h.session.close(context: .background)
    }

    @Test("calls the host listeners registered when its dispatch runs, and none for a commit published without one")
    func hostRegistrationAtPublication() async throws {
        let h = try await openTestSession()
        let calls = SessionTestLog<String>()
        let removed = try h.session.subscribeCommits { _, _ in calls.append("removed") }
        _ = try h.session.subscribeCommits { _, _ in calls.append("kept") }
        let first = Mutex(false)
        _ = try h.session.observeCommits { _, _ in
            let change = first.withLock { value in let previous = value; value = true; return !previous }
            if change {
                removed.cancel()
                _ = try h.session.subscribeCommits { _, _ in calls.append("added") }
            }
        }
        _ = try await createConversation(h.session)
        #expect(calls.values == ["kept", "added"])
        try await h.session.close(context: .background)

        let bare = try await Session.open(storage: MemoryStorage(), context: .background)
        let late = SessionTestLog<Seq>()
        let installed = Mutex(false)
        _ = try bare.observeCommits { _, _ in
            let change = installed.withLock { value in let previous = value; value = true; return !previous }
            if change { _ = try bare.subscribeCommits { publication, _ in late.append(publication.seq) } }
        }
        _ = try await createConversation(bare)
        #expect(late.values.isEmpty)
        _ = try await createConversation(bare)
        #expect(late.count == 1)
        try await bare.close(context: .background)
    }

    @Test("fails the Session after Storage returned for a throw of its own observers; the others and hosts got the commit")
    func ownObserverThrowAfterStoredCommit() async throws {
        let h = try await openTestSession()
        let order = SessionTestLog<String>()
        _ = try h.session.observeCommits { _, _ in order.append("own throw"); throw AdoptionRound1Error.own }
        _ = try h.session.observeCommits { _, _ in order.append("own after") }
        _ = try h.session.subscribeCommits { _, _ in
            order.append(h.session.failure == nil ? "host healthy" : "host failed")
        }
        _ = try await createConversation(h.session)
        #expect(order.values == ["own throw", "own after", "host healthy"])
        #expect(h.session.failure as? AdoptionRound1Error == .own)
        guard case .failed(let cause) = await h.session.closed else { Issue.record("Session did not fail"); return }
        #expect(cause as? AdoptionRound1Error == .own)
        #expect(await h.storage.commits.count == 1)
    }

    @Test("publishes a JSONL commit once the storage reclaimed its sidecar and resolved")
    func jsonlSidecarBeforeHostPublication() async throws {
        let env = FakeExecutionEnv(cwd: "/")
        let storage = try await JsonlStorage.open(directory: "/adoption", fileSystem: env)
        let session = try await Session.open(storage: storage, context: .background)
        let token = try SessionDocToken<JSONObject>(kind: "adoption.rebased", version: 1,
            initial: { ["count": .number(0)] },
            checkpointWhen: { value, _, _ in value["count"] == .number(2) })
        let order = SessionTestLog<String>()
        env.onRename { destination in
            if destination.split(separator: "/").last?.hasPrefix("doc-") == true { order.append("rename") }
        }
        try await bump(session, token, 1)
        _ = try session.subscribeCommits { _, _ in order.append("host") }
        try await bump(session, token, 2)
        order.append("resolved")
        #expect(order.values == ["rename", "host", "resolved"])
        try await session.close(context: .background)
    }
}
