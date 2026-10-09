import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

struct HarnessOwnedTree: Sendable { let owner: TaskID; let conversation: ConversationID; let child: TaskID }
func harnessOwnedTree(_ root: Conversation, definition: HarnessTestTask, input: Int = 0, childInput: Int = 0, background: Bool = false) async throws -> HarnessOwnedTree {
    try await root.commit({ tx in
        let owner = try await tx.createTask(definition, input: input, options: .init(ownership: .conversation(), background: background))
        let conversation = try await tx.createConversation(ownership: .task(taskId: owner)).id
        let child = try await tx.createTask(definition, input: childInput, options: .init(ownership: .conversation(), conversationId: conversation))
        return HarnessOwnedTree(owner: owner, conversation: conversation, child: child)
    }, context: .background)
}
func harnessHoldingTask(clock: TestClock, slowAbort: SessionTestGate? = nil) -> HarnessTestTask {
    harnessOneStep("test.owned-hold", run: { task, runtime, context in
        if task.input == 1 || task.input == -1 {
            try await runtime.commit({ _, _ in
                .terminal(outcome: task.input == 1 ? .completed(result: .number(1)) : .failed(error: .init(message: "owner failed")))
            }, context: context)
        } else { try await runtime.sleep(until: 1_000_000, context: context) }
    }, abort: { task, runtime, context in
        if task.input == 99 { await slowAbort?.wait() }
        try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "owned")) }, context: context)
    })
}

@Suite struct HarnessTaskOwnershipTests {
    // upstream ownership:173,188,224,239; structured:575,626,1355
    @Test(arguments: ["completed", "failed", "aborted", "background"])
    func ownedConversationControlsHoldCascadeAndIdle(mode: String) async throws {
        let clock = TestClock()
        let definition = harnessHoldingTask(clock: clock)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let tree = try await harnessOwnedTree(root, definition: definition, input: mode == "completed" ? 1 : mode == "failed" ? -1 : 0, background: mode == "background")
        try harness.resume()
        if mode == "completed" {
            try await harnessEventually { try await harness.getTask(id: tree.owner, context: .background)?.state.status == "completing" }
            let idle = settled { try await root.waitForIdle(context: .background) }
            #expect(!idle.isSettled)
            #expect(try await harness.getTask(id: tree.child, context: .background)?.abortRequested == false)
            try await root.abort(context: .background)
            #expect(try await harness.waitForTask(id: tree.owner, context: .background).outcome.status == "completed")
        } else if mode == "failed" {
            #expect(try await harness.waitForTask(id: tree.child, context: .background).outcome.status == "aborted")
            #expect(try await harness.waitForTask(id: tree.owner, context: .background).outcome.status == "failed")
        } else {
            if mode == "background" { try await root.waitForIdle(context: .background); try await harness.waitForIdle(context: .background) }
            _ = try await harness.abortTask(id: tree.owner, context: .background)
            #expect(try await harness.waitForTask(id: tree.child, context: .background).outcome.status == "aborted")
            #expect(try await harness.waitForTask(id: tree.owner, context: .background).outcome.status == "aborted")
        }
        try await harness.close(context: .background)
    }

    // upstream ownership:266,410; structured:830
    @Test func newWorkBelowHeldFailureIsMarkedButTerminalOwnerDoesNotCascade() async throws {
        let clock = TestClock()
        let slowAbort = SessionTestGate()
        let definition = harnessHoldingTask(clock: clock, slowAbort: slowAbort)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let tree = try await harnessOwnedTree(root, definition: definition, input: -1, childInput: 99)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: tree.child, context: .background)?.abortRequested == true }
        #expect(try await harness.getTask(id: tree.owner, context: .background)?.state.status == "completing")
        let childConversation = try #require(try await harness.conversation(id: tree.conversation, context: .background))
        let during = try await harnessStart(childConversation, definition)
        #expect(try await harness.waitForTask(id: during, context: .background).outcome.status == "aborted")
        slowAbort.release()
        #expect(try await harness.waitForTask(id: tree.owner, context: .background).outcome.status == "failed")
        let after = try await harnessStart(childConversation, definition, input: 1)
        #expect(try await harness.waitForTask(id: after, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // upstream ownership:305; structured:1390,1523
    @Test func backgroundBoundaryStopsOrdinaryCascadeAndExplicitCrossingReachesIt() async throws {
        let clock = TestClock()
        let definition = harnessHoldingTask(clock: clock)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let outer = try await harnessOwnedTree(root, definition: definition, background: true)
        let childConversation = try #require(try await harness.conversation(id: outer.conversation, context: .background))
        let inner = try await harnessOwnedTree(childConversation, definition: definition, background: true)
        _ = try await harness.abortTask(id: outer.owner, context: .background)
        #expect(try await harness.waitForTask(id: outer.child, context: .background).outcome.status == "aborted")
        #expect(try await harness.getTask(id: inner.owner, context: .background)?.abortRequested == false)
        #expect(try await harness.getTask(id: inner.child, context: .background)?.abortRequested == false)
        try await root.abort(background: true, context: .background)
        #expect(try await harness.waitForTask(id: inner.child, context: .background).outcome.status == "aborted")
        try await harness.close(context: .background)
    }

    // upstream structured:745,761; ownership:435
    @Test func blockedOwnerIsOrphanedOnlyAfterItsOwnedConversationDrains() async throws {
        let clock = TestClock()
        let slowAbort = SessionTestGate()
        let child = harnessHoldingTask(clock: clock, slowAbort: slowAbort)
        let absent = harnessOneStep("test.unregistered") { _, _, _ in Issue.record("Missing task ran") }
        let harness = try await harnessOpen([AnyTaskDefinition(child)], clock: clock)
        let root = try await harness.root(context: .background)
        let tree = try await root.commit({ tx in
            let owner = try await tx.createTask(absent, input: 0, options: .init(ownership: .conversation()))
            let conversation = try await tx.createConversation(ownership: .task(taskId: owner)).id
            let inner = try await tx.createTask(child, input: 99, options: .init(ownership: .conversation(), conversationId: conversation))
            return HarnessOwnedTree(owner: owner, conversation: conversation, child: inner)
        }, context: .background)
        _ = try await harness.abortTask(id: tree.owner, context: .background)
        try await harnessEventually { try await harness.getTask(id: tree.child, context: .background)?.abortRequested == true }
        #expect(try await harness.getTask(id: tree.owner, context: .background)?.state.status != "terminal")
        let inspection = try await harness.inspect(context: .background)
        let ownerInspection = try #require(inspection.tasks.first { $0.record.id == tree.owner })
        guard case .waiting(let on) = ownerInspection.state else { Issue.record("Abort-marked owner must wait for owned work"); slowAbort.release(); try await harness.close(context: .background); return }
        #expect(on == [tree.child])
        slowAbort.release()
        #expect(try await harness.waitForTask(id: tree.child, context: .background).outcome.status == "aborted")
        #expect(try await harness.waitForTask(id: tree.owner, context: .background).outcome == .orphaned(reason: "missing_task"))
        try await harness.close(context: .background)
    }

    // upstream structured:1368
    @Test func backgroundAbortWaitsOnlyForWorkReachedAtAdmission() async throws {
        let clock = TestClock()
        let slowAbort = SessionTestGate()
        let definition = harnessHoldingTask(clock: clock, slowAbort: slowAbort)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], clock: clock)
        let root = try await harness.root(context: .background)
        let first = try await harnessStart(root, definition, input: 99, background: true)
        let abort = Task { try await root.abort(background: true, context: .background) }
        try await harnessEventually { try await harness.getTask(id: first, context: .background)?.abortRequested == true }
        let later = try await harnessStart(root, definition, background: true)
        slowAbort.release()
        try await abort.value
        #expect(try await harness.getTask(id: later, context: .background)?.abortRequested == false)
        _ = try await harness.abortTask(id: later, context: .background)
        _ = try await harness.waitForTask(id: later, context: .background)
        try await harness.close(context: .background)
    }
}
