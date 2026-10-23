import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessW3RestartTests {
    // harness-nested-tools-restart.test.ts:168,621. The D3 owner is a task.
    @Test func restartAbandonsTaskCreatedWorkBeforeAnotherPhaseRuns() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned-restart.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition("test.w3.restart-worker")
        let childID = Mutex<TaskID?>(nil), ownerRuns = SessionTestLog<Int>()
        let owner = harnessOneStep("test.w3.restart-owner") { task, runtime, context in
            ownerRuns.append(1)
            try await runtime.commit({ tx, _ in
                let child = try await tx.createTask(worker, input: 7, options: .init(ownership: .task(taskId: task.id)))
                childID.withLock { $0 = child }
                return nil
            }, context: context)
            _ = try await runtime.waitForTask(try #require(childID.withLock { $0 }), context: context)
        }
        let first = try await harnessOpen([AnyTaskDefinition(owner), AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(owner, input: 0, options: .init(ownership: .conversation(), abandonOnRestart: true))
        }, context: .background)
        try first.resume()
        try await harnessEventually { control.runs.values == [7] }
        try await first.close(context: .background)
        let child = try #require(childID.withLock { $0 })
        let harness = try await harnessOpen([AnyTaskDefinition(owner), AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        #expect(try await w3Terminal(harness, child).outcome.status == "aborted")
        #expect(try await w3Terminal(harness, id).outcome.status == "aborted")
        #expect(control.runs.values == [7])
        #expect(ownerRuns.count == 1)
        #expect(control.aborts.values == [.restart])
        #expect(try await harness.getTask(id: child, context: .background)?.abortReason == .restart)
        try await harness.close(context: .background)
    }

    // harness-nested-tools-restart.test.ts:232,300. Restart waits for definitions;
    // a later request can orphan the task instead.
    @Test(arguments: [false, true])
    func missingRestartDefinitionWaitsForInstallOrRequest(requestAbort: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("missing-restart.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(worker, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
        }, context: .background)
        try first.resume()
        try await harnessEventually { control.runs.count == 1 }
        try await first.close(context: .background)
        let registry = Registry()
        let harness = try await harnessOpen([], storage: SqliteStorage.open(path: path), registry: registry, clock: control.clock)
        try harness.resume()
        try await harnessEventually {
            let inspection = try await harness.inspect(context: .background)
            guard let task = inspection.tasks.first(where: { $0.record.id == id }), case .blocked = task.state else { return false }
            return task.record.abortReason == .restart
        }
        #expect(control.aborts.count == 0)
        #expect(try await harness.getTask(id: id, context: .background)?.state.status != "terminal")
        if requestAbort {
            _ = try await harness.abortTask(id: id, context: .background)
            #expect(try await w3Terminal(harness, id).outcome == .orphaned(reason: "missing_task"))
        } else {
            try registry.install(Extension(name: "late", tasks: [AnyTaskDefinition(worker)]))
            #expect(try await w3Terminal(harness, id).outcome.status == "aborted")
            #expect(control.aborts.values == [.restart])
        }
        #expect(control.runs.count == 1)
        try await harness.close(context: .background)
    }

    // harness-nested-tools-restart.test.ts:363. Inspection must not abandon work.
    @Test func pausedReopensDoNotMarkTasks() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("paused-restart.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(worker, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
        }, context: .background)
        try first.resume()
        try await harnessEventually { control.runs.count == 1 }
        try await first.close(context: .background)
        for _ in 0..<2 {
            let harness = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
            #expect(try await harness.inspect(context: .background).scheduling == .paused)
            let task = try #require(try await harness.getTask(id: id, context: .background))
            #expect(task.abandonOnRestart == true)
            #expect(!task.abortRequested)
            #expect(task.abortReason == nil)
            #expect(task.state.status == "pending")
            try await harness.close(context: .background)
        }
        #expect(control.runs.count == 1)
        #expect(control.aborts.count == 0)
    }

    // harness-nested-tools-restart.test.ts:669. D3 uses a flagged task owner.
    @Test func restartCascadeLeavesBackgroundConversationWorkRunning() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("background-restart.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let owner = try await tx.createTask(worker, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner))
            let background = try await tx.createTask(worker, input: 2, options: .init(ownership: .conversation(), conversationId: conversation.id, background: true))
            return (owner, background)
        }, context: .background)
        try first.resume()
        try await harnessEventually { control.runs.count == 2 }
        try await first.close(context: .background)
        let harness = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        #expect(try await w3Terminal(harness, ids.0).record.abortReason == .restart)
        try await w3State(harness, ids.1, "running")
        #expect(try await harness.getTask(id: ids.1, context: .background)?.abortRequested == false)
        try await harness.waitForIdle(context: .background)
        _ = try await harness.abortTask(id: ids.1, context: .background)
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // A flag applies at the next start, not when a new task is created after open.
    @Test func newFlaggedTasksRunAndUnflaggedTasksRecover() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("new-restart.sqlite").path
        let control = W3LifetimeControl(), worker = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try first.resume()
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let flagged = try await tx.createTask(worker, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
            let unflagged = try await tx.createTask(worker, input: 2, options: .init(ownership: .conversation(), abandonOnRestart: false))
            return (flagged, unflagged)
        }, context: .background)
        try await harnessEventually { control.runs.count == 2 }
        #expect(try await first.getTask(id: ids.0, context: .background)?.abortRequested == false)
        try await first.close(context: .background)
        let harness = try await harnessOpen([AnyTaskDefinition(worker)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        #expect(try await w3Terminal(harness, ids.0).record.abortReason == .restart)
        try await harnessEventually { control.runs.values.filter { $0 == 2 }.count == 2 }
        #expect(try await harness.getTask(id: ids.1, context: .background)?.abortReason == nil)
        control.open(2)
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func migrationAndStateCopiesKeepRestartFields(restart: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("migration-restart.sqlite").path
        let seen = SessionTestLog<TaskRecord>(), migrations = SessionTestLog<Double>()
        let old = TaskKind<Int, HarnessTaskCheckpoint>(name: "test.w3.migrate-restart", version: 1, initial: { _ in HarnessTaskCheckpoint() })
        let upgraded = HarnessTestTask(name: old.name, version: 2, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            seen.append(task.record)
            if task.checkpoint.phase == .run {
                _ = try await runtime.memo("saved", value: .number(1), context: context)
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
            } else {
                #expect(task.record.memos == ["saved": .number(1)])
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
            }
        }, abort: { task, runtime, context in
            seen.append(task.record)
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        }, migrate: { input, checkpoint, version in
            migrations.append(version)
            return (try input.decode(Int.self), try checkpoint.decode(HarnessTaskCheckpoint.self))
        })
        let first = try await harnessOpen([AnyTaskDefinition(upgraded)], storage: SqliteStorage.open(path: path))
        let root = try await first.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(old, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
        }, context: .background)
        let harness: Harness
        if restart {
            try await first.close(context: .background)
            harness = try await harnessOpen([AnyTaskDefinition(upgraded)], storage: SqliteStorage.open(path: path))
        } else { harness = first }
        try harness.resume()
        let receipt = try await w3Terminal(harness, id)
        #expect(migrations.values == [1])
        #expect(receipt.record.version == 2)
        #expect(receipt.record.abandonOnRestart == true)
        #expect(receipt.record.abortReason == (restart ? .restart : nil))
        #expect(receipt.outcome.status == (restart ? "aborted" : "completed"))
        #expect(seen.count == (restart ? 1 : 2))
        for record in seen.values {
            #expect(record.abandonOnRestart == true)
            #expect(record.abortReason == (restart ? .restart : nil))
        }
        try await harness.close(context: .background)
    }
}
