import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

/// Port of v1.3.0 `harness-storage-failure.test.ts` storage failure cases.
@Suite struct HarnessStorageFailureTests {
    @Test func firstWriteFailureEndsWaitsWatchesStreamsAndRunningTasks() async throws {
        let storage = ControlledStorage(), entered = SessionTestGate(), signals = SessionTestLog<String>()
        let waiting = failureWaitingTask(entered, signals: signals)
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(waiting)])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let id = try await harnessStart(root, waiting)
        try harness.resume(); await entered.wait()
        let task = Task { try await harness.waitForTask(id: id, context: .background) }
        let idle = Task { try await harness.waitForIdle(context: .background) }
        try await harnessEventually { harness.tasks.taskWaiters.keys.contains(id) && !harness.tasks.idleWaiters.keys.isEmpty }
        let watch = try #require(try await harness.watchDoc(LiveDoc, conversationId: root.id, context: .background))
        let stream = try await harness.watchEvents(conversationId: root.id, context: .background)
        try stream.start { _, _ in }
        let failure = HarnessStorageFailure()
        await storage.failNextCommit(failure)
        await expectStorageFailure(failure) { try await failureNote(root) }
        await expectSessionFailure(failure) { try await task.value }
        await expectSessionFailure(failure) { try await idle.value }
        expectFailedWatch(await watch.closed, failure)
        expectFailedWatch(await stream.closed, failure)
        await expectSessionFailure(failure) { try await harness.getTask(id: id, context: .background) }
        await expectSessionFailure(failure) { try await harness.waitForIdle(context: .background) }
        await expectSessionFailure(failure) { try await root.submit(.input(content: .text("x")), context: .background) }
        await expectFailedEnd(harness, failure)
        #expect(signals.values == ["aborted"])
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === failure)
        try await harness.close(context: .background)
    }

    @Test func offLineContextReadFailsTheSession() async throws {
        let storage = HarnessFailureStorage()
        let opened = try await openTasks(storage: storage, tasks: [])
        let root = try await opened.harness.root(context: .background)
        _ = try await failureNote(root)
        let failure = HarnessStorageFailure()
        await storage.fail(.range, with: failure)
        await expectStorageFailure(failure) { try await root.context(context: .background) }
        await expectFailedEnd(opened.harness, failure)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === failure)
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func readUnderwayReturnsFirstFailureAndDelaysBackendClose(readAlsoFails: Bool) async throws {
        let storage = HarnessFailureStorage()
        let opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        _ = try await failureNote(root)
        let held = await storage.holdRange()
        let reading = Task { try await root.context(context: .background) }
        await held.entered.wait()
        let failure = HarnessStorageFailure(), later = HarnessStorageFailure("later read failure")
        await storage.fail(.mint, with: failure)
        if readAlsoFails { await storage.fail(.range, with: later) }
        await expectStorageFailure(failure) { try await failureNote(root) }
        let guardStorage = try #require(harness.session.storage as? GuardedStorage)
        try await harnessEventually { guardStorage.closing }
        let closed = settled { await harness.closed }
        #expect(!closed.isSettled)
        #expect(!(await storage.pages).contains("close"))
        held.release.release()
        await expectSessionFailure(failure) { try await reading.value }
        await expectFailedEnd(harness, failure)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === failure)
        try await harness.close(context: .background)
    }

    @Test func closeWaitsForFirstPageAndPreventsNextPage() async throws {
        let storage = HarnessFailureStorage()
        let opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        try await root.commit({ tx in
            for _ in 0..<300 { _ = try await tx.appendEntry(root.id, value: .init(kind: "note")) }
        }, context: .background)
        let held = await storage.holdRange()
        let reading = Task { try await root.context(context: .background) }
        await held.entered.wait()
        let closing = Task { try await harness.close(context: .background) }
        let guardStorage = try #require(harness.session.storage as? GuardedStorage)
        try await harnessEventually { guardStorage.closing }
        #expect(!(await storage.pages).contains("close"))
        held.release.release()
        do { _ = try await reading.value; Issue.record("Paged read continued after close") }
        catch { #expect(String(describing: error).contains("is closed")) }
        try await closing.value
        #expect(await storage.pages == ["first", "close"])
        if case .closed = await harness.closed {} else { Issue.record("Host close did not end as closed") }
    }

    @Test(arguments: [false, true])
    func closeFailureFailsHealthySessionAndPreservesEarlierCause(alreadyFailed: Bool) async throws {
        let storage = HarnessFailureStorage(), closeFailure = HarnessStorageFailure("close failed")
        await storage.failClose(with: closeFailure)
        let opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let expected: HarnessStorageFailure
        if alreadyFailed {
            expected = HarnessStorageFailure()
            await storage.base.failNextCommit(expected)
            await expectStorageFailure(expected) { try await failureNote(root) }
        } else {
            expected = closeFailure
            await expectStorageFailure(closeFailure) { try await harness.close(context: .background) }
        }
        await expectFailedEnd(harness, expected)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === expected)
    }

    @Test func facadeAndQueuedCallsRejectWithFirstCause() async throws {
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let held = await storage.holdCommits(), failure = HarnessStorageFailure()
        await storage.failNextCommit(failure)
        let committing = Task { try await failureNote(root) }
        await held.waitUntilEntered()
        let queued = Task { try await root.entries(limit: 10, context: .background) }
        try await harnessEventually { harness.session.line.queuedCount > 0 }
        await held.release()
        await expectStorageFailure(failure) { try await committing.value }
        await expectSessionFailure(failure) { try await queued.value }
        do { try harness.resume(); Issue.record("Failed harness resumed") }
        catch { #expect(((error as? SessionFailed)?.cause as? HarnessStorageFailure) === failure) }
        await expectSessionFailure(failure) { try await harness.root(context: .background) }
        await expectSessionFailure(failure) { try await harness.conversation(id: root.id, context: .background) }
        await expectSessionFailure(failure) { try await harness.createConversation(options: .init(ownership: .ownerless()), context: .background) }
        await expectFailedEnd(harness, failure)
        try await harness.close(context: .background)
    }

    @Test func taskOwnedWatchAndWaitEndBeforeInvocationCancellation() async throws {
        let ends = SessionTestLog<String>(), watching = SessionTestGate(), storage = ControlledStorage()
        let failure = HarnessStorageFailure()
        let watcher = harnessOneStep("test.failure-watcher", run: { _, runtime, context in
            let doc = try #require(try await runtime.watchDoc(LiveDoc, conversationId: runtime.conversationId, context: context))
            let handle = try #require(try await runtime.conversation(runtime.conversationId, context: context))
            let idle = Task {
                await expectSessionFailure(failure) { try await handle.waitForIdle(context: context) }
                ends.append("SessionFailed")
            }
            watching.release()
            expectFailedWatch(await doc.closed, failure)
            ends.append("session_failed")
            await idle.value
        }, abort: { _, _, _ in })
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(watcher)])
        let harness = opened.harness, root = try await harness.root(context: .background)
        _ = try await harnessStart(root, watcher)
        try harness.resume(); await watching.wait()
        try await harnessEventually { !harness.tasks.idleWaiters.keys.isEmpty }
        await storage.failNextCommit(failure)
        await expectStorageFailure(failure) { try await failureNote(root) }
        await expectFailedEnd(harness, failure)
        #expect(Set(ends.values) == Set(["session_failed", "SessionFailed"]))
        try await harness.close(context: .background)
    }

    @Test func failedMintFailsTheSession() async throws {
        let storage = HarnessFailureStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let root = try await opened.harness.root(context: .background), failure = HarnessStorageFailure()
        await storage.fail(.mint, with: failure)
        await expectStorageFailure(failure) { try await failureNote(root) }
        await expectFailedEnd(opened.harness, failure)
        try await opened.harness.close(context: .background)
    }

    @Test func callbackCannotCommitAfterItCatchesFailedRead() async throws {
        let storage = HarnessFailureStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let root = try await opened.harness.root(context: .background), failure = HarnessStorageFailure()
        let written = await storage.base.admittedCommits.count
        await storage.fail(.task, with: failure)
        await expectSessionFailure(failure) {
            try await root.commit({ tx in
                do { _ = try await tx.task(TaskID(1)) } catch {}
                _ = try await tx.appendEntry(root.id, value: .init(kind: "note"))
            }, context: .background)
        }
        #expect(await storage.base.admittedCommits.count == written)
        await expectFailedEnd(opened.harness, failure)
        try await opened.harness.close(context: .background)
    }

    @Test func storageRequestErrorFromCommitIsFatal() async throws {
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let root = try await opened.harness.root(context: .background), rejection = StorageRequestError("bad batch")
        await storage.failNextCommit(rejection)
        do { _ = try await failureNote(root); Issue.record("Commit accepted a rejected batch") }
        catch { #expect((error as? StorageRequestError)?.message == rejection.message) }
        guard case .failed(let cause) = await opened.harness.closed else { Issue.record("Commit request error did not fail Session"); return }
        #expect((cause as? StorageRequestError)?.message == rejection.message)
        try await opened.harness.close(context: .background)
    }

    @Test func invalidReadRequestsFailOnlyTheirCalls() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background)
        let entry = try await failureNote(root); _ = try await failureNote(root)
        await #expect(throws: StorageRequestError.self) { _ = try await root.entries(limit: 10, cursor: ["after": "x"], context: .background) }
        let page = try await root.entries(order: .ascending, limit: 1, context: .background)
        await #expect(throws: StorageRequestError.self) { _ = try await root.entries(order: .descending, limit: 1, cursor: page.next, context: .background) }
        await #expect(throws: StorageRequestError.self) {
            _ = try await root.commit({ tx in try await tx.scanEntries(.init(conversationId: ConversationID(999_999)), limit: 10) }, context: .background)
        }
        // The public token type prevents this request. Use the internal read, as upstream uses a type cast.
        await #expect(throws: StorageRequestError.self) {
            let _: JSONObject? = try await harness.session.historicalSnapshot(LiveDoc.definition,
                address: .init(kind: LiveDoc.definition.kind, scope: .conversation(conversationId: root.id)),
                at: entry.id, context: .background)
        }
        _ = try await failureNote(root)
        #expect(harness.failure == nil)
        #expect(opened.reports.count == 0)
        try await harness.close(context: .background)
    }

    @Test func internalObserverFailurePreservesDurableCommit() async throws {
        let opened = try await openTasks(tasks: []), harness = opened.harness
        let root = try await harness.root(context: .background), bug = HarnessStorageFailure("listener bug")
        let subscription = try harness.session.observeCommits { _, _ in throw bug }
        let entry = try await failureNote(root)
        #expect(entry.kind == "note")
        await expectFailedEnd(harness, bug)
        #expect(opened.reports.count == 1)
        #expect((opened.reports.values.first as? HarnessStorageFailure) === bug)
        subscription.cancel()
        try await harness.close(context: .background)
    }

    @Test func writeFailureDuringHostCloseSetsFailedResult() async throws {
        let storage = ControlledStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        let held = await storage.holdCommits(), failure = HarnessStorageFailure()
        await storage.failNextCommit(failure)
        let committing = Task { try await failureNote(root) }; await held.waitUntilEntered()
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        await held.release()
        await expectStorageFailure(failure) { try await committing.value }
        try await closing.value
        await expectFailedEnd(harness, failure)
        #expect(opened.reports.count == 1)
    }

    @Test func failureEndsAbortJoinAndReportReentryBeforeStubbornRunEnds() async throws {
        let entered = SessionTestGate(), release = SessionTestGate(), storage = ControlledStorage()
        let stubborn = harnessOneStep("test.failure-stubborn", run: { _, _, _ in
            entered.release(); await release.wait()
        }, abort: { _, _, _ in })
        let registry = createRegistry()
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(stubborn)]))
        let reference = Mutex<Harness?>(nil), reentered = Mutex<Task<Void, Never>?>(nil)
        let failure = HarnessStorageFailure()
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: registry, onReport: { _ in
            guard let harness = reference.withLock({ $0 }) else { return }
            let task = Task { await expectSessionFailure(failure) { try await harness.waitForIdle(context: .background) } }
            reentered.withLock { $0 = task }
        }), context: .background)
        reference.withLock { $0 = harness }
        let root = try await harness.root(context: .background), id = try await harnessStart(root, stubborn)
        try harness.resume(); await entered.wait()
        let aborting = Task { try await harness.abortTask(id: id, context: .background) }
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.abortRequested == true }
        await storage.failNextCommit(failure)
        await expectStorageFailure(failure) { try await failureNote(root) }
        await expectSessionFailure(failure) { try await aborting.value }
        let reentry = try #require(reentered.withLock { $0 })
        await reentry.value
        release.release()
        try await harness.close(context: .background)
        await expectFailedEnd(harness, failure)
    }

    @Test func callerCancelledReadDoesNotFailTheSession() async throws {
        let storage = HarnessFailureStorage(), opened = try await openTasks(storage: storage, tasks: [])
        let harness = opened.harness, root = try await harness.root(context: .background)
        _ = try await failureNote(root)
        let caller = ChordContext.background.withCancel(), cancelled = HarnessStorageFailure("caller gave up")
        await storage.cancelRange { context in
            guard context.abortSignal != nil else { return }
            caller.cancel(cancelled)
            throw cancelled
        }
        await expectStorageFailure(cancelled) { try await root.context(context: caller.context) }
        _ = try await failureNote(root)
        #expect(harness.failure == nil)
        #expect(opened.reports.count == 0)
        try await harness.close(context: .background)
    }
}
