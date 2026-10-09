import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskHoldTests {
    // upstream structured:278,542,575,1329
    @Test func workInOwnedConversationHoldsFinishingCommitAndLateWorkExtendsHold() async throws {
        let clock = TestClock()
        let conversationID = Mutex<ConversationID?>(nil)
        let child = harnessHoldingTask(clock: clock)
        let taskDoc = try TaskDocToken<JSONObject>(kind: "test.held-notes", version: 1, initial: { ["text": "notes"] })
        let parent = harnessOneStep("test.hold-conversation") { _, runtime, context in
            try await runtime.commit({ tx, _ in
                let conversation = try await tx.createConversation(ownership: .task(taskId: runtime.taskId)).id
                conversationID.withLock { $0 = conversation }
                _ = try await tx.doc(taskDoc, taskId: runtime.taskId)
                return nil
            }, context: context)
            try await runtime.commit({ tx, _ in
                let conversation = try #require(conversationID.withLock { $0 })
                _ = try await tx.createTask(child, input: 0, options: .init(ownership: .conversation(), conversationId: conversation))
                return .terminal(outcome: .completed(result: .number(4)))
            }, context: context)
        }
        let harness = try await harnessOpen([AnyTaskDefinition(parent), AnyTaskDefinition(child)], clock: clock)
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: id, context: .background)?.state.status == "completing" }
        #expect(try await harness.snapshot(taskDoc, taskId: id, context: .background) == ["text": "notes"])
        let createdID = try #require(conversationID.withLock { $0 })
        let conversation = try #require(try await harness.conversation(id: createdID, context: .background))
        let late = try await harnessStart(conversation, child)
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "completing")
        let reader = harnessOneStep("test.outcomes-held") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                await #expect(throws: (any Error).self) { _ = try await runtime.outcomes([id], context: context) }
                try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [id], policy: .allSettled) }, context: context)
            case .joined:
                #expect(try await runtime.outcomes([id], context: context) == [.completed(result: .number(4))])
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
            }
        }
        // Install this reader without changing the definitions used by active work.
        let registry = try #require(harness.options.registry as? Registry)
        let migrationCalls = SessionTestLog<Int>()
        let replacement = HarnessTestTask(name: "test.hold-conversation", version: 2,
            initial: { _ in HarnessTaskCheckpoint() }, phase: { _, _, _ in Issue.record("Held task ran a new definition") },
            abort: { _, _, _ in }, migrate: { _, _, _ in migrationCalls.append(1); throw TaskDefinitionError("Held task must not migrate") })
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(replacement), AnyTaskDefinition(child)]))
        try registry.install(Extension(name: "reader", tasks: [AnyTaskDefinition(reader)]))
        let readID = try await harnessStart(root, reader)
        try await harnessEventually { try await harness.getTask(id: readID, context: .background)?.state.status == "waiting" }
        #expect(try await harness.getTask(id: id, context: .background)?.state.status == "completing")
        _ = try await harness.abortTask(id: late, context: .background)
        try await conversation.abort(context: .background)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: .number(4)))
        #expect(receipt.record.version == 1)
        #expect(try await harness.snapshot(taskDoc, taskId: id, context: .background) == nil)
        #expect(migrationCalls.count == 0)
        #expect(try await harness.waitForTask(id: readID, context: .background).outcome.status == "completed")
        try await harness.close(context: .background)
    }

    // upstream structured:692,705,1277
    @Test func abortWaitsForOwnedWorkButIgnoresUnownedWaitMember() async throws {
        let clock = TestClock()
        let child = harnessHoldingTask(clock: clock)
        let external = Mutex<TaskID?>(nil)
        let definition = harnessOneStep("test.unowned-wait") { _, runtime, context in
            let id = try #require(external.withLock { $0 })
            try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [id], policy: .allSettled) }, context: context)
        }
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(child), AnyTaskDefinition(definition)], registry: registry, clock: clock)
        let root = try await harness.root(context: .background)
        let unowned = try await harnessStart(root, child)
        external.withLock { $0 = unowned }
        let waiting = try await harnessStart(root, definition)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: waiting, context: .background)?.state.status == "waiting" }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(child)]))
        _ = try await harness.abortTask(id: waiting, context: .background)
        #expect(try await harness.waitForTask(id: waiting, context: .background).outcome.status == "orphaned")
        #expect(try await harness.getTask(id: unowned, context: .background)?.abortRequested == false)
        _ = try await harness.abortTask(id: unowned, context: .background)
        _ = try await harness.waitForTask(id: unowned, context: .background)
        try await harness.close(context: .background)
    }
    // upstream structured:1259
    @Test func waitingTaskKeepsStateWhenMissingAndMigratesWhenDefinitionReturns() async throws {
        let clock = TestClock()
        let hold = harnessHoldingTask(clock: clock)
        let external = Mutex<TaskID?>(nil)
        let old = harnessOneStep("test.wait-migrate") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                let id = try #require(external.withLock { $0 })
                try await runtime.commit({ _, _ in .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), on: [id], policy: .allSettled) }, context: context)
            case .joined: Issue.record("Missing definition resumed")
            }
        }
        let registry = Registry()
        let harness = try await harnessOpen([AnyTaskDefinition(old), AnyTaskDefinition(hold)], registry: registry, clock: clock)
        let root = try await harness.root(context: .background)
        let member = try await harnessStart(root, hold)
        external.withLock { $0 = member }
        let waiting = try await harnessStart(root, old, input: 4)
        try harness.resume()
        try await harnessEventually { try await harness.getTask(id: waiting, context: .background)?.state.status == "waiting" }
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(hold)]))
        _ = try await harness.abortTask(id: member, context: .background)
        _ = try await harness.waitForTask(id: member, context: .background)
        let inspection = try await harness.inspect(context: .background)
        let item = try #require(inspection.tasks.first { $0.record.id == waiting })
        guard case .blocked(let reason, _) = item.state else { Issue.record("Expected missing waiting definition"); try await harness.close(context: .background); return }
        #expect(reason == .missingTask)
        #expect(item.record.state.status == "waiting")
        let newer = HarnessTestTask(name: "test.wait-migrate", version: 2, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            #expect(task.checkpoint.phase == .joined)
            #expect(task.input == 5)
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
        }, abort: { _, _, _ in }, migrate: { input, checkpoint, _ in (try input.decode(Int.self) + 1, try checkpoint.decode(HarnessTaskCheckpoint.self)) })
        try registry.install(Extension(name: "tasks", tasks: [AnyTaskDefinition(hold), AnyTaskDefinition(newer)]))
        let receipt = try await harness.waitForTask(id: waiting, context: .background)
        #expect(receipt.outcome == .completed(result: .number(2)))
        #expect(receipt.record.version == 2)
        try await harness.close(context: .background)
    }

}
