import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite(.timeLimit(.minutes(1)))
struct HarnessTaskAnyWaitTests {
    // Upstream v1.6.0 harness-signals.test.ts:525.
    @Test("resumes once one task in on is terminal, with the ended ones as its wake")
    func resumesOnceOneTaskIsTerminalWithEndedTasksAsItsWake() async throws {
        let signal = try makeSignal()
        let child = makeChild(signal)
        let parent = makeParent(child)
        let harness = try await harnessOpen([parent.eraseToAnyTaskDefinition(), child.eraseToAnyTaskDefinition()], clock: TestClock())
        let (id, children) = try await startParent(harness, parent)

        let expectedWake = WakeReason.tasks(ended: [children[1]])
        #expect(try await harness.signal(taskId: children[1], token: signal, key: "ready", value: true,
            context: .background) == .delivered)
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: try JSONValue(encoding: expectedWake)))
        let other = try await harness.getTask(id: children[0], context: .background)
        #expect(other?.state.outcome == .aborted(reason: "test"))
        try await harness.close(context: .background)
    }

    // Upstream v1.6.0 harness-signals.test.ts:535.
    @Test("is active in wake() once a task in on is terminal, not while all are live")
    func wakeReportsActiveWhenAnAnyDependencyEndsWhilePaused() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("any-wait.sqlite").path
        let clock = TestClock()
        let child = try makeChild(makeSignal())
        let parent = makeParent(child)
        let initial = try await harnessOpen([parent.eraseToAnyTaskDefinition(), child.eraseToAnyTaskDefinition()],
            storage: SqliteStorage.open(path: path), clock: clock)
        let (id, children) = try await startParent(initial, parent)
        try await initial.close(context: .background)

        let harness = try await harnessOpen([parent.eraseToAnyTaskDefinition()], storage: SqliteStorage.open(path: path), clock: clock)
        try await harnessEventually { !harness.wake().active }
        #expect(harness.wake() == HarnessWake(active: false))
        #expect(try await harness.abortTask(id: children[0], context: .background) == .marked)
        let ended = try await harness.getTask(id: children[0], context: .background)
        #expect(ended?.state.outcome == .orphaned(reason: "missing_task"))

        try await harnessEventually { harness.tasks.state.withLock { $0.reconciles.isEmpty } }
        #expect(harness.wake() == HarnessWake(active: true))
        let inspection = try await harness.inspect(context: .background)
        #expect(inspection.scheduling == .paused)
        let waiter = try #require(inspection.tasks.first { $0.record.id == id })
        guard case .pending(migrates: false) = waiter.state else {
            Issue.record("A paused waiter with a terminal dependency must be ready")
            try await harness.close(context: .background)
            return
        }

        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: try JSONValue(encoding: WakeReason.tasks(ended: [children[0]]))))
        try await harness.close(context: .background)
    }

    @Test(arguments: [JoinPolicy.any, .allSettled, .failFast])
    func emptyWaitWakesWithAnEmptyEndedList(policy: JoinPolicy) async throws {
        let waiter = makeWaiter(policy: policy)
        let harness = try await harnessOpen([waiter.eraseToAnyTaskDefinition()], clock: TestClock())
        let root = try await harness.root(context: .background)
        let id = try await root.commit({ tx in
            try await tx.createTask(waiter, input: [], options: .init(ownership: .conversation()))
        }, context: .background)

        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: ["reason": "tasks", "ended": []]))
        try await harness.close(context: .background)
    }

    @Test(arguments: [JoinPolicy.any, .allSettled])
    func listsEndedTasksInWaitOrderAndAllowsUnownedTasks(policy: JoinPolicy) async throws {
        let child = try makeChild(makeSignal())
        let waiter = makeWaiter(policy: policy)
        let harness = try await harnessOpen([child.eraseToAnyTaskDefinition(), waiter.eraseToAnyTaskDefinition()], clock: TestClock())
        let root = try await harness.root(context: .background)
        let children = try await root.commit({ tx in
            var ids: [TaskID] = []
            for _ in 0..<3 {
                ids.append(try await tx.createTask(child, input: 0, options: .init(ownership: .conversation())))
            }
            return ids
        }, context: .background)
        for id in [children[0], children[2]] {
            _ = try await harness.abortTask(id: id, context: .background)
            _ = try await harness.waitForTask(id: id, context: .background)
        }
        try await harnessEventually {
            try await harness.getTask(id: children[1], context: .background)?.state.status == "sleeping"
        }
        let on = [children[2], children[1], children[0]]
        let id = try await root.commit({ tx in
            try await tx.createTask(waiter, input: on, options: .init(ownership: .conversation()))
        }, context: .background)

        if policy == .allSettled {
            try await harnessEventually { !harness.wake().active }
            let inspection = try await harness.inspect(context: .background)
            let waiting = try #require(inspection.tasks.first { $0.record.id == id })
            if case .waiting(let remaining) = waiting.state { #expect(remaining == [children[1]]) }
            else { Issue.record("An allSettled wait must hold while a dependency is live") }
            _ = try await harness.abortTask(id: children[1], context: .background)
        }
        let expected = policy == .any ? [children[2], children[0]] : on
        let receipt = try await harness.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: try JSONValue(encoding: WakeReason.tasks(ended: expected))))
        if policy == .any {
            let other = try await harness.getTask(id: children[1], context: .background)
            #expect(other?.state.status == "sleeping")
            #expect(other?.abortRequested == false)
        }
        try await harness.close(context: .background)
    }

    @Test func keepsTaskWakeUntilCheckpointChangesAcrossReopen() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("task-wake.sqlite").path
        let clock = TestClock()
        let wakes = SessionTestLog<WakeReason?>()
        let checkpoint = try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined))
        let task = harnessOneStep("test.keep-task-wake") { task, runtime, context in
            switch (task.checkpoint.phase, task.checkpoint.count) {
            case (.run, _):
                try await runtime.wait(on: [], policy: .any, checkpoint: checkpoint, context: context)
            case (.joined, 0):
                wakes.append(try task.record.state.wakeReason())
                try await runtime.commit({ _, _ in .running(checkpoint: checkpoint) }, context: context)
                wakes.append(try await runtime.getTask(runtime.taskId, context: context)?.state.wakeReason())
                if wakes.count == 2 { try await harnessToolAwaitAbort(context) }
                try await runtime.commit({ _, _ in
                    .running(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, count: 1)))
                }, context: context)
            case (.joined, _):
                wakes.append(try task.record.state.wakeReason())
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(0))) }, context: context)
            }
        }
        let definitions = [task.eraseToAnyTaskDefinition()]
        let first = try await harnessOpen(definitions, storage: SqliteStorage.open(path: path), clock: clock)
        let id = try await harnessStart(first.root(context: .background), task)
        try first.resume()
        try await harnessEventually { wakes.count == 2 }
        let expected = WakeReason.tasks(ended: [])
        #expect(wakes.values == [expected, expected])
        try await first.close(context: .background)

        let reopened = try await harnessOpen(definitions, storage: SqliteStorage.open(path: path), clock: clock)
        let record = try await reopened.getTask(id: id, context: .background)
        #expect(record?.state.status == "pending")
        #expect(try record?.state.wakeReason() == expected)
        let receipt = try await reopened.waitForTask(id: id, context: .background)
        #expect(receipt.outcome == .completed(result: .number(0)))
        #expect(wakes.values == [expected, expected, expected, expected, nil])
        try await reopened.close(context: .background)
    }

    private typealias Waiter = TaskDefinition<[TaskID], HarnessTaskCheckpoint, WakeReason, NoTaskHooks>

    private func makeSignal() throws -> SignalToken<Bool> {
        try defineSignal(name: "test.any-ready", version: 1, schema: ["type": "boolean"])
    }

    private func makeChild(_ signal: SignalToken<Bool>) -> HarnessTestTask {
        harnessOneStep("test.any-child") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.sleep(signals: [try signal.key("ready")],
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            case .joined:
                try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(0))) }, context: context)
            }
        }
    }

    private func makeParent(_ child: HarnessTestTask) -> HarnessTestTask {
        harnessOneStep("test.any-parent") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.commit({ tx, _ in
                    let options = TaskOptions(ownership: .task(taskId: runtime.taskId))
                    let first = try await tx.createTask(child, input: 0, options: options)
                    let second = try await tx.createTask(child, input: 0, options: options)
                    let on = [first, second]
                    return .waiting(checkpoint: try JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined, ids: on)),
                        on: on, policy: .any)
                }, context: context)
            case .joined:
                let wake = try #require(try task.record.state.wakeReason())
                for id in task.checkpoint.ids { try await runtime.abortOwned(id, context: context) }
                try await runtime.commit({ _, _ in
                    .terminal(outcome: .completed(result: try JSONValue(encoding: wake)))
                }, context: context)
            }
        }
    }

    private func makeWaiter(policy: JoinPolicy) -> Waiter {
        Waiter(name: "test.any-waiter", version: 1, initial: { _ in HarnessTaskCheckpoint() }, phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                try await runtime.wait(on: task.input, policy: policy,
                    checkpoint: JSONValue(encoding: HarnessTaskCheckpoint(phase: .joined)), context: context)
            case .joined:
                let wake = try #require(try task.record.state.wakeReason())
                try await runtime.commit({ _, _ in
                    .terminal(outcome: .completed(result: try JSONValue(encoding: wake)))
                }, context: context)
            }
        }, abort: { _, runtime, context in
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "test")) }, context: context)
        })
    }

    private func startParent(_ harness: Harness, _ parent: HarnessTestTask) async throws -> (TaskID, [TaskID]) {
        let root = try await harness.root(context: .background)
        let id = try await harnessStart(root, parent)
        try harness.resume()
        try await harnessEventually { !harness.wake().active }
        let inspection = try await harness.inspect(context: .background)
        let waiter = try #require(inspection.tasks.first { $0.record.id == id })
        guard case .waiting(let on) = waiter.state, on.count == 2 else {
            throw TaskDefinitionError("Expected the parent to wait on two tasks")
        }
        for child in on {
            let record = try await harness.getTask(id: child, context: .background)
            #expect(record?.state.status == "sleeping")
        }
        #expect(harness.tasks.state.withLock { $0.invocations.isEmpty })
        return (id, on)
    }
}
