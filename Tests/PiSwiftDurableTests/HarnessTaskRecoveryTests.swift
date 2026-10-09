import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskRecoveryTests {
    // upstream harness-tasks-recovery.test.ts:112,148,388,408; SQLite survives a process boundary.
    @Test(arguments: ["pending", "running", "terminal", "marked"])
    func reopensStoredTaskAndRunsOnlyRequiredHandler(status: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("h5-recovery.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        let rootID = rootConversationID
        let id = try TaskID(20)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint(count: 1))
        let state: TaskState
        switch status {
        case "running", "marked": state = .running(checkpoint: checkpoint)
        case "terminal": state = .terminal(outcome: .completed(result: .number(8)))
        default: state = .pending(checkpoint: checkpoint)
        }
        let record = TaskRecord(id: id, conversationId: rootID, kind: "test.recovery", version: 1,
                                input: .number(0), state: state, abortRequested: status == "marked", startedAt: 10)
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootID)), .task(value: record)], context: .background)
        try await storage.close(context: .background)
        let runs = SessionTestLog<String>()
        let definition = harnessOneStep("test.recovery", run: { task, runtime, context in
            runs.append("run")
            #expect(task.checkpoint.count == 1)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(8))) }, context: context)
        }, abort: { _, runtime, context in
            runs.append("abort")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "recovery")) }, context: context)
        })
        let reopened = try await SqliteStorage.open(path: path)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: reopened)
        #expect(runs.count == 0)
        #expect(try await harness.getTask(id: id, context: .background)?.startedAt == 10)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome.status == (status == "marked" ? "aborted" : "completed"))
        #expect(runs.values == (status == "terminal" ? [] : status == "marked" ? ["abort"] : ["run"]))
        #expect(receipt.record.startedAt == 10)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:429,447,513,526; inspect:39
    @Test(arguments: ["missing", "newer-record", "no-migration"])
    func blockedRecordsRemainUnchangedAndAbortOrphans(mode: String) async throws {
        let storage = MemoryStorage()
        let id = try TaskID(40)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        let version: Double = mode == "newer-record" ? 2 : 1
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: TaskRecord(id: id, conversationId: rootConversationID, kind: "test.blocked", version: version,
                             input: .number(0), state: .pending(checkpoint: checkpoint)))], context: .background)
        let registry = Registry()
        if mode != "missing" {
            let definition = harnessOneStep("test.blocked", version: mode == "no-migration" ? 2 : 1) { _, _, _ in Issue.record("Blocked handler ran") }
            try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(definition)]))
        }
        let harness = try await harnessOpen([], storage: storage, registry: registry)
        let taskDoc = try TaskDocToken<JSONObject>(kind: "test.orphan-document", version: 1, initial: { ["retained": true] })
        try await harness.commit({ tx in _ = try await tx.doc(taskDoc, taskId: id) }, context: .background)
        let inspection = try await harness.inspect(context: .background)
        let item = try #require(inspection.tasks.first)
        guard case .blocked(let reason, _) = item.state else { Issue.record("Expected blocked inspection"); try await harness.close(context: .background); return }
        #expect(reason.rawValue == (mode == "missing" ? "missing_task" : mode == "newer-record" ? "task_too_old" : "migration_failed"))
        #expect(try await harness.getTask(id: id, context: .background)?.version == version)
        _ = try await harness.abortTask(id: id, context: .background)
        #expect(try await harness.waitForTask(id: id, context: .background).outcome.status == "orphaned")
        #expect(try await harness.snapshot(taskDoc, taskId: id, context: .background) == nil)
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:582. abortTask commits the mark and,
    // as upstream, does not enable scheduling.
    @Test func reopenedAbortMarkedMissingDefinitionOrphansOnlyAfterResume() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("marked-missing.sqlite").path
        let handlers = SessionTestLog<String>()
        let definition = harnessOneStep("test.marked-missing", run: { _, _, _ in
            handlers.append("run"); Issue.record("A paused task ran")
        }, abort: { _, _, _ in
            handlers.append("abort"); Issue.record("A paused task aborted")
        })
        let token = try TaskDocToken<JSONObject>(kind: "test.marked-missing-doc", version: 1,
                                                initial: { ["retained": true] })
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path))
        let root = try await first.root(context: .background)
        let id = try await harnessStart(root, definition)
        try await first.commit({ tx in _ = try await tx.doc(token, taskId: id) }, context: .background)
        #expect(try await first.abortTask(id: id, context: .background) == .marked)
        try await first.close(context: .background)
        #expect(handlers.values.isEmpty)

        let reopened = try await harnessOpen([], storage: SqliteStorage.open(path: path))
        let pending = try #require(await reopened.getTask(id: id, context: .background))
        #expect(pending.abortRequested)
        #expect(pending.state.status == "pending")
        #expect(try await reopened.snapshot(token, taskId: id, context: .background) == ["retained": true])
        #expect(try await reopened.inspect(context: .background).scheduling == .paused)
        try reopened.resume()
        try await reopened.waitForIdle(context: .background)
        let receipt = try await reopened.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .orphaned(reason: "missing_task"))
        #expect(try await reopened.snapshot(token, taskId: id, context: .background) == nil)
        #expect(handlers.values.isEmpty)
        try await reopened.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:461,708,721
    @Test func migratesOnlyAtReservationAndRetriesWithNewDefinition() async throws {
        let attempts = SessionTestLog<Int>()
        let registry = Registry()
        let failing = HarnessTestTask(name: "test.migrate", version: 2,
            initial: { _ in HarnessTaskCheckpoint() },
            phase: { _, _, _ in Issue.record("Failed migration ran") },
            abort: { _, _, _ in }, migrate: { _, _, _ in attempts.append(1); throw TaskDefinitionError("migration rejected") })
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(failing)]))
        let harness = try await harnessOpen([], registry: registry)
        let root = try await harness.root(context: .background)
        let old = TaskKind<Int, HarnessTaskCheckpoint>(name: "test.migrate", version: 1, initial: { _ in HarnessTaskCheckpoint() })
        let id = try await root.commit({ tx in try await tx.createTask(old, input: 4, options: .init(ownership: .conversation())) }, context: .background)
        let before = try await harness.inspect(context: .background)
        #expect(attempts.count == 0)
        guard case .ready(let migrates) = try #require(before.tasks.first).state else { Issue.record("Expected ready migration"); return }
        #expect(migrates)
        try harness.resume()
        try await harnessEventually { attempts.count == 1 }
        #expect(try await harness.getTask(id: id, context: .background)?.version == 1)
        _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "wake")) }, context: .background)
        _ = try await harness.inspect(context: .background)
        #expect(attempts.count == 1)
        let working = HarnessTestTask(name: "test.migrate", version: 2,
            initial: { _ in HarnessTaskCheckpoint() },
            phase: { task, runtime, context in
                #expect(task.input == 5)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(5))) }, context: context)
            }, abort: { _, _, _ in }, migrate: { input, checkpoint, version in
                #expect(version == 1)
                return (try input.decode(Int.self) + 1, try checkpoint.decode(HarnessTaskCheckpoint.self))
            })
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(working)]))
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.record.version == 2)
        #expect(receipt.outcome == .completed(result: .number(5)))
        try await harness.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:656,668
    @Test func replacementTakesOverAtProgressBoundaryAndKeepsMemos() async throws {
        let registry = Registry()
        let entered = SessionTestGate()
        let release = SessionTestGate()
        let log = SessionTestLog<String>()
        let first = harnessOneStep("test.handover") { task, runtime, context in
            log.append("old")
            _ = try await runtime.memo("kept", value: .number(4), context: context)
            entered.release()
            await release.wait()
            try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(count: task.checkpoint.count + 1))) }, context: context)
        }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(first)]))
        let harness = try await harnessOpen([], registry: registry)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, first)
        try harness.resume()
        await entered.wait()
        let replacement = harnessOneStep("test.handover") { task, runtime, context in
            log.append("new")
            #expect(task.checkpoint.count == 1)
            #expect(try await runtime.memo("kept", context: context) == .number(4))
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(4))) }, context: context)
        }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(replacement)]))
        release.release()
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(4)))
        #expect(log.values == ["old", "new"])
        try await harness.close(context: .background)
    }
    // upstream harness-tasks-recovery.test.ts:176
    @Test func closeAndReopenAtEveryDirectAbortStage() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("abort-stages.sqlite").path
        let log = SessionTestLog<String>()
        let runEntered = SessionTestGate()
        let runRelease = SessionTestGate()
        let abortEntered = SessionTestGate()
        let blockAbort = Mutex(true)
        let clock = TestClock()
        let definition = harnessOneStep("test.abort-stages", run: { _, _, _ in
            log.append("run"); runEntered.release(); await runRelease.wait()
        }, abort: { _, runtime, context in
            log.append("abort")
            if blockAbort.withLock({ $0 }) {
                abortEntered.release()
                try await runtime.sleep(until: 1_000_000, context: context)
            }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "stop")) }, context: context)
        })
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        let root = try await first.root(context: .background)
        let id = try await harnessStart(root, definition)
        try first.resume(); await runEntered.wait()
        let aborting = Task { try await first.abortTask(id: id, context: .background) }
        try await harnessEventually { try await first.getTask(id: id, context: .background)?.abortRequested == true }
        let closing = Task { try await first.close(context: .background) }
        try await harnessEventually { first.tasks.closing }
        runRelease.release()
        try await closing.value
        #expect(try await aborting.value == .marked)
        #expect(log.values == ["run"])
        let second = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        #expect(try await second.getTask(id: id, context: .background)?.state.status == "pending")
        try second.resume(); await abortEntered.wait()
        try await second.close(context: .background)
        #expect(log.values == ["run", "abort"])
        blockAbort.withLock { $0 = false }
        let third = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        #expect(try await third.waitForTask(id: id, context: .background).outcome == .aborted(reason: "stop"))
        try await third.close(context: .background)
        let fourth = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        #expect(try await fourth.abortTask(id: id, context: .background) == .terminal)
        #expect(log.values == ["run", "abort", "abort"])
        try await fourth.close(context: .background)
    }

    // upstream harness-tasks-recovery.test.ts:429,447
    @Test(arguments: [false, true])
    func blockedTaskKeepsIdlePendingUntilFittingRegistration(tooOld: Bool) async throws {
        let registry = Registry()
        let old = harnessOneStep("test.block-registration", version: 1) { _, _, _ in Issue.record("Too-old definition ran") }
        if tooOld { try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(old)])) }
        let harness = try await harnessOpen([], registry: registry)
        let root = try await harness.root(context: .background)
        let fitting = harnessOneStep("test.block-registration", version: 2) { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
        }
        let id = try await harnessStart(root, fitting)
        let idle = settled { try await harness.waitForIdle(context: .background) }
        try await harnessEventually { try await harness.inspect(context: .background).scheduling == .running }
        #expect(!idle.isSettled)
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "pending")
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(fitting)]))
        try await harnessEventually { idle.isSettled }
        #expect(try await harness.waitForTask(id: id, context: .background).outcome == .completed(result: .number(2)))
        try await harness.close(context: .background)
    }

}
