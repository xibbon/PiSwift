import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskOwnershipRecoveryTests {
    // upstream harness-ownership.test.ts:410; admit into an empty owned
    // conversation after reopen while its marked owner remains live.
    @Test func reopenedCancelledOwnerMarksWorkThroughPreviouslyEmptyConversation() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("late-owner-edge.sqlite").path
        let clock = TestClock()
        let definition = harnessOneStep("test.late-owner-edge", run: { _, _, _ in
            Issue.record("Cancelled work ran")
        }, abort: { task, runtime, context in
            if task.input == 0 { try await runtime.sleep(until: 100, context: context) }
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "owner")) }, context: context)
        })
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        let root = try await first.root(context: .background)
        let tree = try await root.commit({ tx in
            let owner = try await tx.createTask(definition, input: 0, options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner)).id
            return (owner, conversation)
        }, context: .background)
        try await first.commit({ tx in
            let owner = try #require(await tx.task(tree.0))
            try tx.setTask(owner.replacing(abortRequested: true))
        }, context: .background)
        try await first.close(context: .background)

        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: SqliteStorage.open(path: path), clock: clock)
        let conversation = try #require(await harness.conversation(id: tree.1, context: .background))
        #expect(try await harness.getTask(id: tree.0, context: .background)?.abortRequested == true)
        let late = try await harnessStart(conversation, definition, input: 1)
        #expect(try await harness.waitForTask(id: late, context: .background).outcome.status == "aborted")
        try await harnessEventually { clock.pendingSleeperCount == 1 }
        #expect(try await harness.getTask(id: tree.0, context: .background)?.state.status == "running")
        clock.advance(by: 100)
        #expect(try await harness.waitForTask(id: tree.0, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // upstream ownership:319; structured:1490,1523
    @Test(arguments: ["foreground", "terminal-background"])
    func reopenedOwnerEdgesDetermineIdleAndBackgroundBoundary(mode: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owner-edges.sqlite").path
        let original = try await SqliteStorage.open(path: path)
        let parent = try TaskID(20)
        let child = try TaskID(30)
        let inner = try TaskID(40)
        let firstConversation = try ConversationID(50)
        let secondConversation = try ConversationID(60)
        let background = try TaskID(70)
        let backgroundConversation = try ConversationID(80)
        let backgroundInner = try TaskID(90)
        let held: TaskState = .completing(outcome: .completed(result: .number(1)))
        let pending = TaskState.pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()))
        let ownerState: TaskState = mode == "terminal-background" ? .terminal(outcome: .completed(result: .number(1))) : held
        var writes: [StorageWrite] = [
            .conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: TaskRecord(id: parent, conversationId: rootConversationID, kind: "test.edge-recovery", version: 1, input: .number(0), state: ownerState, background: mode == "terminal-background")),
            .conversation(value: ConversationRecord(id: firstConversation, owner: ConversationOwner(conversationId: rootConversationID, taskId: parent))),
            .task(value: TaskRecord(id: child, conversationId: firstConversation, kind: "test.edge-recovery", version: 1, input: .number(0), state: mode == "terminal-background" ? .terminal(outcome: .completed(result: .number(1))) : held)),
            .conversation(value: ConversationRecord(id: secondConversation, owner: ConversationOwner(conversationId: firstConversation, taskId: child))),
            .task(value: TaskRecord(id: inner, conversationId: secondConversation, kind: "test.edge-recovery", version: 1, input: .number(1), state: pending))
        ]
        if mode == "foreground" {
            writes += [
                .task(value: TaskRecord(id: background, conversationId: rootConversationID, kind: "test.edge-recovery", version: 1, input: .number(0), state: held, background: true)),
                .conversation(value: ConversationRecord(id: backgroundConversation, owner: ConversationOwner(conversationId: rootConversationID, taskId: background))),
                .task(value: TaskRecord(id: backgroundInner, conversationId: backgroundConversation, kind: "test.edge-recovery", version: 1, input: .number(2), state: pending))
            ]
        }
        _ = try await original.commit(writes, context: .background)
        try await original.close(context: .background)
        let clock = TestClock()
        let definition = harnessOneStep("test.edge-recovery") { task, runtime, context in
            try await runtime.sleep(until: task.input == 1 ? 100 : 1_000, context: context)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let reopened = try await SqliteStorage.open(path: path)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: reopened, clock: clock)
        let root = try await harness.root(context: .background)
        if mode == "foreground" {
            let idle = settled { try await root.waitForIdle(context: .background) }
            try await harnessEventually { clock.pendingSleeperCount == 2 }
            #expect(!idle.isSettled)
            clock.advance(by: 100)
            try await harnessEventually { idle.isSettled }
            #expect(try await harness.waitForTask(id: parent, context: .background).outcome.status == "completed")
            #expect(try await harness.getTask(id: backgroundInner, context: .background)?.state.status == "running")
            try await root.abort(background: true, context: .background)
        } else {
            try await root.waitForIdle(context: .background)
            try await root.abort(context: .background)
            #expect(try await harness.getTask(id: inner, context: .background)?.abortRequested == false)
            try await root.abort(background: true, context: .background)
            #expect(try await harness.waitForTask(id: inner, context: .background).outcome.status == "aborted")
        }
        try await harness.close(context: .background)
    }
}
