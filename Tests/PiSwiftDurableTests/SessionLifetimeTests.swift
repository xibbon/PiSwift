import PiSwiftChord
import Testing
@testable import PiSwiftDurable

private enum SessionLifetimeFailure: Error, Equatable { case callback }

@Suite struct SessionLifetimeTests {
    @Test(arguments: [false, true])
    func revokesLoadedAndNewDocumentHandlesAtSettlement(callbackFails: Bool) async throws {
        let harness = try await openTestSession()
        let loaded = try SessionDocToken<JSONObject>(kind: "lifetime.loaded", version: 1, initial: { ["nested": ["count": 0]] })
        let created = try SessionDocToken<JSONObject>(kind: "lifetime.created", version: 1, initial: { ["nested": ["count": 0]] })
        try await harness.session.commit({ tx in _ = try await tx.doc(loaded) }, context: .background)
        let before = await harness.storage.commits.count
        let transactions = SessionTestLog<Transaction>()
        let handles = SessionTestLog<JSONDraft>()
        let gate = await harness.storage.holdCommits()
        let callbackReady = SessionTestGate()
        let commit = Task {
            try await harness.session.commit({ tx in
                transactions.append(tx)
                for token in [loaded, created] {
                    let draft = try await tx.doc(token)
                    let nested = try #require(try draft.child("nested"))
                    try nested.set("count", 1)
                    handles.append(draft)
                    handles.append(nested)
                }
                callbackReady.release()
                if callbackFails { throw SessionLifetimeFailure.callback }
            }, context: .background)
        }
        await callbackReady.wait()
        let tx = try #require(transactions.values.first)
        await tx.waitUntilSettled()
        #expect(tx.lifetime.isRevoked)
        if callbackFails {
            await #expect(throws: SessionLifetimeFailure.callback) { try await commit.value }
        } else {
            await gate.waitUntilEntered()
        }
        for draft in handles.values {
            #expect(throws: TrackerError.settled) { _ = try draft.snapshot() }
            #expect(throws: TrackerError.settled) { try draft.set("count", 9) }
        }
        await gate.release()
        if !callbackFails { try await commit.value }
        #expect(await harness.storage.commits.count == before + (callbackFails ? 0 : 1))
        let stored = try await harness.session.snapshot(loaded, context: .background)
        #expect(stored?["nested"] == .object(["count": callbackFails ? 0 : 1]))
        let newValue = try await harness.session.snapshot(created, context: .background)
        if callbackFails { #expect(newValue == nil) }
        else { #expect(newValue?["nested"] == .object(["count": 1])) }
        try await harness.session.close(context: .background)
    }
}
