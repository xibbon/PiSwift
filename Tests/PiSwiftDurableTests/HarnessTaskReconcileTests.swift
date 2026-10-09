import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskReconcileTests {
    // upstream structured:1428; ownership:522,559
    @Test(arguments: ["cascade", "finalization"])
    func rejectedReconcileWriteRetriesOnNextCommit(mode: String) async throws {
        let storage = HarnessSelectiveStorage()
        let clock = TestClock()
        let definition = harnessHoldingTask(clock: clock)
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(definition)], clock: clock)
        let harness = opened.harness
        let root = try await harness.root(context: .background)
        let tree = try await harnessOwnedTree(root, definition: definition)
        storage.rejectOnce { writes in
            writes.contains { write in
                guard case .task(let task, _) = write else { return false }
                return mode == "finalization" ? task.id == tree.owner && task.state.status == "terminal" : task.id == tree.child && task.abortRequested
            }
        }
        try await root.commit({ tx in
            let parent = try #require(try await tx.task(tree.owner))
            if mode == "finalization" {
                let child = try #require(try await tx.task(tree.child))
                try tx.setTask(parent.replacing(state: .completing(outcome: .completed(result: .number(1)))))
                try tx.setTask(child.replacing(state: .terminal(outcome: .completed(result: .number(2)))))
            } else { try tx.setTask(parent.replacing(state: .completing(outcome: .failed(error: .init(message: "held failure"))))) }
        }, context: .background)
        try await harnessEventually { opened.reports.count > 0 }
        #expect(try await harness.getTask(id: tree.owner, context: .background)?.state.status == "completing")
        if mode != "finalization" { #expect(try await harness.getTask(id: tree.child, context: .background)?.abortRequested == false) }
        _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "retry")) }, context: .background)
        let receipt = try await harness.waitForTask(id: tree.owner, context: .background)
        #expect(receipt.outcome.status == (mode == "finalization" ? "completed" : "failed"))
        if mode != "finalization" { #expect(try await harness.waitForTask(id: tree.child, context: .background).outcome.status == "aborted") }
        try await harness.close(context: .background)
    }

    // upstream ownership:492
    @Test func ownerMarkWinsWhenUnownedWaitMemberEndsInSameCommit() async throws {
        let clock = TestClock()
        let hold = harnessHoldingTask(clock: clock)
        let child = harnessOneStep("test.wait-abort-race") { task, runtime, context in
            let external = try TaskID(Int64(task.input))
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [external], policy: .allSettled) }, context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(99))) }, context: context)
            }
        }
        let harness = try await harnessOpen([AnyTaskDefinition(hold), AnyTaskDefinition(child)], clock: clock)
        let root = try await harness.root(context: .background)
        let parent = try await harnessStart(root, hold)
        let external = try await harnessStart(root, hold)
        let waiting = try await root.commit({ tx in
            try await tx.createTask(child, input: Int(external.rawValue), options: .init(ownership: .task(taskId: parent)))
        }, context: .background)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: waiting, context: .background)?.state.status == "waiting" }
        try await root.commit({ tx in
            let owner = try #require(try await tx.task(parent))
            let member = try #require(try await tx.task(external))
            try tx.setTask(owner.replacing(abortRequested: true))
            try tx.setTask(member.replacing(state: .terminal(outcome: .completed(result: .number(1)))))
        }, context: .background)
        #expect(try await harness.waitForTask(id: waiting, context: .background).outcome.status == "aborted")
        #expect(try await harness.waitForTask(id: parent, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }
    // upstream ownership:522; loaded owner edges are restored from SQLite before the rejected mark.
    @Test func reopenedOwnerEdgeMarkRetriesAfterStorageRejection() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("edge-retry.sqlite").path
        let database = try await SqliteStorage.open(path: path)
        let parent = try TaskID(20)
        let child = try TaskID(30)
        let owned = try ConversationID(40)
        _ = try await database.commit([
            .conversation(value: ConversationRecord(id: rootConversationID)),
            .conversation(value: ConversationRecord(id: owned, owner: ConversationOwner(conversationId: rootConversationID, taskId: parent))),
            .task(value: TaskRecord(id: parent, conversationId: rootConversationID, kind: "test.owned-hold", version: 1, input: .number(0), state: .completing(outcome: .failed(error: .init(message: "stored failure"))))),
            .task(value: TaskRecord(id: child, conversationId: owned, kind: "test.owned-hold", version: 1, input: .number(0), state: .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()))))
        ], context: .background)
        try await database.close(context: .background)
        let reopened = try await SqliteStorage.open(path: path)
        let storage = HarnessSelectiveStorage(reopened)
        storage.rejectOnce { writes in writes.contains { if case .task(let task, _) = $0 { return task.id == child && task.abortRequested }; return false } }
        let clock = TestClock()
        let definition = harnessHoldingTask(clock: clock)
        let opened = try await openTasks(storage: storage, tasks: [AnyTaskDefinition(definition)], clock: clock)
        try await harnessEventually { opened.reports.count > 0 }
        #expect(try await opened.harness.getTask(id: child, context: .background)?.abortRequested == false)
        let root = try await opened.harness.root(context: .background)
        _ = try await root.commit({ tx in try await tx.appendEntry(root.id, value: EntryDraft(kind: "retry")) }, context: .background)
        #expect(try await opened.harness.waitForTask(id: child, context: .background).outcome.status == "aborted")
        #expect(try await opened.harness.waitForTask(id: parent, context: .background).outcome.status == "failed")
        try await opened.harness.close(context: .background)
    }

}
