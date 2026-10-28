import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func d3StateRecord(_ id: TaskID, state: TaskState, owner: TaskID? = nil,
                           restarts: Double? = nil, kind: String = "test.state", version: Double = 1) -> TaskRecord {
    TaskRecord(id: id, conversationId: rootConversationID, kind: kind, version: version,
               input: .number(0), state: state, owner: owner, restarts: restarts)
}

@Suite struct D3HarnessStateTests {
    // v1.4.0 scheduler progress compares the complete state by JSON value.
    @Test(arguments: ["sleep-time", "wait-order", "wait-policy", "state-extension", "equal-key-order"])
    func fullStateProgressUsesValueEquality(change: String) async throws {
        let storage = MemoryStorage(), id = try TaskID(20), first = try TaskID(21), second = try TaskID(22)
        let checkpoint: JSONValue = .object(JSONObject([("phase", "run"), ("left", 1), ("right", 2)]))
        let reordered: JSONValue = .object(JSONObject([("right", 2), ("left", 1), ("phase", "run")]))
        let before: TaskState, after: TaskState
        switch change {
        case "sleep-time":
            before = .sleeping(checkpoint: checkpoint, until: 100)
            after = .sleeping(checkpoint: checkpoint, until: 101)
        case "wait-order":
            before = .waiting(checkpoint: checkpoint, on: [first, second], policy: .allSettled)
            after = .waiting(checkpoint: checkpoint, on: [second, first], policy: .allSettled)
        case "wait-policy":
            before = .waiting(checkpoint: checkpoint, on: [first, second], policy: .allSettled)
            after = .waiting(checkpoint: checkpoint, on: [first, second], policy: .failFast)
        case "state-extension":
            before = .running(checkpoint: checkpoint, extensions: ["intent": 1])
            after = .running(checkpoint: checkpoint, extensions: ["intent": 2])
        default:
            before = .running(checkpoint: checkpoint)
            after = .running(checkpoint: reordered)
            #expect(try checkpoint.jsonText() != reordered.jsonText())
        }
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: d3StateRecord(id, state: .pending(checkpoint: checkpoint), restarts: 3)),
            .task(value: d3StateRecord(first, state: .pending(checkpoint: checkpoint), owner: id)),
            .task(value: d3StateRecord(second, state: .pending(checkpoint: checkpoint), owner: id))], context: .background)
        let harness = try await harnessOpen([], storage: storage, clock: TestClock(now: 0))
        try await harness.session.commit({ tx in
            let record = try #require(await tx.task(id))
            try tx.setTask(record.replacing(state: before))
        }, context: .background)
        try await harness.session.commit({ tx in
            let record = try #require(await tx.task(id))
            let invocation = TaskInvocation(record, abort: false, context: .background)
            try await harness.tasks.commitState(tx, invocation: invocation, current: record, next: after)
        }, context: .background)
        let result = try #require(await harness.getTask(id: id, context: .background))
        #expect(result.state == after)
        #expect(result.storedRestarts == (change == "equal-key-order" ? 3 : nil))
        try await harness.close(context: .background)
    }

    @Test func completingOutcomeRemovesCountAndRetryLeavesOtherTasksUnchanged() async throws {
        let base = MemoryStorage(), events = SessionTestLog<String>(), storage = D3TestStorage(base, events: events)
        let owner = try TaskID(20), child = try TaskID(21), terminal = try TaskID(22), ready = try TaskID(23)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        _ = try await base.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: d3StateRecord(owner, state: .pending(checkpoint: checkpoint), restarts: 3)),
            .task(value: d3StateRecord(child, state: .pending(checkpoint: checkpoint), owner: owner)),
            .task(value: d3StateRecord(terminal, state: .terminal(outcome: .completed(result: .number(7))))),
            .task(value: d3StateRecord(ready, state: .pending(checkpoint: checkpoint), restarts: 2))], context: .background)
        let harness = try await harnessOpen([], storage: storage)
        try await harness.session.commit({ tx in
            let record = try #require(await tx.task(owner))
            try await harness.tasks.commitState(tx, invocation: TaskInvocation(record, abort: false, context: .background),
                current: record, next: .terminal(outcome: .completed(result: .number(1))))
        }, context: .background)
        let completing = try #require(await harness.getTask(id: owner, context: .background))
        #expect(completing.state == .completing(outcome: .completed(result: .number(1))))
        #expect(completing.storedRestarts == nil)
        #expect(try JSONValue(encoding: completing)["restarts"] == nil)
        let finished = try #require(await harness.getTask(id: terminal, context: .background))
        let pending = try #require(await harness.getTask(id: ready, context: .background))
        let writes = events.count
        for id in [owner, terminal, ready] { try await harness.retryTask(id: id, context: .background) }
        #expect(try await harness.getTask(id: owner, context: .background) == completing)
        #expect(try await harness.getTask(id: terminal, context: .background) == finished)
        #expect(try await harness.getTask(id: ready, context: .background) == pending)
        #expect(events.count == writes)
        do {
            try await harness.retryTask(id: TaskID(90_000), context: .background)
            Issue.record("Unknown task retry succeeded")
        } catch { #expect(String(describing: error) == "Task 90000 does not exist") }
        #expect(try await harness.getTask(id: ready, context: .background) == pending)
        try await harness.close(context: .background); try await base.close(context: .background)
    }

    @Test(arguments: ["missing_task", "task_too_old", "migration_failed", "restart_limit", ""])
    func graphCodecKeepsExactBlockedReason(reason: String) throws {
        var object: JSONObject = ["id": 20, "kind": "test.state", "conversationId": .number(Double(rootConversationID.rawValue)),
            "background": false, "abortRequested": false, "state": ["status": "pending", "phase": "run"], "conversations": []]
        if !reason.isEmpty { object["blocked"] = .string(reason) }
        let raw = JSONValue.object(object), node = try raw.decode(TaskGraphNode.self)
        #expect(node.blocked?.rawValue == (reason.isEmpty ? nil : reason))
        #expect(try JSONValue(encoding: node) == raw)
        let graph = TaskGraph(tasks: ["20": node])
        #expect(try JSONValue(encoding: graph).decode(TaskGraph.self) == graph)
    }

    @Test func graphShowsOldDefinitionAndMissingMigrationBeforeResume() async throws {
        let storage = MemoryStorage(), old = try TaskID(20), noMigration = try TaskID(21)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: d3StateRecord(old, state: .pending(checkpoint: checkpoint), kind: "test.old", version: 2)),
            .task(value: d3StateRecord(noMigration, state: .pending(checkpoint: checkpoint), kind: "test.no-migration"))], context: .background)
        let first = harnessOneStep("test.old", version: 1) { _, _, _ in Issue.record("Old definition ran") }
        let second = harnessOneStep("test.no-migration", version: 2) { _, _, _ in Issue.record("Missing migration ran") }
        let harness = try await harnessOpen([AnyTaskDefinition(first), AnyTaskDefinition(second)], storage: storage)
        let graph = try await harness.taskGraph(context: .background)
        #expect(graph.value.tasks[String(old.rawValue)]?.blocked == .taskTooOld)
        #expect(graph.value.tasks[String(noMigration.rawValue)]?.blocked == .migrationFailed)
        let inspection = try await harness.inspect(context: .background)
        #expect(inspection.scheduling == .paused)
        for item in inspection.tasks {
            guard case .blocked(let reason, _) = item.state else { Issue.record("Expected blocked readiness"); continue }
            #expect(reason == (item.record.id == old ? .taskTooOld : .migrationFailed))
        }
        graph.dispose(); try await harness.close(context: .background)
    }

    @Test func closeKeepsReservationThatWasReadingItsOwnershipChain() async throws {
        let base = MemoryStorage(), storage = D3TestStorage(base), id = try TaskID(20)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint())
        _ = try await base.commit([.conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: d3StateRecord(id, state: .pending(checkpoint: checkpoint)))], context: .background)
        let definition = harnessOneStep("test.state") { _, _, _ in Issue.record("Close started a handler") }
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: storage)
        try await harnessEventually {
            harness.tasks.state.withLock { !$0.cascadePending && $0.reconcilingWork == 0 && !$0.reconcileScheduled }
        }
        let entered = SessionTestGate(), release = SessionTestGate()
        storage.holdConversations(entered: entered, release: release)
        // Evict the ownership cache so this reservation must read the chain again.
        harness.tasks.state.withLock { state in
            state.edges.removeValue(forKey: rootConversationID)
            state.unloaded.insert(id)
        }
        try harness.resume(); await entered.wait()
        let closing = Task { try await harness.close(context: .background) }
        try await harnessEventually { harness.tasks.closing }
        release.release(); try await closing.value
        let saved = try #require(await base.task(id, context: .background))
        #expect(saved.state == .pending(checkpoint: checkpoint) && saved.storedRestarts == nil)
        try await base.close(context: .background)
    }
}
