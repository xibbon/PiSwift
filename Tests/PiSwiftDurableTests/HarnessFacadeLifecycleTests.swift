import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessFacadeLifecycleTests {
    // harness-lifecycle.test.ts:85
    @Test func failedOpenClosesWithUncancelledContextAndKeepsOriginalError() async throws {
        let storage = ControlledStorage(); let session = try await Session.open(storage: storage, context: .background)
        try await session.commit({ tx in
            let root = try await tx.createRootConversation()
            let kind = TaskKind<JSONObject, JSONObject>(name: "h5.seed", version: 1, initial: { _ in ["phase": "run"] })
            let id = try await tx.createTask(kind, input: [:], options: .init(ownership: .conversation(), conversationId: root.id))
            let record = try #require(await tx.currentTask(id))
            try tx.setTask(record.replacing(state: .running(checkpoint: ["phase": "run"])))
        }, context: .background)
        let reader = countingReader(createRegistry()); let held = await storage.holdCommits()
        await storage.failNextCommit(StorageRejected("disk full"))
        let caller = ChordContext.background.withCancel()
        let opening = Task { try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: reader), context: caller.context) }
        await held.waitUntilEntered(); caller.cancel(StorageRejected("caller gave up")); await held.release()
        do { _ = try await opening.value; Issue.record("Open must fail") }
        catch { #expect(String(describing: error).contains("disk full")) }
        #expect(reader.subscriptionCount == 0)
        await #expect(throws: (any Error).self) { _ = try await storage.scanTasks(.init(), limit: 1, cursor: nil, context: .background) }
    }
    // harness-lifecycle.test.ts:105
    @Test func failedOpenReportsCloseFailureAndKeepsOpenFailure() async throws {
        let base = ControlledStorage(); let session = try await Session.open(storage: base, context: .background)
        try await seedFacadeRunningTask(session)
        await base.failNextCommit(StorageRejected("disk full"))
        let reports = HarnessReports()
        do {
            _ = try await Harness.open(storage: HarnessFailingCloseStorage(base: base), options: .init(models: FakeDurableModels(), registry: createRegistry(), onReport: { reports.append($0) }), context: .background)
            Issue.record("Open must fail")
        } catch { #expect(String(describing: error).contains("disk full")) }
        #expect(reports.values.map { String(describing: $0) } == ["close failed"])
    }
    // harness-lifecycle.test.ts:197
    @Test func newHarnessRunsNoOldInvocationAfterClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reopen.sqlite").path
        let gate = SessionTestGate(); let entered = SessionTestGate(); let log = SessionTestLog<String>(); let generation = Mutex(1)
        let definition = harnessOneStep("h5.reopen") { _, runtime, context in
            let value = generation.withLock { $0 }; log.append("start \(value)")
            if value == 1 { entered.release(); await gate.wait() }
            log.append("end \(value)")
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let firstStorage = try await SqliteStorage.open(path: path)
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: firstStorage)
        let root = try await first.root(context: .background); let id = try await harnessStart(root, definition)
        try first.resume(); await entered.wait()
        let close = Task { try await first.close(context: .background); log.append("closed") }
        try await harnessEventually { first.tasks.closing }; gate.release(); try await close.value
        #expect(log.values == ["start 1", "end 1", "closed"])
        generation.withLock { $0 = 2 }
        let secondStorage = try await SqliteStorage.open(path: path)
        let second = try await harnessOpen([AnyTaskDefinition(definition)], storage: secondStorage)
        _ = try await second.waitForTask(id: id, context: .background)
        #expect(log.values == ["start 1", "end 1", "closed", "start 2", "end 2"])
        try await second.close(context: .background)
    }
    // harness-lifecycle.test.ts:230
    @Test func cancelledCloseContinuesAndSecondCloseJoinsSameWork() async throws {
        let entered = SessionTestGate(); let release = SessionTestGate(); let storage = ControlledStorage()
        let definition = harnessOneStep("h5.cancel-close") { _, _, _ in entered.release(); await release.wait() }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        let root = try await harness.root(context: .background); _ = try await harnessStart(root, definition)
        try harness.resume(); await entered.wait()
        let caller = ChordContext.background.withCancel()
        let first = Task { try await harness.close(context: caller.context) }
        try await harnessEventually { harness.tasks.closing }; caller.cancel(StorageRejected("stop waiting"))
        do { try await first.value; Issue.record("Close waiter must cancel") }
        catch { #expect(String(describing: error).contains("stop waiting")) }
        await #expect(throws: HarnessClosedError.self) { _ = try await harness.root(context: .background) }
        _ = try await storage.scanTasks(.init(), limit: 1, cursor: nil, context: .background)
        let second = settled { try await harness.close(context: .background) }
        #expect(!second.isSettled); release.release()
        try await harnessEventually { second.isSettled }
        await #expect(throws: (any Error).self) { _ = try await storage.scanTasks(.init(), limit: 1, cursor: nil, context: .background) }
    }
    // harness-lifecycle.test.ts:256
    @Test func cancelledCommitterStillGetsDurableReceiptAfterStorageAdmission() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage); let root = try await h.harness.root(context: .background)
        let held = await storage.holdCommits(); let caller = ChordContext.background.withCancel()
        let commit = Task { try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "note")) }, context: caller.context) }
        await held.waitUntilEntered(); caller.cancel(StorageRejected("committer gave up")); await held.release()
        let entry = try await commit.value
        let page = try await root.entries(limit: 10, context: .background); #expect(page.items.map(\.id) == [entry.id])
        try await h.harness.close(context: .background)
    }
    // harness-lifecycle.test.ts:275
    @Test func closeSuppressesDocumentStateAndWatchFramesFromAdmittedCommit() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage)
        let token = try SessionDocToken<JSONObject>(kind: "h5.close-frames", version: 1, initial: { ["text": "before"] })
        try await h.harness.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let state = try #require(await h.harness.documentState(token, context: .background))
        let watch = try #require(await h.harness.watchDoc(token, context: .background))
        let held = await storage.holdCommits()
        let commit = Task { try await h.harness.commit({ tx in try await tx.doc(token).set("text", "after") }, context: .background) }
        await held.waitUntilEntered(); let closing = Task { try await h.harness.close(context: .background) }
        try await harnessEventually { h.harness.tasks.closing }; await held.release(); try await commit.value; try await closing.value
        #expect(state.value == ["text": "before"]); state.dispose(); _ = await watch.stop()
    }
    // harness-lifecycle.test.ts:336
    @Test func cancelledWatchAcquisitionLeavesNoListener() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage)
        let token = try SessionDocToken<JSONObject>(kind: "h5.cancel-watch", version: 1, initial: { ["text": "before"] })
        try await h.harness.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let root = try await h.harness.root(context: .background); let held = await storage.holdCommits()
        let blocking = Task { _ = try await harnessAppendForLifecycle(root) }
        await held.waitUntilEntered()
        let caller = ChordContext.background.withCancel()
        let acquire = Task { try await h.harness.watchDoc(token, context: caller.context) }
        caller.cancel(StorageRejected("stop acquisition")); await held.release(); try await blocking.value
        await #expect(throws: (any Error).self) { _ = try await acquire.value }
        try await h.harness.close(context: .background)
    }
    // harness-lifecycle.test.ts:393. Submission and H9 operations are deferred.
    @Test func closeRejectsNewOperationsWhileQueuedInspectReportsClosing() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage); let root = try await h.harness.root(context: .background)
        let held = await storage.holdCommits()
        let blocking = Task { _ = try await harnessAppendForLifecycle(root) }
        await held.waitUntilEntered()
        let inspect = Task { try await h.harness.inspect(context: .background) }
        try await harnessEventually { h.harness.session.line.queuedCount >= 1 }
        let close = Task { try await h.harness.close(context: .background) }
        try await harnessEventually { h.harness.tasks.closing }
        await #expect(throws: HarnessClosedError.self) { _ = try await root.agent(context: .background) }
        await #expect(throws: HarnessClosedError.self) { try await root.configure(change: .init(cwd: .set("/closed")), context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await root.entries(limit: 10, context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await root.context(context: .background) }
        await #expect(throws: HarnessClosedError.self) { try await root.waitForIdle(context: .background) }
        await #expect(throws: HarnessClosedError.self) { try await h.harness.waitForIdle(context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await h.harness.inspect(context: .background) }
        await #expect(throws: HarnessClosedError.self) { _ = try await h.harness.commit({ _ in 0 }, context: .background) }
        await held.release(); try await blocking.value
        #expect(try await inspect.value.scheduling == .closing); try await close.value
    }
    // harness-lifecycle.test.ts:450. Submission and H9 operations are deferred.
    @Test func queuedReadsFinishAtCloseButQueuedWaitsReject() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage); let root = try await h.harness.root(context: .background)
        let token = try SessionDocToken<JSONObject>(kind: "h5.seal-read", version: 1, initial: { ["text": "before"] })
        try await h.harness.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        let held = await storage.holdCommits(); let blocking = Task { _ = try await harnessAppendForLifecycle(root) }
        await held.waitUntilEntered()
        let read = Task { try await root.entries(limit: 10, context: .background) }
        try await harnessEventually { h.harness.session.line.queuedCount >= 1 }
        let idle = Task { try await root.waitForIdle(context: .background) }
        try await harnessEventually { h.harness.session.line.queuedCount >= 2 }
        let acquire = Task { try await h.harness.watchDoc(token, context: .background) }
        try await harnessEventually { h.harness.session.line.queuedCount >= 3 }
        let close = Task { try await h.harness.close(context: .background) }
        try await harnessEventually { h.harness.tasks.closing }; await held.release(); try await blocking.value
        #expect(try await read.value.items.count == 1)
        await #expect(throws: (any Error).self) { try await idle.value }
        await #expect(throws: (any Error).self) { _ = try await acquire.value }
        try await close.value
    }
    // harness-lifecycle.test.ts:533. Submissions and structural views belong to H6/H9.
    @Test func readOnlyOperationsNeverEnableScheduling() async throws {
        let ran = Mutex(false); let definition = harnessOneStep("h5.read-only") { _, runtime, context in
            ran.withLock { $0 = true }; try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]); let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        let token = try SessionDocToken<JSONObject>(kind: "h5.viewer", version: 1, initial: { [:] })
        try await harness.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        _ = try await harness.inspect(context: .background); _ = try await harness.getTask(id: id, context: .background)
        _ = try await harness.usage(context: .background); _ = try await harness.conversation(id: root.id, context: .background)
        _ = try await harness.snapshot(token, context: .background)
        let state = try await harness.documentState(token, context: .background); state?.dispose()
        let watch = try await harness.watchDoc(token, context: .background); _ = await watch?.stop()
        _ = try await root.agent(context: .background); _ = try await root.context(context: .background); _ = try await root.entries(limit: 10, context: .background)
        #expect(!ran.withLock { $0 }); #expect(try await harness.inspect(context: .background).scheduling == .paused)
        try await harness.close(context: .background)
    }
    // harness-lifecycle.test.ts:565. Submit/compact/submission waits belong to H6/H8.
    @Test(arguments: ["waitForTask", "harnessIdle", "conversationIdle", "conversationAbort", "abortTask"])
    func progressOperationsEnableScheduling(operation: String) async throws {
        let ran = Mutex(false)
        let finish: HarnessTestTask.Handler = { _, runtime, context in
            ran.withLock { $0 = true }; try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let definition = harnessOneStep("h5.progress", run: finish, abort: finish)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)]); let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, definition)
        switch operation {
        case "waitForTask": _ = try await harness.waitForTask(id: id, context: .background)
        case "harnessIdle": try await harness.waitForIdle(context: .background)
        case "conversationIdle": try await root.waitForIdle(context: .background)
        case "conversationAbort": try await root.abort(context: .background)
        default: _ = try await harness.abortTask(id: id, context: .background); _ = try await harness.waitForTask(id: id, context: .background)
        }
        #expect(ran.withLock { $0 }); #expect(try await harness.inspect(context: .background).scheduling == .running)
        try await harness.close(context: .background)
    }
    // harness-lifecycle.test.ts:590
    @Test func resumeUsesDefinitionInstalledOrReplacedAfterOpen() async throws {
        let log = SessionTestLog<String>()
        let make: @Sendable (String) -> HarnessTestTask = { label in
            harnessOneStep("h5.late-definition") { _, runtime, context in
                log.append(label); try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }
        let h = try await openTasks(tasks: []); let root = try await h.harness.root(context: .background)
        let missing = try await harnessStart(root, make("unused"))
        let before = try await h.harness.inspect(context: .background)
        if case .blocked(let reason, _) = before.tasks.first?.state { #expect(reason == .missingTask) } else { Issue.record("Missing task must be blocked") }
        try h.registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(make("v1"))]))
        try h.registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(make("v2"))]))
        _ = try await h.harness.waitForTask(id: missing, context: .background)
        #expect(log.values == ["v2"]); try await h.harness.close(context: .background)
    }
}
private func harnessAppendForLifecycle(_ root: Conversation) async throws -> EntryRecord {
    try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "blocker")) }, context: .background)
}

private func seedFacadeRunningTask(_ session: Session) async throws {
    try await session.commit({ tx in
        let root = try await tx.createRootConversation()
        let kind = TaskKind<JSONObject, JSONObject>(name: "h5.seed-open", version: 1, initial: { _ in ["phase": "run"] })
        let id = try await tx.createTask(kind, input: [:], options: .init(ownership: .conversation(), conversationId: root.id))
        let record = try #require(await tx.currentTask(id))
        try tx.setTask(record.replacing(state: .running(checkpoint: ["phase": "run"])))
    }, context: .background)
}
