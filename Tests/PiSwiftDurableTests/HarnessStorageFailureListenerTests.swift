import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Swift callbacks for commit, close, report, clock, and view publication do not throw.
/// The upstream promise, thenable, foreign-realm, and throwing-clock cases have no Swift equivalent.
/// Watches and task handlers retain their existing throwing contracts.
@Suite struct HarnessStorageFailureListenerTests {
    @Test func watchListenerFailureIsReportedAndOtherViewWatchContinues() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        let failed = try await root.watch(context: .background), healthy = try await root.watch(context: .background)
        let failure = HarnessStorageFailure("observer broke"), seen = SessionTestLog<[EntryID]>()
        try failed.start { _, _, _ in throw failure }
        try healthy.start { view, _, _ in seen.append(view.entries.map(\.id)) }
        let first = try await failureNote(root)
        guard case .listenerError(let error) = await failed.closed else { Issue.record("Watch listener failure did not end watch"); return }
        #expect((error as? HarnessStorageFailure) === failure)
        let second = try await failureNote(root)
        await healthy.waitUntilIdle()
        #expect(seen.values == [[first.id], [first.id, second.id]])
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === failure)
        #expect(harness.failure == nil)
        try await harness.close(context: .background)
        if case .sessionClosed = await healthy.closed {} else { Issue.record("Healthy watch did not end with Session") }
    }

    @Test func documentWatchFailureEndsOnlyThatWatchAndReportsError() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        let watch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        let failure = HarnessStorageFailure("listener broke")
        try watch.start { _, _, _ in throw failure }
        try await root.commit({ tx in try await tx.doc(LiveDoc, conversationId: root.id).set("compactions", []) }, context: .background)
        guard case .listenerError(let error) = await watch.closed else { Issue.record("Document watch did not end for its listener error"); return }
        #expect((error as? HarnessStorageFailure) === failure)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === failure)
        _ = try await failureNote(root)
        #expect(harness.failure == nil)
        try await harness.close(context: .background)
    }

    @Test func opaqueThrownErrorFaultsOnlyTaskAndStopsOnlyWatch() async throws {
        // Swift can throw only Error values. A plain Error has no user formatting callback.
        struct OpaqueError: Error {}
        let definition = harnessOneStep("test.failure-opaque", run: { _, _, _ in throw OpaqueError() }, abort: { _, _, _ in })
        let opened = try await openTasks(tasks: [AnyTaskDefinition(definition)]), harness = opened.harness
        let root = try await harness.root(context: .background)
        let watch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        try watch.start { _, _, _ in throw OpaqueError() }
        let id = try await harnessStart(root, definition)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        guard case .faulted(let error, _) = receipt.outcome else { Issue.record("Thrown error did not fault task"); return }
        #expect(!error.message.isEmpty)
        try await root.commit({ tx in try await tx.doc(LiveDoc, conversationId: root.id).set("compactions", []) }, context: .background)
        guard case .listenerError(let error) = await watch.closed else { Issue.record("Thrown error did not end watch"); return }
        #expect(error is OpaqueError)
        _ = try await failureNote(root)
        #expect(harness.failure == nil)
        try await harness.close(context: .background)
    }

    @Test func nonthrowingCommitAndCloseListenersAllRunAndDurableCommitStands() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background), seen = SessionTestLog<String>()
        let subscriptions = try [
            harness.subscribeCommits { _, _ in seen.append("commit-one") },
            harness.subscribeCommits { _, _ in seen.append("commit-two") },
            harness.subscribeClose { seen.append("close-one") },
            harness.subscribeClose { seen.append("close-two") }
        ]
        let entry = try await failureNote(root)
        #expect(entry.kind == "note")
        try await harness.close(context: .background)
        #expect(seen.values == ["commit-one", "commit-two", "close-one", "close-two"])
        #expect(opened.reports.count == 0)
        for subscription in subscriptions { subscription.cancel() }
    }
}
