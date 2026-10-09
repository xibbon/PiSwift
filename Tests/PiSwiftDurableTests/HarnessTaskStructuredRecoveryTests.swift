import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessTaskStructuredRecoveryTests {
    // upstream structured:891,906,921,948,1291,1461,1490
    @Test(arguments: ["waiting-settled", "failFast", "held-drained", "held-live", "marked-owner"])
    func reopensOwnershipAndReconcilesDurableIntent(mode: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("structured.sqlite").path
        let storage = try await SqliteStorage.open(path: path)
        let parent = try TaskID(20)
        let child = try TaskID(30)
        let grandchild = try TaskID(40)
        let ownedConversation = try ConversationID(50)
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [child]))
        let parentState: TaskState
        switch mode {
        case "held-drained", "held-live": parentState = .completing(outcome: .completed(result: .number(7)))
        default: parentState = .waiting(checkpoint: checkpoint, on: [child], policy: mode == "failFast" ? .failFast : .allSettled)
        }
        let childState: TaskState = mode == "waiting-settled" || mode == "held-drained" ? .terminal(outcome: .completed(result: .number(1))) : .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint()))
        var writes: [StorageWrite] = [
            .conversation(value: ConversationRecord(id: rootConversationID)),
            .task(value: TaskRecord(id: parent, conversationId: rootConversationID, kind: "test.structured-recovery", version: 1, input: .number(1), state: parentState, abortRequested: mode == "marked-owner")),
            .task(value: TaskRecord(id: child, conversationId: rootConversationID, kind: "test.structured-recovery", version: 1, input: .number(2), state: childState, owner: parent))
        ]
        if mode == "failFast" {
            let failed = TaskRecord(id: grandchild, conversationId: rootConversationID, kind: "test.structured-recovery", version: 1,
                                    input: .number(0), state: .terminal(outcome: .failed(error: .init(message: "stored failure"))), owner: parent)
            writes.append(.task(value: failed))
            writes[1] = .task(value: TaskRecord(id: parent, conversationId: rootConversationID, kind: "test.structured-recovery", version: 1, input: .number(1),
                state: .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: [child, grandchild])), on: [child, grandchild], policy: .failFast)))
        } else if mode == "held-live" || mode == "marked-owner" {
            writes.append(.conversation(value: ConversationRecord(id: ownedConversation, owner: ConversationOwner(conversationId: rootConversationID, taskId: parent))))
            writes.append(.task(value: TaskRecord(id: grandchild, conversationId: ownedConversation, kind: "test.structured-recovery", version: 1, input: .number(2), state: .pending(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint())))))
        }
        _ = try await storage.commit(writes, context: .background)
        try await storage.close(context: .background)
        let clock = TestClock()
        let log = SessionTestLog<Int>()
        let abortOrder = SessionTestLog<TaskID>()
        let definition = harnessOneStep("test.structured-recovery", run: { task, runtime, context in
            log.append(task.input)
            if task.input == 1 {
                let outcomes = try await runtime.outcomes(task.checkpoint.ids, context: context)
                #expect(!outcomes.isEmpty)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(7))) }, context: context)
            } else {
                try await runtime.sleep(until: 1_000, context: context)
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(2))) }, context: context)
            }
        }, abort: { task, runtime, context in
            if mode == "marked-owner" && task.id == parent {
                let outcomes = try await runtime.outcomes([child, grandchild], context: context)
                #expect(outcomes.map(\.status) == ["aborted", "aborted"])
            }
            abortOrder.append(task.id)
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
        let reopened = try await SqliteStorage.open(path: path)
        let harness = try await harnessOpen([AnyTaskDefinition(definition)], storage: reopened, clock: clock)
        #expect(log.count == 0)
        if mode == "marked-owner" {
            let item = try #require(try await harness.inspect(context: .background).tasks.first { $0.record.id == parent })
            guard case .waiting(let on) = item.state else { Issue.record("Reopened marked owner must wait for owned work"); try await harness.close(context: .background); return }
            #expect(Set(on) == Set([child, grandchild]))
        }
        let root = try await harness.root(context: .background)
        if mode == "held-live" {
            try harness.resume()
            let idle = settled { try await root.waitForIdle(context: .background) }
            try await harnessEventually { clock.pendingSleeperCount == 2 }
            #expect(!idle.isSettled)
            #expect(try await harness.getTask(id: parent, context: .background)?.state.status == "completing")
            clock.advance(by: 1_000)
        }
        let receipt = try await harness.waitForTask(id: parent, context: .background)
        #expect(receipt.outcome.status == (mode == "marked-owner" ? "aborted" : "completed"))
        if mode == "held-drained" || mode == "held-live" { #expect(!log.values.contains(1)); #expect(receipt.outcome == .completed(result: .number(7))) }
        if mode == "failFast" || mode == "marked-owner" { #expect(try await harness.waitForTask(id: child, context: .background).outcome.status == "aborted") }
        if mode == "marked-owner" {
            let order = abortOrder.values
            #expect(order.last == parent)
            #expect(Set(order.dropLast()) == Set([child, grandchild]))
            #expect(order.count == 3)
            #expect(log.values.isEmpty)
        }
        try await harness.close(context: .background)
    }

    // upstream harness-structured.test.ts:963
    @Test func reopensWaitingCheckoutWithLivePaymentsAndFinishesNormally() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("live-payments.sqlite").path
        let name = "test.live-payments-recovery"
        let childKind = TaskKind<Int, HarnessTaskCheckpoint>(name: name, version: 1, initial: { _ in HarnessTaskCheckpoint() })
        let log = SessionTestLog<Int>()
        let joined = SessionTestLog<TaskOutcome>()
        let definition = HarnessTestTask(name: name, version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                log.append(task.input)
                if task.input == 1 {
                    try await runtime.commit({ tx, current in
                        let first = try await tx.createTask(childKind, input: 2, options: .init(ownership: .task(taskId: current.id)))
                        let second = try await tx.createTask(childKind, input: 3, options: .init(ownership: .task(taskId: current.id)))
                        let checkpoint = HarnessTaskCheckpoint(phase: .joined, ids: [first, second])
                        return .waiting(checkpoint: try JSONValue(encoding: checkpoint), on: [first, second], policy: .failFast)
                    }, context: context)
                } else {
                    try await runtime.sleep(until: 1_000, context: context)
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(Double(task.input)))) }, context: context)
                }
            case .joined:
                log.append(7)
                let outcomes = try await runtime.outcomes(task.checkpoint.ids, context: context)
                for outcome in outcomes { joined.append(outcome) }
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(7))) }, context: context)
            }
        }, abort: { _, runtime, context in
            Issue.record("Recovery of live payments must not invoke an abort handler")
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "unexpected")) }, context: context)
        })
        let firstClock = TestClock()
        let firstStorage = try await SqliteStorage.open(path: path)
        let first = try await harnessOpen([AnyTaskDefinition(definition)], storage: firstStorage, clock: firstClock)
        let root = try await first.root(context: .background)
        let parent = try await harnessStart(root, definition, input: 1)
        try first.resume()
        try await harnessEventually { firstClock.pendingSleeperCount == 2 }
        let waiting = try #require(await first.getTask(id: parent, context: .background))
        guard case .waiting(_, let children, let policy, _) = waiting.state else {
            Issue.record("Checkout must wait before close")
            try await first.close(context: .background)
            return
        }
        #expect(children.count == 2); #expect(policy == .failFast)
        try await first.close(context: .background)
        #expect(joined.values.isEmpty)
        let beforeReopen = log.values
        #expect(beforeReopen.filter { $0 == 1 }.count == 1)

        let secondClock = TestClock()
        let secondStorage = try await SqliteStorage.open(path: path)
        let second = try await harnessOpen([AnyTaskDefinition(definition)], storage: secondStorage, clock: secondClock)
        #expect(log.values == beforeReopen)
        let reopenedParent = try #require(await second.getTask(id: parent, context: .background))
        #expect(reopenedParent.state == waiting.state)
        for child in children {
            let record = try #require(await second.getTask(id: child, context: .background))
            #expect(record.state.status == "pending"); #expect(!record.abortRequested)
        }
        let result = Task { try await second.waitForTask(id: parent, context: .background) }
        try await harnessEventually { secondClock.pendingSleeperCount == 2 }
        #expect(joined.values.isEmpty)
        #expect(try await second.getTask(id: parent, context: .background)?.state.status == "waiting")
        secondClock.advance(by: 1_000)
        let receipt = try await result.value
        #expect(receipt.outcome == .completed(result: .number(7)))
        #expect(joined.values == [.completed(result: .number(2)), .completed(result: .number(3))])
        #expect(log.values.filter { $0 == 1 }.count == 1)
        #expect(log.values.filter { $0 == 2 }.count == 2)
        #expect(log.values.filter { $0 == 3 }.count == 2)
        #expect(log.values.filter { $0 == 7 }.count == 1)
        for child in children {
            #expect(try await second.waitForTask(id: child, context: .background).outcome.status == "completed")
        }
        try await second.close(context: .background)
    }

}
