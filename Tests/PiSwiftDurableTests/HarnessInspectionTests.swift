import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessInspectionTests {
    // harness-inspect.test.ts:40
    @Test func allLiveStatesAreDerivedWithoutTaskOrMigrationCode() async throws {
        let gate = SessionTestGate(); let migrations = Mutex(0); let gateID = Mutex<TaskID?>(nil)
        let gated = harnessOneStep("h5.inspect-gate") { _, runtime, context in
            await gate.wait(); try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }
        let dependent = HarnessTestTask(name: "h5.inspect-dependent", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                let child = try #require(gateID.withLock { $0 })
                let checkpoint = HarnessTaskCheckpoint(phase: .joined)
                try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: checkpoint), on: [child], policy: .allSettled) }, context: context)
            case .joined: try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
            }
        }, abort: { _, runtime, context in try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context) })
        let migrating = HarnessTestTask(name: "h5.inspect-migrating", version: 2, initial: { _ in HarnessTaskCheckpoint() }, phase: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .null)) }, context: context)
        }, abort: { _, _, _ in }, migrate: { input, _, _ in
            migrations.withLock { $0 += 1 }; return (try input.decode(Int.self), HarnessTaskCheckpoint())
        })
        let noMigration = harnessOneStep("h5.inspect-no-migration", version: 2) { _, _, _ in Issue.record("Blocked task ran") }
        let failing = HarnessTestTask(name: "h5.inspect-failing", version: 2, initial: { _ in HarnessTaskCheckpoint() }, phase: { _, _, _ in Issue.record("Blocked task ran") }, abort: { _, _, _ in }, migrate: { _, _, _ in throw StorageRejected("cannot migrate") })
        let tooOld = harnessOneStep("h5.inspect-too-old", version: 1) { _, _, _ in Issue.record("Blocked task ran") }
        let opened = try await openTasks(tasks: [gated, dependent, migrating, noMigration, failing, tooOld].map(AnyTaskDefinition.init))
        let root = try await opened.harness.root(context: .background)
        let gateId = try await harnessStart(root, gated); gateID.withLock { $0 = gateId }
        let depId = try await harnessStart(root, dependent)
        let migrationId = try await harnessStart(root, harnessOneStep("h5.inspect-migrating", version: 1) { _, _, _ in })
        let noMigrationId = try await harnessStart(root, harnessOneStep("h5.inspect-no-migration", version: 1) { _, _, _ in })
        let failingId = try await harnessStart(root, harnessOneStep("h5.inspect-failing", version: 1) { _, _, _ in })
        let oldId = try await harnessStart(root, harnessOneStep("h5.inspect-too-old", version: 2) { _, _, _ in })
        let missingId = try await harnessStart(root, harnessOneStep("h5.inspect-missing") { _, _, _ in })
        let paused = try await opened.harness.inspect(context: .background)
        #expect(paused.scheduling == .paused); #expect(paused.tasks.map(\.record.id) == [gateId, depId, migrationId, noMigrationId, failingId, oldId, missingId])
        expectInspection(paused, id: gateId, ready: false); expectInspection(paused, id: depId, ready: false)
        expectInspection(paused, id: migrationId, ready: true); expectInspection(paused, id: failingId, ready: true)
        expectInspectionBlocked(paused, id: noMigrationId, reason: .migrationFailed)
        expectInspectionBlocked(paused, id: oldId, reason: .taskTooOld)
        expectInspectionBlocked(paused, id: missingId, reason: .missingTask)
        #expect(migrations.withLock { $0 } == 0)
        try opened.harness.resume()
        _ = try await opened.harness.waitForTask(id: migrationId, context: .background)
        try await harnessEventually {
            let inspection = try await opened.harness.inspect(context: .background)
            guard case .running? = inspection.tasks.first(where: { $0.record.id == gateId })?.state,
                  case .waiting(let on)? = inspection.tasks.first(where: { $0.record.id == depId })?.state else { return false }
            return on == [gateId]
        }
        let running = try await opened.harness.inspect(context: .background)
        expectInspectionBlocked(running, id: failingId, reason: .migrationFailed)
        #expect(migrations.withLock { $0 } == 1)
        gate.release(); _ = try await opened.harness.waitForTask(id: depId, context: .background)
        let final = try await opened.harness.inspect(context: .background)
        #expect(final.tasks.map(\.record.id) == [noMigrationId, failingId, oldId, missingId])
        try await opened.harness.close(context: .background)
    }
    // harness-inspect.test.ts:183. H5 can read raw unsettled submissions; H6 supplies generation transitions.
    @Test func rawUnsettledSubmissionsAreListedInIDOrder() async throws {
        let h = try await openTasks(tasks: []); let root = try await h.harness.root(context: .background)
        let ids = try await root.commit({ tx in
            let first = try await tx.createSubmission(.input(conversationId: root.id))
            let second = try await tx.createSubmission(.write(conversationId: root.id))
            let done = try await tx.createSubmission(.write(conversationId: root.id, state: .done(entry: EntryID(999))))
            return [first.id, second.id, done.id]
        }, context: .background)
        let inspection = try await h.harness.inspect(context: .background)
        #expect(inspection.submissions.map(\.id) == Array(ids.prefix(2))); #expect(inspection.tasks.isEmpty)
        #expect(inspection.scheduling == .paused); try await h.harness.close(context: .background)
    }
}
private func expectInspection(_ inspection: HarnessInspection, id: TaskID, ready migrates: Bool) {
    guard case .ready(let value)? = inspection.tasks.first(where: { $0.record.id == id })?.state else { Issue.record("Task should be ready"); return }
    #expect(value == migrates)
}
private func expectInspectionBlocked(_ inspection: HarnessInspection, id: TaskID, reason: TaskBlockedReason) {
    guard case .blocked(let found, _)? = inspection.tasks.first(where: { $0.record.id == id })?.state else { Issue.record("Task should be blocked"); return }
    #expect(found == reason)
}
