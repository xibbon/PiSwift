import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessW3CancellationTests {
    // harness-cancellation-barrier.test.ts:39
    @Test func nextPhaseWaitsForOwnerCascadeToCommit() async throws {
        let storage = W3MarkStorage(), control = W3LifetimeControl()
        let entered = SessionTestLog<Int>(), advance = SessionTestGate(), nextRuns = SessionTestLog<Int>()
        let parent = control.definition()
        let child = harnessOneStep("test.w3.barrier-child") { task, runtime, context in
            if task.checkpoint.phase == .run {
                entered.append(1); await advance.wait()
                try await runtime.commit({ _, _ in .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))) }, context: context)
            } else {
                nextRuns.append(1)
                // Upstream harness-cancellation-barrier.test.ts:54-56 waits for abort.
                // scheduler.ts:2168: keep the next phase active until abort.
                try await harnessToolAwaitAbort(context.withAbortSignal(runtime.signal))
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)], storage: storage, clock: control.clock)
        let root = try await harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let owner = try await tx.createTask(parent, input: 1, options: .init(ownership: .conversation()))
            let child = try await tx.createTask(child, input: 2, options: .init(ownership: .task(taskId: owner)))
            return (owner, child)
        }, context: .background)
        storage.hold(ids.1)
        try harness.resume()
        try await harnessEventually { entered.count == 1 }
        let aborting = Task { try await harness.abortTask(id: ids.0, context: .background) }
        try await harnessEventually { storage.entered.count > 0 }
        advance.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(nextRuns.count == 0)
        storage.release.release()
        _ = try await aborting.value
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        #expect(nextRuns.count == 0)
        try await harness.close(context: .background)
    }

    // harness-cancellation-barrier.test.ts:94
    @Test func failFastRequestOverridesRestartMarkInSamePass() async throws {
        let storage = MemoryStorage(), control = W3LifetimeControl(), definition = control.definition()
        let seed = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage, clock: control.clock)
        let root = try await seed.root(context: .background)
        let ids = try await root.commit({ tx in
            let parent = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            let failed = try await tx.createTask(definition, input: 2, options: .init(ownership: .task(taskId: parent)))
            let child = try await tx.createTask(definition, input: 3, options: .init(ownership: .task(taskId: parent)))
            return (parent, failed, child)
        }, context: .background)
        let owner = try #require(try await storage.task(ids.0, context: .background))
        let failed = try #require(try await storage.task(ids.1, context: .background))
        let waiting = TaskState.waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()), on: [ids.1, ids.2], policy: .failFast)
        _ = try await storage.commit([
            .task(value: TaskRecord(id: owner.id, conversationId: owner.conversationId, kind: owner.kind, version: owner.version, input: owner.input, state: waiting, abortRequested: true, abortReason: .restart)),
            .task(value: failed.replacing(state: .terminal(outcome: .failed(error: .init(message: "failed")))))
        ], context: .background)
        // The first Harness stayed paused. A new Harness reads the saved restart mark.
        let harness = try await harnessOpen([], storage: storage)
        try harness.resume()
        #expect(try await w3Terminal(harness, ids.2).outcome == .orphaned(reason: "missing_task"))
        try await harness.close(context: .background)
    }

    // harness-cancellation-barrier.test.ts:146
    @Test func abortRequestUpgradesRestartMarksThroughTree() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("upgrade.sqlite").path
        let control = W3LifetimeControl(), definition = control.definition(), missing = control.definition("test.w3.missing")
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation()))
            let middle = try await tx.createTask(definition, input: 2, options: .init(ownership: .task(taskId: top), abandonOnRestart: true))
            let leaf = try await tx.createTask(missing, input: 3, options: .init(ownership: .task(taskId: middle)))
            return (top, middle, leaf)
        }, context: .background)
        try await first.close(context: .background)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: ids.2, context: .background)?.abortReason == .restart }
        try await harnessEventually {
            let inspection = try await harness.inspect(context: .background)
            guard let task = inspection.tasks.first(where: { $0.record.id == ids.2 }), case .blocked = task.state else { return false }
            return true
        }
        #expect(try await harness.getTask(id: ids.2, context: .background)?.state.status != "terminal")
        _ = try await harness.abortTask(id: ids.0, context: .background)
        #expect(try await w3Terminal(harness, ids.2).outcome == .orphaned(reason: "missing_task"))
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        #expect(try await w3Terminal(harness, ids.0).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // harness-cancellation-barrier.test.ts:190
    @Test func flaggedHolderKeepsOutcomeAndAbortsOwnedWorkOnRestart() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("held.sqlite").path
        let control = W3LifetimeControl(), definition = control.definition()
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
        let root = try await first.root(context: .background)
        let ids = try await root.commit({ tx in
            let holder = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation(), abandonOnRestart: true))
            let child = try await tx.createTask(definition, input: 2, options: .init(ownership: .task(taskId: holder)))
            return (holder, child)
        }, context: .background)
        try await first.commit({ tx in
            let holder = try #require(await tx.task(ids.0))
            try tx.setTask(holder.replacing(state: .completing(outcome: .completed(result: .number(1)))))
        }, context: .background)
        try await first.close(context: .background)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: control.clock)
        try harness.resume()
        #expect(try await w3Terminal(harness, ids.1).outcome.status == "aborted")
        let holder = try await w3Terminal(harness, ids.0)
        #expect(holder.record.abortReason == .restart)
        #expect(holder.outcome == .completed(result: .number(1)))
        try await harness.close(context: .background)
    }

    // harness-scheduler-indexes.test.ts:82. Read the nearest owner's reason first.
    @Test func nearestCancellingOwnerSuppliesFirstCascadeReason() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nearest-reason.sqlite").path
        let control = W3LifetimeControl(), definition = control.definition()
        let first = try await Session.open(storage: SqliteStorage.open(path: path), context: .background)
        let ids = try await first.commit({ tx in
            let conversation = try await tx.createConversation(ownership: .ownerless())
            let top = try await tx.createTask(definition, input: 1, options: .init(ownership: .conversation(), conversationId: conversation.id))
            let middle = try await tx.createTask(definition, input: 2, options: .init(ownership: .task(taskId: top)))
            let leaf = try await tx.createTask(definition, input: 3, options: .init(ownership: .task(taskId: middle)))
            return (top, middle, leaf)
        }, context: .background)
        try await first.commit({ tx in
            let top = try #require(await tx.task(ids.0)), middle = try #require(await tx.task(ids.1))
            try tx.setTask(top.withAbortMark())
            try tx.setTask(middle.withAbortMark(.restart))
        }, context: .background)
        try await first.close(context: .background)
        let storage = W3MarkStorage(try await SqliteStorage.open(path: path))
        storage.hold(ids.2)
        storage.release.release()
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage, clock: control.clock)
        try harness.resume()
        for id in [ids.2, ids.1, ids.0] { _ = try await w3Terminal(harness, id) }
        #expect(storage.marks.values.first == .some(.restart))
        try await harness.close(context: .background)
    }
}
